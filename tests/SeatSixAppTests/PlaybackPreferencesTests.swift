import Darwin
import Foundation
import XCTest
@testable import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

private final class PreferencesMemoryStorage: ApplicationPersisting {
    var value: SavedApplication
    var failing = false
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws {
        if failing { throw ApplicationPersistenceError.saveFailed }
        value = data
    }
}

final class PlaybackPreferencesTests: XCTestCase {
    private func serverSubtitle(title: String = "English", language: String? = "eng", fileExtension: String = "srt", isDefault: Bool = false, isForced: Bool = false, streamIndex: Int = 3) -> ServerSubtitle {
        var url = URLComponents(string: "https://example.test/private")!
        // Generate a disposable test value; no credential is committed.
        url.queryItems = [URLQueryItem(name: "api_key", value: UUID().uuidString)]
        return ServerSubtitle(itemID: "film", mediaSourceID: "version", streamIndex: streamIndex,
                       title: title, language: language, isDefault: isDefault, isForced: isForced, fileExtension: fileExtension,
                       connectionID: UUID(), serverID: "server", userID: "user", requestURL: url.url!)
    }
    private func track(_ id: Int, title: String? = nil, language: String? = "eng", codec: String = "aac", external: Bool = false) -> LocalPlaybackTrack {
        LocalPlaybackTrack(id: id, kind: external ? .subtitle : .audio, title: title, language: language, codec: codec,
                           isDefault: false, isForced: false, isExternal: external, channelCount: 2)
    }

    func testMetadataRestoresTrackAfterIDsAndOrderChange() {
        let english = track(1, title: "English"), chinese = track(2, title: "中文", language: "chi")
        let saved = SavedTrackSelection(track: chinese, among: [english, chinese])
        XCTAssertEqual(saved.resolve(in: [track(8, title: "中文", language: "chi"), track(3, title: "English")]), 8)
        XCTAssertNil(saved.resolve(in: [english, track(2, title: "Commentary", language: "chi")]))
        XCTAssertNil(saved.resolve(in: [track(2, title: "中文", language: "chi", codec: "ac3")]))
    }

    func testIdenticalSignaturesUseOccurrenceOnlyWhileMultiplicityMatches() {
        let first = track(1), second = track(2)
        let saved = SavedTrackSelection(track: second, among: [first, second])
        XCTAssertEqual(saved.resolve(in: [track(5), track(9)]), 9)
        XCTAssertNil(saved.resolve(in: [track(9)]), "A missing duplicate must not silently select a different track")
        XCTAssertNil(saved.resolve(in: [track(3), track(5), track(9)]))
        XCTAssertNil(SavedTrackSelection(track: first, among: []).resolve(in: [first]))
    }

