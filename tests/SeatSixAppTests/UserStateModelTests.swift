import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class UserStateStorage: ApplicationPersisting {
    var value: SavedApplication
    var failSave = false
    var saveCount = 0
    var failAfter: Int?
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ value: SavedApplication) throws {
        saveCount += 1
        if failSave || failAfter.map({ saveCount > $0 }) == true { throw ApplicationPersistenceError.saveFailed }
        self.value = value
    }
}
private final class UserStateProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: UserStateFixture!
    private let cancellationLock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, body, delay) = Self.fixture.respond(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            cancellationLock.lock(); let cancelled = self.cancelled; cancellationLock.unlock()
            guard !cancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
}
private final class UserStateFixture: @unchecked Sendable {
    let lock = NSLock()
    var favorite = false, played = false, failReads = false
    var writeStatus = 200
    var writeDelay: TimeInterval = 0
    var writes = 0
    var readsAfterWrite = 0
    var series = false
    var invalidType = false, negativePosition = false
    var favoriteReadOverride: Bool?
    func row(_ id: String = "movie", newUser: Bool = false) -> [String: Any] {
        var row: [String: Any] = ["Id": id, "Name": id, "Type": id == "ep" ? "Episode" : (series ? "Series" : "Movie"), "UserData": ["Played": newUser ? false : played, "IsFavorite": newUser ? false : (favoriteReadOverride ?? favorite), "PlaybackPositionTicks": 0]]
        if writes > 0 && invalidType { row["Type"] = "Audio" }
        if writes > 0 && negativePosition { row["UserData"] = ["Played": played, "IsFavorite": favorite, "PlaybackPositionTicks": -1] }
        if id == "ep" { row["SeriesId"] = "movie"; row["ParentIndexNumber"] = 1; row["IndexNumber"] = 1 }
        return row
    }
    func respond(_ request: URLRequest) -> (Int, [String: Any], TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        if path.contains("FavoriteItems") || path.contains("PlayedItems") {
            writes += 1
            if writeStatus == 200 {
                if path.contains("FavoriteItems") { favorite = method == "POST" }
                else { played = method == "POST" }
            }
            return (writeStatus, [:], writeDelay)
        }
        if writes > 0 { readsAfterWrite += 1 }
        if path.hasSuffix("/Views") { return (200, ["Items": [["Id":"library", "Name":"Movies"]]], 0) }
        if failReads && writes > 0 { return (500, [:], 0) }
        if path.hasSuffix("/Seasons") { return (200, ["Items":[], "TotalRecordCount":0], 0) }
        if path.hasSuffix("/Episodes") { return (200, ["Items":[row("ep")], "TotalRecordCount":1], 0) }
        if path.hasSuffix("/Resume") { return (200, ["Items":[]], 0) }
        if path.hasSuffix("/Items") { return (200, ["Items":[row(newUser:path.contains("new-user"))], "TotalRecordCount":1], 0) }
        return (200, row(newUser:path.contains("new-user")), 0)
    }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    func readsFail(_ value: Bool) { lock.lock(); failReads = value; lock.unlock() }
}

