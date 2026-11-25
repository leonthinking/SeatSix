import Foundation
import SeatSixPlayback

/// Opt-in pixel evidence collected only while the movie is paused and before
/// its reporting session. The report contains no subtitle text or frame data.
@MainActor
enum SubtitleSettingsProbe {
    struct DelaySample: Equatable {
        let early: Double
        let late: Double
        let cueStart: Double
        let cueEnd: Double
        let amount: Double
    }

    static func delaySample(original: Double, duration: Double) -> DelaySample? {
        guard duration.isFinite, duration >= 14 else { return nil }
        let position = original.isFinite ? max(0, original) : 0
        let base = min(position, duration - 14)
        return DelaySample(early: base + 1, late: base + 11,
                           cueStart: base + 5, cueEnd: base + 7, amount: 5)
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        let milliseconds = Int64((max(0, min(seconds.isFinite ? seconds : 0, 1_000_000_000)) * 1_000).rounded())
        return String(format: "%02lld:%02lld:%02lld,%03lld", milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60, milliseconds / 1_000 % 60, milliseconds % 1_000)
    }

    static func isBitmap(codec: String?) -> Bool {
        guard let codec else { return false }
        return ["hdmv_pgs_subtitle", "pgs", "dvd_subtitle", "dvdsub", "dvb_subtitle", "xsub"]
            .contains(codec.lowercased())
    }

    static func delayEvidence(clean: String, original: String, delayed: String, restored: String) -> String? {
        guard original != clean, delayed != original, restored == original else { return nil }
        return delayed == clean ? "cue_hidden" : "cue_changed"
    }

    static func hasDelayEvidence(_ presentation: [String: Any]) -> Bool {
        presentation["delayVerified"] as? Bool == true
            && ["cue_hidden", "cue_changed"].contains(presentation["delayEvidence"] as? String ?? "")
    }

    static func presentationPassed(embedded: [[String: Any]], externalText: [String: Any], artificialDelay: [String: Any]) -> Bool {
        guard !embedded.isEmpty, externalText["passed"] as? Bool == true,
              artificialDelay["passed"] as? Bool == true else { return false }
        return embedded.allSatisfy { result in
            guard result["renderVerified"] as? Bool == true,
                  let presentation = result["presentation"] as? [String: Any],
                  hasDelayEvidence(presentation),
                  presentation["pausedPositionPreserved"] as? Bool == true else { return false }
            switch presentation["kind"] as? String {
            case "bitmap": return presentation["fontSizeApplicable"] as? Bool == false
            case "text": return (presentation["textRendering"] as? [String: Any])?["passed"] as? Bool == true
            default: return false
            }
        }
    }

    static func embedded(_ engine: LocalPlaybackEngine, track: LocalPlaybackTrack) async throws -> [String: Any] {
        let pausedAt = engine.snapshot.seconds
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        try await engine.selectSubtitleTrack(id: nil)
        let clean = try await frame(engine)
        try await engine.selectSubtitleTrack(id: track.id)
        let original = try await frame(engine)
        var verifiedDelay: Double?
        var verifiedEvidence: String?
        // At this fixed paused video frame, either a disappearing cue or a
        // different rendered cue proves that the delay changes presentation.
        // Reset must restore the exact original pixels; property replies alone
        // cannot satisfy this check, including for bitmap subtitles.
        for amount in [1.0, -1, 2, -2, 4, -4, 8, -8, 15, -15, 30, -30] {
            try await engine.applySubtitlePresentation(SubtitlePresentation(delaySeconds: amount))
            let delayed = try await frame(engine)
            try verifyPause(engine, at: pausedAt)
            if delayed != original {
                try await engine.applySubtitlePresentation(SubtitlePresentation())
                let restored = try await frame(engine)
                try verifyPause(engine, at: pausedAt)
                if let evidence = delayEvidence(clean: clean, original: original, delayed: delayed, restored: restored) {
                    verifiedDelay = amount
                    verifiedEvidence = evidence
                    break
                }
            }
        }
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        let bitmap = isBitmap(codec: track.codec)
        var result: [String: Any] = ["kind": bitmap ? "bitmap" : "text", "delayVerified": verifiedDelay != nil,
                                    "fontSizeApplicable": !bitmap]
        if let verifiedDelay { result["delaySeconds"] = verifiedDelay }
        if let verifiedEvidence { result["delayEvidence"] = verifiedEvidence }
        else { result["delayReason"] = "no_cue_change_in_bounded_delay_scan" }
        if !bitmap {
            result["textRendering"] = try await textRendering(engine, trackID: track.id)
        }
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        try await engine.selectSubtitleTrack(id: nil)
        try verifyPause(engine, at: pausedAt)
        result["pausedPositionPreserved"] = true
        return result
    }

