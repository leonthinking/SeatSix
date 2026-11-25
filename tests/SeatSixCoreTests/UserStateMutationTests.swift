import Foundation
import XCTest
@testable import SeatSixCore

final class UserStateMutationTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserStateURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel(); UserStateURLProtocol.handler = nil
        super.tearDown()
    }

    func testAllMutationRoutesUseAuthenticatedEmptyBodyThenFreshReadForBothServers() async throws {
        for kind in [ServerKind.emby, .jellyfin] {
            for action in [MediaUserStateAction.favorite(true), .favorite(false), .played(true), .played(false)] {
                let requests = UserStateRequestRecorder()
                let expected = try item(played: action == .played(true), favorite: action == .favorite(true), position: 350_000_000)
                UserStateURLProtocol.handler = { request in
                    requests.append(request)
                    if request.httpMethod == "GET" { return try .json(Self.json(played: expected.userData.played, favorite: expected.userData.isFavorite, position: expected.userData.playbackPositionTicks)) }
                    return try .json(["Played": !expected.userData.played, "IsFavorite": !expected.userData.isFavorite, "PlaybackPositionTicks": 999])
                }
                let result = try await perform(action, client: client(kind), item: item(position: 22))
                XCTAssertEqual(result, expected)
                XCTAssertEqual(requests.values.map(\.httpMethod), [action.enabled ? "POST" : "DELETE", "GET"])
                XCTAssertEqual(requests.values.map { $0.url!.path }, ["/emby/Users/user-1/\(action.resource)/1001", "/emby/Users/user-1/Items/1001"])
                for request in requests.values {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
                    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
                    XCTAssertNil(request.url?.query)
                    XCTAssertNil(request.httpBody)
                    XCTAssertNil(request.httpBodyStream)
                }
            }
        }
    }

    func testCompatibilityMutationUsesTokenHeaderAndNeverParentID() async throws {
        let requests = UserStateRequestRecorder()
        UserStateURLProtocol.handler = { request in
            requests.append(request)
            return request.httpMethod == "GET" ? try .json(Self.json(type: "Series", favorite: true)) : .init(status: 204, data: Data())
        }
        _ = try await client(compatibility: true).setFavorite(item: item(type: "Series"), isFavorite: true)
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertNil(requests.values.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests.values.first?.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
        XCTAssertEqual(requests.values.first?.url?.path, "/emby/Users/user-1/FavoriteItems/1001")
    }

    func testEmptyAndMalformedAcknowledgementStillRequiresAuthoritativeReadback() async throws {
        for acknowledgement in [UserStateResponse(status: 204, data: Data()), .init(status: 200, data: Data("not-json".utf8))] {
            let requests = UserStateRequestRecorder()
            UserStateURLProtocol.handler = { request in
                requests.append(request)
                return request.httpMethod == "GET" ? try .json(Self.json(favorite: true, position: 123)) : acknowledgement
            }
            let result = try await client().setFavorite(item: item(), isFavorite: true)
            XCTAssertTrue(result.userData.isFavorite)
            XCTAssertEqual(result.userData.playbackPositionTicks, 123)
            XCTAssertEqual(requests.values.count, 2)
        }
    }

    func testUnwatchedResultUsesServerProgressRatherThanOriginalOrInventedPosition() async throws {
        UserStateURLProtocol.handler = { request in
            request.httpMethod == "GET" ? try .json(Self.json(played: false, favorite: true, position: 0)) : try .json([:])
        }
        let result = try await client().setPlayed(item: item(played: true, favorite: true, position: 500_000_000), played: false)
        XCTAssertEqual(result.userData.playbackPositionTicks, 0)
        XCTAssertFalse(result.userData.played)
        XCTAssertTrue(result.userData.isFavorite)
    }

    func testMissingAndNullUserStateFieldsCannotConfirmFalseOrOverwriteOtherState() async throws {
        for missingKey in ["IsFavorite", "Played", "PlaybackPositionTicks"] {
            for missingValue in [false, true] {
                for action in [MediaUserStateAction.favorite(false), .played(false)] {
                    var json = Self.json()
                    var data = json["UserData"] as! [String: Any]
                    if missingValue { data[missingKey] = NSNull() } else { data.removeValue(forKey: missingKey) }
                    json["UserData"] = data
                    UserStateURLProtocol.handler = { request in request.httpMethod == "GET" ? try .json(json) : try .json([:]) }
                    await assertFailure(.outcomeUncertain, action: action)
                }
            }
        }
        for missingData in [NSNull(), [:]] as [Any] {
            var json = Self.json(); json["UserData"] = missingData
            UserStateURLProtocol.handler = { request in request.httpMethod == "GET" ? try .json(json) : try .json([:]) }
            await assertFailure(.outcomeUncertain, action: .favorite(false))
        }
    }

    func testMismatchWrongItemWrongTypeAndNegativeProgressAreUncertain() async throws {
        for json in [Self.json(favorite: false), Self.json(id: "other", favorite: true), Self.json(type: "Series", favorite: true), Self.json(favorite: true, position: -1)] {
            let requests = UserStateRequestRecorder()
            UserStateURLProtocol.handler = { request in
                requests.append(request)
                return request.httpMethod == "GET" ? try .json(json) : try .json([:])
            }
            await assertFailure(.outcomeUncertain, action: .favorite(true))
            XCTAssertEqual(requests.values.count, 2)
        }
        UserStateURLProtocol.handler = { request in request.httpMethod == "GET" ? try .json(Self.json(played: false)) : try .json([:]) }
        await assertFailure(.outcomeUncertain, action: .played(true))
    }

    func testHTTPWriteRejectionsAreNotRetriedAndDoNotReadback() async throws {
        for status in [400, 401, 403, 404, 409, 429] {
            let requests = UserStateRequestRecorder()
            UserStateURLProtocol.handler = { request in requests.append(request); return .init(status: status, data: Data()) }
            do { _ = try await client().setPlayed(item: item(), played: true); XCTFail("HTTP error accepted") }
            catch { XCTAssertEqual(error as? MediaServerError, .httpStatus(status)) }
            XCTAssertEqual(requests.values.count, 1)
        }
    }

    func testServerErrorAndLostWriteResponseAreUncertainWithoutRetry() async throws {
        for responseFails in [true, false] {
            let requests = UserStateRequestRecorder()
            UserStateURLProtocol.handler = { request in
                requests.append(request)
                if responseFails { throw URLError(.networkConnectionLost) }
                return .init(status: 503, data: Data())
            }
            await assertFailure(.outcomeUncertain, action: .played(true))
            XCTAssertEqual(requests.values.count, 1)
        }
    }

    func testReadbackFailureOrMalformedResponseNeverReplaysWrite() async throws {
        for failure in 0..<3 {
            let requests = UserStateRequestRecorder()
            UserStateURLProtocol.handler = { request in
                requests.append(request)
                if request.httpMethod != "GET" { return .init(status: 204, data: Data()) }
                if failure == 0 { throw URLError(.timedOut) }
                if failure == 1 { return .init(status: 401, data: Data()) }
                return .init(status: 200, data: Data("bad json".utf8))
            }
            await assertFailure(.outcomeUncertain, action: .favorite(true))
            XCTAssertEqual(requests.values.map(\.httpMethod), ["POST", "GET"])
        }
    }

    func testCancelledBeforeDispatchMakesNoRequest() async throws {
        let requests = UserStateRequestRecorder()
        UserStateURLProtocol.handler = { request in requests.append(request); return try .json(Self.json()) }
        let client = client(), item = try item()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.setPlayed(item: item, played: true)
        }
        do { _ = try await task.value; XCTFail("Cancelled mutation completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testUnsupportedItemsAndUnsafeIDsNeverSendRequest() async throws {
        let requests = UserStateRequestRecorder()
        UserStateURLProtocol.handler = { request in requests.append(request); return try .json(Self.json()) }
        for (id, type, compatibility) in [("1001-episode-2", "Episode", true), ("1001-season-1", "Season", true), ("１００１", "Movie", true), ("abc", "Movie", true), ("1001", "Folder", false), ("../1001", "Movie", false), ("", "Movie", false), ("a?x=y", "Movie", false)] {
            for action in [MediaUserStateAction.favorite(true), .played(false)] {
                await assertFailure(.unsupportedAction, action: action, client: client(compatibility: compatibility), item: try item(id: id, type: type))
            }
        }
        XCTAssertTrue(requests.values.isEmpty)
    }

    func testCapabilitiesAcceptOnlyContractedTypes() throws {
        for type in ["Movie", "Series", "Episode", "Video"] {
            let item = try item(type: type)
            XCTAssertTrue(MediaUserStateCapabilities.canFavorite(item: item, connection: connection()))
            XCTAssertTrue(MediaUserStateCapabilities.canSetPlayed(item: item, connection: connection()))
            XCTAssertEqual(MediaUserStateCapabilities.canFavorite(item: item, connection: connection(compatibility: true)), ["Movie", "Series"].contains(type))
        }
    }

    func testDecodedUserDataKeepsMissingAndExplicitFalseDistinct() throws {
        let missing = try decode(["Id": "1001"])
        XCTAssertFalse(missing.userData.isFavorite)
        XCTAssertFalse(missing.userData.isFavoriteKnown)
        XCTAssertFalse(missing.userData.playedKnown)
        XCTAssertFalse(missing.userData.playbackPositionKnown)
        let explicit = try item()
        XCTAssertFalse(explicit.userData.isFavorite)
        XCTAssertTrue(explicit.userData.isFavoriteKnown)
        XCTAssertTrue(explicit.userData.playedKnown)
        XCTAssertTrue(explicit.userData.playbackPositionKnown)
    }

    private func connection(_ kind: ServerKind = .emby, compatibility: Bool = false) -> ServerConnection {
        ServerConnection(kind: kind, name: "fixture", baseURL: URL(string: "https://media.example:9443/emby")!, serverID: "server-1", userID: "user-1", username: "fixture", libraryIDs: ["library-1"], compatibilityMode: compatibility)
    }

    private func client(_ kind: ServerKind = .emby, compatibility: Bool = false) -> MediaServerClient {
        MediaServerClient(connection: connection(kind, compatibility: compatibility), token: "fixture-token", deviceID: "test", session: session)
    }

    private func item(id: String = "1001", type: String = "Movie", played: Bool = false, favorite: Bool = false, position: Int64 = 0) throws -> MediaItem {
        try decode(Self.json(id: id, type: type, played: played, favorite: favorite, position: position))
    }

    private func decode(_ json: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func json(id: String = "1001", type: String = "Movie", played: Bool = false, favorite: Bool = false, position: Int64 = 0) -> [String: Any] {
        ["Id": id, "Name": "Fixture movie", "Type": type, "UserData": ["Played": played, "IsFavorite": favorite, "PlaybackPositionTicks": position]]
    }

    private func perform(_ action: MediaUserStateAction, client: MediaServerClient, item: MediaItem) async throws -> MediaItem {
        switch action {
        case .favorite(let value): return try await client.setFavorite(item: item, isFavorite: value)
        case .played(let value): return try await client.setPlayed(item: item, played: value)
        }
    }

    private func assertFailure(_ expected: MediaUserStateError, action: MediaUserStateAction, client: MediaServerClient? = nil, item: MediaItem? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await perform(action, client: client ?? self.client(), item: item ?? self.item()); XCTFail("Mutation unexpectedly accepted", file: file, line: line) }
        catch { XCTAssertEqual(error as? MediaUserStateError, expected, file: file, line: line) }
    }
}

private struct UserStateResponse {
    let status: Int
    let data: Data
    static func json(_ value: [String: Any]) throws -> Self { .init(status: 200, data: try JSONSerialization.data(withJSONObject: value)) }
}

private final class UserStateRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class UserStateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> UserStateResponse)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
