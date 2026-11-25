import XCTest
import AppKit
@testable import SeatSixPlayback

@MainActor
final class TrackSelectionTests: XCTestCase {
    func testPausedSeekImmediatelyAfterSwitchingEveryAudioTrack() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures")
        for name in ["two-audio-tracks.mkv", "three-audio-tracks.mkv"] {
            for _ in 0..<3 {
                let engine = try LocalPlaybackEngine()
                defer { engine.shutdown() }
                engine.setVolume(0)
                try await engine.load(url: root.appendingPathComponent(name), startSeconds: 0)
                engine.pause()
                try await eventually { engine.snapshot.paused && engine.snapshot.audioTracks.count >= 2 }
                for track in engine.snapshot.audioTracks {
                    try await engine.selectAudioTrack(id: track.id)
                }
                try await engine.seek(to: 2.5)
                XCTAssertEqual(engine.snapshot.seconds, 2.5, accuracy: 1.0 / 24)
            }
        }
    }

    func testOutputMuteSurvivesTrackReplacementReloadAndRapidChanges() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }

        let level = 0.22
        engine.setVolume(level, muted: true)
        func isMuted() -> Bool {
            guard let driver = engine.snapshot.audioOutput else { return false }
            if driver == "avfoundation" {
                return engine.rendererMuted == true && abs(engine.observedSoftwareVolume - level) < 0.001
            }
            return engine.observedSoftwareVolume == 0
        }
        func confirm(_ stage: String, _ check: () -> Bool) async throws {
            do { try await eventually(check) }
            catch {
                XCTFail("\(stage): driver=\(engine.snapshot.audioOutput ?? "unavailable"), mute=\(String(describing: engine.rendererMuted)), gain=\(engine.observedSoftwareVolume), tracks=\(engine.snapshot.audioTracks.count)")
                throw error
            }
        }
        try await engine.load(url: movie, startSeconds: 1)
        try await confirm("initial mute") { isMuted() && engine.snapshot.audioTracks.count == 2 }
        let second = try XCTUnwrap(engine.snapshot.audioTracks.last)
        try await engine.selectAudioTrack(id: second.id)
        try await confirm("change track") { engine.snapshot.selectedAudioTrackID == second.id && isMuted() }
        try await engine.load(url: movie, startSeconds: 2)
        try await confirm("reload") { isMuted() }

        for _ in 0..<8 {
            engine.setVolume(level)
            engine.setVolume(level, muted: true)
        }
        engine.setVolume(.nan)
        try await confirm("last fast write") { isMuted() }
        engine.setVolume(level)
        try await confirm("unmute") {
            let nativeReady = engine.snapshot.audioOutput != "avfoundation" || engine.rendererMuted == false
            return nativeReady && abs(engine.observedSoftwareVolume - level) < 0.001
        }
        engine.setVolume(0)
        try await confirm("volume slider at zero") { isMuted() }
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
        XCTAssertNil(engine.snapshot.failure)
    }

    func testExternalSubtitleValidationRejectsNetworkPlaylistsBinaryAndOversizedFiles() throws {
        for location in ["https://example.test/captions.srt", "http://127.0.0.1:1234/sub.srt", "file://remote/tmp/sub.srt"] {
            XCTAssertThrowsError(try LocalPlaybackEngine.validatedSubtitleData(url: URL(string: location)!))
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, contents) in [("playlist.srt", "#EXTM3U\nhttp://example.test/secret\n"), ("invalid.ass", "[Script Info]\n"), ("binary.srt", "1\n00:00:00,000 --> 00:00:10,000\nhello\0"), ("unknown.txt", "1\n00:00:00,000 --> 00:00:10,000\nhello")] {
            let file = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: file)
            XCTAssertThrowsError(try LocalPlaybackEngine.validatedSubtitleData(url: file))
        }
        let oversized = directory.appendingPathComponent("large.srt")
        try Data(repeating: 65, count: 10 * 1024 * 1024 + 1).write(to: oversized)
        XCTAssertThrowsError(try LocalPlaybackEngine.validatedSubtitleData(url: oversized)) { XCTAssertEqual($0 as? LocalPlaybackError, .subtitleTooLarge) }
        let utf16 = directory.appendingPathComponent("utf16.srt")
        let caption = "1\n00:00:00,000 --> 00:00:10,000\n字幕\n"
        try XCTUnwrap(caption.data(using: .utf16)).write(to: utf16)
        XCTAssertEqual(String(data: try LocalPlaybackEngine.validatedSubtitleData(url: utf16), encoding: .utf8), caption)
    }

    func testSubRipCueNumberAllowsHorizontalPaddingButRejectsBrokenNumericLines() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("captions.srt")
        let cue = "00:00:02,000 --> 00:00:05,000\nCaption\n"
        for number in ["1", "1 ", "24\t "] {
            let input = number + "\n" + cue
            try Data(input.utf8).write(to: file)
            XCTAssertEqual(try LocalPlaybackEngine.validatedSubtitleData(url: file), Data(input.utf8))
        }
        for invalid in ["\n", "1x\n", "1 2\n", "1 \n\n", "1 \ninvalid\n"] {
            try Data((invalid + cue).utf8).write(to: file)
            XCTAssertThrowsError(try LocalPlaybackEngine.validatedSubtitleData(url: file))
        }
    }

    func testAudioEmbeddedAndExternalSubtitlesConfirmSelectionAndRenderingWithoutSeeking() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 3)
        try await eventually { engine.snapshot.audioTracks.count == 2 && engine.snapshot.subtitleTracks.count == 2 }
        XCTAssertEqual(engine.snapshot.audioTracks.map(\.language), ["eng", "fra"])
        XCTAssertTrue(engine.snapshot.subtitleTracks.allSatisfy { !$0.isExternal })
        let audio = try XCTUnwrap(engine.snapshot.audioTracks.first { $0.codec == "ac3" })
        let srt = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.codec == "subrip" })
        let ass = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.codec == "ass" })
        let position = engine.snapshot.seconds
        try await engine.selectAudioTrack(id: audio.id)
        try await eventually { engine.snapshot.audioCodec == "ac3" }
        XCTAssertEqual(engine.snapshot.selectedAudioTrackID, audio.id)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, position, accuracy: 0.15)
        try await engine.selectSubtitleTrack(id: nil)
        try await eventually { engine.snapshot.subtitleText?.isEmpty != false }
        let clean = try engine.captureFrameEvidence()
        try await engine.selectSubtitleTrack(id: srt.id)
        try await eventually { engine.snapshot.subtitleText?.contains("Embedded SRT") == true }
        let subtitled = try engine.captureFrameEvidence()
        XCTAssertNotEqual(clean.sampleSHA256, subtitled.sampleSHA256, "Selected text must actually render over the static video")
        try await engine.selectSubtitleTrack(id: ass.id)
        try await eventually { engine.snapshot.subtitleText?.contains("Embedded ASS") == true }
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, position, accuracy: 0.15)

        let external: [(String, String, String)] = [
            ("srt", "1\n00:00:00,000 --> 00:00:15,000\nExternal SRT\n", "External SRT"),
            ("ass", assText("External ASS"), "External ASS"),
            ("vtt", "WEBVTT\n\n00:00.000 --> 00:15.000\nExternal VTT\n", "External VTT")
        ]
        for (ext, text, expected) in external {
            let file = directory.appendingPathComponent("external.\(ext)")
            try Data(text.utf8).write(to: file)
            let selected = try await engine.addExternalSubtitle(url: file)
            XCTAssertTrue(selected.isExternal)
            XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, selected.id)
            try await eventually { engine.snapshot.subtitleText?.contains(expected) == true }
            XCTAssertTrue(engine.snapshot.paused)
            XCTAssertEqual(engine.snapshot.seconds, position, accuracy: 0.15)
            // Original file replacement does not alter the engine-owned copy.
            try Data("#EXTM3U\nhttp://example.test/unwanted".utf8).write(to: file)
        }
        try await engine.selectSubtitleTrack(id: nil)
        try await eventually { engine.snapshot.subtitleText?.isEmpty != false }
        XCTAssertNil(engine.snapshot.selectedSubtitleTrackID)
        let finalClean = try engine.captureFrameEvidence()
        XCTAssertEqual(clean.sampleSHA256, finalClean.sampleSHA256)
        do { try await engine.selectAudioTrack(id: 999_999); XCTFail("Unknown track selected") }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .invalidTrack) }
        XCTAssertNil(engine.snapshot.failure)

        engine.play()
        try await eventually { engine.snapshot.seconds > position + 0.3 }
        let playingPosition = engine.snapshot.seconds
        let firstAudio = try XCTUnwrap(engine.snapshot.audioTracks.first)
        try await engine.selectAudioTrack(id: firstAudio.id)
        XCTAssertFalse(engine.snapshot.paused)
        XCTAssertGreaterThanOrEqual(engine.snapshot.seconds, playingPosition - 0.15)
        engine.pause()
        try await engine.load(url: movie, startSeconds: 1)
        try await eventually { engine.snapshot.subtitleTracks.count == 2 }
        XCTAssertTrue(engine.snapshot.subtitleTracks.allSatisfy { !$0.isExternal })
        XCTAssertEqual(engine.snapshot.seconds, 1, accuracy: 0.15)
    }

    func testShutdownAndReloadInvalidatePendingTrackOperations() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 2)
        try await eventually { engine.snapshot.audioTracks.count == 2 }
        let id = try XCTUnwrap(engine.snapshot.audioTracks.last?.id)
        let pending = Task { try await engine.selectAudioTrack(id: id) }
        await Task.yield()
        try await engine.load(url: movie, startSeconds: 1)
        do { try await pending.value } catch { XCTAssertEqual(error as? LocalPlaybackError, .superseded) }
        XCTAssertEqual(engine.snapshot.seconds, 1, accuracy: 0.15)
        let subtitle = directory.appendingPathComponent("close.srt")
        try Data("1\n00:00:00,000 --> 00:00:15,000\nClose safely\n".utf8).write(to: subtitle)
        let add = Task { try await engine.addExternalSubtitle(url: subtitle) }
        await Task.yield()
        engine.shutdown()
        do { _ = try await add.value } catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(engine.snapshot.subtitleTracks.isEmpty)
        XCTAssertTrue(engine.snapshot.audioTracks.isEmpty)
        XCTAssertNil(engine.snapshot.selectedSubtitleTrackID)
        do { try await engine.selectSubtitleTrack(id: nil); XCTFail("Closed engine accepted selection") }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
    }

    func testPendingExternalSubtitleCannotAttachToReloadedMovie() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let nextMovie = directory.appendingPathComponent("next.mkv")
        try FileManager.default.copyItem(at: movie, to: nextMovie)
        let subtitle = directory.appendingPathComponent("many-cues.srt")
        // A substantial valid subtitle gives the detached sub-add worker work
        // to finish while the engine is being reused for a different file.
        let cues = (1...60_000).map { index in
            let start = index * 2
            func timestamp(_ seconds: Int) -> String {
                String(format: "%02d:%02d:%02d,000", seconds / 3600, seconds / 60 % 60, seconds % 60)
            }
            return "\(index)\n\(timestamp(start)) --> \(timestamp(start + 1))\nOld file caption \(index)\n\n"
        }.joined()
        try Data(cues.utf8).write(to: subtitle)
        let temp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("SeatSixSubtitles-") })
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 2)
        let add = Task { try await engine.addExternalSubtitle(url: subtitle) }
        // Reading now runs off-actor. Wait until that phase has finished and a
        // real sub-add command is pending, rather than racing a single yield.
        let commandDeadline = ContinuousClock.now + .seconds(10)
        while engine.pendingTrackCommandCount == 0, ContinuousClock.now < commandDeadline {
            await Task.yield()
        }
        XCTAssertGreaterThan(engine.pendingTrackCommandCount, 0, "Must exercise an in-flight mpv sub-add, not merely an unfinished file read")
        let created = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("SeatSixSubtitles-") }).subtracting(before)
        XCTAssertEqual(created.count, 1)
        try await engine.load(url: nextMovie, startSeconds: 1)
        do { _ = try await add.value }
        catch { XCTAssertEqual(error as? LocalPlaybackError, .superseded) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(engine.snapshot.subtitleTracks.count, 2)
        XCTAssertTrue(engine.snapshot.subtitleTracks.allSatisfy { !$0.isExternal })
        XCTAssertFalse(engine.snapshot.subtitleText?.contains("Old file caption") == true)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 1, accuracy: 0.15)
        let during = Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("SeatSixSubtitles-") })
        let copies = during.subtracting(before)
        XCTAssertEqual(copies.count, 1)
        engine.shutdown()
        for name in copies { XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent(name).path), "Subtitle copies must be removed after decoder shutdown") }
    }

    func testSlowSubtitleReadKeepsMainActorResponsiveAndCannotSurviveCloseOrCancellation() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try makeFixture(directory)
        let subtitle = directory.appendingPathComponent("slow.srt")
        let data = Data("1\n00:00:00,000 --> 00:00:15,000\nSlow provider subtitle\n".utf8)
        for shouldClose in [true, false] {
            let reader = DelayedSubtitleReader(data: data)
            let engine = try LocalPlaybackEngine(subtitleReader: { _ in try reader.read() })
            defer { engine.shutdown() }
            engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: 2)
            var finished = false
            let add = Task { @MainActor in
                defer { finished = true }
                return try await engine.addExternalSubtitle(url: subtitle)
            }
            for _ in 0..<100 {
                if reader.started { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let started = reader.started
            XCTAssertTrue(started)
            var heartbeats = 0
            let heartbeat = Task { @MainActor in
                for _ in 0..<5 {
                    heartbeats += 1
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            try await heartbeat.value
            XCTAssertEqual(heartbeats, 5, "A slow provider must not stall rendering or UI events")
            if shouldClose { engine.shutdown() } else { add.cancel() }
            await Task.yield()
            XCTAssertFalse(finished, "The import must retain caller-owned security scope until the reader has actually finished")
            reader.finish()
            do { _ = try await add.value; XCTFail("A closed/cancelled import added a subtitle") }
            catch {
                if shouldClose { XCTAssertEqual(error as? LocalPlaybackError, .closed) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            XCTAssertFalse(engine.snapshot.subtitleTracks.contains { $0.isExternal })
            if !shouldClose {
                XCTAssertTrue(engine.snapshot.loaded)
                XCTAssertTrue(engine.snapshot.paused)
                XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.15)
                try await engine.selectSubtitleTrack(id: nil)
            }
        }
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

    private func assText(_ text: String) -> String {
        """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 320
        PlayResY: 180
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:15.00,Default,,0,0,0,,\(text)

        """
    }

    private func makeFixture(_ directory: URL) throws -> URL {
        let srt = directory.appendingPathComponent("embedded.srt")
        let ass = directory.appendingPathComponent("embedded.ass")
        let movie = directory.appendingPathComponent("tracks.mkv")
        try Data("1\n00:00:00,000 --> 00:00:15,000\nEmbedded SRT\n".utf8).write(to: srt)
        try Data(assText("Embedded ASS").utf8).write(to: ass)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=navy:size=320x180:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-i", srt.path, "-i", ass.path, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map", "4:s", "-t", "15", "-c:v", "libx264", "-preset", "ultrafast", "-c:a:0", "aac", "-c:a:1", "ac3", "-c:s", "copy", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra", movie.path]
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

private final class DelayedSubtitleReader: @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var didStart = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    init(data: Data) { self.data = data }
    func read() throws -> Data {
        lock.lock(); didStart = true; lock.unlock()
        guard completion.wait(timeout: .now() + 10) == .success else { throw LocalPlaybackError.timeout }
        return data
    }
    func finish() { completion.signal() }
}
