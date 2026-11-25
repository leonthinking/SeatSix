import AppKit
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

@MainActor
final class SeriesSkipControllerTests: XCTestCase {
    private func controller(type: String = "Episode", save: @escaping (Int64, Bool) -> Bool = { _, _ in true }) throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data("{\"Id\":\"e1\",\"Name\":\"Test\",\"Type\":\"\(type)\",\"SeriesId\":\"show\"}".utf8))
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        return NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test"), save: save)
    }

    func testSettingsPublishOnlyAfterDurableSaveAndMoviesCannotUseSeriesSettings() async throws {
        var saved = SeriesSkipSettings(introSeconds: 90, outroSeconds: 60)
        var fail = true
        let access = SeriesPlaybackPreferencesAccess(load: { saved }, save: { value in
            if fail { throw ApplicationPersistenceError.saveFailed }
            saved = value
        })
        let owner = try controller(); owner.configureSeriesSkip(access)
        XCTAssertEqual(owner.seriesSkipSettings, saved)
        XCTAssertFalse(owner.canConfigureSeriesSkip)
        owner.preparing = false
        XCTAssertFalse(owner.saveSeriesSkipSettings(.init(introSeconds: 100, outroSeconds: 40)))
        XCTAssertEqual(owner.seriesSkipSettings, saved)
        XCTAssertTrue(owner.seriesSkipMessage?.contains("未能保存") == true)
        fail = false
        XCTAssertTrue(owner.saveSeriesSkipSettings(.init(introSeconds: 100, outroSeconds: 40)))
        XCTAssertEqual(saved.introSeconds, 100)
        XCTAssertFalse(owner.saveSeriesSkipSettings(.init(introSeconds: -1)))
        XCTAssertEqual(owner.seriesSkipSettings, saved)
        let fresh = try controller(); fresh.configureSeriesSkip(access)
        XCTAssertEqual(fresh.seriesSkipSettings, saved)
        let movie = try controller(type: "Movie"); movie.configureSeriesSkip(access); movie.preparing = false
        XCTAssertFalse(movie.canConfigureSeriesSkip)
        XCTAssertEqual(movie.seriesSkipSettings, .init())
        await owner.stop(); await fresh.stop(); await movie.stop()
    }

    func testInitialIntroSkipPreservesLaterResumeAndManualRewind() async throws {
        _ = NSApplication.shared
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for start in [0.0, 4.0] {
            let owner = try controller()
            owner.configureSeriesSkip(.init(load: { .init(introSeconds: 2, outroSeconds: 3) }, save: { _ in }))
            let engine = try LocalPlaybackEngine(); engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: start)
            await owner.restorePreferences(engine: engine, mediaSourceID: "source")
            try await owner.applyInitialSeriesSkip(engine: engine)
            XCTAssertEqual(engine.snapshot.seconds, max(start, 2), accuracy: 0.15)
            XCTAssertTrue(engine.snapshot.paused)
            owner.preparing = false
            engine.onChange = { [weak owner] in owner?.sample() }
            await owner.seek(to: 0.5)
            engine.play()
            try await waitUntil { engine.snapshot.seconds > 0.8 }
            engine.pause()
            XCTAssertLessThan(engine.snapshot.seconds, 2, "An intentional rewind must not be skipped again")
            await owner.stop()
        }
    }

    func testOutroWaitsForPlaybackThenReachesRealEOFExactlyOnceAndSavesObservedPosition() async throws {
        _ = NSApplication.shared
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writes: [Int64] = []
        let owner = try controller { ticks, _ in writes.append(ticks); return true }
        owner.configureSeriesSkip(.init(load: { .init(introSeconds: 2, outroSeconds: 3) }, save: { _ in }))
        let engine = try LocalPlaybackEngine(); engine.setVolume(0)
        try await engine.load(url: movie)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        try await owner.applyInitialSeriesSkip(engine: engine)
        owner.preparing = false
        engine.onChange = { [weak owner] in owner?.sample() }
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        engine.play()
        try await waitUntil { !writes.isEmpty }
        engine.pause()
        await owner.seek(to: 9.2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(owner.isActive)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertEqual(engine.snapshot.seconds, 9.2, accuracy: 0.15)
        XCTAssertEqual(completions, 0, "Paused or seeked frames cannot finish an episode")
        owner.togglePause()
        try await waitUntil(timeout: 5) { completions == 1 }
        XCTAssertTrue(engine.snapshot.ended, "Decoder EOF, not a synthetic completion, must drive handoff")
        XCTAssertFalse(owner.isActive)
        let last = try XCTUnwrap(writes.last)
        XCTAssertEqual(Double(last) / 10_000_000, engine.snapshot.seconds, accuracy: 0.00001)
        XCTAssertGreaterThan(Double(last) / 10_000_000, 11.4)
        await owner.completeNaturally()
        XCTAssertEqual(completions, 1)
    }

    func testManualStopNearOutroDoesNotCallCompletion() async throws {
        _ = NSApplication.shared
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try controller()
        owner.configureSeriesSkip(.init(load: { .init(outroSeconds: 3) }, save: { _ in }))
        let engine = try LocalPlaybackEngine(); engine.setVolume(0)
        try await engine.load(url: movie)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        engine.onChange = { [weak owner] in owner?.sample() }
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        engine.play()
        try await waitUntil { engine.snapshot.seconds > 0.2 }
        engine.pause()
        await owner.seek(to: 9.2)
        owner.togglePause()
        await owner.stop()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(owner.canAutomaticallyContinue)
    }

    func testRapidSeeksAccumulateFromLastRequestAndNewestAbsoluteSeekWins() async throws {
        _ = NSApplication.shared
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try controller()
        let engine = try LocalPlaybackEngine()
        try await engine.load(url: movie)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        var preferences = ApplicationPreferences()
        preferences.seekForwardSeconds = 5
        preferences.seekBackwardSeconds = 5
        owner.updateInterfacePreferences(preferences)
        engine.onChange = { [weak owner] in owner?.sample() }
        owner.sample()
        XCTAssertTrue(owner.canSeek)
        let slider = PlaybackSeekSlider()
        slider.maxValue = 12
        slider.preferences = preferences
        slider.pendingPosition = { owner.manualSeekTarget }
        slider.seek = { owner.requestSeek(to: $0) }
        owner.requestSeek(to: 1)
        owner.requestSeek(.forward)
        // The NSSlider can still show an older sample when a focused key press arrives.
        slider.doubleValue = 0
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(owner.manualSeekTarget, 11)
        try await waitUntil { owner.manualSeekTarget == nil }
        XCTAssertEqual(engine.snapshot.seconds, 11, accuracy: 0.15)

        // Replace a request after mpv starts processing it, before its async
        // seek acknowledgement. The stale completion must not fail playback.
        var replaced = false
        engine.onChange = { [weak owner] in
            guard let owner else { return }
            owner.sample()
            if !replaced, owner.manualSeekTarget == 3 {
                replaced = true
                owner.requestSeek(.backward)
                owner.requestSeek(to: 7)
            }
        }
        owner.requestSeek(to: 3)
        try await waitUntil { replaced && owner.manualSeekTarget == nil }
        XCTAssertEqual(engine.snapshot.seconds, 7, accuracy: 0.15)
        XCTAssertTrue(engine.snapshot.paused)
        XCTAssertTrue(owner.isActive)
        XCTAssertNil(owner.errorMessage)

        owner.requestSeek(to: 9)
        let selection = owner.beginEpisodeSwitch()
        owner.requestSeek(to: 10)
        XCTAssertNil(owner.manualSeekTarget)
        XCTAssertFalse(owner.canSeek)
        await owner.stop(forEpisodeSwitch: selection)
        await owner.seek(to: 2)
        XCTAssertNil(owner.manualSeekTarget)
        XCTAssertNil(owner.errorMessage)
    }

    func testManualRewindDuringAutomaticOutroKeepsPlayingAtTheChosenPosition() async throws {
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try controller()
        owner.configureSeriesSkip(.init(load: { .init(outroSeconds: 3) }, save: { _ in }))
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        try await engine.load(url: movie)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        var interruptOutro = false
        var rewound = false
        engine.onChange = { [weak owner] in
            guard let owner else { return }
            owner.sample()
            if interruptOutro, engine.snapshot.paused, engine.snapshot.seconds > 9 {
                interruptOutro = false
                Task {
                    // The automatic outro pauses before its seek. Intervene at that
                    // exact boundary, as a click on a chapter/timeline could do.
                    owner.requestSeek(to: 3)
                    rewound = true
                }
            }
        }
        engine.play()
        try await waitUntil { engine.snapshot.seconds > 0.3 }
        engine.pause()
        await owner.seek(to: 9.2)
        interruptOutro = true
        owner.togglePause()
        try await waitUntil { rewound && owner.manualSeekTarget == nil && (3..<5).contains(engine.snapshot.seconds) }
        XCTAssertFalse(engine.snapshot.paused)
        XCTAssertNil(owner.seriesSkipMessage)
        XCTAssertNil(owner.errorMessage)
        XCTAssertTrue(owner.isActive)
        await owner.stop()
    }

    func testManualSeekBetweenLocalEOFSampleAndCompletionKeepsCurrentEpisode() async throws {
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try controller()
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 10.7)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        var intercepted = false
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        engine.onChange = { [weak owner] in
            guard let owner else { return }
            owner.sample()
            if engine.snapshot.ended, !intercepted {
                // sample() already queued natural completion. A real seek arrives before
                // the main actor yields and authorizes this episode to finish.
                intercepted = true
                owner.requestSeek(to: 2)
            }
        }
        engine.play()
        try await waitUntil(timeout: 4) { intercepted && owner.manualSeekTarget == nil }
        XCTAssertTrue(owner.isActive)
        XCTAssertEqual(engine.snapshot.seconds, 2, accuracy: 0.2)
        XCTAssertFalse(engine.snapshot.ended)
        XCTAssertEqual(completions, 0)
        await owner.stop()
    }

    func testUnknownDurationRejectsAbsoluteAndRelativeSeeks() async throws {
        let owner = try controller()
        let engine = try LocalPlaybackEngine()
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        XCTAssertEqual(owner.durationSeconds, 0)
        XCTAssertFalse(owner.canSeek)
        owner.requestSeek(.forward)
        await owner.seek(to: 30)
        XCTAssertNil(owner.manualSeekTarget)
        XCTAssertNil(owner.errorMessage, "An unknown duration must never send a seek to zero to the decoder")
        await owner.stop()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("episode.mkv")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=navy:size=320x180:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "12", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", movie.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 30) == .success else { process.terminate(); throw LocalPlaybackError.timeout }
        guard process.terminationStatus == 0 else { throw LocalPlaybackError.noVideoFrame }
        return (directory, movie)
    }
}
