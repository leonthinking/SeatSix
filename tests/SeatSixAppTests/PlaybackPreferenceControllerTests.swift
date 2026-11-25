import AppKit
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

@MainActor
final class PlaybackPreferenceControllerTests: XCTestCase {
    func testApplicationDefaultsFieldOverridesResetAndSessionSnapshot() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        var saved = FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item.id, mediaSourceID: "source"))
        let access = PlaybackPreferencesAccess(load: { _ in saved }, save: { saved = $0 },
            archive: { _ in throw SubtitleArchiveError.unavailable }, url: { _ in throw SubtitleArchiveError.invalidReference }, discard: { _ in })
        var defaults = ApplicationPreferences()
        defaults.subtitleMode = .off
        defaults.subtitleFontSize = 60
        defaults.subtitleStyle = .boxed
        defaults.autoPlayNextEpisode = false
        func controller(defaults: ApplicationPreferences) async throws -> NativePlaybackController {
            let value = NativePlaybackController(item: item, connection: connection,
                client: MediaServerClient(connection: connection, token: "", deviceID: "test"), applicationPreferences: defaults) { _, _ in true }
            value.preferenceAccess = access
            let engine = try LocalPlaybackEngine(); engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: 3)
            // Establish a selected media track so the default-off assertion is meaningful.
            try await engine.selectSubtitleTrack(id: try XCTUnwrap(engine.snapshot.subtitleTracks.first?.id))
            await value.restorePreferences(engine: engine, mediaSourceID: "source")
            value.preparing = false
            return value
        }
        let first = try await controller(defaults: defaults)
        let engine = try XCTUnwrap(first.localEngine)
        XCTAssertEqual(first.subtitlePresentation, SubtitlePresentation(fontSize: 60, style: .boxed))
        XCTAssertNil(engine.snapshot.selectedSubtitleTrackID)
        XCTAssertFalse(first.autoPlayNextEpisode)
        await first.selectAudioTrack(try XCTUnwrap(engine.snapshot.audioTracks.last?.id))
        XCTAssertNil(saved.subtitleFontSizeOverride)
        XCTAssertNil(saved.subtitleStyleOverride)
        await first.setSubtitleDelay(2)
        XCTAssertNil(saved.subtitleFontSizeOverride)
        XCTAssertNil(saved.subtitleStyleOverride)
        await first.setSubtitleFontSize(48)
        XCTAssertEqual(saved.subtitleFontSizeOverride, 48)
        XCTAssertNil(saved.subtitleStyleOverride)
        await first.setSubtitleStyle(.yellow)
        let subtitleID = try XCTUnwrap(engine.snapshot.subtitleTracks.first?.id)
        await first.selectSubtitleTrack(subtitleID)
        let savedAudio = saved.audio, savedSubtitle = saved.subtitle
        var changedDefaults = defaults
        changedDefaults.subtitleFontSize = 72
        changedDefaults.subtitleStyle = .original
        first.updateInterfacePreferences(changedDefaults)
        XCTAssertEqual(first.interfacePreferences, changedDefaults)
        XCTAssertEqual(first.playbackDefaults, defaults)
        var invalidInterface = changedDefaults
        invalidInterface.seekBackwardSeconds = .infinity
        invalidInterface.seekForwardSeconds = -.infinity
        invalidInterface.controlsHideDelay = .nan
        first.updateInterfacePreferences(invalidInterface)
        XCTAssertEqual(first.interfacePreferences.seekBackwardSeconds, 10)
        XCTAssertEqual(first.interfacePreferences.seekForwardSeconds, 10)
        XCTAssertEqual(first.interfacePreferences.controlsHideDelay, 3)
        XCTAssertEqual(first.playbackDefaults, defaults)
        XCTAssertEqual(first.subtitlePresentation, SubtitlePresentation(delaySeconds: 2, fontSize: 48, style: .yellow),
                       "Changing application preferences must not change the active playback session")
        await first.useApplicationSubtitleDefaults()
        XCTAssertEqual(first.subtitlePresentation, SubtitlePresentation(delaySeconds: 2, fontSize: 60, style: .boxed))
        XCTAssertNil(saved.subtitleFontSizeOverride)
        XCTAssertNil(saved.subtitleStyleOverride)
        XCTAssertEqual(saved.audio, savedAudio)
        XCTAssertEqual(saved.subtitle, savedSubtitle)
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, subtitleID)
        await first.stop()

        // A genuinely new session receives changed defaults, while the explicit
        // single-film subtitle selection still takes priority over default-off.
        let second = try await controller(defaults: changedDefaults)
        XCTAssertEqual(second.subtitlePresentation, SubtitlePresentation(delaySeconds: 2, fontSize: 72, style: .original))
        XCTAssertEqual(second.localEngine?.snapshot.selectedSubtitleTrackID, subtitleID)
        XCTAssertNil(second.trackMessage)
        await second.stop()
    }

    func testApplicationDefaultsApplyWithoutPreferenceStorage() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        var defaults = ApplicationPreferences()
        defaults.subtitleFontSize = 72
        defaults.subtitleStyle = .yellow
        for mode in DefaultSubtitleMode.allCases {
            defaults.subtitleMode = mode
            let controller = NativePlaybackController(item: item, connection: connection,
                client: MediaServerClient(connection: connection, token: "", deviceID: "test"), applicationPreferences: defaults) { _, _ in true }
            let engine = try LocalPlaybackEngine(); engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: 3)
            let subtitleID = try XCTUnwrap(engine.snapshot.subtitleTracks.first?.id)
            try await engine.selectSubtitleTrack(id: subtitleID)
            await controller.restorePreferences(engine: engine, mediaSourceID: "source")
            controller.preparing = false
            XCTAssertEqual(controller.subtitlePresentation, SubtitlePresentation(fontSize: 72, style: .yellow))
            XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, mode == .off ? nil : subtitleID)
            await controller.setSubtitleDelay(-1)
            await controller.setSubtitleStyle(.boxed)
            await controller.useApplicationSubtitleDefaults()
            XCTAssertEqual(controller.subtitlePresentation, SubtitlePresentation(delaySeconds: -1, fontSize: 72, style: .yellow))
            await controller.stop()
        }
    }

    func testSelectionsAppearanceOffAndArchivedSubtitleSurviveFreshControllers() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        let archive = SubtitleArchive(directory: directory.appendingPathComponent("archive"))
        var saved = FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item.id, mediaSourceID: "source"))
        let storage = try ApplicationStorage(directory: directory.appendingPathComponent("application"))
        var initial = SavedApplication(); initial.connections = [connection]; initial.playbackPreferences = [saved]
        try storage.save(initial)
        var failSave = false
        let access = PlaybackPreferencesAccess(load: { _ in
            // Each fresh controller reads a fresh disk snapshot.
            (try? storage.load().playbackPreferences.first) ?? saved
        }, save: { value in
            if failSave { throw ApplicationPersistenceError.saveFailed }
            var state = try storage.load()
            state.playbackPreferences = [value]
            try storage.save(state)
            saved = try XCTUnwrap(storage.load().playbackPreferences.first)
        }, archive: { try await archive.archive(url: $0, connectionID: connection.id) }, url: { try archive.url(for: $0) }, discard: { archive.discard($0) })
        func controller() async throws -> NativePlaybackController {
            let value = NativePlaybackController(item: item, connection: connection, client: MediaServerClient(connection: connection, token: "", deviceID: "test")) { _, _ in true }
            value.preferenceAccess = access
            let engine = try LocalPlaybackEngine(); engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: 3)
            await value.restorePreferences(engine: engine, mediaSourceID: "source")
            value.preparing = false
            return value
        }
        let first = try await controller()
        let firstEngine = try XCTUnwrap(first.localEngine)
        let audio = try XCTUnwrap(firstEngine.snapshot.audioTracks.last)
        let subtitle = try XCTUnwrap(firstEngine.snapshot.subtitleTracks.first)
        await first.selectAudioTrack(audio.id)
        await first.selectSubtitleTrack(subtitle.id)
        let presentation = SubtitlePresentation(delaySeconds: 1.5, fontSize: 60, style: .yellow)
        await first.setSubtitlePresentation(presentation)
        XCTAssertEqual(saved.presentation, presentation)
        XCTAssertNotNil(saved.audio)
        XCTAssertNotNil(saved.subtitle)
        await first.stop()

        let second = try await controller()
        let secondEngine = try XCTUnwrap(second.localEngine)
        XCTAssertEqual(secondEngine.snapshot.selectedAudioTrackID, audio.id)
        XCTAssertEqual(secondEngine.snapshot.selectedSubtitleTrackID, subtitle.id)
        XCTAssertEqual(secondEngine.snapshot.subtitlePresentation, presentation)
        XCTAssertEqual(secondEngine.snapshot.seconds, 3, accuracy: 0.15)
        XCTAssertTrue(secondEngine.snapshot.paused)
        await second.selectSubtitleTrack(nil)
        XCTAssertEqual(saved.subtitle, .off)
        await second.stop()

        let third = try await controller()
        XCTAssertNil(third.localEngine?.snapshot.selectedSubtitleTrackID)
        let external = directory.appendingPathComponent("Caption.srt")
        try Data("1\n00:00:00,000 --> 00:00:10,000\nDurable caption\n".utf8).write(to: external)
        await third.importSubtitle(url: external)
        guard case .local(let reference) = saved.subtitle else { return XCTFail("External choice was not persisted") }
        try FileManager.default.removeItem(at: external)
        await third.stop()

        let fourth = try await controller()
        let fourthEngine = try XCTUnwrap(fourth.localEngine)
        XCTAssertTrue(fourthEngine.snapshot.subtitleTracks.contains { $0.id == fourthEngine.snapshot.selectedSubtitleTrackID && $0.isExternal })
        XCTAssertEqual(saved.subtitle, .local(reference))
        failSave = true
        await fourth.selectSubtitleTrack(nil)
        XCTAssertNil(fourthEngine.snapshot.selectedSubtitleTrackID)
        XCTAssertTrue(fourth.trackMessage?.contains("未能保存") == true)
        XCTAssertEqual(saved.subtitle, .local(reference), "Failed persistence cannot claim the off choice was saved")
        await fourth.stop()

        archive.discard(reference)
        failSave = false
        let fifth = try await controller()
        XCTAssertNil(fifth.localEngine?.snapshot.selectedSubtitleTrackID)
        XCTAssertTrue(fifth.trackMessage?.contains("已不可用") == true)
        XCTAssertEqual(saved.subtitle, .local(reference), "Missing captions should not replace the stored preference")
        await fifth.stop()
    }

    func testLanguageDefaultsRespectFilmSelectionsAndEachFollowApplicationAction() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory, languageTracks: true)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        let engine = try LocalPlaybackEngine(); engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 3)
        let englishAudio = try XCTUnwrap(engine.snapshot.audioTracks.first { $0.language == "eng" })
        let frenchAudio = try XCTUnwrap(engine.snapshot.audioTracks.first { $0.language == "fra" })
        let englishSubtitle = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.language == "eng" })
        let japaneseSubtitle = try XCTUnwrap(engine.snapshot.subtitleTracks.first { $0.language == "jpn" })
        try await engine.selectAudioTrack(id: englishAudio.id)
        try await engine.selectSubtitleTrack(id: englishSubtitle.id)
        var saved = FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item.id, mediaSourceID: "source"),
            presentation: SubtitlePresentation(delaySeconds: 1.5, fontSize: 60, style: .yellow))
        saved.audio = SavedTrackSelection(track: englishAudio, among: engine.snapshot.audioTracks)
        saved.subtitle = .embedded(SavedTrackSelection(track: englishSubtitle, among: engine.snapshot.subtitleTracks))
        let oldSubtitle = saved.subtitle
        let presentation = saved.presentation
        var defaults = ApplicationPreferences()
        defaults.preferredAudioLanguage = .french
        defaults.subtitleMode = .preferredLanguage
        defaults.preferredSubtitleLanguage = .japanese
        let controller = NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test"), applicationPreferences: defaults) { _, _ in true }
        controller.preferenceAccess = PlaybackPreferencesAccess(load: { _ in saved }, save: { saved = $0 },
            archive: { _ in throw SubtitleArchiveError.unavailable }, url: { _ in throw SubtitleArchiveError.invalidReference }, discard: { _ in })
        await controller.restorePreferences(engine: engine, mediaSourceID: "source")
        controller.preparing = false
        XCTAssertEqual(engine.snapshot.selectedAudioTrackID, englishAudio.id)
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, englishSubtitle.id)
        XCTAssertFalse(controller.followsApplicationAudio)
        XCTAssertFalse(controller.followsApplicationSubtitle)
        await controller.useApplicationAudioSelection()
        XCTAssertEqual(engine.snapshot.selectedAudioTrackID, frenchAudio.id)
        XCTAssertNil(saved.audio)
        XCTAssertEqual(saved.subtitle, oldSubtitle)
        XCTAssertEqual(saved.presentation, presentation)
        await controller.useApplicationSubtitleSelection()
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, japaneseSubtitle.id)
        XCTAssertNil(saved.subtitle)
        XCTAssertEqual(saved.presentation, presentation)
        XCTAssertTrue(controller.followsApplicationAudio)
        XCTAssertTrue(controller.followsApplicationSubtitle)
        // A current session still uses its original defaults when global settings change.
        var newDefaults = defaults; newDefaults.preferredSubtitleLanguage = .english
        controller.updateInterfacePreferences(newDefaults)
        await controller.useApplicationSubtitleSelection()
        XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, japaneseSubtitle.id)
        await controller.stop()
    }

    func testPreferredLanguageFallbackAndMissingSingleFilmChoice() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory, languageTracks: true)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        var saved = FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item.id, mediaSourceID: "source"))
        let missingTrack = LocalPlaybackTrack(id: 99, kind: .subtitle, language: "kor")
        let missingChoice = SavedSubtitleSelection.embedded(SavedTrackSelection(track: missingTrack, among: [missingTrack]))
        for choice in [nil, SavedSubtitleSelection.off, missingChoice] {
            saved.subtitle = choice
            var defaults = ApplicationPreferences()
            defaults.preferredAudioLanguage = .korean
            defaults.subtitleMode = .preferredLanguage
            defaults.preferredSubtitleLanguage = choice == nil ? .korean : .japanese
            let controller = NativePlaybackController(item: item, connection: connection,
                client: MediaServerClient(connection: connection, token: "", deviceID: "test"), applicationPreferences: defaults) { _, _ in true }
            controller.preferenceAccess = PlaybackPreferencesAccess(load: { _ in saved }, save: { saved = $0 },
                archive: { _ in throw SubtitleArchiveError.unavailable }, url: { _ in throw SubtitleArchiveError.invalidReference }, discard: { _ in })
            let engine = try LocalPlaybackEngine(); engine.setVolume(0)
            try await engine.load(url: movie, startSeconds: 3)
            let mediaAudio = try XCTUnwrap(engine.snapshot.audioTracks.first?.id)
            let mediaSubtitle = try XCTUnwrap(engine.snapshot.subtitleTracks.first?.id)
            try await engine.selectAudioTrack(id: mediaAudio)
            try await engine.selectSubtitleTrack(id: mediaSubtitle)
            await controller.restorePreferences(engine: engine, mediaSourceID: "source")
            controller.preparing = false
            XCTAssertEqual(engine.snapshot.selectedAudioTrackID, mediaAudio)
            XCTAssertEqual(engine.snapshot.selectedSubtitleTrackID, choice == nil ? mediaSubtitle : nil)
            XCTAssertEqual(saved.subtitle, choice)
            if choice == missingChoice { XCTAssertTrue(controller.trackMessage?.contains("已不可用") == true) }
            await controller.stop()
        }
    }

    func testContinuationAppliesCurrentRateBeforeTheNewClockStarts() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try fixture(directory)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"episode","Name":"Test","Type":"Episode"}"#.utf8))
        func makeController() -> NativePlaybackController {
            NativePlaybackController(item: item, connection: connection,
                client: MediaServerClient(connection: connection, token: "", deviceID: "test")) { _, _ in true }
        }
        let previous = makeController()
        let firstEngine = try LocalPlaybackEngine(); firstEngine.setVolume(0)
        try await firstEngine.load(url: movie, startSeconds: 3)
        await previous.restorePreferences(engine: firstEngine, mediaSourceID: "source")
        previous.preparing = false
        await previous.setPlaybackRate(1.5)
        XCTAssertEqual(previous.playbackRate, 1.5)
        await previous.stop()
        let next = makeController()
        next.inheritContinuationPlaybackRate(from: previous)
        let nextEngine = try LocalPlaybackEngine(); nextEngine.setVolume(0)
        try await nextEngine.load(url: movie, startSeconds: 3)
        await next.applyInitialPlaybackRate(engine: nextEngine)
        XCTAssertTrue(nextEngine.snapshot.paused)
        XCTAssertEqual(nextEngine.snapshot.seconds, 3, accuracy: 0.15)
        XCTAssertEqual(nextEngine.snapshot.playbackRate, 1.5)
        XCTAssertEqual(next.playbackRate, 1.5)
        nextEngine.shutdown()
        await next.stop()
        let independent = makeController()
        XCTAssertEqual(independent.playbackRate, 1)
        await independent.stop()
    }

    private func fixture(_ directory: URL, languageTracks: Bool = false) throws -> URL {
        let sub = directory.appendingPathComponent("embedded.srt")
        try Data("1\n00:00:00,000 --> 00:00:12,000\nEmbedded caption\n".utf8).write(to: sub)
        let movie = directory.appendingPathComponent("fixture.mkv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=navy:size=320x180:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-i", sub.path, "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-t", "12", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-c:s", "copy", "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=fra", movie.path]
        if languageTracks {
            process.arguments!.removeLast()
            process.arguments! += ["-map", "3:s", "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=jpn", movie.path]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 30) == .success else { process.terminate(); throw LocalPlaybackError.timeout }
        guard process.terminationStatus == 0 else { throw LocalPlaybackError.invalidSubtitle }
        return movie
    }
}