    func testOldApplicationSchemaLoadsWithNoPreferencesAndKeepsDeviceIdentity() throws {
        let old = Data(#"{"connections":[],"deviceID":"existing-device","recovery":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(SavedApplication.self, from: old)
        XCTAssertEqual(decoded.deviceID, "existing-device")
        XCTAssertTrue(decoded.playbackPreferences.isEmpty)
        let roundTrip = try JSONDecoder().decode(SavedApplication.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip.deviceID, "existing-device")
        XCTAssertTrue(roundTrip.playbackPreferences.isEmpty)
    }

    func testUnsetAndExplicitOffRemainDifferentThroughDiskRoundTrip() throws {
        let identity = FilmPlaybackIdentity(connectionID: UUID(), serverID: "server", userID: "user", itemID: "film", mediaSourceID: "version")
        let choices: [SavedSubtitleSelection?] = [nil, .off, .server(SavedServerSubtitleSelection(serverSubtitle())), .embedded(SavedTrackSelection(track: track(4), among: [track(4)]))]
        for choice in choices {
            let preference = FilmPlaybackPreferences(identity: identity, subtitle: choice)
            let decoded = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONEncoder().encode(preference))
            XCTAssertEqual(decoded, preference)
        }
        let encoded = try JSONEncoder().encode(FilmPlaybackPreferences(identity: identity))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "presentation"); legacy.removeValue(forKey: "updatedAt")
        let decoded = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.presentation, SubtitlePresentation())
        XCTAssertEqual(decoded.updatedAt, .distantPast)
    }

    func testServerSubtitleMatchesOnlySameIDAndCompleteMetadataWithoutCredentials() throws {
        let original = serverSubtitle(), saved = SavedServerSubtitleSelection(original)
        XCTAssertEqual(saved.resolve(in: [serverSubtitle(streamIndex: 9), original]), original)
        for replaced in [serverSubtitle(title: "Commentary"), serverSubtitle(language: "chi"),
                         serverSubtitle(fileExtension: "ass"), serverSubtitle(isDefault: true), serverSubtitle(isForced: true)] {
            XCTAssertEqual(replaced.id, original.id)
            XCTAssertNil(saved.resolve(in: [replaced]), "Reused stream IDs must not select replacement metadata")
        }
        XCTAssertNil(saved.resolve(in: [serverSubtitle(streamIndex: 9)]))
        XCTAssertNil(saved.resolve(in: [original, original]), "Ambiguous candidates must not be guessed")
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(SavedServerSubtitleSelection.self, from: data), saved)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("api_key")); XCTAssertFalse(json.contains("https:"))
        let token = try XCTUnwrap(URLComponents(url: original.requestURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertFalse(json.contains(token))
    }

    func testLegacyServerSubtitleIDLoadsButCannotSilentlyResolve() throws {
        let legacy = Data(#"{"server":{"_0":"film:version:3"}}"#.utf8)
        let selection = try JSONDecoder().decode(SavedSubtitleSelection.self, from: legacy)
        guard case .server(let saved) = selection else { return XCTFail("Expected retained server selection") }
        XCTAssertEqual(saved.id, serverSubtitle().id)
        XCTAssertNil(saved.resolve(in: [serverSubtitle()]))
    }

    func testLegacyJSONPreservesStandardAndCustomPresentationAsExplicitOverrides() throws {
        // These are real pre-settings schema shapes, with no inheritance marker.
        for (fontSize, style) in [(48.0, "original"), (60.0, "yellow")] {
            let data = Data("""
            {"identity":{"connectionID":"B1E79DD4-7BA3-4C6A-9F19-3316DFA03330","serverID":"server","userID":"user","itemID":"film","mediaSourceID":"source"},
             "presentation":{"delaySeconds":1.5,"fontSize":\(fontSize),"style":"\(style)"},"updatedAt":0}
            """.utf8)
            let legacy = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: data)
            let expected = SubtitlePresentation(delaySeconds: 1.5, fontSize: fontSize, style: try XCTUnwrap(SubtitlePresentation.Style(rawValue: style)))
            let differentDefaults = SubtitlePresentation(fontSize: 72, style: .boxed)
            XCTAssertEqual(legacy.resolvedPresentation(defaults: differentDefaults), expected)
            let reopened = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONEncoder().encode(legacy))
            XCTAssertEqual(reopened.resolvedPresentation(defaults: differentDefaults), expected)
        }
    }

    func testNewAudioOnlyPreferenceContinuesToInheritAppearanceAfterDiskRoundTrip() throws {
        let identity = FilmPlaybackIdentity(connectionID: UUID(), serverID: "server", userID: "user", itemID: "film", mediaSourceID: "source")
        let audio = track(1)
        let preference = FilmPlaybackPreferences(identity: identity, audio: SavedTrackSelection(track: audio, among: [audio]))
        let reopened = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONEncoder().encode(preference))
        XCTAssertNil(reopened.subtitleFontSizeOverride)
        XCTAssertNil(reopened.subtitleStyleOverride)
        XCTAssertEqual(reopened.resolvedPresentation(defaults: SubtitlePresentation(fontSize: 60, style: .boxed)),
                       SubtitlePresentation(fontSize: 60, style: .boxed))
        XCTAssertEqual(reopened.resolvedPresentation(defaults: SubtitlePresentation(fontSize: 72, style: .yellow)),
                       SubtitlePresentation(fontSize: 72, style: .yellow))
        XCTAssertNotNil(reopened.audio)
    }

    func testTimingAndIndividualAppearanceEditsDoNotFreezeOtherInheritedFields() throws {
        let identity = FilmPlaybackIdentity(connectionID: UUID(), serverID: "server", userID: "user", itemID: "film", mediaSourceID: "source")
        var preference = FilmPlaybackPreferences(identity: identity)
        preference.setSubtitleDelay(2)
        XCTAssertNil(preference.subtitleFontSizeOverride)
        XCTAssertNil(preference.subtitleStyleOverride)
        preference.setSubtitleFontSize(48)
        XCTAssertNil(preference.subtitleStyleOverride)
        let defaults = SubtitlePresentation(fontSize: 72, style: .yellow)
        XCTAssertEqual(preference.resolvedPresentation(defaults: defaults), SubtitlePresentation(delaySeconds: 2, fontSize: 48, style: .yellow))
        preference.useApplicationSubtitleDefaults()
        preference.setSubtitleStyle(.original)
        let reopened = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONEncoder().encode(preference))
        XCTAssertEqual(reopened.resolvedPresentation(defaults: defaults), SubtitlePresentation(delaySeconds: 2, fontSize: 72, style: .original))
    }

    func testExplicitStandardPresentationAndResetHaveDifferentInheritance() throws {
        let identity = FilmPlaybackIdentity(connectionID: UUID(), serverID: "server", userID: "user", itemID: "film", mediaSourceID: "source")
        let audio = track(1)
        var preference = FilmPlaybackPreferences(identity: identity, audio: SavedTrackSelection(track: audio, among: [audio]), subtitle: .off,
                                                  presentation: SubtitlePresentation(delaySeconds: -1))
        let defaults = SubtitlePresentation(fontSize: 60, style: .boxed)
        XCTAssertEqual(preference.resolvedPresentation(defaults: defaults), SubtitlePresentation(delaySeconds: -1))
        preference.useApplicationSubtitleDefaults()
        let reopened = try JSONDecoder().decode(FilmPlaybackPreferences.self, from: JSONEncoder().encode(preference))
        XCTAssertEqual(reopened.resolvedPresentation(defaults: defaults), SubtitlePresentation(delaySeconds: -1, fontSize: 60, style: .boxed))
        XCTAssertEqual(reopened.audio, preference.audio)
        XCTAssertEqual(reopened.subtitle, .off)
        preference.presentation = .init()
        XCTAssertEqual(preference.resolvedPresentation(defaults: defaults), .init(), "Explicit assignment of factory values is still an override")
    }
}

