import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class UserStateReconciliationTests: XCTestCase {
    func testOlderParallelReadCannotClearNewerUncertainIntentWithDifferentAction() async throws {
        try await assertOlderReadPreservesNewIntent(previousFavorite: false)
    }

    func testOlderParallelReadCannotClearSameActionReplacementIntent() async throws {
        try await assertOlderReadPreservesNewIntent(previousFavorite: true)
    }

    func testLegacyPendingIntentWithoutIdentityDecodesAndKeepsGeneratedIdentityAfterSaving() throws {
        let previous = PendingUserState(connectionID: UUID(), serverID: "server", userID: "user", itemID: "movie",
            itemType: "Movie", action: .played(true), affectedIDs: ["movie", "episode"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
        legacy.removeValue(forKey: "id")
        let decoded = try JSONDecoder().decode(PendingUserState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.connectionID, previous.connectionID)
        XCTAssertEqual(decoded.serverID, previous.serverID); XCTAssertEqual(decoded.userID, previous.userID)
        XCTAssertEqual(decoded.itemID, previous.itemID); XCTAssertEqual(decoded.itemType, previous.itemType)
        XCTAssertEqual(decoded.action, previous.action); XCTAssertEqual(decoded.affectedIDs, previous.affectedIDs)
        let restored = try JSONDecoder().decode(PendingUserState.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.id, decoded.id)
    }

    private func assertOlderReadPreservesNewIntent(previousFavorite: Bool) async throws {
        let transport = ReconciliationTransport()
        ReconciliationProtocol.transport = transport
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReconciliationProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://reconciliation.test")!,
            serverID: "server", userID: "user", username: "fixture", libraryIDs: ["library"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let storage = ReconciliationStorage(saved)
        let model = ApplicationModel(storage: storage, credentials: .init(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) })
        addTeardownBlock {
            transport.releaseAll()
            await model.shutdown()
            // All requests used by this test are explicitly drained below before
            // invalidation, including the detached detail request.
            session.finishTasksAndInvalidate()
            ReconciliationProtocol.transport = nil
        }
        model.page = "recent"
        try await wait("Initial server feed should load") { model.serverBrowseComplete }
        let previous = PendingUserState(connectionID: connection.id, serverID: connection.serverID, userID: connection.userID,
            itemID: "movie", itemType: "Movie", action: .favorite(previousFavorite), affectedIDs: ["movie"])
        model.saved.pendingUserStates = [previous]
        try model.persist()

        transport.holdNextTwoItemReads()
        model.refresh()
        try await wait("Home and the server feed must independently read the same pending intent") { transport.heldReadCount == 2 }
        transport.releaseRead(0)
        try await wait("The first authoritative read should reconcile the original intent") { model.saved.pendingUserStates.isEmpty }

        let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: ReconciliationTransport.item))
        model.showDetail(item)
        try await wait("Detail must load before changing its favorite state") { !model.detailLoading }
        model.toggleFavorite(try XCTUnwrap(model.detail))
        try await wait("The replacement write should end with an uncertain outcome") { transport.writeCount == 1 && !model.userStateBusy }
        XCTAssertTrue(model.userStateNeedsRefresh)
        let replacement = try XCTUnwrap(model.saved.pendingUserStates.first)
        XCTAssertNotEqual(replacement.id, previous.id, "Identical actions still need distinct durable identities")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let replacementData = try encoder.encode(replacement)
        let replacementError = try XCTUnwrap(model.userStateError)

        transport.releaseRead(1)
        try await wait("Both original refreshes must finish after the older read returns") {
            model.catalogComplete && model.serverBrowseComplete && !model.catalogLoading && !model.continuingLoading
        }
        XCTAssertTrue(model.userStateNeedsRefresh, "A response for an older intent must not authorize another write or playback")
        XCTAssertEqual(model.saved.pendingUserStates.count, 1, "The replacement intent must remain durable")
        XCTAssertEqual(storage.value.pendingUserStates.count, 1)
        XCTAssertEqual(model.userStateError, replacementError, "An old read must not erase the replacement write's warning")
        if let remaining = model.saved.pendingUserStates.first {
            XCTAssertEqual(try encoder.encode(remaining), replacementData)
        }
    }

    private func wait(_ message: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }
}

private final class ReconciliationStorage: ApplicationPersisting {
    var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}

private final class ReconciliationTransport: @unchecked Sendable {
    static let item: [String: Any] = ["Id": "movie", "Name": "Movie", "Type": "Movie", "DateCreated": "2026-11-17T00:00:00Z",
        "UserData": ["Played": false, "IsFavorite": false, "PlaybackPositionTicks": 0]]
    private let lock = NSLock()
    private var remainingHeldReads = 0
    private var heldReads: [ReconciliationProtocol] = []
    private var writes = 0
    func holdNextTwoItemReads() { lock.lock(); remainingHeldReads = 2; lock.unlock() }
    var heldReadCount: Int { lock.lock(); defer { lock.unlock() }; return heldReads.count }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }

    func receive(_ request: URLRequest, via channel: ReconciliationProtocol) {
        let path = request.url!.path
        lock.lock()
        if path.hasSuffix("/Items/movie"), remainingHeldReads > 0 {
            remainingHeldReads -= 1; heldReads.append(channel); lock.unlock(); return
        }
        if path.contains("FavoriteItems") {
            writes += 1; lock.unlock(); channel.send(status: 500, body: [:]); return
        }
        lock.unlock()
        if path.hasSuffix("/Views") {
            channel.send(body: ["Items": [["Id": "library", "Name": "Library", "CollectionType": "movies"]]])
        } else if path.hasSuffix("/Resume") {
            channel.send(body: ["Items": [], "TotalRecordCount": 0])
        } else if path.hasSuffix("/Items") {
            channel.send(body: ["Items": [Self.item], "TotalRecordCount": 1, "StartIndex": 0])
        } else {
            channel.send(body: Self.item)
        }
    }

    func releaseRead(_ index: Int) {
        lock.lock(); let channel = heldReads.indices.contains(index) ? heldReads[index] : nil; lock.unlock()
        channel?.send(body: Self.item)
    }
    func releaseAll() {
        lock.lock(); let channels = heldReads; lock.unlock()
        for channel in channels { channel.send(body: Self.item) }
    }
}

private final class ReconciliationProtocol: URLProtocol, @unchecked Sendable {
    static var transport: ReconciliationTransport?
    private let lock = NSLock()
    private var finished = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.transport?.receive(request, via: self) }
    override func stopLoading() { lock.lock(); finished = true; lock.unlock() }
    func send(status: Int = 200, body: [String: Any]) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
