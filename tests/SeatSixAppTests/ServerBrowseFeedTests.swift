import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class ServerBrowseFeedTests: XCTestCase {
    private func fixture(compatibility: Bool = false, restoredPage: String? = nil) -> ServerFeedFixture {
        let fixture = ServerFeedFixture(compatibility: compatibility, restoredPage: restoredPage)
        addTeardownBlock { await fixture.close() }
        return fixture
    }

    private static func item(_ id: String, type: String = "Movie", date: String? = "2026-11-01T00:00:00Z",
                             ticks: Int64 = 0, played: Bool = false, knownPlayed: Bool = true, favorite: Bool = false) -> [String: Any] {
        var state: [String: Any] = ["PlaybackPositionTicks": ticks, "IsFavorite": favorite]
        if knownPlayed { state["Played"] = played }
        var value: [String: Any] = ["Id": id, "Name": id, "Type": type, "UserData": state]
        if let date { value["DateCreated"] = date }
        return value
    }

    private static func page(_ items: [[String: Any]], offset: Int = 0, total: Int? = nil) -> [String: Any] {
        ["Items": items, "TotalRecordCount": total ?? items.count, "StartIndex": offset]
    }

    private func wait(_ label: String = "Expected feed state", _ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), label)
    }

    func testServerSearchUsesOnlyAuthorizedLibrariesAndRestoresQueryFromDetail() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            if request.url!.path.hasSuffix("/Items/match-b") { return .init(body: Self.item("match-b")) }
            return .init(body: Self.page([Self.item("match-" + (request.serverFeedQuery["ParentId"] ?? ""))]))
        }
        let model = fixture.model
        model.libraries = [MediaLibrary(id: "a", name: "Current")]
        model.selectedLibraryID = "a"
        model.navigate(to: "searchLibrary")
        model.searchTerm = "match"
        model.navigate(to: "searchServer")
        try await wait { model.serverBrowseComplete }
        XCTAssertEqual(model.serverBrowseLibraryIDs, ["a", "b"])
        XCTAssertEqual(log.requests.compactMap { $0.serverFeedQuery["ParentId"] }, ["a", "b"])
        let result = SearchPresentation.results(model.serverBrowseCatalogItems, query: "match-b", offset: 0)
        XCTAssertEqual(result.map(\.id), ["match-b"])
        model.showDetail(try XCTUnwrap(result.first))
        try await wait { !model.detailLoading }
        model.navigateBack()
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.page, "searchServer")
        XCTAssertEqual(model.searchTerm, "match")
        model.cancelSearch()
        XCTAssertEqual(model.page, "home")
    }

    func testServerSearchExhaustsPagesForSameNamedLibrariesKeepsDistinctIDsAndCancelsLateRequests() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        let delayed = ServerFeedFlag(false)
        let all: [String: [[String: Any]]] = Dictionary(uniqueKeysWithValues: ["a", "b"].map { library in
            let rows = (0..<63).map { n -> [String: Any] in
                var row = Self.item(n == 0 ? "shared" : "\(library)-\(n)")
                row["Name"] = n == 62 ? "共同片名" : "其他影片"
                return row
            }
            return (library, rows)
        })
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") {
                return .init(body: ["Items": ["a", "b", "private"].map { ["Id": $0, "Name": "同一库名", "CollectionType": "movies"] }])
            }
            let query = request.serverFeedQuery
            let rows = all[query["ParentId"] ?? ""] ?? []
            let start = Int(query["StartIndex"] ?? "0") ?? 0
            return .init(body: Self.page(Array(rows.dropFirst(start).prefix(60)), offset: start, total: rows.count),
                         delay: delayed.value ? 0.2 : 0)
        }
        let model = fixture.model
        model.searchTerm = "共同片名"
        model.page = "searchServer"
        try await wait { model.serverBrowseComplete }
        XCTAssertEqual(log.requests.compactMap { request -> String? in
            let q = request.serverFeedQuery
            return q["ParentId"].map { $0 + "/" + (q["StartIndex"] ?? "?") }
        }, ["a/0", "a/60", "b/0", "b/60"])
        XCTAssertEqual(model.serverBrowseCatalogItems.count, 125)
        XCTAssertEqual(SearchPresentation.results(model.serverBrowseCatalogItems, query: model.searchTerm, offset: 0).map(\.id), ["a-62", "b-62"])
        delayed.value = true
        model.refreshServerBrowse()
        try await wait { log.requests.filter { $0.serverFeedQuery["ParentId"] == "a" }.count == 3 }
        model.navigate(to: "searchLibrary")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.serverBrowseCatalogItems.isEmpty)
        XCTAssertFalse(model.serverBrowseComplete)
        XCTAssertEqual(model.searchTerm, "共同片名")
    }

    func testFavoritesReadSelectedLibrariesAndConfirmFavoriteFlagsAndSupportedTypes() async throws {
        for compatibility in [false, true] {
            let fixture = fixture(compatibility: compatibility)
            let log = ServerFeedRequestLog()
            ServerFeedProtocol.handler = { request in
                log.append(request)
                if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
                let library = request.serverFeedQuery["ParentId"] ?? ""
                let rows = [Self.item("movie-" + library, favorite: true), Self.item("series", type: "Series", favorite: true),
                            Self.item("ignored-filter"), Self.item("episode", type: "Episode", favorite: true),
                            Self.item("video", type: "Video", favorite: true), Self.item("folder", type: "Folder", favorite: true)]
                return .init(body: Self.page(rows))
            }
            let model = fixture.model
            model.query = "only my existing library"; model.favoritesOnly = false
            model.page = "favorites"
            try await wait { model.serverBrowseComplete }
            let requests = log.requests.map(\.serverFeedQuery).filter { $0["ParentId"] != nil }
            XCTAssertEqual(requests.compactMap { $0["ParentId"] }, ["a", "b"])
            XCTAssertTrue(requests.allSatisfy { $0["Filters"] == "IsFavorite" })
            let expectedTypes = compatibility ? "Movie,Series" : "Movie,Series,Video,Episode"
            XCTAssertTrue(requests.allSatisfy { $0["IncludeItemTypes"] == expectedTypes })
            XCTAssertEqual(model.serverBrowseCatalogItems.map(\.id), compatibility
                           ? ["movie-a", "movie-b", "series"] : ["episode", "movie-a", "movie-b", "series", "video"])
            XCTAssertFalse(model.favoritesOnly)
            XCTAssertEqual(model.query, "only my existing library")
            await fixture.close()
        }
    }

    func testRemovingFavoriteInDetailClearsItsCardBeforeAndAfterTheRefreshedFeedReturns() async throws {
        let fixture = fixture()
        let favorite = ServerFeedFlag(true)
        let requests = ServerFeedRequestLog()
        ServerFeedProtocol.handler = { request in
            requests.append(request)
            let path = request.url!.path
            if path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            if path.hasSuffix("/FavoriteItems/film"), request.httpMethod == "DELETE" {
                favorite.value = false
                return .init(body: [:])
            }
            let movie = Self.item("film", favorite: favorite.value)
            if path.hasSuffix("/Items/film") { return .init(body: movie) }
            if path.hasSuffix("/Resume") { return .init(body: Self.page([])) }
            let rows = request.serverFeedQuery["ParentId"] == "a" ? [movie] : []
            let refreshingFavorites = request.serverFeedQuery["Filters"] == "IsFavorite" && !favorite.value
            return .init(body: Self.page(rows), delay: refreshingFavorites ? 0.25 : 0)
        }
        let model = fixture.model
        model.refresh()
        try await wait { model.catalogComplete && !model.loading }
        model.navigate(to: "favorites")
        try await wait { model.serverBrowseComplete }
        let movie = try XCTUnwrap(model.serverBrowseCatalogItems.first)
        model.showDetail(movie)
        try await wait { model.detail?.id == movie.id && !model.detailLoading }
        model.toggleFavorite(movie)
        try await wait { !model.userStateBusy && !favorite.value }
        XCTAssertNil(model.userStateError)
        XCTAssertEqual(model.detail?.userData.isFavorite, false)
        model.navigateBack()
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.page, "favorites")
        XCTAssertTrue(model.serverBrowseLoading)
        XCTAssertTrue(model.serverBrowseCatalogItems.isEmpty, "The removed card must disappear while the refreshed page loads")
        try await wait { model.serverBrowseComplete }
        XCTAssertTrue(model.serverBrowseCatalogItems.isEmpty)
        XCTAssertEqual(requests.requests.filter { $0.httpMethod == "DELETE" }.count, 1)
    }

    func testRecentReadsAllSelectedAvailableLibrariesDeduplicatesAndDoesNotChangeCurrentLibraryFilters() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        let first = (0..<65).map { Self.item("a-\($0)", date: "2026-10-01T00:00:00Z") }
        let second = [Self.item("a-0"), Self.item("latest", date: "2026-11-17T00:00:00Z"), Self.item("undated", date: nil)]
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            let query = request.serverFeedQuery
            let all = query["ParentId"] == "a" ? first : second
            let offset = Int(query["StartIndex"] ?? "0")!
            return .init(body: Self.page(Array(all.dropFirst(offset).prefix(60)), offset: offset, total: all.count))
        }
        let model = fixture.model
        model.libraries = [MediaLibrary(id: "a", name: "Current")]; model.selectedLibraryID = "a"
        model.query = "preserved"; model.filterYear = 1999; model.watchFilter = .watched; model.sortOrder = .yearAscending
        let original = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: Self.item("current-only")))
        model.items = [original]
        model.page = "recent"
        try await wait { model.serverBrowseComplete }
        XCTAssertEqual(model.serverRecentItems.count, 66, "The full page must not truncate to the home's 12 cards")
        XCTAssertEqual(model.serverRecentItems.first?.id, "latest")
        XCTAssertEqual(model.serverBrowseMissingDateCount, 1)
        XCTAssertEqual(model.serverBrowseCatalogItems.count, 67)
        XCTAssertEqual(model.serverBrowseLibraryIDs, ["a", "b"])
        XCTAssertEqual(model.items, [original]); XCTAssertEqual(model.selectedLibraryID, "a")
        XCTAssertEqual(model.query, "preserved"); XCTAssertEqual(model.filterYear, 1999)
        XCTAssertEqual(model.watchFilter, .watched); XCTAssertEqual(model.sortOrder, .yearAscending)
        let parents = log.requests.compactMap { $0.serverFeedQuery["ParentId"] }
        XCTAssertEqual(parents, ["a", "a", "b"], "Never fetch a removed selection or an unselected server view")
    }

    func testCompatibilityContinuingUsesCompleteMultiLibraryCatalogAndOnlyKnownPositiveUnplayedProgress() async throws {
        let fixture = fixture(compatibility: true)
        let log = ServerFeedRequestLog()
        let a = [Self.item("movie", ticks: 12), Self.item("played", ticks: 20, played: true), Self.item("unknown", ticks: 10, knownPlayed: false)]
        let b = [Self.item("show", type: "Series", ticks: 18), Self.item("zero"), Self.item("negative", ticks: -1), Self.item("folder", type: "Folder", ticks: 2)]
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            return .init(body: Self.page(request.serverFeedQuery["ParentId"] == "a" ? a : b))
        }
        fixture.model.page = "continuing"
        try await wait { fixture.model.serverBrowseComplete }
        XCTAssertEqual(fixture.model.serverContinuingItems.map(\.id), ["movie", "show"])
        XCTAssertFalse(log.requests.contains { $0.url!.path.hasSuffix("/Resume") })
        XCTAssertTrue(fixture.model.items.isEmpty, "Server feeds must not replace the selected-library catalog")
    }

    func testNormalContinuingReadsBeyondTwentyAndUsesFreshViewsIntersection() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            let query = request.serverFeedQuery
            let count = query["ParentId"] == "a" ? 75 : 1
            let offset = Int(query["StartIndex"]!)!
            return .init(body: Self.page((offset..<min(offset + 60, count)).map { Self.item("\(query["ParentId"]!)-\($0)", type: "Episode") }, offset: offset, total: count))
        }
        fixture.model.page = "continuing"
        try await wait { fixture.model.serverBrowseComplete }
        XCTAssertEqual(fixture.model.serverContinuingItems.count, 76)
        XCTAssertEqual(log.requests.filter { $0.url!.path.hasSuffix("/Resume") }.map { $0.serverFeedQuery["ParentId"]! }, ["a", "a", "b"])
        XCTAssertTrue(fixture.model.continuing.isEmpty, "The full feed must not rewrite the homepage rail")
    }

    func testPartialFailureKeepsAcceptedDataAndRetryReplacesItWithCompleteResults() async throws {
        let fixture = fixture()
        let failure = ServerFeedFlag(true)
        ServerFeedProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            if request.serverFeedQuery["ParentId"] == "b", failure.value { return .init(status: 500, body: [:]) }
            return .init(body: Self.page([Self.item(request.serverFeedQuery["ParentId"]!)]))
        }
        fixture.model.page = "recent"
        try await wait { fixture.model.serverBrowseError != nil }
        XCTAssertFalse(fixture.model.serverBrowseComplete); XCTAssertFalse(fixture.model.serverBrowseLoading)
        XCTAssertEqual(fixture.model.serverRecentItems.map(\.id), ["a"])
        failure.value = false
        fixture.model.refreshServerBrowse()
        try await wait { fixture.model.serverBrowseComplete }
        XCTAssertNil(fixture.model.serverBrowseError)
        XCTAssertEqual(Set(fixture.model.serverRecentItems.map(\.id)), Set(["a", "b"]))
    }

    func testLeavingCancelsAndReenteringRetriesWithoutLatePreviousRouteResults() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            return .init(body: Self.page([Self.item("late-\(request.serverFeedQuery["ParentId"]!)")]), delay: 0.2)
        }
        let model = fixture.model
        model.page = "recent"
        try await wait { log.requests.contains { $0.serverFeedQuery["ParentId"] == "a" } }
        model.page = "home"
        XCTAssertFalse(model.serverBrowseLoading); XCTAssertTrue(model.serverRecentItems.isEmpty)
        XCTAssertTrue(model.serverBrowseLibraryIDs.isEmpty)
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertFalse(model.serverBrowseComplete); XCTAssertTrue(model.serverRecentItems.isEmpty)
        model.page = "recent"
        try await wait { model.serverBrowseComplete }
        XCTAssertEqual(model.serverRecentItems.count, 2)
        XCTAssertEqual(log.requests.filter { $0.url!.path.hasSuffix("/Views") }.count, 2)
    }

    func testSwitchingConnectionsClearsFeedBeforeLateResponsesAndNewFeedUsesNewAccount() async throws {
        let fixture = fixture()
        let log = ServerFeedRequestLog()
        ServerFeedProtocol.handler = { request in
            log.append(request)
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            let old = request.url!.path.contains("/user/")
            let body = Self.page([Self.item(old ? "old-account" : "new-account")])
            return .init(body: body, delay: old ? 0.25 : 0)
        }
        let model = fixture.model
        model.page = "recent"
        try await wait { log.requests.contains { $0.serverFeedQuery["ParentId"] == "a" } }
        var other = fixture.connection; other.id = UUID(); other.userID = "other-user"
        model.saved.connections.append(other)
        model.switchConnection(other.id)
        XCTAssertTrue(model.serverRecentItems.isEmpty); XCTAssertFalse(model.serverBrowseComplete)
        model.page = "recent"
        try await wait { model.serverBrowseComplete }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.serverRecentItems.map(\.id), ["new-account"])
    }

    func testEachServerRouteRestoresAtStartupAndDetailReturnsToItsNamedOrigin() async throws {
        for (route, title) in [("continuing", "返回继续观看"), ("recent", "返回最近添加"), ("favorites", "返回收藏"), ("movies", "返回电影"), ("series", "返回剧集"), ("other", "返回其他")] {
            let fixture = fixture(restoredPage: route)
            ServerFeedProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
                if request.url!.lastPathComponent == "detail-item" { return .init(body: Self.item("detail-item")) }
                return .init(body: Self.page([Self.item("fixture")]))
            }
            fixture.model.refresh()
            try await wait { fixture.model.page == route && fixture.model.serverBrowseComplete && !fixture.model.catalogLoading }
            let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: Self.item("detail-item")))
            fixture.model.showDetail(item)
            try await wait("The real detail request must complete before returning") { !fixture.model.detailLoading }
            XCTAssertEqual(fixture.model.detail?.id, "detail-item")
            XCTAssertEqual(fixture.model.detailBackTitle, title)
            fixture.model.goBackFromDetail()
            XCTAssertEqual(fixture.model.page, route)
            XCTAssertTrue(fixture.model.serverBrowseComplete)
            XCTAssertEqual(fixture.storage.value.browsingLocations.first?.page, route)
            await fixture.close()
        }
    }

    func testTypeRoutesReadRealTypesAcrossLibrariesAndRefreshInvalidatesPreviousResults() async throws {
        let fixture = fixture()
        let updated = ServerFeedFlag(false)
        ServerFeedProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ServerFeedFixture.views) }
            let suffix = updated.value ? "new" : "old"
            return .init(body: Self.page([Self.item("movie-\(suffix)"), Self.item("series-\(suffix)", type: "Series"),
                                          Self.item("video-\(suffix)", type: "Video"), Self.item("folder", type: "Folder")]))
        }
        for route in ["movies", "series", "other"] {
            fixture.model.page = route
            try await wait { fixture.model.serverBrowseComplete }
            XCTAssertEqual(Set(fixture.model.serverBrowseCatalogItems.map(\.type)), Set(["Movie", "Series", "Video", "Folder"]))
        }
        updated.value = true
        fixture.model.refresh()
        XCTAssertFalse(fixture.model.serverBrowseComplete)
        XCTAssertTrue(fixture.model.serverBrowseCatalogItems.isEmpty)
        try await wait { fixture.model.serverBrowseComplete }
        XCTAssertTrue(fixture.model.serverBrowseCatalogItems.contains { $0.id == "movie-new" })
        XCTAssertFalse(fixture.model.serverBrowseCatalogItems.contains { $0.id == "movie-old" })
    }
}