@MainActor
final class ApplicationPlaybackPreferencesTests: XCTestCase {
    private func connection(id: UUID = UUID(), server: String = "server", user: String = "user") -> ServerConnection {
        var value = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test/emby")!, serverID: server, userID: user, username: "name", libraryIDs: [])
        value.id = id; return value
    }
    private func model(_ connections: [ServerConnection], archive: SubtitleArchive? = nil) -> (ApplicationModel, PreferencesMemoryStorage) {
        var saved = SavedApplication(); saved.connections = connections
        let storage = PreferencesMemoryStorage(saved)
        let model = ApplicationModel(storage: storage,
            credentials: CredentialAccess(read: { _ in "test-token" }, save: { _, _ in }, remove: { _ in }),
            subtitleArchive: archive)
        return (model, storage)
    }

    func testFilmPreferencesAreIsolatedByConnectionServerUserItemAndSource() throws {
        let primary = connection(), second = connection(), otherUser = connection(user: "second"), otherServer = connection(server: "second")
        let (model, storage) = model([primary, second, otherUser, otherServer])
        var preference = model.playbackPreferences(item: "film", connection: primary, mediaSourceID: "source")
        preference.subtitle = .off
        try model.savePlaybackPreferences(preference)
        XCTAssertEqual(storage.value.playbackPreferences.count, 1)
        XCTAssertEqual(model.playbackPreferences(item: "film", connection: primary, mediaSourceID: "source").subtitle, .off)
        for connection in [second, otherUser, otherServer] {
            XCTAssertNil(model.playbackPreferences(item: "film", connection: connection, mediaSourceID: "source").subtitle)
        }
        XCTAssertNil(model.playbackPreferences(item: "other-film", connection: primary, mediaSourceID: "source").subtitle)
        XCTAssertNil(model.playbackPreferences(item: "film", connection: primary, mediaSourceID: "other-source").subtitle)
        var changedIdentity = primary; changedIdentity.serverID = "changed"
        XCTAssertNil(model.playbackPreferences(item: "film", connection: changedIdentity, mediaSourceID: "source").subtitle)
    }

