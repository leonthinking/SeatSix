import AppKit
import XCTest
@testable import SeatSixPlayback

@MainActor
final class MediaAdjustmentTests: XCTestCase {
    func testDisplayRatioFollowsDecodedPixelAspectRotationAndReplacedMedia() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func movie(named name: String, sampleAspect: String) throws -> URL {
            let url = directory.appendingPathComponent(name).appendingPathExtension("mkv")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=180x120:rate=24",
                                 "-vf", "setsar=\(sampleAspect)", "-t", "1", "-c:v", "libx264", url.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return url
        }
        let anamorphic = try movie(named: "anamorphic", sampleAspect: "4/3")
        let squarePixels = try movie(named: "square-pixels", sampleAspect: "1")
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        XCTAssertTrue(try XCTUnwrap(engine.videoView as? NSOpenGLView).wantsBestResolutionOpenGLSurface)
        XCTAssertNil(engine.snapshot.displayAspectRatio)
        func expectRatio(_ expected: Double, line: UInt = #line) async throws {
            for _ in 0..<100 {
                if let actual = engine.snapshot.displayAspectRatio, abs(actual - expected) < 0.01 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(try XCTUnwrap(engine.snapshot.displayAspectRatio), expected, accuracy: 0.01, line: line)
        }
        try await engine.load(url: anamorphic)
        try await expectRatio(2)
        try await engine.adjust(.aspect, to: 2)
        try await expectRatio(4.0 / 3)
        try await engine.adjust(.rotation, to: 1)
        try await expectRatio(3.0 / 4)
        try await engine.adjust(.rotation, to: 0)
        try await engine.adjust(.aspect, to: 0)
        try await engine.load(url: squarePixels)
        try await expectRatio(1.5)
        engine.shutdown()
        XCTAssertNil(engine.snapshot.displayAspectRatio)
    }

    func testBoundedOptionsRejectInvalidTagsAndPreserveAdjacentEQBands() throws {
        for value in [Double.nan, Double.infinity, -1, 3.5, 4] {
            XCTAssertThrowsError(try MediaAdjustment.mirror.option(value, previous: [:]))
        }
        XCTAssertThrowsError(try MediaAdjustment.equalizer(10).option(0, previous: [:]))
        let previous: [MediaAdjustment: Double] = [.equalizer(2): 4]
        let eq = try MediaAdjustment.equalizer(5).option(-3, previous: previous)
        XCTAssertEqual(eq.0, "af")
        XCTAssertTrue(eq.1.contains("f=125:width_type=o:width=1:g=4"))
        XCTAssertTrue(eq.1.contains("f=1000:width_type=o:width=1:g=-3"))
        XCTAssertEqual(try MediaAdjustment.equalizer(2).option(0, previous: previous).1, "")
    }

    func testVideoBrightnessReallyChangesPausedFrameAndResetRestoresIt() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("adjustments.mkv")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gen.arguments = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24",
                         "-f", "lavfi", "-i", "sine=frequency=500", "-t", "2", "-c:v", "libx264", url.path]
        try gen.run()
        gen.waitUntilExit()
        XCTAssertEqual(gen.terminationStatus, 0)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: url)
        try await engine.seek(to: 0.5)
        let initial = try engine.captureFrameEvidence().sampleSHA256
        try await engine.adjust(.brightness, to: 45)
        let changed = try engine.captureFrameEvidence().sampleSHA256
        XCTAssertNotEqual(initial, changed)
        try await engine.adjust(.brightness, to: 0)
        XCTAssertEqual(try engine.captureFrameEvidence().sampleSHA256, initial)
        for (key, value) in [(MediaAdjustment.rotation, 1.0), (.mirror, 1), (.aspect, 2), (.audioDelay, -0.3),
                             (.equalizer(3), 5), (.channels, 2), (.subtitlePosition, 86)] {
            try await engine.adjust(key, to: value)
            XCTAssertEqual(engine.adjustments[key], value)
        }
        do {
            try await engine.adjust(.secondarySubtitle, to: 999)
            XCTFail("An absent subtitle track must be rejected")
        } catch LocalPlaybackError.invalidTrack {}
        XCTAssertNil(engine.adjustments[.secondarySubtitle])
        for n in [1, 2] {
            let sub = directory.appendingPathComponent("track-\(n).srt")
            try "1\n00:00:00,200 --> 00:00:01,200\nTEST \(n)\n".write(to: sub, atomically: true, encoding: .utf8)
            _ = try await engine.addExternalSubtitle(url: sub)
        }
        let tracks = engine.snapshot.subtitleTracks
        XCTAssertEqual(tracks.count, 2)
        let primary = try XCTUnwrap(tracks.first).id
        let secondary = try XCTUnwrap(tracks.last).id
        try await engine.selectSubtitleTrack(id: primary)
        try await engine.adjust(.secondarySubtitle, to: Double(secondary))
        do {
            try await engine.selectSubtitleTrack(id: secondary)
            XCTFail("The same track cannot occupy both subtitle slots")
        } catch LocalPlaybackError.subtitleTrackConflict {}
        try await engine.load(url: url)
        XCTAssertNil(engine.adjustments[.secondarySubtitle])
        XCTAssertTrue(engine.snapshot.subtitleTracks.isEmpty)
        engine.shutdown()
        XCTAssertTrue(engine.adjustments.isEmpty)
    }
}
