import AppKit
import Foundation
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class EpisodeMemoryStorage: ApplicationPersisting {
    var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}
private final class EpisodeModelProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var body: [String: Any]; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class EpisodeApplicationTests: XCTestCase {
    private func item(_ id: String, type: String = "Episode", season: Int = 1, episode: Int = 1, ticks: Int64 = 0) -> [String: Any] {
        ["Id": id, "Name": id, "Type": type, "SeriesId": "show", "SeasonId": "season-\(season)",
         "IndexNumber": type == "Season" ? season : episode, "ParentIndexNumber": season,
         "UserData": ["PlaybackPositionTicks": ticks]]
    }
    private func decode(_ json: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func model(launch: @escaping (MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void = { _, _, _, _, _ in }) -> (ApplicationModel, ServerConnection) {
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "server", userID: "user", username: "test", libraryIDs: ["library"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [EpisodeModelProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let credentials = CredentialAccess(read: { _ in "test" }, save: { _, _ in }, remove: { _ in })
        return (ApplicationModel(storage: EpisodeMemoryStorage(saved), credentials: credentials,
                                 clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) }, playbackLauncher: launch), connection)
    }
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func installBrowseReply() {
        let show = item("show", type: "Series"), seasons = [item("season-1", type: "Season"), item("season-2", type: "Season", season: 2)]
        let episodes = [item("e1", ticks: 80_000_000), item("e2", episode: 2), item("e3", season: 2)]
        EpisodeModelProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Seasons") { return .init(body: ["Items": seasons, "TotalRecordCount": 2]) }
            if request.url!.path.hasSuffix("/Episodes") { return .init(body: ["Items": episodes, "TotalRecordCount": 3]) }
            return .init(body: show)
        }
    }
    func testColdSeriesReservesEpisodeCardHeightAndCanSwitchSeasonsImmediately() async throws {
        let (model, _) = model()
        let show = item("show", type: "Series")
        let seasonOne = item("season-1", type: "Season"), seasonTwo = item("season-2", type: "Season", season: 2)
        let episodes = [item("e1"), item("e2", episode: 2), item("e3", season: 2)]
        EpisodeModelProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Seasons") { return .init(body: ["Items": [seasonOne, seasonTwo], "TotalRecordCount": 2], delay: 0.25) }
            if request.url!.path.hasSuffix("/Episodes") { return .init(body: ["Items": episodes, "TotalRecordCount": 3], delay: 0.25) }
            return .init(body: show)
        }
        let series = try decode(show)
        func railHeight() -> CGFloat {
            NSHostingController(rootView: SeriesEpisodesView(model: model, series: series).frame(width: 690))
                .sizeThatFits(in: CGSize(width: 690, height: 1600)).height
        }
        model.showDetail(series)
        XCTAssertTrue(model.seriesLoading)
        let pending = railHeight()
        try await waitUntil { !model.seriesLoading && model.episodes.count == 2 }
        let loaded = railHeight()
        XCTAssertGreaterThan(pending, 200, "Reserve the episode artwork, titles and actions from the first frame")
        XCTAssertEqual(pending, loaded, accuracy: 10, "A populated preview should replace one episode-card row in place")
        model.selectSeason("season-2")
        XCTAssertFalse(model.seriesLoading)
        XCTAssertEqual(model.episodes.map(\.id), ["e3"])
        XCTAssertEqual(railHeight(), loaded, accuracy: 2)
        await model.shutdown()
    }

