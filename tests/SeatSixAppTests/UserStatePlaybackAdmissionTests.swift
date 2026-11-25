import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class AdmissionStorage: ApplicationPersisting {
    private var data: Data
    init(_ value: SavedApplication) throws { data = try JSONEncoder().encode(value) }
    func load() throws -> SavedApplication { try JSONDecoder().decode(SavedApplication.self, from: data) }
    func save(_ value: SavedApplication) throws { data = try JSONEncoder().encode(value) }
}

private enum AdmissionRemovalError: Error { case requestedFailure }

private final class AdmissionProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let body: [String: Any]; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) -> Reply)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let cancelled = self.cancelled; lock.unlock()
            guard !cancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor
final class UserStatePlaybackAdmissionTests: XCTestCase {
    private func json(_ id: String, episode: Int = 1, type: String = "Episode") -> [String: Any] {
        ["Id": id, "Name": id, "Type": type, "SeriesId": "show", "SeasonId": "season",
         "ParentIndexNumber": 1, "IndexNumber": episode,
         "UserData": ["Played": false, "IsFavorite": false, "PlaybackPositionTicks": 0]]
    }
    private func decode(_ value: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func connection() -> ServerConnection {
        ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://admission.test")!,
                         serverID: "server", userID: "user", username: "test", libraryIDs: ["library"])
    }
    private func model(storage: AdmissionStorage,
                       launch: @escaping (MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void = { _, _, _, _, _ in }) -> ApplicationModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdmissionProtocol.self]
        let session = URLSession(configuration: configuration)
        return ApplicationModel(storage: storage, credentials: .init(read: { _ in "test" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) }, playbackLauncher: launch)
    }
    private func fixture(launch: @escaping (MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void = { _, _, _, _, _ in }) throws
        -> (ApplicationModel, ServerConnection, AdmissionStorage) {
        let connection = connection()
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let storage = try AdmissionStorage(saved)
        return (model(storage: storage, launch: launch), connection, storage)
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for playback admission")
    }
    private func saveIntent(_ action: MediaUserStateAction, model: ApplicationModel, connection: ServerConnection) throws {
        model.saved.pendingUserStates = [PendingUserState(connectionID: connection.id, serverID: connection.serverID,
            userID: connection.userID, itemID: "e2", itemType: "Episode", action: action, affectedIDs: ["e2"])]
        try model.persist()
    }

    func testStoppedControllerStillBlocksPlayedEditsUntilReleased() async throws {
        let (model, connection, _) = try fixture()
        let controller = NativePlaybackController(item: try decode(json("e1")), connection: connection,
            client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        await controller.stop()
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.stopping)
        XCTAssertFalse(model.canEditPlayedState, "A finished controller can still own the playback window and final history")
        model.player = nil
        XCTAssertTrue(model.canEditPlayedState)
    }

    func testSameAccountUnderDifferentAddressCannotBypassPlayerOwnership() throws {
        let (model, connection, _) = try fixture()
        let controller = NativePlaybackController(item: try decode(json("e1")), connection: connection,
            client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        var alias = connection
        alias.id = UUID(); alias.baseURL = URL(string: "https://nas-alias.test/emby")!
        model.saved.connections.append(alias); model.saved.selectedID = alias.id
        XCTAssertNotEqual(controller.connection.id, model.connection?.id)
        XCTAssertNotEqual(controller.connection.baseURL, model.connection?.baseURL)
        XCTAssertFalse(model.canEditPlayedState)
        var otherUser = alias; otherUser.id = UUID(); otherUser.userID = "other-user"
        model.saved.connections.append(otherUser); model.saved.selectedID = otherUser.id
        XCTAssertTrue(model.canEditPlayedState, "An independent account does not share playback history")
    }

    func testRestartedPlayedIntentBlocksPlaybackThroughAddressAliasWithoutReadingMetadata() throws {
        let (original, connection, storage) = try fixture()
        var alias = connection; alias.id = UUID(); alias.baseURL = URL(string: "https://nas-alias.test/emby")!
        original.saved.connections.append(alias); original.saved.selectedID = alias.id
        try saveIntent(.played(false), model: original, connection: connection)
        var launches = 0
        let restarted = model(storage: storage) { _, _, _, _, _ in launches += 1 }
        AdmissionProtocol.handler = { _ in XCTFail("Pending played intent must prevent even metadata admission"); return .init(body: [:]) }
        XCTAssertTrue(restarted.userStateNeedsRefresh)
        restarted.requestPlayback(try decode(json("e2", episode: 2)))
        XCTAssertFalse(restarted.launchingPlayback)
        XCTAssertNil(restarted.recoveryPrompt)
        XCTAssertEqual(launches, 0)
    }

    func testFreshlyWatchedMovieStartsAtZeroInsteadOfServerEndPosition() async throws {
        var launchTicks: [Int64] = []
        var launchedPlayedStates: [Bool] = []
        let (model, _, _) = try fixture { item, _, _, _, ticks in
            XCTAssertEqual(item.id, "movie")
            launchTicks.append(ticks); launchedPlayedStates.append(item.userData.played)
        }
        // A catalog snapshot can predate a manual mark-watched action in another client.
        let listed = json("movie", type: "Movie")
        var fresh = listed
        let endTicks: Int64 = 72_000_000_000
        fresh["RunTimeTicks"] = endTicks
        fresh["UserData"] = ["Played": true, "IsFavorite": false, "PlaybackPositionTicks": endTicks]
        AdmissionProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "movie")
            return .init(body: fresh)
        }
        model.requestPlayback(try decode(listed))
        try await waitUntil { !model.launchingPlayback }
        XCTAssertEqual(launchedPlayedStates, [true], "Playback must use authoritative metadata, not the stale catalog flag")
        XCTAssertEqual(launchTicks, [0], "A watched movie restarts rather than immediately reaching EOF")
        XCTAssertNil(model.recoveryPrompt)
    }

    func testConnectionRemovalRejectsNewFavoriteBeforeConfigurationIsDeleted() async throws {
        try await exerciseRemovalAdmission(failRemoval: false)
    }

    func testFailedConnectionRemovalReleasesAdmissionGuard() async throws {
        try await exerciseRemovalAdmission(failRemoval: true)
    }

    private func exerciseRemovalAdmission(failRemoval: Bool) async throws {
        let connection = connection(), item = try decode(json("movie", type: "Movie"))
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let storage = try AdmissionStorage(saved)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AdmissionProtocol.self]
        let session = URLSession(configuration: configuration)
        AdmissionProtocol.handler = { _ in
            XCTFail("Removing a connection must not allow a new favorite request")
            return .init(body: [:])
        }
        weak var observedModel: ApplicationModel?
        var removalCalls = 0
        let credentials = CredentialAccess(read: { _ in "test" }, save: { _, _ in }, remove: { id in
            removalCalls += 1
            let model = try XCTUnwrap(observedModel)
            // Reenter at an external dependency before the saved connection/visible
            // detail disappear. This proves removal admission independently of UI timing.
            XCTAssertEqual(id, connection.id)
            XCTAssertEqual(model.connection?.id, connection.id)
            XCTAssertEqual(model.detail?.id, item.id)
            XCTAssertFalse(model.detailLoading)
            XCTAssertFalse(model.userStateBusy)
            XCTAssertFalse(model.userStateNeedsRefresh)
            XCTAssertTrue(model.canFavorite(item))
            model.toggleFavorite(item)
            XCTAssertFalse(model.userStateBusy, "The removal guard must reject work synchronously")
            XCTAssertThrowsError(try model.client(for: connection))
            if failRemoval { throw AdmissionRemovalError.requestedFailure }
        })
        let model = ApplicationModel(storage: storage, credentials: credentials,
            clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) })
        observedModel = model
        model.detail = item
        await model.removeConnection(connection.id)
        XCTAssertEqual(removalCalls, 1)
        XCTAssertFalse(model.userStateBusy)
        XCTAssertTrue(try storage.load().pendingUserStates.isEmpty)
        if failRemoval {
            XCTAssertEqual(model.connection?.id, connection.id)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertNoThrow(try model.client(for: connection), "A failed removal must release its temporary guard")
        } else {
            XCTAssertNil(model.connection)
            XCTAssertTrue(try storage.load().connections.isEmpty)
        }
    }

    func testPersistedPlayedIntentBlocksAutomaticContinuation() async throws {
        try await exerciseContinuation(action: .played(false), insertDuringFetch: false, expectedLaunches: [])
    }
    func testFavoriteIntentDoesNotCancelExistingAutomaticContinuation() async throws {
        try await exerciseContinuation(action: .favorite(true), insertDuringFetch: false, expectedLaunches: ["e2"])
    }
    func testPlayedIntentArrivingDuringMetadataReadPreventsNextLaunch() async throws {
        try await exerciseContinuation(action: .played(false), insertDuringFetch: true, expectedLaunches: [])
    }
    func testFavoriteIntentArrivingDuringMetadataReadPreservesNextLaunch() async throws {
        try await exerciseContinuation(action: .favorite(true), insertDuringFetch: true, expectedLaunches: ["e2"])
    }

    private func exerciseContinuation(action: MediaUserStateAction, insertDuringFetch: Bool, expectedLaunches: [String]) async throws {
        var launches: [String] = []
        let (model, connection, storage) = try fixture { item, _, _, _, _ in launches.append(item.id) }
        // Obtain a valid generation via the existing public recovery flow; no playback engine starts.
        let seed = json("seed", type: "Movie")
        AdmissionProtocol.handler = { _ in .init(body: seed) }
        XCTAssertTrue(model.saveRecovery(item: "seed", connection: connection, ticks: 100_000_000, confirmed: false))
        model.requestPlayback(try decode(seed))
        try await waitUntil { model.recoveryPrompt != nil }
        let requestID = try XCTUnwrap(model.recoveryPrompt).generation
        model.recoveryPrompt = nil
        let first = try decode(json("e1")), nextJSON = json("e2", episode: 2)
        let sequence = EpisodeSequence(seriesID: "show", episodes: [first, try decode(nextJSON)])
        var completion = PlaybackCompletionGate()
        XCTAssertTrue(completion.beginNaturalEnd(started: true, stopped: false, failed: false))
        let owner = NativePlaybackController(item: first, connection: connection,
            client: try model.client(for: connection), completionGate: completion) { _, _ in true }
        await owner.stop(naturalEnd: true)
        model.player = owner
        XCTAssertTrue(owner.canAutomaticallyContinue)
        let shouldFetch = insertDuringFetch || !expectedLaunches.isEmpty
        let fetching = shouldFetch ? expectation(description: "Next episode metadata fetch") : nil
        AdmissionProtocol.handler = { _ in
            if let fetching { fetching.fulfill() }
            else { XCTFail("Pending played intent must prevent next-episode metadata request") }
            return .init(body: nextJSON, delay: insertDuringFetch ? 0.15 : 0)
        }
        if insertDuringFetch {
            let continuation = Task { await model.advanceEpisode(after: owner, sequence: sequence, requestID: requestID) }
            await fulfillment(of: [try XCTUnwrap(fetching)], timeout: 2)
            try saveIntent(action, model: model, connection: connection)
            await continuation.value
        } else {
            try saveIntent(action, model: model, connection: connection)
            await model.advanceEpisode(after: owner, sequence: sequence, requestID: requestID)
            if let fetching { await fulfillment(of: [fetching], timeout: 2) }
        }
        XCTAssertEqual(try storage.load().pendingUserStates.first?.action, action, "Admission must honor a durable intent")
        XCTAssertEqual(launches, expectedLaunches)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertTrue(owner.canAutomaticallyContinue, "Blocking a mutation must not irreversibly cancel the episode completion gate")
    }
}