    static func textRendering(_ engine: LocalPlaybackEngine, trackID: Int) async throws -> [String: Any] {
        let pausedAt = engine.snapshot.seconds
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        try await engine.selectSubtitleTrack(id: nil)
        let clean = try await frame(engine)
        try await engine.selectSubtitleTrack(id: trackID)
        let original = try await frame(engine)
        try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 48, style: .outlined))
        let outlined = try await frame(engine)
        try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 72, style: .outlined))
        let larger = try await frame(engine)
        try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 48, style: .boxed))
        let boxed = try await frame(engine)
        try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 48, style: .yellow))
        let yellow = try await frame(engine)
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        let restored = try await frame(engine)
        try await engine.selectSubtitleTrack(id: nil)
        let cleanAgain = try await frame(engine)
        try verifyPause(engine, at: pausedAt)
        let fontSizeVerified = outlined != clean && larger != clean && larger != outlined
        let stylesVerified = Set([outlined, boxed, yellow]).count == 3 && ![outlined, boxed, yellow].contains(clean)
        let originalRestored = restored == original && original != clean
        let offRestored = clean == cleanAgain
        return ["fontSizeVerified": fontSizeVerified, "fontSizesTested": [48, 72],
                "stylesVerified": stylesVerified, "stylesTested": ["outlined", "boxed", "yellow"],
                "originalStyleRestored": originalRestored, "offFrameRestored": offRestored,
                "pausedPositionPreserved": true,
                "passed": fontSizeVerified && stylesVerified && originalRestored && offRestored]
    }

    static func artificialDelay(_ engine: LocalPlaybackEngine, directory: URL, original: Double) async throws -> [String: Any] {
        guard let sample = delaySample(original: original, duration: engine.snapshot.duration ?? 0) else {
            return ["passed": false, "reason": "media_too_short_for_directional_delay_probe"]
        }
        let marker = "SeatSix subtitle timing verification"
        let contents = "1\n\(srtTimestamp(sample.cueStart)) --> \(srtTimestamp(sample.cueEnd))\n\(marker)\n"
        let file = directory.appendingPathComponent("timing-verification.srt")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(contents.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ProbeFailure(message: "无法建立字幕延迟测试样本")
        }
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        let track = try await engine.addExternalSubtitle(url: file)
        var results: [Bool] = []
        for (position, delay) in [(sample.early, -sample.amount), (sample.late, sample.amount)] {
            try await engine.seek(to: position)
            try await engine.applySubtitlePresentation(SubtitlePresentation())
            let clean = try await frame(engine)
            let absentInitially = engine.snapshot.subtitleText?.contains(marker) != true
            try await engine.applySubtitlePresentation(SubtitlePresentation(delaySeconds: delay))
            let captioned = try await frame(engine)
            let textObserved = engine.snapshot.subtitleText?.contains(marker) == true
            try await engine.applySubtitlePresentation(SubtitlePresentation())
            let cleanAgain = try await frame(engine)
            let absentAfterReset = engine.snapshot.subtitleText?.contains(marker) != true
            try verifyPause(engine, at: position)
            results.append(absentInitially && absentAfterReset && textObserved && clean != captioned && clean == cleanAgain)
        }
        try await engine.selectSubtitleTrack(id: nil)
        try await engine.seek(to: original)
        return ["negativeDelayVerified": results[0], "positiveDelayVerified": results[1],
                "delayMagnitudeSeconds": sample.amount, "pausedPositionPreserved": true,
                "externalTrackSelected": track.isExternal, "passed": results.allSatisfy { $0 }]
    }

    private static func frame(_ engine: LocalPlaybackEngine) async throws -> String {
        try await Task.sleep(for: .milliseconds(180))
        return try engine.captureFrameEvidence().sampleSHA256
    }

    private static func verifyPause(_ engine: LocalPlaybackEngine, at position: Double) throws {
        guard engine.snapshot.paused, abs(engine.snapshot.seconds - position) < 0.2 else {
            throw ProbeFailure(message: "字幕外观或延迟设置改变了暂停状态或播放位置")
        }
    }
}
