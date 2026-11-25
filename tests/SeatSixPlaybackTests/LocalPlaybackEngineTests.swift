import XCTest
import AppKit
@testable import SeatSixPlayback

@MainActor
final class LocalPlaybackEngineTests: XCTestCase {
    func testURLBoundaryAllowsOnlyExplicitLoopbackAndLocalFiles() throws {
        try LocalPlaybackEngine.validate(url: URL(string: "http://127.0.0.1:45678/opaque-capability/video")!)
        try LocalPlaybackEngine.validate(url: URL(fileURLWithPath: "/tmp/fixture.mkv"))
        for value in ["https://example.com/movie.mkv", "http://example.com/video", "http://localhost:8888/video", "http://127.0.0.1/video", "http://127.0.0.1:8888/video#fragment", "http://:fixture@127.0.0.1:8888/video", "file://remote/tmp/video", "data:text/plain,hello", "ytdl://video"] {
            XCTAssertThrowsError(try LocalPlaybackEngine.validate(url: URL(string: value)!))
        }
        var credentials = URLComponents(string: "http://127.0.0.1:8888/video")!
        credentials.user = "fixture"
        XCTAssertThrowsError(try LocalPlaybackEngine.validate(url: credentials.url!))
    }

    func testSeekBoundsRejectNonFiniteAndNegative() throws {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertThrowsError(try LocalPlaybackEngine.boundedTime(value, duration: 100))
        }
        XCTAssertEqual(try LocalPlaybackEngine.boundedTime(150, duration: 100), 99.95)
        XCTAssertEqual(try LocalPlaybackEngine.boundedTime(0, duration: 100), 0)
        XCTAssertEqual(try LocalPlaybackEngine.boundedTime(5, duration: nil), 5)
    }

    func testShutdownIsIdempotentAndRejectsFurtherOperations() async throws {
        _ = NSApplication.shared
        let engine = try LocalPlaybackEngine()
        engine.shutdown()
        engine.shutdown()
        engine.play()
        engine.pause()
        engine.setVolume(.nan)
        XCTAssertFalse(engine.snapshot.loaded)
        do {
            try await engine.load(url: URL(fileURLWithPath: "/tmp/nonexistent.mkv"))
            XCTFail("closed engine accepted load")
        } catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
        XCTAssertThrowsError(try engine.captureFrameEvidence())
    }

    func testMKVHEVC10BitAndAC3ActuallyDecodeAndSeek() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("synthetic.mkv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12", "-c:v", "libx265", "-x265-params", "log-level=error:pools=1", "-pix_fmt", "yuv420p10le", "-c:a", "ac3", fixture.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: fixture, startSeconds: 1)
        XCTAssertTrue(engine.snapshot.loaded)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertFalse(engine.snapshot.seeking)
        XCTAssertEqual(engine.snapshot.seconds, 1, accuracy: 0.15)
        let frame = try engine.captureFrameEvidence()
        XCTAssertEqual(frame.width, 160)
        XCTAssertEqual(frame.height, 90)
        XCTAssertGreaterThan(frame.nonBlackPixelCount, 1000)
        XCTAssertEqual(frame.sampleSHA256.count, 64)
        XCTAssertEqual(engine.snapshot.videoCodec, "hevc")
        XCTAssertEqual(engine.snapshot.audioCodec, "ac3")
        XCTAssertEqual(engine.snapshot.audioSampleRate, 48000)
        engine.play()
        // Keep the fixture longer than the output buffer: near audio EOF,
        // AVFoundation can clear audio-pts while the final video frames remain.
        // Wait for actual advancing, synchronized audio samples rather than
        // assuming the audio device is ready after a fixed startup delay.
        let audioDeadline = ContinuousClock.now + .seconds(4)
        var audioBaseline: Double?
        var audioAdvanced = false
        while ContinuousClock.now < audioDeadline {
            if let pts = engine.snapshot.audioPTS, pts > 0,
               abs(pts - engine.snapshot.seconds) < 0.5 {
                if let baseline = audioBaseline, pts - baseline > 0.35 { audioAdvanced = true; break }
                if audioBaseline == nil || pts < audioBaseline! { audioBaseline = pts }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        engine.pause()
        XCTAssertGreaterThan(engine.snapshot.seconds, 1.3)
        XCTAssertTrue(audioAdvanced, "Audio output clock did not actually advance")
        XCTAssertNotNil(engine.snapshot.audioOutput)
        XCTAssertNotEqual(engine.snapshot.audioOutput, "null")
        try await engine.seek(to: 2)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
        XCTAssertTrue(engine.snapshot.paused)
        try await engine.load(url: fixture, startSeconds: 0.5)
        XCTAssertEqual(engine.snapshot.seconds, 0.5, accuracy: 0.15)
        XCTAssertTrue(engine.snapshot.paused)
        try await engine.seek(to: 11.7)
        engine.play()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(engine.snapshot.ended)
        XCTAssertTrue(engine.snapshot.paused)
    }

    func testSixtyFPSVideoRendersBeyondThirtyFPSAndFramesChange() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("motion-60fps.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=60", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", fixture.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: fixture, startSeconds: 1)
        let firstFrame = try engine.captureFrameEvidence()
        engine.play()
        try await Task.sleep(for: .milliseconds(250))
        let start = ContinuousClock.now
        let before = engine.renderedFrameCount
        try await Task.sleep(for: .milliseconds(1100))
        let rendered = engine.renderedFrameCount - before
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        engine.pause()
        let secondFrame = try engine.captureFrameEvidence()
        XCTAssertGreaterThan(Double(rendered) / seconds, 45, "60 fps source was throttled by the state polling interval")
        XCTAssertGreaterThan(firstFrame.nonBlackPixelCount, 1000)
        XCTAssertGreaterThan(secondFrame.nonBlackPixelCount, 1000)
        XCTAssertNotEqual(firstFrame.sampleSHA256, secondFrame.sampleSHA256, "Rendered evidence must contain different motion frames")
        engine.shutdown()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(engine.snapshot.loaded)
    }

    func testShutdownDuringLoadDoesNotDeliverLateState() async throws {
        _ = NSApplication.shared
        let engine = try LocalPlaybackEngine()
        var changes = 0
        engine.onChange = { changes += 1 }
        let load = Task { try await engine.load(url: URL(string: "http://127.0.0.1:9/unavailable")!) }
        await Task.yield()
        engine.shutdown()
        let countAtShutdown = changes
        do { try await load.value; XCTFail("load survived shutdown") } catch { }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(changes, countAtShutdown)
        XCTAssertFalse(engine.snapshot.loaded)
    }
}
