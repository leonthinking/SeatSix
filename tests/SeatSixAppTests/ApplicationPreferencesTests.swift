import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

private final class PreferencesStorage: ApplicationPersisting {
    var value = SavedApplication()
    var failSaving = false
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws {
        if failSaving { throw ApplicationPersistenceError.saveFailed }
        value = data
    }
}

@MainActor
final class ApplicationPreferencesTests: XCTestCase {
    private let noCredentials = CredentialAccess(read: { _ in throw CredentialStoreError.notFound }, save: { _, _ in }, remove: { _ in })
    private func connection(_ user: String = "user") -> ServerConnection {
        ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!, serverID: "server", userID: user, username: "Test", libraryIDs: ["movies"])
    }

    func testLegacyApplicationAndMalformedPreferenceSectionPreserveConnections() throws {
        var saved = SavedApplication()
        let server = connection()
        saved.connections = [server]; saved.selectedID = server.id
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "applicationPreferences")
        json.removeValue(forKey: "librarySortPreferences")
        let legacy = try JSONDecoder().decode(SavedApplication.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.connections.first?.id, server.id)
        XCTAssertEqual(legacy.applicationPreferences, .init())
        XCTAssertFalse(legacy.applicationPreferences.pauseWhenMinimized)
        XCTAssertFalse(legacy.applicationPreferences.keepPlaybackWindowOnTop)
        XCTAssertFalse(legacy.applicationPreferences.hideUnwatchedEpisodeOverview)
        XCTAssertTrue(legacy.applicationPreferences.showHomeRecommendations)
        XCTAssertTrue(legacy.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertEqual(legacy.applicationPreferences.sidebarWidth, 192)
        XCTAssertFalse(legacy.applicationPreferences.sidebarCollapsed)
        json["applicationPreferences"] = ["posterSize": "large", "seekForwardSeconds": "bad", "subtitleMode": "future-value", "autoPlayNextEpisode": false]
        let partial = try JSONDecoder().decode(SavedApplication.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(partial.applicationPreferences.posterSize, .large)
        XCTAssertEqual(partial.applicationPreferences.seekForwardSeconds, 10)
        XCTAssertEqual(partial.applicationPreferences.subtitleMode, .mediaDefault)
        XCTAssertFalse(partial.applicationPreferences.autoPlayNextEpisode)
        json["applicationPreferences"] = "invalid"
        let corrupt = try JSONDecoder().decode(SavedApplication.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(corrupt.connections.first?.id, server.id)
        XCTAssertEqual(corrupt.applicationPreferences, .init())
    }

    func testInvalidNumbersNormalizeAndRoundTrip() throws {
        var preferences = ApplicationPreferences()
        preferences.seekBackwardSeconds = .infinity
        preferences.seekForwardSeconds = -5
        preferences.controlsHideDelay = .nan
        preferences.subtitleFontSize = 1000
        preferences.resumeRewindSeconds = .infinity
        preferences.sidebarWidth = .nan
        XCTAssertEqual(preferences.normalized, .init())
        preferences = .init()
        preferences.posterSize = .compact; preferences.subtitleMode = .off
        preferences.subtitleFontSize = 72; preferences.subtitleStyle = .boxed
        preferences.seekForwardSeconds = 60; preferences.timeDisplay = .remaining
        preferences.resumeRewindSeconds = 5; preferences.startupPage = .lastBrowsed
        preferences.playbackWindowMode = .fullScreen; preferences.rememberVolume = false
        preferences.subtitleMode = .preferredLanguage; preferences.preferredSubtitleLanguage = .japanese
        preferences.preferredAudioLanguage = .cantonese
        preferences.pauseWhenMinimized = true
        preferences.keepPlaybackWindowOnTop = true
        preferences.hideUnwatchedEpisodeOverview = true
        preferences.showHomeRecommendations = false
        preferences.autoRotateHomeRecommendations = false
        preferences.sidebarWidth = 288
        preferences.sidebarCollapsed = true
        XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
    }

    func testHomeRecommendationPreferencesMigrateAndRejectMalformedFieldsIndependently() throws {
        let previous = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"posterSize":"large","showRecentlyAdded":false,"seekForwardSeconds":30}"#.utf8))
        XCTAssertTrue(previous.showHomeRecommendations)
        XCTAssertTrue(previous.autoRotateHomeRecommendations)
        XCTAssertEqual(previous.posterSize, .large)
        XCTAssertFalse(previous.showRecentlyAdded)
        XCTAssertEqual(previous.seekForwardSeconds, 30)

        let invalidVisibility = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"showHomeRecommendations":"false","autoRotateHomeRecommendations":false,"posterSize":"large"}"#.utf8))
        XCTAssertTrue(invalidVisibility.showHomeRecommendations)
        XCTAssertFalse(invalidVisibility.autoRotateHomeRecommendations)
        XCTAssertEqual(invalidVisibility.posterSize, .large)

        let invalidRotation = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"showHomeRecommendations":false,"autoRotateHomeRecommendations":0,"subtitleFontSize":60}"#.utf8))
        XCTAssertFalse(invalidRotation.showHomeRecommendations)
        XCTAssertTrue(invalidRotation.autoRotateHomeRecommendations)
        XCTAssertEqual(invalidRotation.subtitleFontSize, 60)
    }

    func testSidebarPreferencesMigrateClampAndRejectMalformedFieldsIndependently() throws {
        let previous = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"posterSize":"large","startupPage":"lastBrowsed"}"#.utf8))
        XCTAssertEqual(previous.sidebarWidth, 192)
        XCTAssertFalse(previous.sidebarCollapsed)
        XCTAssertEqual(previous.posterSize, .large)
        XCTAssertEqual(previous.startupPage, .lastBrowsed)
        let invalidWidth = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"sidebarWidth":"huge","sidebarCollapsed":true,"seekForwardSeconds":30}"#.utf8))
        XCTAssertEqual(invalidWidth.sidebarWidth, 192)
        XCTAssertTrue(invalidWidth.sidebarCollapsed)
        XCTAssertEqual(invalidWidth.seekForwardSeconds, 30)
        let invalidVisibility = try JSONDecoder().decode(ApplicationPreferences.self,
            from: Data(#"{"sidebarWidth":280,"sidebarCollapsed":"false","showRecentlyAdded":false}"#.utf8))
        XCTAssertEqual(invalidVisibility.sidebarWidth, 280)
        XCTAssertFalse(invalidVisibility.sidebarCollapsed)
        XCTAssertFalse(invalidVisibility.showRecentlyAdded)
        for (number, expected) in [(-30.0, 192.0), (1000, 320), (256, 256)] {
            let json = try JSONSerialization.data(withJSONObject: ["sidebarWidth": number])
            XCTAssertEqual(try JSONDecoder().decode(ApplicationPreferences.self, from: json).sidebarWidth, expected)
        }
    }

    func testNewWindowAndOverviewDefaultsRejectMalformedFieldsIndependently() throws {
        let values = try JSONDecoder().decode(ApplicationPreferences.self, from: Data(#"{"pauseWhenMinimized":"true","keepPlaybackWindowOnTop":true,"hideUnwatchedEpisodeOverview":7,"posterSize":"large"}"#.utf8))
        XCTAssertFalse(values.pauseWhenMinimized)
        XCTAssertTrue(values.keepPlaybackWindowOnTop)
        XCTAssertFalse(values.hideUnwatchedEpisodeOverview)
        XCTAssertEqual(values.posterSize, .large)
    }

    func testVolumeAndNavigationMigrateSafelyWithoutChangingFilmPreferences() throws {
        let old = try JSONDecoder().decode(SavedApplication.self, from: Data(#"{"playbackVolume":"bad","browsingLocations":123,"applicationPreferences":{"startupPage":"future","preferredAudioLanguage":"unknown","resumeRewindSeconds":9,"rememberVolume":false}}"#.utf8))
        XCTAssertEqual(old.playbackVolume, .init()); XCTAssertTrue(old.browsingLocations.isEmpty)
        XCTAssertEqual(old.applicationPreferences.startupPage, .home)
        XCTAssertNil(old.applicationPreferences.preferredAudioLanguage)
        XCTAssertEqual(old.applicationPreferences.resumeRewindSeconds, 0)
        XCTAssertFalse(old.applicationPreferences.rememberVolume)
        XCTAssertEqual(PlaybackVolumeState(volume: .nan, isMuted: true, volumeBeforeMute: -.infinity).normalized,
                       .init(volume: 1, isMuted: true, volumeBeforeMute: 1))
        let muted = PlaybackVolumeState(volume: 0, isMuted: true, volumeBeforeMute: 0.35)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackVolumeState.self, from: JSONEncoder().encode(muted)), muted)
    }

    func testVolumePersistenceOwnershipDisableAndSaveFailure() throws {
        let store = PreferencesStorage(), model = ApplicationModel(storage: store, credentials: noCredentials), server = connection()
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Movie","Type":"Movie"}"#.utf8))
        func player() -> NativePlaybackController {
            NativePlaybackController(item: item, connection: server, client: MediaServerClient(connection: server, token: "test", deviceID: "test")) { _, _ in true }
        }
        let current = player(), stale = player(); model.player = current
        let muted = PlaybackVolumeState(volume: 0, isMuted: true, volumeBeforeMute: 0.35)
        model.rememberPlaybackVolume(muted, from: stale); model.flushPlaybackVolume()
        XCTAssertEqual(store.value.playbackVolume, .init())
        model.rememberPlaybackVolume(muted, from: current); store.failSaving = true
        model.flushPlaybackVolume()
        XCTAssertEqual(model.saved.playbackVolume, .init()); XCTAssertNotNil(model.preferencesError)
        XCTAssertEqual(model.rememberedPlaybackVolume, muted, "A failed disk write must not make the next film unexpectedly audible")
        store.failSaving = false; model.flushPlaybackVolume()
        XCTAssertEqual(store.value.playbackVolume, muted)
        XCTAssertNil(model.preferencesError); XCTAssertNil(model.errorMessage)
        XCTAssertEqual(ApplicationModel(storage: store, credentials: noCredentials).saved.playbackVolume, muted)
        var preferences = model.applicationPreferences; preferences.rememberVolume = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        model.rememberPlaybackVolume(.init(volume: 0.7), from: current); model.flushPlaybackVolume()
        XCTAssertEqual(store.value.playbackVolume, muted)
    }

    func testResumeRewindClipsAtZeroAndNeverAffectsContinuation() {
        XCTAssertEqual(ResumeRewindPolicy.startTicks(30_000_000, seconds: 10, isContinuation: false), 0)
        XCTAssertEqual(ResumeRewindPolicy.startTicks(300_000_000, seconds: 5, isContinuation: false), 250_000_000)
        XCTAssertEqual(ResumeRewindPolicy.startTicks(300_000_000, seconds: 10, isContinuation: true), 300_000_000)
        XCTAssertEqual(ResumeRewindPolicy.startTicks(Int64.max, seconds: .infinity, isContinuation: false), Int64.max)
    }

    func testSettingsPersistAcrossReloadAndPreserveFilmProgressAndConnections() throws {
        let store = PreferencesStorage(), server = connection()
        store.value.connections = [server]; store.value.selectedID = server.id
        store.value.recovery = [.init(serverID: server.serverID, userID: server.userID, itemID: "movie", ticks: 1234, updatedAt: Date(), confirmed: false)]
        let identity = FilmPlaybackIdentity(connection: server, itemID: "movie", mediaSourceID: "version")
        store.value.playbackPreferences = [.init(identity: identity, presentation: .init(delaySeconds: 1, fontSize: 60, style: .boxed))]
        let original = store.value.playbackPreferences
        let model = ApplicationModel(storage: store, credentials: noCredentials)
        var preferences = model.applicationPreferences
        preferences.posterSize = .large; preferences.autoPlayNextEpisode = false; preferences.subtitleFontSize = 72
        preferences.pauseWhenMinimized = true; preferences.keepPlaybackWindowOnTop = true
        preferences.hideUnwatchedEpisodeOverview = true
        preferences.showHomeRecommendations = false; preferences.autoRotateHomeRecommendations = false
        preferences.sidebarWidth = 304; preferences.sidebarCollapsed = true
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        let reopened = ApplicationModel(storage: store, credentials: noCredentials)
        XCTAssertEqual(reopened.applicationPreferences, preferences)
        XCTAssertEqual(reopened.saved.connections.first?.id, server.id)
        XCTAssertEqual(reopened.saved.recovery.first?.ticks, 1234)
        XCTAssertEqual(reopened.saved.playbackPreferences, original)
        XCTAssertTrue(reopened.updateApplicationPreferences(.init()))
        XCTAssertEqual(reopened.saved.playbackPreferences, original)
        XCTAssertEqual(reopened.saved.recovery.count, 1)
    }

    func testFailedSettingsSaveRollsBackPublishedStateAndCanRetry() {
        let store = PreferencesStorage(), model = ApplicationModel(storage: store, credentials: noCredentials)
        var preferences = model.applicationPreferences; preferences.timeDisplay = .remaining
        preferences.showHomeRecommendations = false; preferences.autoRotateHomeRecommendations = false
        preferences.sidebarWidth = 304; preferences.sidebarCollapsed = true
        store.failSaving = true
        XCTAssertFalse(model.updateApplicationPreferences(preferences))
        XCTAssertEqual(model.applicationPreferences.timeDisplay, .total)
        XCTAssertEqual(store.value.applicationPreferences.timeDisplay, .total)
        XCTAssertTrue(model.applicationPreferences.showHomeRecommendations)
        XCTAssertTrue(model.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertTrue(store.value.applicationPreferences.showHomeRecommendations)
        XCTAssertTrue(store.value.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, 192)
        XCTAssertFalse(model.applicationPreferences.sidebarCollapsed)
        XCTAssertNotNil(model.preferencesError)
        store.failSaving = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        XCTAssertEqual(model.applicationPreferences.timeDisplay, .remaining)
        XCTAssertFalse(model.applicationPreferences.showHomeRecommendations)
        XCTAssertFalse(model.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, 304)
        XCTAssertTrue(model.applicationPreferences.sidebarCollapsed)
        XCTAssertNil(model.preferencesError)
        XCTAssertNil(model.errorMessage)

        store.failSaving = true
        XCTAssertFalse(model.updateApplicationPreferences(.init()))
        model.errorMessage = "媒体库连接暂时中断\n" + (model.errorMessage ?? "")
        store.failSaving = false
        XCTAssertTrue(model.updateApplicationPreferences(.init()))
        XCTAssertEqual(model.errorMessage, "媒体库连接暂时中断")
    }

    func testEachLibraryRemembersFirstVisitAndExplicitSortWithoutCrossingAccounts() throws {
        let store = PreferencesStorage(), first = connection(), second = connection("second")
        store.value.connections = [first, second]; store.value.selectedID = first.id
        let model = ApplicationModel(storage: store, credentials: noCredentials)
        model.selectedLibraryID = "movies"
        XCTAssertEqual(model.sortOrder, .nameAscending)
        var preferences = model.applicationPreferences; preferences.defaultLibrarySort = .yearDescending
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        XCTAssertEqual(model.sortOrder, .nameAscending)
        model.selectedLibraryID = "series"
        XCTAssertEqual(model.sortOrder, .yearDescending)
        model.sortOrder = .nameDescending
        model.selectedLibraryID = "movies"
        XCTAssertEqual(model.sortOrder, .nameAscending)
        model.saved.selectedID = second.id
        model.selectedLibraryID = ""; model.selectedLibraryID = "series"
        XCTAssertEqual(model.sortOrder, .yearDescending)
        model.saved.selectedID = first.id
        model.selectedLibraryID = ""; model.selectedLibraryID = "series"
        XCTAssertEqual(model.sortOrder, .nameDescending)
        try model.persist()
        let reopened = ApplicationModel(storage: store, credentials: noCredentials)
        reopened.selectedLibraryID = "series"
        XCTAssertEqual(reopened.sortOrder, .nameDescending)
        XCTAssertEqual(store.value.librarySortPreferences.count, 3)
    }

    func testSortSaveFailureRestoresVisibleOrder() {
        let store = PreferencesStorage(), server = connection()
        store.value.connections = [server]; store.value.selectedID = server.id
        let model = ApplicationModel(storage: store, credentials: noCredentials)
        model.selectedLibraryID = "movies"
        store.failSaving = true
        model.sortOrder = .nameDescending
        XCTAssertEqual(model.sortOrder, .nameAscending)
        XCTAssertEqual(store.value.librarySortPreferences.first?.sort, .nameAscending)
        XCTAssertNotNil(model.preferencesError)
    }

    func testCurrentPlayerGetsOnlyLiveInterfaceChangesAfterSuccessfulSave() throws {
        let store = PreferencesStorage(), model = ApplicationModel(storage: store, credentials: noCredentials), server = connection()
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Movie","Type":"Movie"}"#.utf8))
        let controller = NativePlaybackController(item: item, connection: server, client: MediaServerClient(connection: server, token: "test", deviceID: "test")) { _, _ in true }
        model.player = controller
        var changed = model.applicationPreferences
        changed.seekForwardSeconds = 30; changed.autoHideControls = false
        changed.timeDisplay = .remaining; changed.autoPlayNextEpisode = false; changed.subtitleFontSize = 72
        store.failSaving = true
        XCTAssertFalse(model.updateApplicationPreferences(changed))
        XCTAssertEqual(controller.interfacePreferences.seekForwardSeconds, 10)
        store.failSaving = false
        XCTAssertTrue(model.updateApplicationPreferences(changed))
        XCTAssertEqual(controller.interfacePreferences.seekForwardSeconds, 30)
        XCTAssertFalse(controller.interfacePreferences.autoHideControls)
        XCTAssertEqual(controller.interfacePreferences.timeDisplay, .remaining)
        XCTAssertEqual(controller.playbackDefaults.subtitleFontSize, 48)
        XCTAssertEqual(controller.subtitlePresentation.fontSize, 48)
        XCTAssertTrue(controller.autoPlayNextEpisode)
    }

    func testRemovingSelectedConnectionRestoresSameNamedLibraryForNextAccount() async {
        let store = PreferencesStorage(), first = connection(), second = connection("other")
        store.value.connections = [first, second]; store.value.selectedID = first.id
        store.value.librarySortPreferences = [
            .init(identity: .init(connection: first, libraryID: "movies"), sort: .nameDescending),
            .init(identity: .init(connection: second, libraryID: "movies"), sort: .yearDescending)
        ]
        let model = ApplicationModel(storage: store, credentials: noCredentials)
        model.selectedLibraryID = "movies"
        XCTAssertEqual(model.sortOrder, .nameDescending)
        await model.removeConnection(first.id)
        model.selectedLibraryID = "movies"
        XCTAssertEqual(model.sortOrder, .yearDescending)
        XCTAssertEqual(model.saved.librarySortPreferences.count, 1)
        XCTAssertEqual(model.saved.librarySortPreferences.first?.identity.connectionID, second.id)
    }
}
