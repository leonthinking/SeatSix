import AppKit
import Foundation
import SeatSixCore
import SeatSixPlayback

/// Uses the same renderer as the application. No frame files or authenticated URLs are written.
@MainActor
enum LocalDecoderProbe {
    struct Observation {
        let engine: LocalPlaybackEngine
        let frame: DecodedFrameEvidence
        let start: Double
        let advance: Double
        let audioAdvance: Double
    }

    static func play(url: URL, start: Double) async throws -> Observation {
        _ = NSApplication.shared
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        do {
            try await engine.load(url: url, startSeconds: start)
            let actual = engine.snapshot.seconds
            guard abs(actual - start) < 1.1 else { throw ProbeFailure(message: "本地解码续播位置不一致") }
            engine.play()
            let frame = try await advancingFrame(engine, baseline: actual)
            return Observation(engine: engine, frame: frame.frame, start: actual, advance: engine.snapshot.seconds - actual, audioAdvance: frame.audioAdvance)
        } catch { engine.shutdown(); throw error }
    }

    private static func advancingFrame(_ engine: LocalPlaybackEngine, baseline: Double) async throws -> (frame: DecodedFrameEvidence, audioAdvance: Double) {
        let deadline = ContinuousClock.now + .seconds(35)
        var audioBaseline: Double?
        while ContinuousClock.now < deadline {
            if engine.snapshot.failure != nil { throw ProbeFailure(message: "本地视频解码中断") }
            let state = engine.snapshot
            if state.seconds - baseline > 0.2, let pts = state.audioPTS, pts > 0, state.audioOutput != "null", state.audioOutput != nil {
                if audioBaseline == nil || pts < audioBaseline! { audioBaseline = pts }
                let audioAdvance = pts - audioBaseline!
                if state.seconds - baseline > 1.2, audioAdvance > 0.35,
                   let frame = try? engine.captureFrameEvidence(), frame.nonBlackPixelCount > 10 {
                    return (frame, audioAdvance)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ProbeFailure(message: "本地引擎未在时限内输出有效画面并推进")
    }

    static func verify(client: MediaServerClient, item: MediaItem) async throws -> [String: Any] {
        let original = Double(item.userData.playbackPositionTicks) / 10_000_000
        let plan = try await client.playbackPlan(item: item, startTicks: item.userData.playbackPositionTicks, capability: .localDecoder)
        guard plan.method == .directPlay else { throw ProbeFailure(message: "本地解码不应触发服务器转码") }
        let relay = PinnedPlaybackRelay(sourceURL: plan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
        var first: LocalPlaybackEngine?
        var second: LocalPlaybackEngine?
        var nextRelay: PinnedPlaybackRelay?
        var reporter: PlaybackReporter?
        var nextReporter: PlaybackReporter?
        do {
            let url = try await relay.start()
            let observation = try await play(url: url, start: original)
            let engine = observation.engine; first = engine
            let report = PlaybackReporter(client: client, plan: plan); reporter = report
            try await report.start(positionTicks: ticks(engine.snapshot.seconds))
            engine.pause()
            let pausedAt = engine.snapshot.seconds
            try await Task.sleep(for: .milliseconds(300))
            guard engine.snapshot.paused, abs(engine.snapshot.seconds - pausedAt) < 0.1 else { throw ProbeFailure(message: "本地暂停后时钟仍在前进") }
            try await report.progress(positionTicks: ticks(pausedAt), isPaused: true)
            // Exercise a genuine Range seek without marking the film watched.
            let proposed = original == 0 ? 75.0 : original + 15.0
            let target = min(proposed, max(0, (engine.snapshot.duration ?? item.durationSeconds) - 30))
            try await engine.seek(to: target)
            let seekPosition = engine.snapshot.seconds
            guard abs(seekPosition - target) < 1.1 else { throw ProbeFailure(message: "本地跳转位置不正确") }
            try await report.progress(positionTicks: ticks(seekPosition), isPaused: true)
            engine.play()
            let seekFrame = try await advancingFrame(engine, baseline: seekPosition)
            let audio = engine.snapshot
            guard audio.audioCodec != nil, (audio.audioSampleRate ?? 0) > 0, (audio.audioChannels ?? 0) > 0 else {
                throw ProbeFailure(message: "未确认音轨解码输出")
            }
            engine.pause()
            let saved = engine.snapshot.seconds
            try await report.stop(positionTicks: ticks(saved))
            engine.shutdown(); first = nil
            await relay.stop()
            let remote = try await client.item(id: item.id)
            let remoteSeconds = Double(remote.userData.playbackPositionTicks) / 10_000_000
            guard abs(saved - remoteSeconds) < 2 else { throw ProbeFailure(message: "停止后的服务器位置不一致") }
            let nextPlan = try await client.playbackPlan(item: remote, startTicks: remote.userData.playbackPositionTicks, capability: .localDecoder)
            guard nextPlan.method == .directPlay else { throw ProbeFailure(message: "续播意外触发转码") }
            let relay2 = PinnedPlaybackRelay(sourceURL: nextPlan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
            nextRelay = relay2
            let resumed = try await play(url: relay2.start(), start: remoteSeconds)
            second = resumed.engine
            let report2 = PlaybackReporter(client: client, plan: nextPlan); nextReporter = report2
            try await report2.start(positionTicks: ticks(resumed.engine.snapshot.seconds))
            resumed.engine.pause()
            let final = resumed.engine.snapshot.seconds
            try await report2.stop(positionTicks: ticks(final))
            resumed.engine.shutdown(); second = nil
            await relay2.stop()
            let finalItem = try await client.item(id: item.id)
            let finalRemote = Double(finalItem.userData.playbackPositionTicks) / 10_000_000
            guard abs(final - finalRemote) < 2 else { throw ProbeFailure(message: "续播停止后服务器位置不一致") }
            return ["engine": "libmpv", "actualMethod": plan.method.rawValue, "serverTranscoding": false,
                    "frameWidth": seekFrame.frame.width, "frameHeight": seekFrame.frame.height,
                    "nonBlackPixelCount": seekFrame.frame.nonBlackPixelCount, "videoCodec": audio.videoCodec ?? "unknown",
                    "audioCodec": audio.audioCodec ?? "unknown", "audioSampleRate": audio.audioSampleRate ?? 0,
                    "audioChannels": audio.audioChannels ?? 0, "audioOutput": audio.audioOutput ?? "unknown", "audioAdvancedSeconds": seekFrame.audioAdvance, "hardwareDecoder": audio.hardwareDecoder ?? "software",
                    "playbackAdvancedSeconds": observation.advance, "originalSeconds": original,
                    "pausePassed": true, "seekTargetSeconds": target, "seekActualSeconds": seekPosition,
                    "savedSeconds": saved, "remoteSeconds": remoteSeconds, "resumedSeconds": resumed.start,
                    "resumeAdvancedSeconds": resumed.advance, "finalSavedSeconds": final, "finalRemoteSeconds": finalRemote,
                    "pinnedTransport": client.connection.certificatePin != nil]
        } catch {
            // Finish established sessions once, even if rendering fails after login.
            if let first { first.pause(); if let reporter, await reporter.status() == .reporting { try? await reporter.stop(positionTicks: ticks(first.snapshot.seconds)) }; first.shutdown() }
            if let second { second.pause(); if let nextReporter, await nextReporter.status() == .reporting { try? await nextReporter.stop(positionTicks: ticks(second.snapshot.seconds)) }; second.shutdown() }
            await relay.stop(); await nextRelay?.stop()
            throw error
        }
    }

    static func verifyFiles(arguments: [String]) async {
        guard arguments.count >= 2 else { print("Usage: SeatSixProbe --local-files REPORT FILE..."); exit(2) }
        var results: [[String: Any]] = []
        for (index, path) in arguments.dropFirst().enumerated() {
            var engine: LocalPlaybackEngine?
            do {
                let decoded = try await play(url: URL(fileURLWithPath: path), start: 2)
                engine = decoded.engine
                decoded.engine.pause()
                let paused = decoded.engine.snapshot.seconds
                try await Task.sleep(for: .milliseconds(250))
                guard abs(decoded.engine.snapshot.seconds - paused) < 0.1 else { throw ProbeFailure(message: "暂停失败") }
                try await decoded.engine.seek(to: 8)
                let sought = decoded.engine.snapshot.seconds
                decoded.engine.play()
                let frame = try await advancingFrame(decoded.engine, baseline: sought)
                let state = decoded.engine.snapshot
                guard (state.audioSampleRate ?? 0) > 0 else { throw ProbeFailure(message: "音频解码未确认") }
                results.append(["case": index + 1, "success": true, "width": frame.frame.width, "height": frame.frame.height,
                                "videoCodec": state.videoCodec ?? "", "audioCodec": state.audioCodec ?? "",
                                "audioSampleRate": state.audioSampleRate ?? 0, "audioChannels": state.audioChannels ?? 0,
                                "hardwareDecoder": state.hardwareDecoder ?? "software", "seekSeconds": sought,
                                "nonBlackPixelCount": frame.frame.nonBlackPixelCount, "audioAdvanceSeconds": frame.audioAdvance, "audioOutput": state.audioOutput ?? "unknown", "advanceSeconds": decoded.advance])
            } catch { results.append(["case": index + 1, "success": false, "message": "本地样片解码、暂停或跳转未通过"]) }
            engine?.shutdown()
        }
        do {
            try PrivateReportWriter.write(JSONSerialization.data(withJSONObject: ["generatedAt": ISO8601DateFormatter().string(from: Date()), "cases": results], options: [.prettyPrinted, .sortedKeys]), to: URL(fileURLWithPath: arguments[0]))
        } catch { print("Unable to write local decoder report"); exit(1) }
        let passed = results.allSatisfy { $0["success"] as? Bool == true }
        print(passed ? "Local decoder file verification passed." : "Local decoder file verification failed; inspect the local report.")
        if !passed { exit(1) }
    }

    private static func ticks(_ seconds: Double) -> Int64 {
        seconds.isFinite ? Int64(max(0, min(seconds, 1_000_000_000)) * 10_000_000) : 0
    }
}