@MainActor
final class UserStateModelTests: XCTestCase {
    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out waiting for user state")
    }
    private func setup(series: Bool = false) async throws -> (ApplicationModel, UserStateFixture, UserStateStorage) {
        let fixture = UserStateFixture(); fixture.series = series; UserStateProtocol.fixture = fixture
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UserStateProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://state.test/emby")!, serverID: "server", userID: "user", username: "Test", libraryIDs: ["library"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let storage = UserStateStorage(saved)
        let model = ApplicationModel(storage: storage, credentials: .init(read: { _ in "token" }, save: { _,_ in }, remove: { _ in }), clientFactory: { MediaServerClient(connection:$0, token:$1, deviceID:$2, session:session) })
        model.refresh(); try await wait { model.catalogComplete }
        model.showDetail(model.items[0]); try await wait { !model.detailLoading && !model.seriesLoading }
        return (model, fixture, storage)
    }
    func testFavoriteWaitsForReadbackSerializesAndUpdatesCompleteFilter() async throws {
        let (model, fixture, _) = try await setup(); fixture.writeDelay = 0.15
        model.favoritesOnly = true; XCTAssertTrue(model.displayedItems.isEmpty)
        model.toggleFavorite(model.detail!); model.toggleFavorite(model.detail!)
        XCTAssertTrue(model.userStateBusy); XCTAssertFalse(model.detail!.userData.isFavorite)
        try await wait { !model.userStateBusy && model.catalogComplete && !model.detailLoading }
        XCTAssertEqual(fixture.writeCount, 1); XCTAssertTrue(model.detail!.userData.isFavorite)
        XCTAssertEqual(model.displayedItems.map(\.id), ["movie"])
        model.toggleFavorite(model.detail!)
        try await wait { !model.userStateBusy && model.catalogComplete && !model.detailLoading }
        XCTAssertTrue(model.displayedItems.isEmpty); XCTAssertEqual(fixture.writeCount, 2)
    }
    func testPlayedChangesRemoveOnlyAffectedRecoveryAndRefreshFilters() async throws {
        let (model, fixture, storage) = try await setup(); let connection = model.connection!
        XCTAssertTrue(model.saveRecovery(item:"movie", connection:connection, ticks:90_000_000, confirmed:false))
        XCTAssertTrue(model.saveRecovery(item:"other", connection:connection, ticks:80_000_000, confirmed:false))
        model.watchFilter = .watched; model.setPlayed(model.detail!, played:true)
        try await wait { !model.userStateBusy && model.catalogComplete && !model.detailLoading }
        XCTAssertEqual(model.displayedItems.map(\.id), ["movie"])
        XCTAssertEqual(storage.value.recovery.map(\.itemID), ["other"])
        model.setPlayed(model.detail!, played:false)
        try await wait { !model.userStateBusy && model.catalogComplete && !model.detailLoading }
        XCTAssertTrue(model.displayedItems.isEmpty); XCTAssertEqual(model.detail!.userData.playbackPositionTicks, 0)
        XCTAssertEqual(fixture.writeCount, 2)
    }
    func testRejectedWriteKeepsOriginalStateAndReportsFailure() async throws {
        let (model, fixture, _) = try await setup(); fixture.writeStatus = 403
        model.toggleFavorite(model.detail!)
        try await wait { !model.userStateBusy }
        XCTAssertFalse(model.detail!.userData.isFavorite); XCTAssertNotNil(model.userStateError)
        XCTAssertFalse(model.userStateNeedsRefresh); XCTAssertEqual(fixture.writeCount, 1)
    }
    func testUncertainWriteRequiresReadOnlyRefreshAndCannotRepeatOrPlay() async throws {
        let (model, fixture, _) = try await setup(); fixture.readsFail(true)
        model.toggleFavorite(model.detail!)
        try await wait { !model.userStateBusy }
        XCTAssertTrue(model.userStateNeedsRefresh); XCTAssertFalse(model.detail!.userData.isFavorite)
        model.toggleFavorite(model.detail!); model.requestPlayback(model.detail!)
        XCTAssertEqual(fixture.writeCount, 1); XCTAssertFalse(model.launchingPlayback)
        fixture.readsFail(false); model.refresh()
        try await wait { model.catalogComplete && !model.detailLoading && !model.userStateNeedsRefresh }
        XCTAssertTrue(model.detail!.userData.isFavorite); XCTAssertNil(model.userStateError)
        XCTAssertEqual(fixture.writeCount, 1)
    }
    func testSeriesChangeUsesRealChildIDsAndRefreshesEpisodes() async throws {
        let (model, fixture, storage) = try await setup(series:true); let connection = model.connection!
        XCTAssertTrue(model.saveRecovery(item:"ep", connection:connection, ticks:90_000_000, confirmed:false))
        XCTAssertTrue(model.saveRecovery(item:"outside", connection:connection, ticks:80_000_000, confirmed:false))
        model.setPlayed(model.detail!, played:true)
        try await wait { !model.userStateBusy && model.catalogComplete && !model.detailLoading && !model.seriesLoading }
        XCTAssertEqual(storage.value.recovery.map(\.itemID), ["outside"])
        XCTAssertTrue(model.episodes.first!.userData.played); XCTAssertEqual(fixture.writeCount, 1)
    }
    func testLaunchInProgressBlocksManualPlayedChange() async throws {
        let (model, fixture, _) = try await setup(); model.launchingPlayback = true
        model.setPlayed(model.detail!, played:true)
        XCTAssertFalse(model.userStateBusy); XCTAssertEqual(fixture.writeCount, 0)
    }
    func testConnectionSwitchDoesNotApplyOldWriteToNewAccount() async throws {
        let (model, fixture, _) = try await setup(); fixture.writeDelay = 0.2
        var second = model.connection!; second.id = UUID(); second.userID = "new-user"
        model.saved.connections.append(second)
        model.toggleFavorite(model.detail!); try await wait { fixture.writeCount == 1 }
        model.switchConnection(second.id)
        try await wait { !model.userStateBusy && model.catalogComplete }
        XCTAssertEqual(model.connection?.userID, "new-user")
        XCTAssertFalse(model.items[0].userData.isFavorite); XCTAssertNil(model.userStateError)
    }
    func testSameAccountAliasRefreshesAfterDelayedMutationCompletes() async throws {
        let (model, fixture, _) = try await setup(); fixture.writeDelay = 0.25
        fixture.favoriteReadOverride = false
        var alias = model.connection!; alias.id = UUID(); alias.baseURL = URL(string: "https://alias.test/emby")!
        model.saved.connections.append(alias)
        model.toggleFavorite(model.detail!); try await wait { fixture.writeCount == 1 }
        model.switchConnection(alias.id); try await wait { model.catalogComplete }
        XCTAssertFalse(model.items[0].userData.isFavorite)
        fixture.favoriteReadOverride = nil
        try await wait { !model.userStateBusy && model.catalogComplete && model.items.first?.userData.isFavorite == true }
        XCTAssertEqual(model.connection?.id, alias.id); XCTAssertFalse(model.userStateNeedsRefresh)
        XCTAssertEqual(fixture.writeCount, 1)
    }
    func testStorageFailureBeforeDispatchPreventsServerWrite() async throws {
        let (model, fixture, storage) = try await setup(); let connection = model.connection!
        XCTAssertTrue(model.saveRecovery(item:"movie", connection:connection, ticks:90_000_000, confirmed:false))
        storage.failSave = true
        model.setPlayed(model.detail!, played:true)
        try await wait { !model.userStateBusy }
        XCTAssertEqual(fixture.writeCount, 0); XCTAssertFalse(model.detail!.userData.played)
        XCTAssertNotNil(model.recovery(for:"movie", connection:connection)); XCTAssertNotNil(model.userStateError)
    }
    func testFailedCleanupRetainsDurableIntentAndWarningAcrossRefresh() async throws {
        let (model, fixture, storage) = try await setup(); let connection = model.connection!
        XCTAssertTrue(model.saveRecovery(item:"movie", connection:connection, ticks:90_000_000, confirmed:false))
        storage.failAfter = storage.saveCount + 1 // allow the durable intent, fail cleanup
        model.setPlayed(model.detail!, played:true)
        try await wait { !model.userStateBusy }
        XCTAssertEqual(fixture.writeCount, 1); XCTAssertTrue(model.userStateNeedsRefresh)
        XCTAssertEqual(storage.value.pendingUserStates.count, 1)
        XCTAssertTrue(model.userStateError?.contains("本机旧续播") == true)
        model.refresh(); try await wait { model.catalogFailed }
        XCTAssertTrue(model.userStateError?.contains("本机旧续播") == true)
        XCTAssertTrue(model.userStateNeedsRefresh); XCTAssertNotNil(model.recovery(for:"movie", connection:connection))
        storage.failAfter = nil; model.refresh()
        try await wait { model.catalogComplete && !model.userStateNeedsRefresh }
        XCTAssertNil(model.userStateError); XCTAssertNil(model.recovery(for:"movie", connection:connection))
        XCTAssertTrue(storage.value.pendingUserStates.isEmpty); XCTAssertEqual(fixture.writeCount, 1)
    }
    func testUncertainPlayedIntentSurvivesRestartAndReconcilesWithoutAnotherWrite() async throws {
        let (model, fixture, storage) = try await setup(); let connection = model.connection!
        XCTAssertTrue(model.saveRecovery(item:"movie", connection:connection, ticks:90_000_000, confirmed:false))
        fixture.readsFail(true); model.setPlayed(model.detail!, played:true)
        try await wait { !model.userStateBusy }
        // Exercise the actual persisted schema, including the enum and affected IDs.
        storage.value = try JSONDecoder().decode(SavedApplication.self, from: JSONEncoder().encode(storage.value))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UserStateProtocol.self]
        let session = URLSession(configuration: configuration)
        let restarted = ApplicationModel(storage: storage, credentials: .init(read: { _ in "token" }, save: { _,_ in }, remove: { _ in }), clientFactory: { MediaServerClient(connection:$0, token:$1, deviceID:$2, session:session) })
        XCTAssertTrue(restarted.userStateNeedsRefresh)
        restarted.requestPlayback(model.detail!); XCTAssertFalse(restarted.launchingPlayback)
        fixture.readsFail(false); restarted.refresh()
        try await wait { restarted.catalogComplete && !restarted.userStateNeedsRefresh }
        XCTAssertNil(restarted.recovery(for:"movie", connection:connection)); XCTAssertTrue(storage.value.pendingUserStates.isEmpty)
        XCTAssertEqual(fixture.writeCount, 1); XCTAssertTrue(restarted.items[0].userData.played)
    }
    func testMalformedReadbackCannotClearPendingIntent() async throws {
        for negative in [false, true] {
            let (model, fixture, storage) = try await setup()
            fixture.invalidType = !negative; fixture.negativePosition = negative
            model.toggleFavorite(model.detail!); try await wait { !model.userStateBusy }
            XCTAssertTrue(model.userStateNeedsRefresh)
            model.refresh(); try await wait { model.catalogFailed }
            XCTAssertTrue(model.userStateNeedsRefresh); XCTAssertEqual(storage.value.pendingUserStates.count, 1)
            fixture.invalidType = false; fixture.negativePosition = false
            model.refresh(); try await wait { model.catalogComplete && !model.userStateNeedsRefresh }
            XCTAssertEqual(fixture.writeCount, 1)
        }
    }
    func testRevokingTrustCancelsReadbackAndRetainsDurableUncertainty() async throws {
        let (model, fixture, storage) = try await setup()
        // Only model lifecycle is exercised; the URLProtocol transport does not evaluate TLS.
        let pin = try JSONDecoder().decode(CertificatePin.self, from: Data(#"{"origin":"https://state.test:443","certificateDER":"AA==","approvedAt":0}"#.utf8))
        model.saved.connections[0].certificatePin = pin; try model.persist()
        fixture.writeDelay = 0.25
        model.toggleFavorite(model.detail!); try await wait { fixture.writeCount == 1 }
        await model.revokeCertificateTrust(model.connection!.id)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.connection?.certificatePin); XCTAssertFalse(model.userStateBusy)
        XCTAssertTrue(model.userStateNeedsRefresh); XCTAssertEqual(storage.value.pendingUserStates.count, 1)
        XCTAssertEqual(fixture.readsAfterWrite, 0); XCTAssertEqual(fixture.writeCount, 1)
    }
    func testOlderConfigurationDefaultsToNoPendingMutations() throws {
        let saved = try JSONDecoder().decode(SavedApplication.self, from: Data("{}".utf8))
        XCTAssertTrue(saved.pendingUserStates.isEmpty)
    }
}
