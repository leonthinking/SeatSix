import AppKit
import XCTest
@testable import SeatSixPlayback

@MainActor
final class SubtitlePresentationTests: XCTestCase {
    func testNormalizationAndCodableRoundTrip() throws {
        XCTAssertEqual(SubtitlePresentation().normalized, SubtitlePresentation(delaySeconds: 0, fontSize: 48, style: .original))
        XCTAssertEqual(SubtitlePresentation(delaySeconds: .infinity, fontSize: .nan, style: .boxed).normalized,
                       SubtitlePresentation(delaySeconds: 0, fontSize: 48, style: .boxed))
        XCTAssertEqual(SubtitlePresentation(delaySeconds: -100, fontSize: 2).normalized,
                       SubtitlePresentation(delaySeconds: -30, fontSize: 24))
        XCTAssertEqual(SubtitlePresentation(delaySeconds: 100, fontSize: 999).normalized,
                       SubtitlePresentation(delaySeconds: 30, fontSize: 72))
        for style in SubtitlePresentation.Style.allCases {
            let value = SubtitlePresentation(delaySeconds: -1.5, fontSize: 60, style: style)
            XCTAssertEqual(try JSONDecoder().decode(SubtitlePresentation.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testPositiveAndNegativeDelayChangeTheCueWithoutMovingPlayback() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: movie, startSeconds: 2)
        let srt = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.codec == "subrip" })
        try await engine.selectSubtitleTrack(id: nil)
        try await eventually { engine.snapshot.subtitleText?.isEmpty != false }
        let clean = try engine.captureFrameEvidence().sampleSHA256
        try await engine.selectSubtitleTrack(id: srt.id)
        try await eventually { engine.snapshot.subtitleText?.contains("First subtitle") == true }
        let first = try engine.captureFrameEvidence().sampleSHA256
        XCTAssertNotEqual(clean, first)

        try await engine.applySubtitlePresentation(SubtitlePresentation(delaySeconds: 3))
        try await eventually { engine.snapshot.subtitleText?.isEmpty != false }
        XCTAssertEqual(try engine.captureFrameEvidence().sampleSHA256, clean)
        XCTAssertEqual(engine.snapshot.subtitlePresentation.delaySeconds, 3)

        try await engine.applySubtitlePresentation(SubtitlePresentation(delaySeconds: -3))
        try await eventually { engine.snapshot.subtitleText?.contains("Second subtitle") == true }
        XCTAssertNotEqual(try engine.captureFrameEvidence().sampleSHA256, first)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, srt.id)
        XCTAssertNil(engine.snapshot.failure)
    }

    func testSizesAndEveryStyleRenderForEmbeddedSRTAndASSAndRestoreOriginal() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: makeFixture(directory), startSeconds: 2)
        let tracks = engine.snapshot.subtitleTracks
        XCTAssertEqual(tracks.count, 2)
        for track in tracks {
            try await engine.selectSubtitleTrack(id: track.id)
            try await engine.applySubtitlePresentation(SubtitlePresentation())
            try await eventually { engine.snapshot.subtitleText?.contains("First subtitle") == true }
            let original = try engine.captureFrameEvidence().sampleSHA256
            try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 24))
            let small = try engine.captureFrameEvidence().sampleSHA256
            try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 72))
            let large = try engine.captureFrameEvidence().sampleSHA256
            XCTAssertNotEqual(small, large, "Font size must change actual \(track.codec ?? "") subtitle pixels")
            var presetFrames = Set<String>()
            for style in [SubtitlePresentation.Style.outlined, .boxed, .yellow] {
                let value = SubtitlePresentation(fontSize: 60, style: style)
                try await engine.applySubtitlePresentation(value)
                XCTAssertEqual(engine.snapshot.subtitlePresentation, value)
                presetFrames.insert(try engine.captureFrameEvidence().sampleSHA256)
            }
            XCTAssertEqual(presetFrames.count, 3, "Preset styles must render visibly different \(track.codec ?? "") captions")
            try await engine.applySubtitlePresentation(SubtitlePresentation())
            XCTAssertEqual(try engine.captureFrameEvidence().sampleSHA256, original, "Original must remove every preset override")
            XCTAssertTrue(engine.snapshot.paused)
            XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
        }
    }

    func testSettingsDoNotPausePlayingVideoAndPersistWhenReusingTheEngine() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: movie, startSeconds: 1)
        engine.play()
        try await eventually { engine.snapshot.seconds > 1.2 && !engine.snapshot.paused }
        let before = engine.snapshot.seconds
        let value = SubtitlePresentation(delaySeconds: 0.5, fontSize: 64, style: .boxed)
        try await engine.applySubtitlePresentation(value)
        XCTAssertFalse(engine.snapshot.paused)
        try await eventually { engine.snapshot.seconds > before + 0.2 }
        engine.pause()
        try await engine.load(url: movie, startSeconds: 2)
        XCTAssertEqual(engine.snapshot.subtitlePresentation, value)
        XCTAssertTrue(engine.snapshot.paused)
    }

    func testCancellationAndShutdownDoNotLeaveCommandsBlockingLaterSelections() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: movie, startSeconds: 2)
        let preCancelled = Task { try await engine.applySubtitlePresentation(SubtitlePresentation(style: .yellow)) }
        preCancelled.cancel()
        do { try await preCancelled.value; XCTFail("Cancelled operation changed settings") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.snapshot.subtitlePresentation, SubtitlePresentation())

        let value = SubtitlePresentation(delaySeconds: 0.25, fontSize: 60, style: .boxed)
        let change = Task { try await engine.applySubtitlePresentation(value) }
        await Task.yield()
        change.cancel()
        do { try await change.value } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        try await engine.applySubtitlePresentation(SubtitlePresentation())
        try await engine.selectSubtitleTrack(id: nil)
        let closing = Task { try await engine.applySubtitlePresentation(value) }
        await Task.yield()
        engine.shutdown()
        do { try await closing.value } catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        XCTAssertFalse(engine.snapshot.loaded)
        XCTAssertNil(engine.snapshot.failure)
    }

    func testReplacingMediaDuringPendingPresentationBatchRestoresLastAcknowledgedPixels() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let replacement = directory.appendingPathComponent("replacement.mkv")
        try FileManager.default.copyItem(at: movie, to: replacement)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: movie, startSeconds: 2)
        let ass = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.codec == "ass" })
        try await engine.selectSubtitleTrack(id: ass.id)
        let saved = SubtitlePresentation(delaySeconds: 0.25, fontSize: 60, style: .boxed)
        let interrupted = SubtitlePresentation(delaySeconds: 3, fontSize: 24, style: .yellow)
        try await engine.applySubtitlePresentation(saved)
        try await eventually { engine.snapshot.subtitleText?.contains("First subtitle") == true }
        let savedPixels = try engine.captureFrameEvidence().sampleSHA256

        // Observe an actual pending command batch, not merely a task that may
        // not have started. Retry if this machine acknowledges an entire batch
        // before the observing task gets its first scheduling opportunity.
        var pendingChange: Task<Void, Error>?
        for _ in 0..<12 {
            try await engine.applySubtitlePresentation(saved)
            var completed = false
            let change = Task {
                defer { completed = true }
                try await engine.applySubtitlePresentation(interrupted)
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while engine.pendingTrackCommandCount == 0, !completed, ContinuousClock.now < deadline {
                await Task.yield()
            }
            if engine.pendingTrackCommandCount > 0 {
                pendingChange = change
                break
            }
            try await change.value
        }
        let changing = try XCTUnwrap(pendingChange, "Must interrupt commands actually pending in mpv")
        XCTAssertEqual(engine.snapshot.subtitlePresentation, saved)
        try await engine.load(url: replacement, startSeconds: 2)
        do { try await changing.value; XCTFail("A replaced media batch must not be acknowledged") }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .superseded) }
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        XCTAssertEqual(engine.snapshot.subtitlePresentation, saved)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)

        let replacementASS = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.codec == "ass" })
        try await engine.selectSubtitleTrack(id: replacementASS.id)
        try await eventually { engine.snapshot.subtitleText?.contains("First subtitle") == true }
        XCTAssertEqual(try engine.captureFrameEvidence().sampleSHA256, savedPixels,
                       "Snapshot and actual render must both retain the last complete style")
        try await engine.selectSubtitleTrack(id: nil)
        XCTAssertNil(engine.snapshot.selectedSubtitleTrackID)
        try await engine.selectSubtitleTrack(id: replacementASS.id)
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, replacementASS.id)
        XCTAssertEqual(engine.pendingTrackCommandCount, 0)
        XCTAssertNil(engine.snapshot.failure)
    }

    func testExternalSubtitleCanPreserveItsDisplayNameAcrossPrivateCopies() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: makeFixture(directory), startSeconds: 2)
        let file = directory.appendingPathComponent("random-archive-id.srt")
        try Data("1\n00:00:00,000 --> 00:00:04,000\nExternal caption\n".utf8).write(to: file)
        let selected = try await engine.addExternalSubtitle(url: file, title: "Saved caption\n\u{0007}")
        XCTAssertEqual(selected.title, "Saved caption")
        try await engine.applySubtitlePresentation(SubtitlePresentation(fontSize: 72, style: .yellow))
        try await eventually { engine.snapshot.subtitleText?.contains("External caption") == true }
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, selected.id)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LocalPlaybackError.timeout }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFixture(_ directory: URL) throws -> URL {
        let srt = directory.appendingPathComponent("timing.srt")
        let ass = directory.appendingPathComponent("timing.ass")
        let movie = directory.appendingPathComponent("presentation.mkv")
        try Data("1\n00:00:00,000 --> 00:00:03,000\nFirst subtitle\n\n2\n00:00:05,000 --> 00:00:08,000\nSecond subtitle\n".utf8).write(to: srt)
        try Data("""
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,34,&H0000FF00,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:03.00,Default,,0,0,0,,First subtitle
        Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Second subtitle

        """.utf8).write(to: ass)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=navy:size=640x360:rate=24", "-i", srt.path, "-i", ass.path, "-map", "0:v", "-map", "1:s", "-map", "2:s", "-t", "10", "-c:v", "libx264", "-preset", "ultrafast", "-c:s", "copy", movie.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else { process.terminate(); throw LocalPlaybackError.timeout }
        XCTAssertEqual(process.terminationStatus, 0)
        return movie
    }
}
