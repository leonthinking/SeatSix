import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class SeatSixNavigationTests: XCTestCase {
    func testExplicitSearchPreservesScopeFiltersAndCatalogWithoutRefresh() async throws {
        let fixture = fixture()
        let model = fixture.model
        let navigation = SeatSixNavigation()
        model.items = try [item("existing", name: "Needle", year: 2025)]
        model.total = 1
        model.query = "Needle"
        model.filterYear = 2025
        model.filterGenre = "Drama"
        model.watchFilter = .unwatched
        model.favoritesOnly = true
        model.sortOrder = .yearDescending
        model.detail = model.items.first
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))

        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertNil(model.detail)
        XCTAssertEqual(navigation.searchRequest?.scope, scope)
        XCTAssertEqual(model.query, "Needle")
        XCTAssertEqual(model.filterYear, 2025)
        XCTAssertEqual(model.filterGenre, "Drama")
        XCTAssertEqual(model.watchFilter, .unwatched)
        XCTAssertTrue(model.favoritesOnly)
        XCTAssertEqual(model.sortOrder, .yearDescending)
        XCTAssertEqual(model.items.map(\.id), ["existing"])
        XCTAssertEqual(model.total, 1)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.catalogLoading)
        XCTAssertTrue(navigation.consumeSearchRequest(model: model))
        XCTAssertFalse(navigation.consumeSearchRequest(model: model), "A request only focuses once")
        await Task.yield()
        XCTAssertEqual(fixture.credentials.readCount, 0, "Searching an already loaded library must not refresh or authenticate")
        await model.shutdown()
    }

    func testCancelSearchRestoresOriginAndKeepsLibraryFiltersSeparate() {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        model.query = "Library filter"
        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertEqual(model.searchDraft, "")
        XCTAssertEqual(model.searchTerm, "", "Opening a new search from Home must show recommendations.")
        model.searchTerm = "New search"
        XCTAssertEqual(model.query, "Library filter")
        model.cancelSearch()
        XCTAssertEqual(model.page, "home")
        XCTAssertEqual(model.query, "Library filter")
        model.navigateForward()
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertEqual(model.searchTerm, "New search")
    }

    func testLibrarySearchCarriesTheInlineQueryOnlyFromTheLibrary() {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        model.navigate(to: "library")
        model.query = "Library filter"
        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertEqual(model.searchTerm, "Library filter")
        XCTAssertEqual(model.searchDraft, "Library filter")
        model.cancelSearch()
        XCTAssertEqual(model.page, "library")
        model.navigate(to: "favorites")
        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertTrue(model.searchTerm.isEmpty)
        XCTAssertTrue(model.searchDraft.isEmpty)
        model.cancelSearch()
        XCTAssertEqual(model.page, "favorites")
        XCTAssertEqual(model.query, "Library filter")
    }

    func testSearchDraftSurvivesHistoryWithoutReplacingSubmittedQuery() throws {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        XCTAssertTrue(navigation.requestSearch(model: model))
        model.editSearchDraft("  movie  ")
        XCTAssertTrue(model.searchTerm.isEmpty)
        XCTAssertTrue(model.submitSearchDraft())
        XCTAssertEqual(model.searchTerm, "movie")
        XCTAssertEqual(model.searchDraft, "movie")
        model.editSearchDraft("next")
        model.showDetail(try item("detail"))
        model.navigateBack()
        XCTAssertEqual(model.searchDraft, "next")
        XCTAssertEqual(model.searchTerm, "movie")

        model.navigate(to: "searchServer")
        XCTAssertEqual(model.searchDraft, "next")
        XCTAssertEqual(model.searchTerm, "movie")
        model.editSearchDraft("   ")
        XCTAssertFalse(model.submitSearchDraft())
        XCTAssertEqual(model.searchTerm, "movie")
        model.editSearchDraft("")
        XCTAssertTrue(model.searchTerm.isEmpty)
        model.navigateBack()
        XCTAssertEqual(model.searchDraft, "next")
        XCTAssertEqual(model.searchTerm, "movie")
        model.cancelSearch()
        XCTAssertEqual(model.page, "home")
        XCTAssertTrue(model.searchDraft.isEmpty)
        model.navigateForward()
        XCTAssertEqual(model.searchDraft, "next")
        XCTAssertEqual(model.searchTerm, "movie")
        model.cancelSearch()
        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertTrue(model.searchDraft.isEmpty)
        XCTAssertTrue(model.searchTerm.isEmpty)
    }

    func testUnavailableLibraryCannotRequestSearchOrNavigate() throws {
        let scenarios: [(String, (ApplicationModel) -> Void)] = [
            ("no connection", { $0.saved.selectedID = nil }),
            ("no selection", { $0.selectedLibraryID = "" }),
            ("removed library", { $0.libraries = [] }),
            ("unknown library", { $0.selectedLibraryID = "missing" }),
            ("unselected server library", { $0.saved.connections[0].libraryIDs = ["other"] })
        ]
        for (name, change) in scenarios {
            let model = fixture().model
            change(model)
            let navigation = SeatSixNavigation()
            XCTAssertFalse(navigation.canSearch(model: model), name)
            XCTAssertFalse(navigation.requestSearch(model: model), name)
            XCTAssertEqual(model.page, "home", name)
            XCTAssertNil(navigation.searchRequest, name)
        }
    }

    func testDelayedSearchRejectsEveryAccessibleIdentityBoundary() throws {
        let scenarios: [(String, (ApplicationModel) -> Void)] = [
            ("connection", {
                let replacementID = UUID()
                $0.saved.connections[0].id = replacementID
                $0.saved.selectedID = replacementID
            }),
            ("server", { $0.saved.connections[0].serverID = "another-server" }),
            ("user", { $0.saved.connections[0].userID = "another-user" }),
            ("URL", { $0.saved.connections[0].baseURL = URL(string: "https://another.invalid")! }),
            ("library", { $0.selectedLibraryID = "other" })
        ]
        for (name, change) in scenarios {
            let model = fixture().model
            let navigation = SeatSixNavigation()
            XCTAssertTrue(navigation.requestSearch(model: model))
            change(model)
            XCTAssertTrue(navigation.canSearch(model: model), "The new \(name) is valid, but does not own the old request")
            XCTAssertFalse(navigation.consumeSearchRequest(model: model), name)
            XCTAssertNil(navigation.searchRequest, name)
        }
    }

    func testInterveningRouteDetailAndModalDiscardPendingFocus() throws {
        let movie = try item("movie")
        let scenarios: [(String, (ApplicationModel) -> Void)] = [
            ("other page", { $0.page = "home" }),
            ("detail", { $0.detail = movie }),
            ("login", { $0.showLogin = true }),
            ("preparing playback", { $0.launchingPlayback = true }),
            ("recovery", { model in
                model.recoveryPrompt = ApplicationModel.RecoveryPrompt(item: movie, connection: model.connection!,
                    mode: .automatic, mediaSourceID: nil, remoteTicks: 0, localTicks: 10_000_000,
                    generation: UUID(), sequence: nil, reuseWindow: false, autoPlayNext: false,
                    continuationOwner: nil, manualSwitchID: nil, playbackDefaults: .init())
            })
        ]
        for (name, change) in scenarios {
            let model = fixture().model
            let navigation = SeatSixNavigation()
            XCTAssertTrue(navigation.requestSearch(model: model))
            change(model)
            XCTAssertFalse(navigation.consumeSearchRequest(model: model), name)
            XCTAssertNil(navigation.searchRequest, name)
        }
    }

    func testModalAndPlaybackLaunchBlockSearchButExistingPlayerAllowsMainWindowBrowsing() throws {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        model.showLogin = true
        XCTAssertFalse(navigation.requestSearch(model: model))
        model.showLogin = false
        model.launchingPlayback = true
        XCTAssertFalse(navigation.requestSearch(model: model))
        model.launchingPlayback = false
        let connection = try XCTUnwrap(model.connection)
        model.player = NativePlaybackController(item: try item("playing"), connection: connection,
            client: MediaServerClient(connection: connection, token: "synthetic", deviceID: "test"), save: { _, _ in true })
        let player = model.player
        XCTAssertTrue(navigation.canSearch(model: model))
        XCTAssertTrue(navigation.requestSearch(model: model))
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertTrue(model.player === player, "Main-window browsing must preserve the existing playback session")
        XCTAssertTrue(navigation.consumeSearchRequest(model: model))
        model.player = nil
    }

    func testOldFocusTaskCannotConsumeNewerExplicitRequest() throws {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        XCTAssertTrue(navigation.requestSearch(model: model))
        let first = try XCTUnwrap(navigation.searchRequest)
        XCTAssertTrue(navigation.requestSearch(model: model))
        let second = try XCTUnwrap(navigation.searchRequest)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(navigation.consumeSearchRequest(model: model, requestID: first.id))
        XCTAssertEqual(navigation.searchRequest, second)
        XCTAssertTrue(navigation.consumeSearchRequest(model: model, requestID: second.id))
        XCTAssertFalse(navigation.consumeSearchRequest(model: model, requestID: second.id))
    }

    func testCatalogProgressAndResultReorderingNeverReplayFocus() throws {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        model.query = "e"
        model.items = try [item("z", name: "Zebra")]
        XCTAssertTrue(navigation.requestSearch(model: model))
        let request = try XCTUnwrap(navigation.searchRequest)
        model.items = try [item("z", name: "Zebra"), item("a", name: "Apple")]
        XCTAssertEqual(model.displayedItems.map(\.id), ["a", "z"])
        XCTAssertEqual(navigation.searchRequest, request, "Catalog arrival must not replace an explicit request")
        XCTAssertTrue(navigation.consumeSearchRequest(model: model))
        model.items = try [item("z", name: "Zebra"), item("a", name: "Apple"), item("b", name: "Berry")]
        model.query = "Berry"
        XCTAssertEqual(model.displayedItems.map(\.id), ["b"])
        XCTAssertNil(navigation.searchRequest)
        XCTAssertFalse(navigation.consumeSearchRequest(model: model), "Typing and late pages must not steal focus from a result or another control")
    }

    func testExplicitInvalidationCancelsRapidAwayAndBack() {
        let model = fixture().model
        let navigation = SeatSixNavigation()
        XCTAssertTrue(navigation.requestSearch(model: model))
        navigation.invalidate()
        model.page = "home"
        model.page = "library"
        XCTAssertFalse(navigation.consumeSearchRequest(model: model))
        XCTAssertNil(navigation.searchRequest)
    }

    private func fixture() -> (model: ApplicationModel, credentials: NavigationCredentialSpy) {
        let connection = ServerConnection(kind: .emby, name: "合成 NAS", baseURL: URL(string: "https://navigation.invalid")!,
            serverID: "server", userID: "user", username: "fixture", libraryIDs: ["movies", "other"])
        var saved = SavedApplication()
        saved.connections = [connection]
        saved.selectedID = connection.id
        let credentials = NavigationCredentialSpy()
        let model = ApplicationModel(storage: NavigationMemoryStorage(saved), credentials: credentials.access,
            subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("seatsix-navigation-unused-\(UUID().uuidString)")))
        model.libraries = [MediaLibrary(id: "movies", name: "电影"), MediaLibrary(id: "other", name: "其他")]
        model.selectedLibraryID = "movies"
        return (model, credentials)
    }

    private func item(_ id: String, name: String = "合成影片", year: Int = 2026) throws -> MediaItem {
        let object: [String: Any] = ["Id": id, "Name": name, "Type": "Movie", "ProductionYear": year,
            "Genres": ["Drama"], "UserData": ["Played": false, "IsFavorite": true, "PlaybackPositionTicks": 0]]
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private final class NavigationMemoryStorage: ApplicationPersisting {
    private var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}

private final class NavigationCredentialSpy {
    var readCount = 0
    var access: CredentialAccess {
        CredentialAccess(read: { [self] _ in
            readCount += 1
            throw CredentialStoreError.notFound
        }, save: { _, _ in XCTFail("Search must not store credentials") },
           remove: { _ in XCTFail("Search must not remove credentials") })
    }
}
