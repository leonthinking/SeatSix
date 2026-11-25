import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixProbe

final class LibraryCatalogProbeTests: XCTestCase {
    private func item(_ id: String, year: Int? = 2000, genres: [String] = ["Drama"], played: Bool = false) throws -> MediaItem {
        var fields: [String: Any] = ["Id": id, "Name": "Title \(id)", "Type": "Movie", "Genres": genres,
            "UserData": ["Played": played, "PlaybackPositionTicks": 0]]
        if let year { fields["ProductionYear"] = year }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testAcceptanceUsesAllTitlesBeyondTheOldPageAndBothWatchStates() throws {
        let items = try (0..<83).map { try item(String($0), year: $0.isMultiple(of: 3) ? nil : 2000 + $0 % 4,
            genres: $0.isMultiple(of: 2) ? ["Drama", "Action"] : ["Comedy"], played: $0.isMultiple(of: 4)) }
        let report = LibraryCatalogProbe.evaluate(items: Array(items.reversed()), reference: items)
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["beyondFirstPageTitleCount"] as? Int, 23)
        XCTAssertEqual(report["watchedCount"] as? Int, 21)
        XCTAssertEqual(report["watchedPositiveAvailable"] as? Bool, true)
        XCTAssertEqual(report["unwatchedPositiveAvailable"] as? Bool, true)
    }

    func testAcceptanceRejectsMissingItemsEvenIfTheRemainingQueriesWork() throws {
        let reference = try (0..<75).map { try item(String($0)) }
        let report = LibraryCatalogProbe.evaluate(items: Array(reference.prefix(60)), reference: reference)
        XCTAssertEqual(report["passed"] as? Bool, false)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first { $0["name"] as? String == "everyTitleBeyondFirstPageIsSearchable" }?["passed"] as? Bool, false)
        XCTAssertEqual(checks.first { $0["name"] as? String == "independentPaginationIdentitySet" }?["passed"] as? Bool, false)
    }

    func testAcceptanceRejectsDuplicateCatalogIdentifiers() throws {
        let movie = try item("a")
        XCTAssertEqual(LibraryCatalogProbe.evaluate(items: [movie, movie], reference: [movie])["passed"] as? Bool, false)
    }

    func testEmptyPositiveSetsAreReportedUnavailable() throws {
        let movie = try item("a", year: nil, genres: [])
        let report = LibraryCatalogProbe.evaluate(items: [movie], reference: [movie])
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["watchedPositiveAvailable"] as? Bool, false)
        XCTAssertEqual(report["beyondFirstPagePositiveAvailable"] as? Bool, false)
        XCTAssertEqual(report["combinedFilterSampleCount"] as? Int, 0)
    }

    func testPublicEvaluationContainsNoMediaNamesOrIdentifiers() throws {
        let movie = try item("private-unique-film-id")
        let result = LibraryCatalogProbe.evaluate(items: [movie], reference: [movie])
        let json = try JSONSerialization.data(withJSONObject: result)
        let text = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(text.contains(movie.id))
        XCTAssertFalse(text.contains(movie.name))
        XCTAssertFalse(text.contains("Drama"))
    }

    func testActualProbeTraversesBothPathsReadOnlyAndAcceptsOfficialResultsWithoutStartIndex() async throws {
        let rows: [[String: Any]] = (0..<65).map { ["Id": "movie-\($0)", "Name": "Private Movie \($0)", "Type": "Movie",
            "ProductionYear": 2000, "Genres": ["Private Genre"], "UserData": ["Played": false]] }
        CatalogProbeURLProtocol.reset(rows: rows)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProbeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let connection = ServerConnection(kind: .emby, name: "Private Server", baseURL: URL(string: "https://server.test/emby")!,
            serverID: "private-server", userID: "private-user", username: "private-name", libraryIDs: ["private-library"])
        let client = MediaServerClient(connection: connection, token: "private-token", deviceID: "private-device", session: session)
        let result = try await LibraryCatalogProbe.verify(client: client, libraries: [MediaLibrary(id: "private-library", name: "Private Library")])
        XCTAssertEqual(result.report["passed"] as? Bool, true)
        XCTAssertEqual(result.report["catalogItemCount"] as? Int, 65)
        XCTAssertEqual(CatalogProbeURLProtocol.requestCount, 4)
        let publicJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: result.report), encoding: .utf8))
        XCTAssertFalse(publicJSON.lowercased().contains("private"))
        let privateJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: result.privateReport), encoding: .utf8))
        XCTAssertTrue(privateJSON.contains("Private Movie 60"))
        XCTAssertFalse(privateJSON.contains("private-token"))
    }
}

private final class CatalogProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var rows: [[String: Any]] = []
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset(rows: [[String: Any]]) { lock.lock(); defer { lock.unlock() }; self.rows = rows; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "GET", let url = request.url,
              url.path.hasSuffix("/Users/private-user/Items") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = Int(query.first { $0.name == "StartIndex" }?.value ?? "0") ?? 0
        Self.lock.lock()
        let rows = Self.rows
        Self.count += 1
        Self.lock.unlock()
        // The official query result contract includes Items and TotalRecordCount;
        // StartIndex is deliberately omitted from both pagination traversals.
        let body: [String: Any] = ["Items": Array(rows.dropFirst(offset).prefix(60)), "TotalRecordCount": rows.count]
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