    func testWriteFailureDoesNotPublishUnpersistedSelection() throws {
        let connection = connection(), (model, storage) = model([connection])
        var preference = model.playbackPreferences(item: "film", connection: connection, mediaSourceID: "source")
        preference.subtitle = .off
        storage.failing = true
        XCTAssertThrowsError(try model.savePlaybackPreferences(preference))
        XCTAssertTrue(model.saved.playbackPreferences.isEmpty)
        XCTAssertTrue(storage.value.playbackPreferences.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        storage.failing = false
        try model.savePlaybackPreferences(preference)
        XCTAssertEqual(storage.value.playbackPreferences.first?.subtitle, .off)
    }

    func testConnectionScopedAccessRejectsForeignIdentityAndMissingConnections() throws {
        let first = connection(), second = connection(), (model, _) = model([first, second])
        let access = model.playbackPreferencesAccess(item: "film", connection: first)
        let foreign = model.playbackPreferences(item: "film", connection: second, mediaSourceID: "source")
        XCTAssertThrowsError(try access.save(foreign))
        let otherFilm = model.playbackPreferences(item: "other", connection: first, mediaSourceID: "source")
        XCTAssertThrowsError(try access.save(otherFilm))
        let missing = model.playbackPreferences(item: "film", connection: connection(), mediaSourceID: "source")
        XCTAssertThrowsError(try model.savePlaybackPreferences(missing))
    }

    func testPreferencesRememberEveryFilmBeyondTwoHundredRecords() throws {
        let connection = connection(), (model, storage) = model([connection])
        for index in 0..<201 {
            var preference = model.playbackPreferences(item: "film-\(index)", connection: connection, mediaSourceID: "source")
            preference.subtitle = .off
            try model.savePlaybackPreferences(preference)
        }
        XCTAssertEqual(model.saved.playbackPreferences.count, 201)
        XCTAssertEqual(storage.value.playbackPreferences.count, 201)
        XCTAssertEqual(model.playbackPreferences(item: "film-0", connection: connection, mediaSourceID: "source").subtitle, .off)
        XCTAssertEqual(model.playbackPreferences(item: "film-200", connection: connection, mediaSourceID: "source").subtitle, .off)
        let reopened = ApplicationModel(storage: storage)
        XCTAssertEqual(reopened.playbackPreferences(item: "film-0", connection: connection, mediaSourceID: "source").subtitle, .off)
        XCTAssertEqual(reopened.playbackPreferences(item: "film-200", connection: connection, mediaSourceID: "source").subtitle, .off)
    }

    func testMissingRememberedSubtitleDoesNotBlockOtherPreferenceUpdates() throws {
        let connection = connection(), (model, storage) = model([connection])
        var preference = model.playbackPreferences(item: "film", connection: connection, mediaSourceID: "source")
        preference.subtitle = .local(.init(connectionID: connection.id, id: UUID(), displayName: "Missing", fileExtension: "srt"))
        preference.presentation = SubtitlePresentation(delaySeconds: 2, fontSize: 60, style: .outlined)
        try model.savePlaybackPreferences(preference)
        XCTAssertEqual(storage.value.playbackPreferences.first?.presentation.delaySeconds, 2)
        let foreign = ArchivedSubtitle(connectionID: UUID(), id: UUID(), displayName: "Foreign", fileExtension: "srt")
        preference.subtitle = .local(foreign)
        XCTAssertThrowsError(try model.savePlaybackPreferences(preference))
    }

    func testArchiveSurvivesFailedSaveAndConnectionRemovalOnlyAfterSuccessfulWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixPreferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = SubtitleArchive(directory: root.appendingPathComponent("Archive"))
        let input = root.appendingPathComponent("Test.srt")
        try Data("1\n00:00:00,000 --> 00:00:05,000\nExample\n".utf8).write(to: input)
        let first = connection(), second = connection(), (model, storage) = model([first, second], archive: archive)
        let firstRef = try await archive.archive(url: input, connectionID: first.id)
        let secondRef = try await archive.archive(url: input, connectionID: second.id)
        var preference = model.playbackPreferences(item: "film", connection: first, mediaSourceID: "source")
        preference.subtitle = .local(firstRef); try model.savePlaybackPreferences(preference)
        var other = model.playbackPreferences(item: "film", connection: second, mediaSourceID: "source")
        other.subtitle = .local(secondRef); try model.savePlaybackPreferences(other)
        storage.failing = true
        await model.removeConnection(first.id)
        XCTAssertEqual(model.saved.connections.count, 2)
        XCTAssertNoThrow(try archive.url(for: firstRef))
        storage.failing = false
        await model.removeConnection(first.id)
        XCTAssertEqual(model.saved.connections.map(\.id), [second.id])
        XCTAssertThrowsError(try archive.url(for: firstRef))
        XCTAssertNoThrow(try archive.url(for: secondRef))
        XCTAssertEqual(model.saved.playbackPreferences.map(\.identity.connectionID), [second.id])
    }
}

