import AppKit
import Foundation
import SeatSixCore
import SeatSixPlayback

/// Reports only scalar decoder evidence. Network URLs, media identities, frame
/// pixels and credentials never enter this result. Uses the existing resume
/// point and reports only the short playback actually performed by this probe.
@MainActor
enum PlaybackExperienceProbe {
    static let testedRates: [Double] = [0.5, 1, 1.5, 2]

    /// Reserve the full warm-up timeout, maximum accepted sample duration and
    /// scheduling margin at every rate, plus a final safety margin before EOF.
    static func requiredRemainingSeconds(for rates: [Double]) -> Double {
        rates.reduce(0, +) * (8 + 6 + 1) + 5
    }

    struct RateMeasurement {
        var requestedRate: Double
        var actualRate: Double
        var wallSeconds: Double
        var mediaAdvancedSeconds: Double
        var audioAdvancedSeconds: Double
        var renderedFrames: UInt64
        var nonBlackPixelCount: Int
        var audioOutputPresent: Bool
        var pitchCorrectionEnabled: Bool
        var pausePreserved: Bool
        var seekPreserved: Bool

        var mediaRatio: Double { mediaAdvancedSeconds / wallSeconds }
        var audioRatio: Double { audioAdvancedSeconds / wallSeconds }
        var passed: Bool {
            guard requestedRate.isFinite, PlaybackRate.allowedRange.contains(requestedRate),
                  actualRate.isFinite, abs(actualRate - requestedRate) < 0.0001,
                  wallSeconds.isFinite, (2...6).contains(wallSeconds),
                  mediaAdvancedSeconds.isFinite, audioAdvancedSeconds.isFinite else { return false }
            return abs(mediaRatio - requestedRate) <= max(0.1, requestedRate * 0.15)
                && abs(audioRatio - requestedRate) <= max(0.15, requestedRate * 0.2)
                && audioAdvancedSeconds > 0.2 && renderedFrames > 0 && nonBlackPixelCount > 10
                && audioOutputPresent && pitchCorrectionEnabled && pausePreserved && seekPreserved
        }

        var report: [String: Any] {
            ["requestedRate": requestedRate, "actualRate": actualRate, "wallSeconds": wallSeconds,
             "mediaAdvancedSeconds": mediaAdvancedSeconds, "audioAdvancedSeconds": audioAdvancedSeconds,
             "mediaClockRatio": mediaRatio, "audioClockRatio": audioRatio, "renderedFrames": renderedFrames,
             "nonBlackPixelCount": nonBlackPixelCount, "audioOutputPresent": audioOutputPresent,
             "pitchCorrectionEnabled": pitchCorrectionEnabled, "pausePreserved": pausePreserved,
             "seekPreservedRate": seekPreserved, "passed": passed]
        }
    }

    static func measurementsPassed(_ measurements: [RateMeasurement]) -> Bool {
        measurements.map(\.requestedRate) == testedRates && measurements.allSatisfy(\.passed)
    }

