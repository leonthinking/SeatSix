import Foundation
import XCTest
@testable import SeatSixCore

final class LibraryCatalogTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel(); CatalogURLProtocol.handler = nil
        super.tearDown()
    }

    func testCatalogReadsAllPagesAndFindsItemBeyondFirstPageForBothServers() async throws {
        for kind in [ServerKind.emby, .jellyfin] {
            let requests = CatalogRequestRecorder()
            let progress = CatalogProgressRecorder()
            CatalogURLProtocol.handler = { request in
                requests.append(request)
                let offset = Int(request.catalogQuery["StartIndex"]!)!
                let end = min(offset + 60, 125)
                return ["Items": (offset..<end).map { Self.json(String($0), name: $0 == 124 ? "Unloaded target" : "Movie \($0)") }, "StartIndex": offset, "TotalRecordCount": 125]
            }
            let snapshot = try await client(kind).libraryCatalog(libraryID: "library-1") { await progress.append($0) }
            XCTAssertTrue(snapshot.isComplete)
            XCTAssertEqual(snapshot.items.count, 125)
            XCTAssertEqual(snapshot.total, 125)
            XCTAssertEqual(LibraryQuery(text: "target").apply(to: snapshot.items).map(\.id), ["124"])
            XCTAssertEqual(requests.values.map { $0.catalogQuery["StartIndex"]! }, ["0", "60", "120"])
            for request in requests.values {
                XCTAssertEqual(request.url?.path, "/base/Users/user-1/Items")
                XCTAssertEqual(request.catalogQuery["ParentId"], "library-1")
                XCTAssertEqual(request.catalogQuery["SortBy"], "SortName")
                XCTAssertEqual(request.catalogQuery["SortOrder"], "Ascending")
                XCTAssertEqual(request.catalogQuery["EnableTotalRecordCount"], "true")
                XCTAssertNil(request.catalogQuery["SearchTerm"])
                XCTAssertNil(request.catalogQuery["IsPlayed"])
                XCTAssertNil(request.catalogQuery["Genres"])
                XCTAssertTrue(request.catalogQuery["Fields"]!.contains("Genres"))
            }
            let updates = await progress.values
            XCTAssertEqual(updates.map { $0.items.count }, [60, 120, 125])
            XCTAssertEqual(updates.map(\.isComplete), [false, false, true])
        }
    }

    func testCatalogUsesRawReturnedCountAndAcceptsOmittedStartIndex() async throws {
        let requests = CatalogRequestRecorder()
        CatalogURLProtocol.handler = { request in
            requests.append(request)
            let offset = Int(request.catalogQuery["StartIndex"]!)!
            return ["Items": [Self.json(String(offset))], "TotalRecordCount": 3]
        }
        let snapshot = try await client().libraryCatalog(libraryID: "library-1")
        XCTAssertEqual(snapshot.items.map(\.id), ["0", "1", "2"])
        XCTAssertEqual(requests.values.map { $0.catalogQuery["StartIndex"]! }, ["0", "1", "2"])
    }

    func testCompatibilityCatalogOnlyRequestsMovieAndSeries() async throws {
        let requests = CatalogRequestRecorder()
        CatalogURLProtocol.handler = { request in
            requests.append(request)
            return ["Items": [], "TotalRecordCount": 0]
        }
        let snapshot = try await client(compatibility: true).libraryCatalog(libraryID: "library-1")
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(requests.values.first?.catalogQuery["IncludeItemTypes"], "Movie,Series")
    }

    func testCatalogRejectsOutsideScopeWithoutRequest() async {
        let requests = CatalogRequestRecorder()
        CatalogURLProtocol.handler = { request in requests.append(request); return ["Items": [], "TotalRecordCount": 0] }
        do {
            _ = try await client().libraryCatalog(libraryID: "other-library")
            XCTFail("Out-of-scope library accepted")
        } catch { XCTAssertEqual(error as? MediaServerError, .invalidScope) }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testCatalogRejectsMissingNegativeOrOversizedTotal() async {
        for response in [
            ["Items": [Self.json("one")]],
            ["Items": [], "TotalRecordCount": -1],
            ["Items": [], "TotalRecordCount": 100_001]
        ] {
            CatalogURLProtocol.handler = { _ in response }
            let expected: LibraryCatalogError = (response["TotalRecordCount"] as? Int) == 100_001 ? .tooLarge : .invalidPage
            await assertCatalogFailure(expected)
        }
    }

    func testCatalogRejectsWrongStartAndMoreRowsThanTotal() async {
        for response in [
            ["Items": [Self.json("one")], "TotalRecordCount": 1, "StartIndex": 1],
            ["Items": [Self.json("one")], "TotalRecordCount": 1, "StartIndex": -1],
            ["Items": [Self.json("one"), Self.json("two")], "TotalRecordCount": 1]
        ] {
            CatalogURLProtocol.handler = { _ in response }
            await assertCatalogFailure(.invalidPage)
        }
    }

    func testCatalogRejectsChangingTotalWithoutPublishingInvalidPage() async {
        let progress = CatalogProgressRecorder()
        CatalogURLProtocol.handler = { request in
            let first = request.catalogQuery["StartIndex"] == "0"
            return ["Items": [Self.json(first ? "one" : "two")], "TotalRecordCount": first ? 2 : 3]
        }
        await assertCatalogFailure(.changedDuringLoading, progress: progress)
        let updates = await progress.values
        XCTAssertEqual(updates.map { $0.items.map(\.id) }, [["one"]])
        XCTAssertFalse(updates[0].isComplete)
    }

    func testCatalogRejectsDuplicateIDsWithinAndAcrossPages() async {
        CatalogURLProtocol.handler = { _ in ["Items": [Self.json("one"), Self.json("one")], "TotalRecordCount": 2] }
        await assertCatalogFailure(.invalidPage)
        let progress = CatalogProgressRecorder()
        CatalogURLProtocol.handler = { _ in ["Items": [Self.json("one")], "TotalRecordCount": 2] }
        await assertCatalogFailure(.invalidPage, progress: progress)
        let updates = await progress.values
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].items.count, 1)
    }

    func testCatalogRejectsEmptyPageBeforeTotalAndInvalidItemID() async {
        CatalogURLProtocol.handler = { request in
            ["Items": request.catalogQuery["StartIndex"] == "0" ? [Self.json("one")] : [], "TotalRecordCount": 2]
        }
        let progress = CatalogProgressRecorder()
        await assertCatalogFailure(.invalidPage, progress: progress)
        let updates = await progress.values
        XCTAssertEqual(updates.count, 1)
        for id in ["", "bad/path", "bad\nheader"] {
            CatalogURLProtocol.handler = { _ in ["Items": [Self.json(id)], "TotalRecordCount": 1] }
            await assertCatalogFailure(.invalidPage)
        }
    }

    func testCatalogCancellationBetweenPagesStopsFurtherRequests() async throws {
        let requests = CatalogRequestRecorder()
        CatalogURLProtocol.handler = { request in requests.append(request); return ["Items": [Self.json("one")], "TotalRecordCount": 2] }
        let client = client()
        let task = Task {
            try await client.libraryCatalog(libraryID: "library-1") { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled load completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.values.count, 1)
    }

    func testCombinedSearchYearGenreAndWatchedFilters() throws {
        let items = try [
            Self.json("match", name: "Café 夜行者", year: 2024, genres: [" Drama "], played: true),
            Self.json("year", name: "Cafe 夜行者", year: 2023, genres: ["Drama"], played: true),
            Self.json("genre", name: "Cafe 夜行者", year: 2024, genres: ["Comedy"], played: true),
            Self.json("watch", name: "Cafe 夜行者", year: 2024, genres: ["Drama"], played: false),
            Self.json("title", name: "Different", year: 2024, genres: ["Drama"], played: true)
        ].map(decode)
        let query = LibraryQuery(text: "  ＣＡＦＥ\n夜行  ", year: 2024, genre: "dRaMa ", watched: .watched)
        XCTAssertEqual(query.apply(to: items).map(\.id), ["match"])
        XCTAssertEqual(LibraryQuery(year: 2024, genre: "Drama", watched: .unwatched).apply(to: items).map(\.id), ["watch"])
        XCTAssertTrue(LibraryQuery(text: "does-not-exist").apply(to: items).isEmpty)
    }

    func testSearchBlankTextAndGenreDoNotFilterAndMissingPlayedRemainsUnwatched() throws {
        let items = try [Self.json("one", played: true), ["Id": "two", "Name": "Two", "Type": "Movie"]].map(decode)
        XCTAssertEqual(LibraryQuery(text: " \n\t ", genre: " ").apply(to: items).count, 2)
        XCTAssertEqual(LibraryQuery(watched: .unwatched).apply(to: items).map(\.id), ["two"])
    }

    func testFavoritesCombineWithOtherFiltersAndPreserveSort() throws {
        let items = try [
            Self.json("match-2", name: "Film 2", year: 2024, genres: ["Drama"], played: true, favorite: true),
            Self.json("match-10", name: "Film 10", year: 2024, genres: ["Drama"], played: true, favorite: true),
            Self.json("not-favorite", name: "Film 1", year: 2024, genres: ["Drama"], played: true),
            Self.json("wrong-year", name: "Film 3", year: 2023, genres: ["Drama"], played: true, favorite: true),
            Self.json("wrong-watch", name: "Film 4", year: 2024, genres: ["Drama"], favorite: true),
            Self.json("wrong-genre", name: "Film 5", year: 2024, genres: ["Comedy"], played: true, favorite: true),
            Self.json("wrong-text", name: "Movie 6", year: 2024, genres: ["Drama"], played: true, favorite: true),
            ["Id": "missing-favorite", "Name": "Film 7", "Type": "Movie"]
        ].map(decode)
        let query = LibraryQuery(text: "film", year: 2024, genre: "Drama", watched: .watched, sort: .nameDescending, favoritesOnly: true)
        XCTAssertEqual(query.apply(to: items).map(\.id), ["match-10", "match-2"])
        XCTAssertEqual(LibraryQuery().apply(to: items).count, 8)
        XCTAssertEqual(LibraryQuery(favoritesOnly: true).apply(to: items).count, 6)
    }

    func testFavoritesFindContentBeyondVisibleFirstPageInCompleteCatalog() async throws {
        CatalogURLProtocol.handler = { request in
            let offset = Int(request.catalogQuery["StartIndex"]!)!
            return ["Items": (offset..<min(offset + 60, 125)).map { Self.json(String($0), favorite: $0 == 124) }, "StartIndex": offset, "TotalRecordCount": 125]
        }
        let snapshot = try await client(compatibility: true).libraryCatalog(libraryID: "library-1")
        XCTAssertEqual(LibraryQuery(favoritesOnly: true).apply(to: snapshot.items).map(\.id), ["124"])
        XCTAssertEqual(snapshot.items.count, 125)
        XCTAssertTrue(snapshot.isComplete)
    }

    func testNaturalNameSortAndStableIDTieForBothDirections() throws {
        let items = try [
            Self.json("z", name: "Film 2"), Self.json("a", name: "Film 2"),
            Self.json("b", name: "Film 10"), Self.json("c", name: "Film 1")
        ].map(decode)
        XCTAssertEqual(LibraryQuery().apply(to: items).map(\.id), ["c", "a", "z", "b"])
        XCTAssertEqual(LibraryQuery(sort: .nameDescending).apply(to: Array(items.reversed())).map(\.id), ["b", "a", "z", "c"])
    }

    func testYearSortKeepsUnknownAtEndAndUsesNameThenIDForTies() throws {
        let items = try [
            Self.json("unknown", name: "A"), Self.json("old", name: "Z", year: 1980),
            Self.json("new-z", name: "Z", year: 2024), Self.json("new-a", name: "A", year: 2024)
        ].map(decode)
        XCTAssertEqual(LibraryQuery(sort: .yearDescending).apply(to: items).map(\.id), ["new-a", "new-z", "old", "unknown"])
        XCTAssertEqual(LibraryQuery(sort: .yearAscending).apply(to: items).map(\.id), ["old", "new-a", "new-z", "unknown"])
    }

    func testFacetsCoverWholeInputWithUniqueNormalizedGenresAndYears() throws {
        let items = try [
            Self.json("one", year: 2024, genres: [" Drama", "", "Comedy"]),
            Self.json("two", year: 1980, genres: ["drama ", "COMEDY", "动作"]),
            Self.json("three", year: 2024, genres: ["动作", "   "])
        ].map(decode)
        let facets = LibraryCatalogFacets(items: items)
        XCTAssertEqual(facets.years, [2024, 1980])
        XCTAssertEqual(facets.genres.count, 3)
        XCTAssertEqual(Set(facets.genres), Set(["Drama", "COMEDY", "动作"]))
        XCTAssertEqual(facets, LibraryCatalogFacets(items: Array(items.reversed())))
        XCTAssertTrue(LibraryCatalogFacets(items: []).years.isEmpty)
    }

    func testGenreMetadataFallbackAndPrimaryFieldPrecedence() throws {
        for genres in [NSNull(), [], [" "]] {
            let item = try decode(["Id": "one", "Genres": genres, "GenreItems": [["Name": " 动作 "], ["Name": "Drama"], [:]], "SortName": "sort title"])
            XCTAssertEqual(item.genres, ["动作", "Drama"])
            XCTAssertEqual(item.sortName, "sort title")
        }
        let primary = try decode(["Id": "one", "Genres": ["Primary"], "GenreItems": [["Name": "Fallback"]]])
        XCTAssertEqual(primary.genres, ["Primary"])
        XCTAssertEqual(try decode(["Id": "one"]).genres, [])
    }

    private func client(_ kind: ServerKind = .emby, compatibility: Bool = false) -> MediaServerClient {
        let connection = ServerConnection(kind: kind, name: "fixture", baseURL: URL(string: "https://media.example:9443/base")!, serverID: "server-1", userID: "user-1", username: "fixture", libraryIDs: ["library-1"], compatibilityMode: compatibility)
        return MediaServerClient(connection: connection, token: "fixture-token", deviceID: "test", session: session)
    }

    private func decode(_ json: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func json(_ id: String, name: String = "Movie", year: Int? = nil, genres: [String] = [], played: Bool = false, favorite: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["Id": id, "Name": name, "Type": "Movie", "Genres": genres, "UserData": ["Played": played, "IsFavorite": favorite]]
        if let year { result["ProductionYear"] = year }
        return result
    }

    private func assertCatalogFailure(_ expected: LibraryCatalogError, progress: CatalogProgressRecorder = CatalogProgressRecorder(), file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client().libraryCatalog(libraryID: "library-1") { await progress.append($0) }
            XCTFail("Incomplete or inconsistent catalog accepted", file: file, line: line)
        } catch { XCTAssertEqual(error as? LibraryCatalogError, expected, file: file, line: line) }
        let updates = await progress.values
        XCTAssertFalse(updates.contains(where: \.isComplete), file: file, line: line)
    }
}

private actor CatalogProgressRecorder {
    private(set) var values: [LibraryCatalogSnapshot] = []
    func append(_ snapshot: LibraryCatalogSnapshot) { values.append(snapshot) }
}

private final class CatalogRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class CatalogURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.handler!(request))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var catalogQuery: [String: String] {
        Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}
