import Foundation
import XCTest
@testable import SeatSixCore

final class CompleteResumeTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompleteResumeProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        session.invalidateAndCancel(); CompleteResumeProtocol.handler = nil
        super.tearDown()
    }

    private func client(_ kind: ServerKind = .emby, compatibility: Bool = false) -> MediaServerClient {
        let connection = ServerConnection(kind: kind, name: "Fixture", baseURL: URL(string: "https://resume.test")!,
            serverID: "server", userID: "user", username: "fixture", libraryIDs: ["a", "b", "excluded"], compatibilityMode: compatibility)
        return MediaServerClient(connection: connection, token: "fixture-token", deviceID: "fixture-device", session: session)
    }

    private static func item(_ id: String) -> [String: Any] { ["Id": id, "Name": id, "Type": "Episode"] }

    func testCompleteResumePaginatesBothServersAcrossAllowedLibrariesWithoutTwentyItemLimit() async throws {
        for kind in [ServerKind.emby, .jellyfin] {
            let log = CompleteResumeLog()
            CompleteResumeProtocol.handler = { request in
                log.append(request)
                let query = request.completeResumeQuery
                let offset = Int(query["StartIndex"]!)!
                let library = query["ParentId"]!
                let all = library == "a" ? (0..<125).map { Self.item("a-\($0)") } : [Self.item("a-0"), Self.item("b-only")]
                return ["Items": Array(all.dropFirst(offset).prefix(60)), "TotalRecordCount": all.count, "StartIndex": offset]
            }
            let result = try await client(kind).completeResumeItems(libraryIDs: ["a", "a", "b"])
            XCTAssertEqual(result.count, 126)
            XCTAssertEqual(result.last?.id, "b-only")
            XCTAssertEqual(log.requests.map { $0.completeResumeQuery["StartIndex"]! }, ["0", "60", "120", "0"])
            XCTAssertEqual(log.requests.map { $0.completeResumeQuery["ParentId"]! }, ["a", "a", "a", "b"])
            XCTAssertTrue(log.requests.allSatisfy { $0.completeResumeQuery["EnableTotalRecordCount"] == "true" })
        }
    }

    func testCompleteResumeRejectsUnselectedScopeAndCompatibilityNeverRequestsResume() async throws {
        let log = CompleteResumeLog()
        CompleteResumeProtocol.handler = { request in log.append(request); return ["Items": [], "TotalRecordCount": 0] }
        do { _ = try await client().completeResumeItems(libraryIDs: ["unknown"]); XCTFail("Accepted invalid scope") }
        catch { XCTAssertEqual(error as? MediaServerError, .invalidScope) }
        let items = try await client(compatibility: true).completeResumeItems(libraryIDs: ["a"])
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(log.requests.isEmpty)
    }

    func testCompleteResumeRejectsMissingTotalsWrongOffsetsDuplicatesAndEarlyEmptyPage() async {
        let responses: [[String: Any]] = [
            ["Items": [Self.item("one")]],
            ["Items": [], "TotalRecordCount": -1],
            ["Items": [Self.item("one")], "TotalRecordCount": 1, "StartIndex": 9],
            ["Items": [Self.item("one"), Self.item("one")], "TotalRecordCount": 2],
            ["Items": [], "TotalRecordCount": 2],
            ["Items": [Self.item("one"), Self.item("two")], "TotalRecordCount": 1]
        ]
        for response in responses {
            CompleteResumeProtocol.handler = { _ in response }
            do { _ = try await client().completeResumeItems(libraryIDs: ["a"]); XCTFail("Accepted broken resume page") }
            catch { XCTAssertEqual(error as? LibraryCatalogError, .invalidPage) }
        }
    }

    func testCompleteResumeRejectsRepeatedPageAndChangingTotal() async {
        for changesTotal in [false, true] {
            CompleteResumeProtocol.handler = { request in
                let first = request.completeResumeQuery["StartIndex"] == "0"
                return ["Items": [Self.item(first || !changesTotal ? "one" : "two")], "TotalRecordCount": first ? 2 : (changesTotal ? 3 : 2)]
            }
            do { _ = try await client().completeResumeItems(libraryIDs: ["a"]); XCTFail("Accepted inconsistent resume pages") }
            catch { XCTAssertEqual(error as? LibraryCatalogError, changesTotal ? .changedDuringLoading : .invalidPage) }
        }
    }

    func testCompleteResumeCapAppliesAcrossLibrariesAndKeepsValidPartialProgress() async {
        let progress = CompleteResumeProgress()
        CompleteResumeProtocol.handler = { request in
            let id = request.completeResumeQuery["ParentId"]!
            return ["Items": [Self.item(id)], "TotalRecordCount": 1]
        }
        do {
            _ = try await client().completeResumeItems(libraryIDs: ["a", "b"], maximumItems: 1) { await progress.append($0) }
            XCTFail("Accepted aggregate over limit")
        } catch { XCTAssertEqual(error as? LibraryCatalogError, .tooLarge) }
        let values = await progress.values
        XCTAssertEqual(values.map { $0.map(\.id) }, [["a"]])
    }

    func testCompleteResumeCancellationStopsBeforeAnotherPage() async {
        let log = CompleteResumeLog()
        CompleteResumeProtocol.handler = { request in
            log.append(request)
            return ["Items": [Self.item("one")], "TotalRecordCount": 2]
        }
        let api = client()
        let task = Task {
            try await api.completeResumeItems(libraryIDs: ["a"]) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(log.requests.count, 1)
    }

    func testHomeResumeStillUsesTwentyItemRailWithoutRequiringTotals() async throws {
        let log = CompleteResumeLog()
        CompleteResumeProtocol.handler = { request in log.append(request); return ["Items": [Self.item("one")]] }
        let items = try await client().resumeItems()
        XCTAssertEqual(items.map(\.id), ["one"])
        XCTAssertEqual(log.requests.count, 3)
        XCTAssertTrue(log.requests.allSatisfy { $0.completeResumeQuery["Limit"] == "20" && $0.completeResumeQuery["StartIndex"] == nil })
    }
}

private final class CompleteResumeProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let body = Self.handler?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CompleteResumeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private actor CompleteResumeProgress {
    var values: [[MediaItem]] = []
    func append(_ items: [MediaItem]) { values.append(items) }
}

private extension URLRequest {
    var completeResumeQuery: [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
}