    static func verify(client: MediaServerClient, item: MediaItem) async throws -> [String: Any] {
        _ = NSApplication.shared
        let original = Double(item.userData.playbackPositionTicks) / 10_000_000
        let plan = try await client.playbackPlan(item: item, startTicks: item.userData.playbackPositionTicks, capability: .localDecoder)
        guard plan.method == .directPlay else { throw ProbeFailure(message: "倍速验证不允许触发服务器转码") }
        let relay = PinnedPlaybackRelay(sourceURL: plan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        var reporter: PlaybackReporter?
        var resumedEngine: LocalPlaybackEngine?
        var resumedRelay: PinnedPlaybackRelay?
        do {
            try await engine.load(url: relay.start(), startSeconds: original)
            guard abs(engine.snapshot.seconds - original) < 1.1, engine.snapshot.paused else {
                throw ProbeFailure(message: "倍速验证加载的续播位置不一致")
            }
            // Refuse to move the user's position elsewhere merely to obtain a
            // longer sample when the remaining duration is insufficient.
            guard (engine.snapshot.duration ?? item.durationSeconds) - original > requiredRemainingSeconds(for: testedRates) else {
                throw ProbeFailure(message: "影片剩余时长不足以完成倍速验证，请选择另一部影片")
            }
            let report = PlaybackReporter(client: client, plan: plan)
            reporter = report
            try await report.start(positionTicks: ticks(engine.snapshot.seconds))
            var measurements: [RateMeasurement] = []
            for (index, rate) in testedRates.enumerated() {
                guard (engine.snapshot.duration ?? item.durationSeconds) - engine.snapshot.seconds
                    > requiredRemainingSeconds(for: Array(testedRates[index...])) else {
                    throw ProbeFailure(message: "影片剩余时长不足以安全完成余下倍速验证")
                }
                let measurement = try await measure(engine, rate: rate)
                measurements.append(measurement)
                try await report.progress(positionTicks: ticks(engine.snapshot.seconds), isPaused: true)
            }
            let state = engine.snapshot
            let saved = state.seconds
            try await report.stop(positionTicks: ticks(saved))
            engine.shutdown()
            await relay.stop()
            let remote = try await client.item(id: item.id)
            let remoteSeconds = Double(remote.userData.playbackPositionTicks) / 10_000_000
            guard abs(saved - remoteSeconds) < 2 else { throw ProbeFailure(message: "倍速播放后的服务器续播位置不一致") }
            let nextPlan = try await client.playbackPlan(item: remote, startTicks: remote.userData.playbackPositionTicks, capability: .localDecoder)
            guard nextPlan.method == .directPlay else { throw ProbeFailure(message: "倍速验证后续播意外触发转码") }
            let nextRelay = PinnedPlaybackRelay(sourceURL: nextPlan.url, serverURL: client.connection.baseURL, certificatePin: client.connection.certificatePin)
            resumedRelay = nextRelay
            let next = try LocalPlaybackEngine()
            resumedEngine = next
            next.setVolume(0)
            try await next.load(url: nextRelay.start(), startSeconds: remoteSeconds)
            let resumed = next.snapshot.seconds
            let newEngineRate = next.snapshot.playbackRate
            let resumePassed = abs(resumed - remoteSeconds) < 1.1 && next.snapshot.paused && newEngineRate == 1
            next.shutdown()
            await nextRelay.stop()
            let passed = measurementsPassed(measurements) && resumePassed
            return ["engine": "libmpv", "actualMethod": plan.method.rawValue, "serverTranscoding": false,
                    "pinnedTransport": client.connection.certificatePin != nil,
                    "videoCodec": state.videoCodec ?? "unknown", "audioCodec": state.audioCodec ?? "unknown",
                    "frameWidth": state.videoWidth, "frameHeight": state.videoHeight,
                    "measurements": measurements.map(\.report), "rateMeasurementsPassed": measurementsPassed(measurements),
                    "originalSeconds": original, "savedSeconds": saved, "remoteSeconds": remoteSeconds,
                    "resumedSeconds": resumed, "newEnginePlaybackRate": newEngineRate,
                    "resumePassed": resumePassed, "passed": passed]
        } catch {
            engine.pause()
            if let reporter, await reporter.status() == .reporting {
                try? await reporter.stop(positionTicks: ticks(engine.snapshot.seconds))
            }
            engine.shutdown()
            resumedEngine?.shutdown()
            await relay.stop()
            await resumedRelay?.stop()
            throw error
        }
    }

    static func measure(_ engine: LocalPlaybackEngine, rate: Double) async throws -> RateMeasurement {
        engine.pause()
        let pausedAt = engine.snapshot.seconds
        try await engine.setPlaybackRate(rate)
        try await Task.sleep(for: .milliseconds(200))
        let pausePreserved = engine.snapshot.paused && abs(engine.snapshot.seconds - pausedAt) < 0.1
        // A real exact seek to the current position tests rate retention without
        // adding an artificial forward jump to the user's resume history.
        try await engine.seek(to: pausedAt)
        let seekPreserved = engine.snapshot.paused && abs(engine.snapshot.seconds - pausedAt) < 0.15
            && abs(engine.snapshot.playbackRate - rate) < 0.0001
        engine.play()
        try await waitForAdvancingAudio(engine)
        let before = engine.snapshot
        let initialFrames = engine.renderedFrameCount
        guard let audioStart = before.audioPTS else { throw ProbeFailure(message: "倍速验证未取得音频时钟") }
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(2500))
        engine.pause()
        let elapsed = started.duration(to: .now).components
        let wallSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let after = engine.snapshot
        guard after.failure == nil, !after.ended, let audioEnd = after.audioPTS else {
            throw ProbeFailure(message: "倍速采样期间播放中断或音频时钟不可用")
        }
        let frame = try engine.captureFrameEvidence()
        return RateMeasurement(requestedRate: rate, actualRate: after.playbackRate,
            wallSeconds: wallSeconds, mediaAdvancedSeconds: after.seconds - before.seconds,
            audioAdvancedSeconds: audioEnd - audioStart, renderedFrames: engine.renderedFrameCount - initialFrames,
            nonBlackPixelCount: frame.nonBlackPixelCount,
            audioOutputPresent: after.audioOutput != nil && after.audioOutput != "null",
            pitchCorrectionEnabled: after.audioPitchCorrectionEnabled,
            pausePreserved: pausePreserved, seekPreserved: seekPreserved)
    }

    private static func waitForAdvancingAudio(_ engine: LocalPlaybackEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        var baseline: Double?
        let frames = engine.renderedFrameCount
        while ContinuousClock.now < deadline {
            let state = engine.snapshot
            guard state.failure == nil, !state.ended else { throw ProbeFailure(message: "倍速播放未能开始") }
            if let pts = state.audioPTS, state.audioOutput != nil, state.audioOutput != "null",
               !state.buffering, abs(pts - state.seconds) < 0.5 {
                if let baseline, pts - baseline > 0.25, engine.renderedFrameCount > frames + 2 { return }
                if baseline == nil || pts < baseline! { baseline = pts }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        throw ProbeFailure(message: "倍速播放未在时限内输出连续音视频")
    }

    private static func ticks(_ seconds: Double) -> Int64 {
        seconds.isFinite ? Int64(max(0, min(seconds, 1_000_000_000)) * 10_000_000) : 0
    }
}