@MainActor
private final class ServerFeedFixture {
    let model: ApplicationModel
    let connection: ServerConnection
    let storage: ServerFeedStorage
    let session: URLSession
    static let views: [String: Any] = ["Items": [
        ["Id": "a", "Name": "Arbitrary library", "CollectionType": "movies"],
        ["Id": "b", "Name": "Mixed content", "CollectionType": "mixed"],
        ["Id": "unselected", "Name": "Not selected", "CollectionType": "tvshows"]
    ]]

    init(compatibility: Bool, restoredPage: String?) {
        connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://feed.test")!, serverID: "server", userID: "user",
            username: "fixture", libraryIDs: ["a", "b", "removed"], compatibilityMode: compatibility)
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        if let restoredPage {
            saved.applicationPreferences.startupPage = .lastBrowsed
            saved.browsingLocations = [.init(connection: connection, page: restoredPage, libraryID: "a")]
        }
        storage = ServerFeedStorage(saved)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ServerFeedProtocol.self]
        let session = URLSession(configuration: configuration); self.session = session
        model = ApplicationModel(storage: storage, credentials: .init(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
                                 clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) })
    }
    private var closed = false
    func close() async {
        guard !closed else { return }
        closed = true
        // A feed can finish before the independent Home catalog/resume request.
        // Do not invalidate its session while one of those tasks can still issue
        // its next request, including a just-scheduled detail load.
        let deadline = Date().addingTimeInterval(4)
        while isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let settled = !isLoading
        XCTAssertTrue(settled, "Fixture requests must settle before its URLSession is invalidated")
        await model.shutdown()
        if settled { session.invalidateAndCancel() }
        ServerFeedProtocol.handler = nil
    }
    private var isLoading: Bool {
        model.loading || model.catalogLoading || model.continuingLoading || model.serverBrowseLoading
            || model.detailLoading || model.userStateBusy
    }
}

private final class ServerFeedStorage: ApplicationPersisting {
    var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}

private final class ServerFeedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body: [String: Any]; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) -> Reply)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let cancelled = cancelled; lock.unlock()
            guard !cancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class ServerFeedRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class ServerFeedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private extension URLRequest {
    var serverFeedQuery: [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
