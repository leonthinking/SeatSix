import AppKit
import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class ManualSwitchStorage: ApplicationPersisting {
    var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}

private final class ManualSwitchProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body: [String: Any]
        var delay: TimeInterval = 0
    }
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
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class ManualSwitchRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class ManualEpisodeSwitchTests: XCTestCase {
    private struct Launch: Equatable {
        let id: String
        let ticks: Int64
    }
    private func json(_ id: String, episode: Int = 1, ticks: Int64 = 0,
                      played: Bool = false, seriesID: String = "show") -> [String: Any] {
        ["Id": id, "Name": id, "Type": "Episode", "SeriesId": seriesID,
         "SeasonId": "season-1", "ParentIndexNumber": 1, "IndexNumber": episode,
         "UserData": ["PlaybackPositionTicks": ticks, "Played": played]]
    }
    private func decode(_ body: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: body))
    }
    private func fixture(defaults: ApplicationPreferences = .init(),
                         launch: ((MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void)? = nil)
        throws -> (ApplicationModel, NativePlaybackController) {
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "test", libraryIDs: ["library"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        saved.applicationPreferences = defaults
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ManualSwitchProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = CredentialAccess(read: { _ in "test-token" }, save: { _, _ in }, remove: { _ in })
        let model = ApplicationModel(storage: ManualSwitchStorage(saved), credentials: credentials,
                                     clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) },
                                     playbackLauncher: launch)
        let first = try decode(json("e1", ticks: 100_000_000))
        let controller = NativePlaybackController(item: first, connection: connection, client: try model.client(for: connection),
                                                   applicationPreferences: defaults) { _, _ in true }
        controller.episodeSequence = EpisodeSequence(seriesID: "show", episodes: [
            first, try decode(json("e2", episode: 2, ticks: 20_000_000)), try decode(json("e3", episode: 3))
        ])
        controller.preparing = false
        model.player = controller
        return (model, controller)
    }
    private func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), description)
    }

    func testManualSwitchStopsOwnerBeforeFetchingAndUsesFreshRemoteProgressWithAutoPlayOff() async throws {
        var launches: [Launch] = []
        var defaults = ApplicationPreferences(); defaults.resumeRewindSeconds = 10
        let (model, owner) = try fixture(defaults: defaults) { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        owner.autoPlayNextEpisode = false
        let fresh = json("e2", episode: 2, ticks: 910_000_000)
        let observedStopped = expectation(description: "Metadata is read after the previous controller stopped")
        ManualSwitchProtocol.handler = { _ in
            Task { @MainActor in
                XCTAssertFalse(owner.isActive)
                XCTAssertFalse(owner.stopping, "Stop barrier has completed before the metadata read")
                observedStopped.fulfill()
            }
            return .init(body: fresh)
        }
        XCTAssertTrue(owner.canSelectEpisode)
        model.requestEpisodeSwitch(to: "e2", from: owner)
        XCTAssertTrue(owner.switchingEpisode)
        XCTAssertFalse(owner.canSelectEpisode)
        await fulfillment(of: [observedStopped], timeout: 2)
        try await waitUntil("Fresh episode launches and releases the transition") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e2", ticks: 910_000_000)])
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertNil(model.recoveryPrompt)
    }

    func testFromBeginningCanRestartActiveCurrentEpisodeWithoutRecoveryPrompt() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        XCTAssertTrue(model.saveRecovery(item: "e1", connection: owner.connection, ticks: 800_000_000, confirmed: false))
        let fresh = json("e1", ticks: 500_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: fresh) }
        model.requestEpisodeSwitch(to: "e1", from: owner, fromBeginning: true)
        try await waitUntil("Current episode restarts") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e1", ticks: 0)])
        XCTAssertNil(owner.episodeRecoveryChoice)
        XCTAssertNil(model.recoveryPrompt)
    }

    func testWatchedEpisodeStartsAtBeginningInsteadOfStaleEndPosition() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        let watched = json("e2", episode: 2, ticks: 24_000_000_000, played: true)
        ManualSwitchProtocol.handler = { _ in .init(body: watched) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Watched episode starts") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e2", ticks: 0)])
    }

    func testUnknownAndActiveCurrentEpisodeSelectionsDoNotStopOrFetch() throws {
        var launches = 0
        let (model, owner) = try fixture { _, _, _, _, _ in launches += 1 }
        let requests = ManualSwitchRequestLog()
        ManualSwitchProtocol.handler = { request in requests.append(request.url!.lastPathComponent); return .init(body: [:]) }
        model.requestEpisodeSwitch(to: "missing", from: owner)
        model.requestEpisodeSwitch(to: "e1", from: owner)
        XCTAssertTrue(owner.isActive)
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertTrue(requests.ids.isEmpty)
        XCTAssertEqual(launches, 0)
    }

    func testControllerThatNoLongerOwnsPlayerCannotSwitch() throws {
        var launches = 0
        let (model, owner) = try fixture { _, _, _, _, _ in launches += 1 }
        model.player = nil
        model.requestEpisodeSwitch(to: "e2", from: owner)
        XCTAssertTrue(owner.isActive)
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertEqual(launches, 0)
    }

    func testDirectStopDuringMetadataFetchCancelsManualSwitch() async throws {
        try await exercisePendingSwitch(cancel: { _, owner in await owner.stop() })
    }

    func testShutdownDuringMetadataFetchCancelsManualSwitch() async throws {
        try await exercisePendingSwitch(cancel: { model, _ in await model.shutdown() })
    }

    private func exercisePendingSwitch(cancel: (ApplicationModel, NativePlaybackController) async -> Void) async throws {
        var launches: [String] = []
        let (model, owner) = try fixture { item, _, _, _, _ in launches.append(item.id) }
        let next = json("e2", episode: 2)
        let fetching = expectation(description: "Episode metadata is pending")
        ManualSwitchProtocol.handler = { _ in fetching.fulfill(); return .init(body: next, delay: 0.15) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        await fulfillment(of: [fetching], timeout: 2)
        await cancel(model, owner)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(launches.isEmpty)
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertNil(owner.episodeRecoveryChoice)
    }

    func testRepeatedSelectionWhileMetadataPendingCannotLaunchTwoEpisodes() async throws {
        var launches: [String] = []
        let (model, owner) = try fixture { item, _, _, _, _ in launches.append(item.id) }
        let next = json("e2", episode: 2), requests = ManualSwitchRequestLog()
        let fetching = expectation(description: "First selection is pending")
        ManualSwitchProtocol.handler = { request in
            requests.append(request.url!.lastPathComponent); fetching.fulfill()
            return .init(body: next, delay: 0.15)
        }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        await fulfillment(of: [fetching], timeout: 2)
        model.requestEpisodeSwitch(to: "e2", from: owner)
        model.requestEpisodeSwitch(to: "e3", from: owner)
        try await waitUntil("Only the first accepted selection completes") { !model.launchingPlayback }
        XCTAssertEqual(requests.ids, ["e2"])
        XCTAssertEqual(launches, ["e2"])
        XCTAssertFalse(owner.switchingEpisode)
    }

    func testMetadataFailureAllowsRetryFromStoppedOwner() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        ManualSwitchProtocol.handler = { _ in .init(status: 500, body: [:]) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Failed transition releases the controls") { !model.launchingPlayback }
        XCTAssertTrue(launches.isEmpty)
        XCTAssertFalse(owner.isActive)
        XCTAssertTrue(owner.canSelectEpisode)
        XCTAssertNotNil(owner.nextEpisodeMessage)
        let next = json("e2", episode: 2, ticks: 350_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: next) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Retried selection launches") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e2", ticks: 350_000_000)])
    }

    func testStoppedCurrentEpisodeCanResumeItself() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        await owner.stop()
        let fresh = json("e1", ticks: 450_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: fresh) }
        model.requestEpisodeSwitch(to: "e1", from: owner)
        try await waitUntil("Stopped current episode can be resumed") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e1", ticks: 450_000_000)])
    }

    func testFailedCurrentEpisodeCanBeRetried() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        owner.errorMessage = "Test playback failure"
        let fresh = json("e1", ticks: 460_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: fresh) }
        model.requestEpisodeSwitch(to: "e1", from: owner)
        try await waitUntil("Failed current episode can be retried") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e1", ticks: 460_000_000)])
    }

    func testInlineRecoveryCanChooseLocalProgressWithoutOpeningMainWindowPrompt() async throws {
        try await exerciseRecoveryChoice(local: true, expectedTicks: 700_000_000)
    }

    func testInlineRecoveryCanChooseRemoteProgressWithoutOpeningMainWindowPrompt() async throws {
        try await exerciseRecoveryChoice(local: false, expectedTicks: 300_000_000)
    }

    func testManualRecoveryStartsNextControllerWithOwnerDefaultsAndCurrentAutoPlayChoice() async throws {
        _ = NSApplication.shared
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApplication.shared.windows where !existingWindows.contains(ObjectIdentifier(window)) {
                window.close()
            }
        }
        var sessionDefaults = ApplicationPreferences()
        sessionDefaults.subtitleMode = .off
        sessionDefaults.subtitleFontSize = 60
        sessionDefaults.subtitleStyle = .boxed
        let (model, owner) = try fixture(defaults: sessionDefaults)
        owner.autoPlayNextEpisode = false // The user disabled continuation for this session.
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: owner.connection, ticks: 700_000_000, confirmed: false))
        let next = json("e2", episode: 2, ticks: 300_000_000)
        let fetching = expectation(description: "Manual switch metadata is pending")
        ManualSwitchProtocol.handler = { request in
            if request.url?.path.hasSuffix("/PlaybackInfo") == true {
                // Build the real next controller, then end before opening media.
                return .init(body: ["MediaSources": []])
            }
            fetching.fulfill()
            return .init(body: next, delay: 0.15)
        }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        await fulfillment(of: [fetching], timeout: 2)
        var changedDefaults = sessionDefaults
        changedDefaults.subtitleMode = .mediaDefault
        changedDefaults.subtitleFontSize = 72
        changedDefaults.subtitleStyle = .yellow
        XCTAssertTrue(model.updateApplicationPreferences(changedDefaults))
        try await waitUntil("Inline recovery remains attached to the old owner") { owner.episodeRecoveryChoice != nil }
        XCTAssertNil(model.recoveryPrompt)
        XCTAssertEqual(owner.playbackDefaults, sessionDefaults)
        XCTAssertFalse(owner.autoPlayNextEpisode)
        XCTAssertTrue(model.applicationPreferences.autoPlayNextEpisode)

        // A second edit while the choice is visible must not replace the prompt's snapshot.
        changedDefaults.subtitleFontSize = 32
        changedDefaults.subtitleStyle = .outlined
        XCTAssertTrue(model.updateApplicationPreferences(changedDefaults))
        owner.chooseEpisodeRecovery(local: true)
        try await waitUntil("The chosen episode receives the original playback session") {
            model.player !== owner && model.player?.item.id == "e2" && !model.launchingPlayback
        }
        let nextController = try XCTUnwrap(model.player)
        XCTAssertEqual(nextController.playbackDefaults, sessionDefaults)
        XCTAssertEqual(nextController.interfacePreferences, changedDefaults)
        XCTAssertFalse(nextController.autoPlayNextEpisode)
        XCTAssertNil(owner.episodeRecoveryChoice)
        XCTAssertFalse(owner.switchingEpisode)
        await model.shutdown()
    }

    private func exerciseRecoveryChoice(local: Bool, expectedTicks: Int64) async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: owner.connection, ticks: 700_000_000, confirmed: false))
        let next = json("e2", episode: 2, ticks: 300_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: next) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Player owns the recovery choice") { owner.episodeRecoveryChoice != nil }
        XCTAssertEqual(owner.episodeRecoveryChoice?.localTicks, 700_000_000)
        XCTAssertEqual(owner.episodeRecoveryChoice?.remoteTicks, 300_000_000)
        XCTAssertNil(model.recoveryPrompt)
        XCTAssertTrue(owner.switchingEpisode)
        XCTAssertFalse(owner.canSelectEpisode)
        XCTAssertTrue(launches.isEmpty)
        owner.chooseEpisodeRecovery(local: local)
        try await waitUntil("Chosen recovery position launches") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e2", ticks: expectedTicks)])
        XCTAssertNil(owner.episodeRecoveryChoice)
        XCTAssertFalse(owner.switchingEpisode)
    }

    func testCancelledInlineRecoveryRejectsStaleCallbackAndAllowsNewSelection() async throws {
        var launches: [Launch] = []
        let (model, owner) = try fixture { item, _, _, _, ticks in launches.append(Launch(id: item.id, ticks: ticks)) }
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: owner.connection, ticks: 700_000_000, confirmed: false))
        let next = json("e2", episode: 2, ticks: 300_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: next) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Recovery choice appears") { owner.episodeRecoveryChoice != nil }
        let staleChoice = try XCTUnwrap(owner.onChooseEpisodeRecovery)
        owner.cancelEpisodeRecovery()
        staleChoice(true)
        XCTAssertTrue(launches.isEmpty)
        XCTAssertNil(owner.episodeRecoveryChoice)
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertTrue(owner.canSelectEpisode)
        model.requestEpisodeSwitch(to: "e2", from: owner, fromBeginning: true)
        staleChoice(false)
        try await waitUntil("A new selection supersedes the cancelled callback") { !model.launchingPlayback }
        XCTAssertEqual(launches, [Launch(id: "e2", ticks: 0)])
    }

    func testDirectStopWhileInlineRecoveryPendingRejectsSavedChoiceCallback() async throws {
        var launches = 0
        let (model, owner) = try fixture { _, _, _, _, _ in launches += 1 }
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: owner.connection, ticks: 700_000_000, confirmed: false))
        let next = json("e2", episode: 2, ticks: 300_000_000)
        ManualSwitchProtocol.handler = { _ in .init(body: next) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Recovery choice appears") { owner.episodeRecoveryChoice != nil }
        let staleChoice = try XCTUnwrap(owner.onChooseEpisodeRecovery)
        await owner.stop()
        staleChoice(true)
        XCTAssertEqual(launches, 0)
        XCTAssertNil(owner.episodeRecoveryChoice)
        XCTAssertFalse(owner.switchingEpisode)
        XCTAssertFalse(model.launchingPlayback)
    }

    func testFreshMetadataCannotReplaceTargetWithEpisodeFromAnotherSeries() async throws {
        var launches = 0
        let (model, owner) = try fixture { _, _, _, _, _ in launches += 1 }
        let wrongSeries = json("e2", episode: 2, seriesID: "another-show")
        ManualSwitchProtocol.handler = { _ in .init(body: wrongSeries) }
        model.requestEpisodeSwitch(to: "e2", from: owner)
        try await waitUntil("Wrong series metadata is rejected") { !model.launchingPlayback }
        XCTAssertEqual(launches, 0)
        XCTAssertNotNil(owner.nextEpisodeMessage)
        XCTAssertNil(model.errorMessage, "Manual transitions keep errors in the fullscreen player")
        XCTAssertTrue(owner.canSelectEpisode)
    }
}
