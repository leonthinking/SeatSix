import AppKit
import Foundation
import SeatSixCore
import SeatSixPlayback

/// Private, opt-in real-server verification. Subtitle text, frames, authenticated
/// URLs and catalog identities never enter this report. Exploratory seeks happen
/// before a reporting session, then return to the user's original position.
@MainActor
enum TrackProbe {
    static func verify(client: MediaServerClient, item: MediaItem) async throws -> [String: Any] {
        _ = NSApplication.shared
        let original = Double(item.userData.playbackPositionTicks) / 10_000_000
        let plan = try await client.playbackPlan(item: item, startTicks: item.userData.playbackPositionTicks, capability: .localDecoder)
        guard plan.method == .directPlay else { throw ProbeFailure(message: "音轨字幕验证不允许触发服务器转码") }
        let relay = PinnedPlaybackRelay(sourceURL: plan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        var reporter: PlaybackReporter?
        var resumedEngine: LocalPlaybackEngine?
        var resumedRelay: PinnedPlaybackRelay?
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixTrackProbe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await engine.load(url: relay.start(), startSeconds: original)
            try await eventually { engine.snapshot.audioTracks.count >= 2 && !engine.snapshot.subtitleTracks.isEmpty }
            let audioTracks = engine.snapshot.audioTracks
            let embedded = engine.snapshot.subtitleTracks.filter { !$0.isExternal }
            let secondAudio = audioTracks[1]
            let pausedAt = engine.snapshot.seconds
            try await engine.selectAudioTrack(id: secondAudio.id)
            try await settledPause(engine, at: pausedAt)
            guard engine.snapshot.selectedAudioTrackID == secondAudio.id else { throw ProbeFailure(message: "第二音轨未实际选中") }

            // One representative for each codec, rather than conflating server
            // stream indices with libmpv IDs or trusting IsTextSubtitleStream.
            var codecs = Set<String>()
            let representatives = embedded.filter { codecs.insert($0.codec ?? "unknown").inserted }
            var embeddedResults: [[String: Any]] = []
            for track in representatives {
                embeddedResults.append(try await verifyEmbedded(engine, track: track, original: original))
            }
            try await engine.seek(to: original)
            var externalResults: [[String: Any]] = []
            var externalPresentation: [String: Any] = [:]
            for (ext, contents, marker) in artificialSubtitles {
                let file = directory.appendingPathComponent("verification." + ext)
                guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]) else {
                    throw ProbeFailure(message: "无法建立人工字幕测试样本")
                }
                let position = engine.snapshot.seconds
                let track = try await engine.addExternalSubtitle(url: file)
                try await eventually { engine.snapshot.subtitleText?.contains(marker) == true }
                let evidence = try await compareSubtitleRendering(engine, trackID: track.id)
                try await settledPause(engine, at: position)
                guard track.isExternal, evidence.verified else { throw ProbeFailure(message: "外挂字幕未产生可验证的画面叠加") }
                externalResults.append(["format": ext, "selected": true, "textObserved": true, "renderVerified": true,
                                        "offFrameRestored": evidence.offRestored, "pausedPositionPreserved": true])
                if ext == "srt" {
                    externalPresentation = try await SubtitleSettingsProbe.textRendering(engine, trackID: track.id)
                }
            }
            let artificialDelay = try await SubtitleSettingsProbe.artificialDelay(engine, directory: directory, original: original)
            try await engine.applySubtitlePresentation(SubtitlePresentation())
            try await engine.selectSubtitleTrack(id: nil)
            try await settledPause(engine, at: original)
            guard engine.snapshot.selectedSubtitleTrackID == nil else { throw ProbeFailure(message: "关闭字幕未生效") }