    func testColdDetailOnlyReservesMissingMetadataUntilTheCurrentRequestResolves() async throws {
        let (model, _) = model()
        let connection = model.connection
        let episode = try decode(item("e1"))
        let full = item("e1").merging(["Overview": "合成分集简介"]) { _, new in new }
        EpisodeModelProtocol.handler = { _ in .init(body: full, delay: 0.15) }
        func overviewHeight(_ item: MediaItem, loading: Bool) -> CGFloat {
            let view = MediaOverviewView(connection: connection, item: item, hideUnwatched: false,
                                         expanded: .constant(false), isLoading: loading).frame(width: 380)
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 380, height: 800)).height
        }
        func supplementalHeight(loading: Bool) -> CGFloat {
            let view = VStack {
                MediaDetailInformationView(model: model, people: [], streams: [], awaitsCredits: loading, awaitsStreams: loading)
            }.frame(width: 500)
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 500, height: 1200)).height
        }
        model.showDetail(episode)
        XCTAssertTrue(model.isLoadingPresentedDetailMetadata)
        let blank = overviewHeight(episode, loading: false)
        XCTAssertGreaterThan(overviewHeight(episode, loading: true), blank + 20)
        XCTAssertGreaterThan(supplementalHeight(loading: true), 150)
        try await waitUntil { !model.detailLoading }
        let loaded = try XCTUnwrap(model.detail)
        XCTAssertEqual(loaded.overview, "合成分集简介")
        XCTAssertFalse(model.isLoadingPresentedDetailMetadata)
        XCTAssertEqual(overviewHeight(loaded, loading: true), overviewHeight(loaded, loading: false), accuracy: 1,
                       "A known overview remains readable during enrichment")
        XCTAssertLessThan(supplementalHeight(loading: false), 1, "Confirmed absent optional sections leave no slots")
        model.showSeries(for: episode)
        XCTAssertTrue(model.detailLoading)
        XCTAssertFalse(model.isLoadingPresentedDetailMetadata, "Looking up another route leaves the current detail intact")
        try await waitUntil { !model.detailLoading }
        XCTAssertFalse(model.isLoadingPresentedDetailMetadata)
        await model.shutdown()
    }

    func testAllEpisodesReservesGridRowsThenShowsTheServerEmptyOrErrorState() async throws {
        for fails in [false, true] {
            let (model, _) = model()
            let show = item("show", type: "Series")
            EpisodeModelProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Seasons") || request.url!.path.hasSuffix("/Episodes") {
                    let response: [String: Any] = fails ? ["Items": "unreadable"] : ["Items": [], "TotalRecordCount": 0]
                    return .init(body: response, delay: 0.15)
                }
                return .init(body: show)
            }
            let series = try decode(show)
            func gridHeight() -> CGFloat {
                NSHostingController(rootView: SeriesEpisodesView(model: model, series: series).frame(width: 690))
                    .sizeThatFits(in: CGSize(width: 690, height: 1800)).height
            }
            model.showDetail(series)
            model.showAllEpisodes()
            XCTAssertTrue(model.seriesLoading && model.seriesPresentation.showsAll)
            XCTAssertGreaterThan(gridHeight(), 390, "Viewing all episodes reserves more than one card row")
            try await waitUntil { !model.seriesLoading && !model.detailLoading }
            XCTAssertEqual(model.seriesError != nil, fails)
            XCTAssertTrue(model.episodes.isEmpty)
            XCTAssertLessThan(gridHeight(), 180, "Empty and failed results release the synthetic card slots")
            await model.shutdown()
        }
    }

    func testSeasonSelectionAndExplicitAllSurviveDetailRefresh() async throws {
        installBrowseReply(); let (model, _) = model()
        let show = try decode(item("show", type: "Series"))
        model.showDetail(show)
        try await waitUntil { !model.seriesLoading && model.seasons.count == 2 }
        XCTAssertEqual(model.episodes.map(\.id), ["e1", "e2"])
        XCTAssertEqual(model.seriesPlaybackCandidate?.id, "e1")
        model.selectSeason("season-2")
        XCTAssertEqual(model.episodes.map(\.id), ["e3"])
        model.showDetail(show)
        try await waitUntil { !model.seriesLoading && model.selectedSeasonID == "season-2" }
        model.selectSeason("")
        XCTAssertEqual(model.episodes.map(\.id), ["e1", "e2", "e3"])
        model.showDetail(show)
        try await waitUntil { !model.seriesLoading && model.episodes.count == 3 }
        XCTAssertEqual(model.selectedSeasonID, "")
    }
    func testDismissedSeriesCannotBeRepopulatedByLateReply() async throws {
        let seasons = [item("season-1", type: "Season")], episodes = [item("e1")], show = item("show", type: "Series")
        EpisodeModelProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Seasons") { return .init(body: ["Items": seasons, "TotalRecordCount": 1], delay: 0.15) }
            if request.url!.path.hasSuffix("/Episodes") { return .init(body: ["Items": episodes, "TotalRecordCount": 1], delay: 0.15) }
            return .init(body: show)
        }
        let (model, _) = model(); model.showDetail(try decode(show)); model.dismissDetail()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.detail); XCTAssertTrue(model.seasons.isEmpty); XCTAssertTrue(model.episodes.isEmpty); XCTAssertFalse(model.seriesLoading)
    }
    func testManualSecondSelectionWinsOverDelayedFirstMetadata() async throws {
        var launches: [String] = []
        let (model, _) = model { item, _, _, _, _ in launches.append(item.id) }
        let first = item("e1", type: "Movie"), second = item("e2", type: "Movie")
        EpisodeModelProtocol.handler = { request in
            .init(body: request.url!.lastPathComponent == "e1" ? first : second, delay: request.url!.lastPathComponent == "e1" ? 0.2 : 0)
        }
        model.requestPlayback(try decode(first)); try await Task.sleep(for: .milliseconds(30))
        model.requestPlayback(try decode(second))
        try await waitUntil { launches == ["e2"] }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(launches, ["e2"]); XCTAssertFalse(model.launchingPlayback)
    }
    func testShutdownInvalidatesInFlightEpisodePreparation() async throws {
        var launches = 0
        let (model, _) = model { _, _, _, _, _ in launches += 1 }
        let episode = item("e1", type: "Movie")
        EpisodeModelProtocol.handler = { _ in .init(body: episode, delay: 0.15) }
        model.requestPlayback(try decode(episode)); try await Task.sleep(for: .milliseconds(30))
        await model.shutdown()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(launches, 0); XCTAssertFalse(model.launchingPlayback)
    }
    func testRemovedConnectionInvalidatesDelayedPreparation() async throws {
        var launches = 0
        let (model, connection) = model { _, _, _, _, _ in launches += 1 }
        let episode = item("e1", type: "Movie")
        EpisodeModelProtocol.handler = { _ in .init(body: episode, delay: 0.15) }
        model.requestPlayback(try decode(episode)); try await Task.sleep(for: .milliseconds(30))
        await model.removeConnection(connection.id)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(launches, 0); XCTAssertNil(model.connection)
    }
    func testDirectStopDuringNextEpisodeFetchPreventsLaunch() async throws {
        try await exercisePendingContinuation(cancel: { controller in await controller.stop() }, expectedLaunches: [])
    }
    func testDisablingAutoPlayDuringNextEpisodeFetchPreventsLaunch() async throws {
        try await exercisePendingContinuation(cancel: { controller in controller.autoPlayNextEpisode = false }, expectedLaunches: [])
    }
    func testNaturalCompletionRemainsEligibleDuringNextEpisodeFetch() async throws {
        try await exercisePendingContinuation(cancel: { _ in }, expectedLaunches: ["e2"])
    }
    func testAutomaticContinuationRestartsFreshlyMarkedPlayedEpisodeDespiteNonzeroEndPosition() async throws {
        try await exercisePendingContinuation(cancel: { _ in }, expectedLaunches: ["e2"],
                                              nextPlayed: true, nextRemoteTicks: 9_990_000_000, expectedLaunchTicks: [0])
    }
    func testAutomaticContinuationResumesUnfinishedEpisodeAtFreshRemotePosition() async throws {
        try await exercisePendingContinuation(cancel: { _ in }, expectedLaunches: ["e2"],
                                              nextPlayed: false, nextRemoteTicks: 345_000_000, expectedLaunchTicks: [345_000_000])
    }
    func testDirectStopWhileAwaitingRecoveryChoicePreventsLaunch() async throws {
        try await exercisePendingContinuation(cancel: { controller in await controller.stop() }, expectedLaunches: [], afterPrompt: true)
    }
    func testDisablingAutoPlayWhileAwaitingRecoveryChoicePreventsLaunch() async throws {
        try await exercisePendingContinuation(cancel: { controller in controller.autoPlayNextEpisode = false }, expectedLaunches: [], afterPrompt: true)
    }
    func testUncancelledNextEpisodeCanResolveRecoveryChoice() async throws {
        try await exercisePendingContinuation(cancel: { _ in }, expectedLaunches: ["e2"], afterPrompt: true)
    }
    func testMinimizingDuringAutomaticMetadataFetchPreventsLateContinuation() async throws {
        try await exercisePendingContinuation(cancel: { controller in
            var preferences = controller.interfacePreferences
            preferences.pauseWhenMinimized = true
            controller.updateInterfacePreferences(preferences)
            controller.setWindowMiniaturized(true)
            controller.setWindowMiniaturized(false)
        }, expectedLaunches: [])
    }
    func testMinimizingDismissesAutomaticRecoveryWithoutLaunchingNextEpisode() async throws {
        try await exercisePendingContinuation(cancel: { controller in
            var preferences = controller.interfacePreferences
            preferences.pauseWhenMinimized = true
            controller.updateInterfacePreferences(preferences)
            controller.setWindowMiniaturized(true)
            controller.setWindowMiniaturized(false)
        }, expectedLaunches: [], afterPrompt: true, expectsMinimizeDismissal: true)
    }
    func testAutomaticContinuationRecoveryKeepsOwnerDefaultsAndCurrentAutoPlayChoice() async throws {
        var launches: [(id: String, ticks: Int64)] = []
        let (model, connection) = model { item, _, _, _, ticks in launches.append((item.id, ticks)) }
        var sessionDefaults = ApplicationPreferences()
        sessionDefaults.autoPlayNextEpisode = false
        sessionDefaults.resumeRewindSeconds = 10
        sessionDefaults.subtitleMode = .off
        sessionDefaults.subtitleFontSize = 60
        sessionDefaults.subtitleStyle = .boxed
        XCTAssertTrue(model.updateApplicationPreferences(sessionDefaults))

        // Establish the model's real intent through its normal preparation path.
        let seed = item("seed", type: "Movie")
        XCTAssertTrue(model.saveRecovery(item: "seed", connection: connection, ticks: 100_000_000, confirmed: false))
        EpisodeModelProtocol.handler = { _ in .init(body: seed) }
        model.requestPlayback(try decode(seed))
        try await waitUntil { model.recoveryPrompt != nil }
        let requestID = try XCTUnwrap(model.recoveryPrompt).generation
        model.recoveryPrompt = nil

        let first = try decode(item("e1")), next = item("e2", episode: 2, ticks: 300_000_000)
        let sequence = EpisodeSequence(seriesID: "show", episodes: [first, try decode(next)])
        var completion = PlaybackCompletionGate()
        XCTAssertTrue(completion.beginNaturalEnd(started: true, stopped: false, failed: false))
        let owner = NativePlaybackController(item: first, connection: connection, client: try model.client(for: connection),
                                             applicationPreferences: sessionDefaults, completionGate: completion) { _, _ in true }
        owner.autoPlayNextEpisode = true // The user enabled continuation for this session.
        await owner.stop(naturalEnd: true)
        model.player = owner
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: connection, ticks: 700_000_000, confirmed: false))
        let fetching = expectation(description: "Automatic continuation metadata is pending")
        EpisodeModelProtocol.handler = { _ in fetching.fulfill(); return .init(body: next, delay: 0.15) }
        let transition = Task { await model.advanceEpisode(after: owner, sequence: sequence, requestID: requestID) }
        await fulfillment(of: [fetching], timeout: 2)
        var changedDefaults = sessionDefaults
        changedDefaults.subtitleMode = .mediaDefault
        changedDefaults.subtitleFontSize = 72
        changedDefaults.subtitleStyle = .yellow
        XCTAssertTrue(model.updateApplicationPreferences(changedDefaults))
        await transition.value

        let prompt = try XCTUnwrap(model.recoveryPrompt)
        XCTAssertTrue(prompt.continuationOwner === owner)
        XCTAssertEqual(prompt.playbackDefaults, sessionDefaults)
        XCTAssertTrue(prompt.autoPlayNext, "The current session choice takes priority over the disabled application default")
        XCTAssertFalse(model.applicationPreferences.autoPlayNextEpisode)
        XCTAssertEqual(owner.interfacePreferences, changedDefaults)
        XCTAssertTrue(launches.isEmpty)
        model.chooseRecovery(local: true)
        try await waitUntil { !model.launchingPlayback }
        XCTAssertEqual(launches.map(\.id), ["e2"])
        XCTAssertEqual(launches.map(\.ticks), [700_000_000])
        XCTAssertEqual(owner.playbackDefaults, sessionDefaults)
        await model.shutdown()
    }
    func testAutomaticContinuationWaitsForDurableProgressAndRetriesOnlyFrozenLocalSnapshot() async throws {
        var launches: [String] = []
        let (model, connection) = model { item, _, _, _, _ in launches.append(item.id) }
        // Use the normal request path to obtain an active intent without opening a playback window.
        let seed = item("seed", type: "Movie")
        XCTAssertTrue(model.saveRecovery(item: "seed", connection: connection, ticks: 100_000_000, confirmed: false))
        EpisodeModelProtocol.handler = { _ in .init(body: seed) }
        model.requestPlayback(try decode(seed))
        try await waitUntil { model.recoveryPrompt != nil }
        let requestID = try XCTUnwrap(model.recoveryPrompt).generation
        model.recoveryPrompt = nil

        let first = try decode(item("e1")), nextJSON = item("e2", episode: 2)
        let sequence = EpisodeSequence(seriesID: "show", episodes: [first, try decode(nextJSON)])
        var completion = PlaybackCompletionGate()
        XCTAssertTrue(completion.beginNaturalEnd(started: true, stopped: false, failed: false))
        var diskAvailable = false
        var localWrites: [(ticks: Int64, confirmed: Bool)] = []
        let controller = NativePlaybackController(item: first, connection: connection, client: try model.client(for: connection), completionGate: completion) { ticks, confirmed in
            localWrites.append((ticks, confirmed))
            return diskAvailable
        }
        let frozenTicks: Int64 = 235_000_000
        XCTAssertFalse(controller.persistSnapshot(ticks: frozenTicks, confirmed: false))
        controller.markUncertain()
        await controller.stop(naturalEnd: true)
        model.player = controller
        XCTAssertTrue(controller.canAutomaticallyContinue)
        XCTAssertTrue(controller.episodeProgressAtRisk)

        EpisodeModelProtocol.handler = { _ in
            XCTFail("Automatic continuation must not fetch the next episode while neither progress copy is durable")
            return .init(body: nextJSON)
        }
        await model.advanceEpisode(after: controller, sequence: sequence, requestID: requestID)
        XCTAssertTrue(launches.isEmpty)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertTrue(controller.nextEpisodeMessage?.contains("已停止自动连播") == true)
        XCTAssertEqual(localWrites.map(\.ticks), [frozenTicks, frozenTicks])
        XCTAssertTrue(controller.episodeProgressAtRisk)

        // Recovery writes the same frozen position locally, without replaying an uncertain server report.
        diskAvailable = true
        var metadataRequests = 0
        EpisodeModelProtocol.handler = { _ in metadataRequests += 1; return .init(body: nextJSON) }
        await model.advanceEpisode(after: controller, sequence: sequence, requestID: requestID)
        XCTAssertEqual(launches, ["e2"])
        XCTAssertEqual(metadataRequests, 1)
        XCTAssertEqual(localWrites.map(\.ticks), [frozenTicks, frozenTicks, frozenTicks])
        XCTAssertTrue(localWrites.allSatisfy { !$0.confirmed })
        XCTAssertFalse(controller.episodeProgressAtRisk)
        XCTAssertEqual(controller.syncMessage, "进度仅保存在本机 · 下次播放可选择恢复位置")
    }
    private func exercisePendingContinuation(cancel: (NativePlaybackController) async -> Void, expectedLaunches: [String], afterPrompt: Bool = false,
                                             nextPlayed: Bool = false, nextRemoteTicks: Int64 = 0, expectedLaunchTicks: [Int64]? = nil,
                                             expectsMinimizeDismissal: Bool = false) async throws {
        var launches: [String] = []
        var launchTicks: [Int64] = []
        let (model, connection) = model { item, _, _, _, ticks in launches.append(item.id); launchTicks.append(ticks) }
        // Obtain a live intent token through the normal recovery flow, without opening a window.
        let seed = item("seed", type: "Movie")
        XCTAssertTrue(model.saveRecovery(item: "seed", connection: connection, ticks: 100_000_000, confirmed: false))
        EpisodeModelProtocol.handler = { _ in .init(body: seed) }
        model.requestPlayback(try decode(seed))
        try await waitUntil { model.recoveryPrompt != nil }
        let requestID = try XCTUnwrap(model.recoveryPrompt).generation
        model.recoveryPrompt = nil

        let firstItem = try decode(item("e1")), listedNextJSON = item("e2", episode: 2)
        let sequence = EpisodeSequence(seriesID: "show", episodes: [firstItem, try decode(listedNextJSON)])
        // The sequence predates the response; continuation must use the fresh Played flag and position.
        var nextJSON = listedNextJSON
        nextJSON["UserData"] = ["PlaybackPositionTicks": nextRemoteTicks, "Played": nextPlayed]
        var observedEOF = PlaybackCompletionGate()
        XCTAssertTrue(observedEOF.beginNaturalEnd(started: true, stopped: false, failed: false))
        let controller = NativePlaybackController(item: firstItem, connection: connection, client: try model.client(for: connection), completionGate: observedEOF) { _, _ in true }
        await controller.stop(naturalEnd: true)
        XCTAssertTrue(controller.canAutomaticallyContinue)
        model.player = controller
        controller.onMinimizePause = { [weak model, weak controller] in
            guard let controller else { return }
            model?.playbackPausedForMinimization(controller)
        }
        let fetching = expectation(description: "Next episode metadata request is in flight")
        EpisodeModelProtocol.handler = { _ in
            fetching.fulfill()
            return .init(body: nextJSON, delay: 0.15)
        }
        if afterPrompt { XCTAssertTrue(model.saveRecovery(item: "e2", connection: connection, ticks: 200_000_000, confirmed: false)) }
        let transition = Task { await model.advanceEpisode(after: controller, sequence: sequence, requestID: requestID) }
        await fulfillment(of: [fetching], timeout: 2)
        if afterPrompt {
            await transition.value
            XCTAssertNotNil(model.recoveryPrompt)
            await cancel(controller)
            if expectsMinimizeDismissal {
                XCTAssertNil(model.recoveryPrompt)
                XCTAssertEqual(controller.nextEpisodeMessage, "已因最小化暂停，可重新选择单集。")
            }
            model.chooseRecovery(local: true)
            try await waitUntil { !model.launchingPlayback }
        } else {
            await cancel(controller)
            await transition.value
        }
        XCTAssertEqual(launches, expectedLaunches)
        if let expectedLaunchTicks { XCTAssertEqual(launchTicks, expectedLaunchTicks) }
        XCTAssertFalse(model.launchingPlayback)
    }
    func testWrongReturnedEpisodeIDCannotStartDifferentEpisode() async throws {
        var launches = 0
        let (model, _) = model { _, _, _, _, _ in launches += 1 }
        let requested = item("e1", type: "Movie"), wrong = item("e2", type: "Movie")
        EpisodeModelProtocol.handler = { _ in .init(body: wrong) }
        model.requestPlayback(try decode(requested))
        try await waitUntil { !model.launchingPlayback }
        XCTAssertEqual(launches, 0); XCTAssertNotNil(model.errorMessage)
    }
    func testNextEpisodeInheritsLowVolumeAndMutedRestoreTarget() throws {
        let (model, connection) = model()
        let previous = NativePlaybackController(item: try decode(item("e1")), connection: connection, client: try model.client(for: connection)) { _, _ in true }
        let next = NativePlaybackController(item: try decode(item("e2")), connection: connection, client: try model.client(for: connection)) { _, _ in true }
        previous.setVolume(0.35)
        next.inheritContinuationVolume(from: previous)
        XCTAssertEqual(next.volume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(Double(next.player.volume), 0.35, accuracy: 0.0001)
        previous.toggleMute()
        next.inheritContinuationVolume(from: previous)
        XCTAssertEqual(next.volume, 0)
        XCTAssertEqual(Double(next.player.volume), 0.35, accuracy: 0.0001)
        XCTAssertTrue(next.player.isMuted)
        next.toggleMute()
        XCTAssertEqual(next.volume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(next.playbackRate, 1, "Volume inheritance alone does not change playback speed")
    }
    func testWindowReplacementKeepsWindowAndCloseOwnsNewController() async throws {
        _ = NSApplication.shared
        let (model, connection) = model()
        let first = NativePlaybackController(item: try decode(item("e1")), connection: connection, client: try model.client(for: connection)) { _, _ in true }
        let second = NativePlaybackController(item: try decode(item("e2")), connection: connection, client: try model.client(for: connection)) { _, _ in true }
        var closing: NativePlaybackController?, closed: NativePlaybackController?
        let owner = PlaybackWindowController(controller: first, onClosing: { closing = $0 }, onClose: { closed = $0 })
        let original = try XCTUnwrap(owner.window)
        let frame = original.frame
        owner.replaceController(second)
        XCTAssertTrue(owner.window === original)
        XCTAssertEqual(owner.window?.frame, frame)
        XCTAssertEqual(owner.window?.title, "e2")
        XCTAssertFalse(owner.windowShouldClose(original))
        XCTAssertTrue(closing === second)
        XCTAssertFalse(owner.canReplaceController)
        try await waitUntil { closed != nil }
        XCTAssertTrue(closed === second)
        XCTAssertFalse(second.isActive)
    }
    func testPerEpisodeRecoveryIsIsolatedAndCancelledPromptCannotLaunch() async throws {
        var launches: [String] = []
        let (model, connection) = model { item, _, _, _, _ in launches.append(item.id) }
        XCTAssertTrue(model.saveRecovery(item: "e1", connection: connection, ticks: 300_000_000, confirmed: false))
        XCTAssertTrue(model.saveRecovery(item: "e2", connection: connection, ticks: 700_000_000, confirmed: true))
        let episode = item("e1", type: "Movie", ticks: 10_000_000)
        EpisodeModelProtocol.handler = { _ in .init(body: episode) }
        model.requestPlayback(try decode(episode))
        try await waitUntil { model.recoveryPrompt != nil }
        XCTAssertEqual(model.recoveryPrompt?.localTicks, 300_000_000)
        XCTAssertEqual(model.recovery(for: "e2", connection: connection)?.ticks, 700_000_000)
        await model.shutdown(); model.chooseRecovery(local: true)
        XCTAssertTrue(launches.isEmpty); XCTAssertNil(model.recoveryPrompt)
    }
}

final class EpisodeCompletionTests: XCTestCase {
    func testNaturalCompletionIsExactlyOnce() {
        var gate = PlaybackCompletionGate()
        XCTAssertTrue(gate.beginNaturalEnd(started: true, stopped: false, failed: false))
        XCTAssertTrue(gate.mayContinue)
        XCTAssertFalse(gate.beginNaturalEnd(started: true, stopped: false, failed: false))
    }
    func testCloseDuringStopBarrierCancelsAlreadyObservedEOF() {
        var gate = PlaybackCompletionGate()
        XCTAssertTrue(gate.beginNaturalEnd(started: true, stopped: false, failed: false))
        gate.cancel()
        XCTAssertFalse(gate.mayContinue)
        XCTAssertFalse(gate.beginNaturalEnd(started: true, stopped: false, failed: false))
    }
    func testManualStopFailureAndUnstartedMediaNeverAutoplay() {
        for (started, stopped, failed) in [(true, true, false), (true, false, true), (false, false, false)] {
            var gate = PlaybackCompletionGate()
            XCTAssertFalse(gate.beginNaturalEnd(started: started, stopped: stopped, failed: failed))
            XCTAssertFalse(gate.mayContinue)
        }
        var gate = PlaybackCompletionGate(); gate.cancel()
        XCTAssertFalse(gate.beginNaturalEnd(started: true, stopped: false, failed: false))
    }
}
