import AppKit
import XCTest
@testable import SeatSixPlayback

@MainActor
final class PlaybackRateTests: XCTestCase {
    func testRateValidationRejectsNonFiniteAndOutOfRangeValues() throws {
        for rate in [Double.nan, .infinity, -.infinity, 0, 0.4999, 2.0001, -1] {
            XCTAssertThrowsError(try PlaybackRate.validate(rate)) { error in
                XCTAssertEqual(error as? LocalPlaybackError, .invalidPlaybackRate)
            }
        }
        for rate in PlaybackRate.presets + [0.6, 1.37] { try PlaybackRate.validate(rate) }
        XCTAssertEqual(PlaybackRate.presets, [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
    }

    func testRateAcknowledgementIsActualAndClosedEngineRejectsMutation() async throws {
        _ = NSApplication.shared
        let engine = try LocalPlaybackEngine()
        XCTAssertEqual(engine.snapshot.playbackRate, 1)
        for rate in PlaybackRate.presets {
            try await engine.setPlaybackRate(rate)
            XCTAssertEqual(engine.snapshot.playbackRate, rate)
            XCTAssertTrue(engine.snapshot.audioPitchCorrectionEnabled)
            XCTAssertTrue(engine.snapshot.paused)
        }
        do { try await engine.setPlaybackRate(.nan); XCTFail("Accepted invalid rate") }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .invalidPlaybackRate) }
        XCTAssertEqual(engine.snapshot.playbackRate, 2)
        engine.shutdown()
        do { try await engine.setPlaybackRate(1); XCTFail("Accepted speed change after shutdown") }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
    }

    func testRatePreservesPauseSeekAndReloadAndActuallyChangesMediaClock() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("motion.mkv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "30", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", movie.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runFixtureProcess(process)
        XCTAssertEqual(process.terminationStatus, 0)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 1)
        let paused = engine.snapshot.seconds
        try await engine.setPlaybackRate(2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, paused, accuracy: 0.1)
        try await engine.seek(to: 2)
        XCTAssertEqual(engine.snapshot.playbackRate, 2)
        XCTAssertTrue(engine.snapshot.paused)
        engine.play()
        let deadline = ContinuousClock.now + .seconds(5)
        while engine.snapshot.seconds < 2.5, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        let baseline = engine.snapshot.seconds
        let audioStart = try XCTUnwrap(engine.snapshot.audioPTS)
        let started = ContinuousClock.now
        try await Task.sleep(for: .milliseconds(1500))
        engine.pause()
        let elapsed = started.duration(to: .now).components
        let wall = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        XCTAssertEqual((engine.snapshot.seconds - baseline) / wall, 2, accuracy: 0.2)
        XCTAssertGreaterThan(try XCTUnwrap(engine.snapshot.audioPTS) - audioStart, 2.3)
        XCTAssertTrue(engine.snapshot.audioPitchCorrectionEnabled)
        try await engine.load(url: movie, startSeconds: 1)
        XCTAssertEqual(engine.snapshot.playbackRate, 2)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 1, accuracy: 0.15)
        // Anchor the elapsed-time bound while paused: seconds is a polled
        // snapshot, so sampling it during playback can predate the wall clock.
        let resumedBaseline = engine.snapshot.seconds
        let resumedClockStarted = ContinuousClock.now
        engine.play()
        let liveDeadline = ContinuousClock.now + .seconds(5)
        while engine.snapshot.seconds < 1.3, ContinuousClock.now < liveDeadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThanOrEqual(engine.snapshot.seconds, 1.3, "Speed must change during active playback")
        let beforeLiveChange = engine.snapshot.seconds
        try await engine.setPlaybackRate(0.5)
        let liveElapsed = resumedClockStarted.duration(to: .now).components
        let liveWall = Double(liveElapsed.seconds) + Double(liveElapsed.attoseconds) / 1e18
        XCTAssertFalse(engine.snapshot.paused, "Changing speed during playback must not pause")
        XCTAssertGreaterThanOrEqual(engine.snapshot.seconds - beforeLiveChange, -0.1)
        XCTAssertLessThanOrEqual(engine.snapshot.seconds - resumedBaseline, 2 * liveWall + 0.15)
        XCTAssertEqual(engine.snapshot.playbackRate, 0.5)
        engine.pause()
        let replacing = Task { try await engine.setPlaybackRate(1.5) }
        await Task.yield()
        try await engine.load(url: movie, startSeconds: 1)
        do { try await replacing.value }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .superseded) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertNil(engine.snapshot.failure)
        try await engine.setPlaybackRate(1.25)
        XCTAssertEqual(engine.snapshot.playbackRate, 1.25)
        engine.shutdown()
        let replacement = try LocalPlaybackEngine()
        defer { replacement.shutdown() }
        try await replacement.load(url: movie, startSeconds: 1)
        XCTAssertEqual(replacement.snapshot.playbackRate, 1)
    }

    func testCancellationAndShutdownSettleRateCommandsBeforeNextMutation() async throws {
        _ = NSApplication.shared
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        let preCancelled = Task { try await engine.setPlaybackRate(2) }
        preCancelled.cancel()
        do { try await preCancelled.value; XCTFail("Pre-cancelled speed change was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.snapshot.playbackRate, 1)

        let changing = Task { try await engine.setPlaybackRate(1.5) }
        await Task.yield()
        changing.cancel()
        do { try await changing.value } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        try await engine.setPlaybackRate(1)
        XCTAssertEqual(engine.snapshot.playbackRate, 1)

        let closing = Task { try await engine.setPlaybackRate(2) }
        await Task.yield()
        engine.shutdown()
        do { try await closing.value } catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        XCTAssertNil(engine.snapshot.failure)
    }

    private func runFixtureProcess(_ process: Process) throws {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            throw LocalPlaybackError.timeout
        }
    }
}