            // Only genuine viewing at the original position is reported. A
            // failed subtitle scan must never advance the user's resume point.
            let report = PlaybackReporter(client: client, plan: plan)
            reporter = report
            try await report.start(positionTicks: ticks(engine.snapshot.seconds))
            engine.play()
            let audioAdvance = try await verifyAudioAdvance(engine, original: original)
            let decodedAudioCodec = engine.snapshot.audioCodec ?? "unknown"
            guard engine.snapshot.selectedAudioTrackID == secondAudio.id else {
                throw ProbeFailure(message: "实际播放时第二音轨选择发生意外变化")
            }
            engine.pause()
            try await eventually { engine.snapshot.paused }
            let saved = engine.snapshot.seconds
            try await report.progress(positionTicks: ticks(saved), isPaused: true)
            try await report.stop(positionTicks: ticks(saved))
            engine.shutdown()
            await relay.stop()
            let remote = try await client.item(id: item.id)
            let remoteSeconds = Double(remote.userData.playbackPositionTicks) / 10_000_000
            guard abs(saved - remoteSeconds) < 2, remoteSeconds >= original - 1 else {
                throw ProbeFailure(message: "音轨字幕切换后服务器续播位置不一致")
            }
            let nextPlan = try await client.playbackPlan(item: remote, startTicks: remote.userData.playbackPositionTicks, capability: .localDecoder)
            guard nextPlan.method == .directPlay else { throw ProbeFailure(message: "续播意外触发服务器转码") }
            let nextRelay = PinnedPlaybackRelay(sourceURL: nextPlan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
            resumedRelay = nextRelay
            let next = try LocalPlaybackEngine()
            resumedEngine = next
            next.setVolume(0)
            try await next.load(url: nextRelay.start(), startSeconds: remoteSeconds)
            let resumed = next.snapshot.seconds
            guard abs(resumed - remoteSeconds) < 1.1, next.snapshot.paused else { throw ProbeFailure(message: "切换音轨后新引擎续播加载位置不一致") }
            next.shutdown()
            await nextRelay.stop()
            return ["engine": "libmpv", "actualMethod": plan.method.rawValue, "serverTranscoding": false,
                    "pinnedTransport": client.connection.certificatePin != nil,
                    "audioTrackCount": audioTracks.count, "embeddedSubtitleCount": embedded.count,
                    "secondAudioSelected": true, "audioCodec": decodedAudioCodec,
                    "audioAdvancedSeconds": audioAdvance, "audioSwitchPreservedPauseAndPosition": true,
                    "embeddedSubtitles": embeddedResults,
                    "embeddedRenderingPassed": !embeddedResults.isEmpty && embeddedResults.allSatisfy { $0["renderVerified"] as? Bool == true },
                    "externalSubtitles": externalResults, "subtitlesOffPassed": true,
                    "subtitlePresentation": ["artificialDelay": artificialDelay, "externalText": externalPresentation,
                        "passed": SubtitleSettingsProbe.presentationPassed(embedded: embeddedResults,
                            externalText: externalPresentation, artificialDelay: artificialDelay)],
                    "originalSeconds": original, "savedSeconds": saved, "remoteSeconds": remoteSeconds,
                    "resumedSeconds": resumed, "resumePassed": true]
        } catch {
            engine.pause()
            if let reporter, await reporter.status() == .reporting {
                try? await reporter.stop(positionTicks: ticks(max(original, engine.snapshot.seconds)))
            }
            engine.shutdown()
            resumedEngine?.shutdown()
            await relay.stop()
            await resumedRelay?.stop()
            throw error
        }
    }

    private static func verifyEmbedded(_ engine: LocalPlaybackEngine, track: LocalPlaybackTrack, original: Double) async throws -> [String: Any] {
        let duration = engine.snapshot.duration ?? original + 180
        var attempts = 0
        var textObserved = false
        var lastVisibleResult: [String: Any]?
        for position in candidatePositions(original: original, duration: duration) {
            try await engine.selectSubtitleTrack(id: track.id)
            try await engine.seek(to: position)
            try await Task.sleep(for: .milliseconds(400))
            attempts += 1
            textObserved = textObserved || engine.snapshot.subtitleText?.isEmpty == false
            let evidence = try await compareSubtitleRendering(engine, trackID: track.id)
            try await settledPause(engine, at: position)
            if evidence.verified {
                let presentation = try await SubtitleSettingsProbe.embedded(engine, track: track)
                let result: [String: Any] = ["codec": track.codec ?? "unknown", "selected": true, "renderVerified": true,
                        "textObserved": textObserved, "offFrameRestored": evidence.offRestored,
                        "pausedPositionPreserved": true, "sampleSeconds": position, "sampleAttempts": attempts,
                        "presentation": presentation]
                if SubtitleSettingsProbe.hasDelayEvidence(presentation) { return result }
                // A static opening title can remain identical throughout the
                // entire delay range. Keep scanning the same bounded list for
                // changing dialogue instead of treating first visibility as
                // proof that presentation timing works.
                lastVisibleResult = result
            }
        }
        if var lastVisibleResult {
            lastVisibleResult["sampleAttempts"] = attempts
            lastVisibleResult["reason"] = "no_time_varying_cue_in_bounded_scan"
            return lastVisibleResult
        }
        // Some films have no cues near the current viewing position. Preserve
        // that distinction rather than calling selection proof of rendering.
        return ["codec": track.codec ?? "unknown", "selected": true, "renderVerified": false,
                "textObserved": textObserved, "sampleAttempts": attempts, "reason": "no_visible_cue_in_bounded_scan"]
    }

    /// Resume-relative samples alone can miss every short cue as the resume
    /// point advances. Keep a small, repeatable set of early-dialogue anchors
    /// as well. These seeks remain outside the reporting session.
    static func candidatePositions(original: Double, duration: Double) -> [Double] {
        let end = duration.isFinite ? max(0, duration - 1) : 300
        let start = original.isFinite ? max(0, original) : 0
        let candidates = [0.0, 2, 5, 10, 20, 35, 60, 90, 120].map { start + $0 }
            + [60, 90, 120, 156, 180, 300]
        var seen = Set<Double>()
        return candidates.map { min($0, end) }.filter { seen.insert($0).inserted }
    }

    private static func compareSubtitleRendering(_ engine: LocalPlaybackEngine, trackID: Int) async throws -> (verified: Bool, offRestored: Bool) {
        try await engine.selectSubtitleTrack(id: nil)
        try await Task.sleep(for: .milliseconds(150))
        let clean = try engine.captureFrameEvidence()
        try await engine.selectSubtitleTrack(id: trackID)
        try await Task.sleep(for: .milliseconds(200))
        let captioned = try engine.captureFrameEvidence()
        try await engine.selectSubtitleTrack(id: nil)
        try await Task.sleep(for: .milliseconds(150))
        let cleanAgain = try engine.captureFrameEvidence()
        let restored = clean.sampleSHA256 == cleanAgain.sampleSHA256
        return (restored && captioned.sampleSHA256 != clean.sampleSHA256, restored)
    }

    private static func settledPause(_ engine: LocalPlaybackEngine, at position: Double) async throws {
        try await Task.sleep(for: .milliseconds(150))
        guard engine.snapshot.paused, abs(engine.snapshot.seconds - position) < 0.2 else {
            throw ProbeFailure(message: "切换音轨或字幕改变了暂停状态或播放位置")
        }
    }

    private static func verifyAudioAdvance(_ engine: LocalPlaybackEngine, original: Double) async throws -> Double {
        var baseline: Double?
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard engine.snapshot.failure == nil else { throw ProbeFailure(message: "切换音轨后解码中断") }
            let state = engine.snapshot
            if state.seconds > original + 0.2, let pts = state.audioPTS, pts > 0,
               state.audioOutput != nil, state.audioOutput != "null", (state.audioSampleRate ?? 0) > 0 {
                if baseline == nil || pts < baseline! { baseline = pts }
                if state.seconds > original + 1.2, pts - baseline! > 0.4 { return pts - baseline! }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
        throw ProbeFailure(message: "切换后的音轨未确认实际音频时钟推进")
    }

    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ProbeFailure(message: "音轨或字幕状态未在时限内确认") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func ticks(_ seconds: Double) -> Int64 {
        seconds.isFinite ? Int64(max(0, min(seconds, 1_000_000_000)) * 10_000_000) : 0
    }

    private static var artificialSubtitles: [(String, String, String)] {
        let marker = "SeatSix external subtitle verification"
        return [
            ("srt", "1\n00:00:00,000 --> 23:59:59,000\n\(marker) SRT\n", marker + " SRT"),
            ("ass", """
            [Script Info]
            ScriptType: v4.00+
            PlayResX: 1280
            PlayResY: 720
            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,20,20,20,1
            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            Dialogue: 0,0:00:00.00,23:59:59.00,Default,,0,0,0,,\(marker) ASS

            """, marker + " ASS"),
            ("vtt", "WEBVTT\n\n00:00:00.000 --> 23:59:59.000\n\(marker) VTT\n", marker + " VTT")
        ]
    }
}