final class SubtitleArchiveTests: XCTestCase {
    private let sample = "1\n00:00:00,000 --> 00:00:05,000\nExample\n"
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SubtitleArchiveTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testArchiveStoresValidatedPrivateCopyAndOriginalMayDisappear() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("字幕.srt"), archive = SubtitleArchive(directory: root.appendingPathComponent("Archive"))
        try XCTUnwrap(sample.data(using: .utf16)).write(to: input)
        let reference = try await archive.archive(url: input, connectionID: UUID())
        let path = try archive.url(for: reference)
        XCTAssertEqual(reference.displayName, "字幕")
        XCTAssertEqual(path.lastPathComponent, "字幕.srt")
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), sample)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let encoded = String(data: try JSONEncoder().encode(reference), encoding: .utf8)!
        XCTAssertFalse(encoded.contains(root.path)); XCTAssertFalse(encoded.contains("file:"))
    }

    func testInvalidPathsAndSymlinkDirectoriesAreRejected() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = SubtitleArchive(directory: root.appendingPathComponent("Archive"))
        let connectionID = UUID(), id = UUID()
        for name in ["../outside", "/outside", "a\\b", "a\nb", ".."] {
            XCTAssertThrowsError(try archive.url(for: .init(connectionID: connectionID, id: id, displayName: name, fileExtension: "srt")))
        }
        XCTAssertThrowsError(try archive.url(for: .init(connectionID: connectionID, id: id, displayName: "file", fileExtension: "../../srt")))
        let external = root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: archive.directory, withDestinationURL: external)
        let input = root.appendingPathComponent("Test.srt"); try Data(sample.utf8).write(to: input)
        do { _ = try await archive.archive(url: input, connectionID: connectionID); XCTFail("Symlink archive root must be rejected") }
        catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testOnlyValidTextSubtitlesAreArchivedAndCancellationLeavesNoReference() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = SubtitleArchive(directory: root.appendingPathComponent("Archive")), input = root.appendingPathComponent("Bad.srt")
        try Data("#EXTM3U\nhttp://example.test/file".utf8).write(to: input)
        do { _ = try await archive.archive(url: input, connectionID: UUID()); XCTFail("A disguised playlist must be rejected") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directory.path))
        try Data(sample.utf8).write(to: input)
        let task = Task { try await archive.archive(url: input, connectionID: UUID()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled imports must not publish an archive") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.directory.path))
    }

    func testPruningWaitsUntilNextPlaybackAndDoesNotTouchOtherConnection() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = SubtitleArchive(directory: root.appendingPathComponent("Archive")), input = root.appendingPathComponent("Test.srt")
        try Data(sample.utf8).write(to: input)
        let connection = UUID(), foreign = UUID()
        let old = try await archive.archive(url: input, connectionID: connection)
        let current = try await archive.archive(url: input, connectionID: connection)
        let other = try await archive.archive(url: input, connectionID: foreign)
        XCTAssertNoThrow(try archive.url(for: old))
        archive.prune(connectionID: connection, keeping: [current])
        XCTAssertThrowsError(try archive.url(for: old))
        XCTAssertNoThrow(try archive.url(for: current))
        XCTAssertNoThrow(try archive.url(for: other))
    }
}
