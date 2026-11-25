import Foundation
import XCTest
@testable import SeatSixCore

final class HomeLibraryContentTests: XCTestCase {
    func testServerCreationDatesDecodeWithAndWithoutFractionalSeconds() throws {
        let plain = try item("plain", date: "2026-10-24T06:00:00Z")
        let fractional = try item("fractional", date: "2026-10-24T06:00:00.1234567Z")
        let offset = try item("offset", date: "2026-10-24T14:00:00+08:00")
        let first = try XCTUnwrap(plain.dateCreated)
        XCTAssertEqual(try XCTUnwrap(offset.dateCreated), first)
        XCTAssertEqual(try XCTUnwrap(fractional.dateCreated).timeIntervalSince(first), 0.1234567, accuracy: 0.00001)
    }

    func testMissingNullAndMalformedCreationDatesDoNotBreakMediaDecoding() throws {
        for value in [nil, NSNull(), "", "not a date", "2026-99-99T12:00:00Z", "2026-02-30T12:00:00Z",
                      "2026-10-24T25:00:00Z", "2026-10-24T12:00:00Zgarbage", "2026-10-24T12:00:00Z\n",
                      "2026-10-24T12:00:00", 42, ["year": 2026]] as [Any?] {
            let media = try item("valid-movie", date: value, year: 2026)
            XCTAssertEqual(media.id, "valid-movie")
            XCTAssertNil(media.dateCreated)
            XCTAssertTrue(HomeLibraryContent.recentlyAdded(from: [media]).isEmpty,
                          "An unknown addition date must never be replaced with the production year")
        }
    }

    func testRecentItemsUseAdditionDateRatherThanReleaseYearOrInputOrder() throws {
        let recentlyAddedOldMovie = try item("old-movie", date: "2026-10-24T00:00:00Z", year: 1950)
        let olderAdditionNewRelease = try item("new-release", date: "2026-10-22T00:00:00Z", year: 2026)
        let recentSeries = try item("series", type: "Series", date: "2026-10-23T00:00:00Z")
        let unknownDate = try item("unknown", year: 2027)
        let input = [unknownDate, olderAdditionNewRelease, recentlyAddedOldMovie, recentSeries]
        XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: input).map(\.id), ["old-movie", "series", "new-release"])
        XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: Array(input.reversed())).map(\.id), ["old-movie", "series", "new-release"])
        XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: input, limit: 2).map(\.id), ["old-movie", "series"])
        XCTAssertTrue(HomeLibraryContent.recentlyAdded(from: input, limit: 0).isEmpty)
        XCTAssertTrue(HomeLibraryContent.recentlyAdded(from: input, limit: -1).isEmpty)
    }

    func testTiedDatesAreDeterministicAndDoNotCollapseDistinctEpisodesOrVersions() throws {
        let date = "2026-10-24T00:00:00Z"
        let input = try [
            item("z", name: "Episode 10", type: "Episode", date: date),
            item("b", name: "Episode 2", type: "Episode", date: date),
            item("a", name: "Episode 2", type: "Episode", date: date),
            item("video", name: "Home video", type: "Video", date: date),
            item("folder", name: "A folder", type: "Folder", date: date),
            item("season", name: "A season", type: "Season", date: date)
        ]
        XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: input).map(\.id), ["a", "b", "z", "video"])
        XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: Array(input.reversed())).map(\.id), ["a", "b", "z", "video"])
    }

    func testBothCatalogModesRequestDatesAndLatestCanArriveOnLaterPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeContentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); HomeContentURLProtocol.handler = nil }
        for compatibility in [false, true] {
            let recorder = HomeContentRequests()
            HomeContentURLProtocol.handler = { request in
                recorder.append(request)
                let query = Self.query(request)
                let later = query["StartIndex"] == "1"
                return ["Items": [["Id": later ? "late-page" : "first-page", "Type": "Movie", "Name": later ? "Z" : "A",
                                   "DateCreated": later ? "2026-10-24T00:00:00Z" : "2026-01-01T00:00:00Z"]],
                        "TotalRecordCount": 2, "StartIndex": later ? 1 : 0]
            }
            let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test/base")!,
                                              serverID: "server", userID: "user", username: "test", libraryIDs: ["library"], compatibilityMode: compatibility)
            let client = MediaServerClient(connection: connection, token: "test", deviceID: "device", session: session)
            let progress = HomeContentProgress()
            let full = try await client.libraryCatalog(libraryID: "library") { await progress.append($0) }
            let snapshots = await progress.values
            XCTAssertFalse(snapshots[0].isComplete)
            XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: snapshots[0].items).map(\.id), ["first-page"])
            XCTAssertTrue(full.isComplete)
            XCTAssertEqual(HomeLibraryContent.recentlyAdded(from: full.items).map(\.id), ["late-page", "first-page"])
            for request in recorder.values {
                let query = Self.query(request)
                XCTAssertTrue(query["Fields"]!.split(separator: ",").contains("DateCreated"))
                XCTAssertEqual(query["ParentId"], "library")
                XCTAssertEqual(query["SortBy"], "SortName", "Addition metadata must not change catalog pagination ordering")
                XCTAssertEqual(query["IncludeItemTypes"], compatibility ? "Movie,Series" : "Movie,Series,Video")
            }
        }
    }

    private func item(_ id: String, name: String? = nil, type: String = "Movie", date: Any? = nil, year: Int? = nil) throws -> MediaItem {
        var data: [String: Any] = ["Id": id, "Name": name ?? id, "Type": type]
        if let date { data["DateCreated"] = date }
        if let year { data["ProductionYear"] = year }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: data))
    }

    private static func query(_ request: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}

private actor HomeContentProgress {
    private(set) var values: [LibraryCatalogSnapshot] = []
    func append(_ snapshot: LibraryCatalogSnapshot) { values.append(snapshot) }
}

private final class HomeContentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class HomeContentURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.handler!(request))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
