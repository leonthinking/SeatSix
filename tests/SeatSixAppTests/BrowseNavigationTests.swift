import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class BrowseStorage: ApplicationPersisting {
    var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}

private final class BrowseProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body: [String: Any]; var delay: TimeInterval = 0 }
    static var handler: ((URLRequest) -> Reply)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: reply.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor
final class BrowseNavigationTests: XCTestCase {
    private func item(_ id: String, type: String = "Movie", season: Int = 1, episode: Int = 1,
                      ticks: Int64 = 0, played: Bool = false) -> [String: Any] {
        ["Id": id, "Name": id, "Type": type, "SeriesId": "show", "SeasonId": "season-\(season)",
         "IndexNumber": type == "Season" ? season : episode, "ParentIndexNumber": season,
         "UserData": ["PlaybackPositionTicks": ticks, "Played": played, "IsFavorite": false]]
    }
    private func decode(_ object: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func makeModel(compatibility: Bool = false, focus: (() -> Void)? = nil,
                           launch: @escaping (MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void = { _, _, _, _, _ in }) -> (ApplicationModel, ServerConnection) {
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://browse.test")!, serverID: "server", userID: "user", username: "tester", libraryIDs: ["library", "other"], compatibilityMode: compatibility)
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BrowseProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = CredentialAccess(read: { _ in "token" }, save: { _, _ in }, remove: { _ in })
        let model = ApplicationModel(storage: BrowseStorage(saved), credentials: credentials,
                                     clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) }, focusPlayback: focus, playbackLauncher: launch)
        return (model, connection)
    }
    private func wait(_ label: String = "Expected state", _ predicate: @escaping () -> Bool) async throws {
        let until = Date().addingTimeInterval(3)
        while !predicate(), Date() < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), label)
    }
    private func installSeries(episodes: [[String: Any]], delay: TimeInterval = 0) {
        let show = item("show", type: "Series", ticks: 999_000_000)
        let seasons = [item("season-1", type: "Season"), item("season-2", type: "Season", season: 2)]
        BrowseProtocol.handler = { request in
            let path = request.url!.path
            if path.hasSuffix("/Seasons") { return .init(body: ["Items": seasons, "TotalRecordCount": seasons.count], delay: delay) }
            if path.hasSuffix("/Episodes") { return .init(body: ["Items": episodes, "TotalRecordCount": episodes.count], delay: delay) }
            if let episode = episodes.first(where: { $0["Id"] as? String == request.url!.lastPathComponent }) { return .init(body: episode) }
            return .init(body: show)
        }
    }

    func testMovieContinueBypassesDetailAndUsesFreshServerProgress() async throws {
        var launched: [(String, Int64)] = []
        let (model, _) = makeModel(launch: { item, _, _, _, ticks in launched.append((item.id, ticks)) })
        var fresh = item("movie", ticks: 120_000_000)
        fresh["MediaSources"] = [["Id": "single-version", "Container": "mkv"]]
        BrowseProtocol.handler = { _ in .init(body: fresh) }
        model.resumeWatching(try decode(item("movie", ticks: 10_000_000)))
        XCTAssertEqual(model.resumeLoadingID, "movie")
        try await wait { launched.count == 1 }
        XCTAssertEqual(launched.first?.0, "movie"); XCTAssertEqual(launched.first?.1, 120_000_000)
        XCTAssertNil(model.detail); XCTAssertNil(model.resumeLoadingID)
    }

    func testFreshMultipleMovieVersionsRequireChoiceEvenWhenResumeSummaryOmitsSources() async throws {
        var launched = false
        let (model, connection) = makeModel(launch: { _, _, _, _, _ in launched = true })
        // A previous session may have watched version B, but item-level recovery
        // alone cannot prove that its timeline belongs to current version A.
        XCTAssertTrue(model.saveRecovery(item: "movie", connection: connection, ticks: 900_000_000, confirmed: true))
        let summary = item("movie", ticks: 900_000_000)
        var full = summary
        full["MediaSources"] = [["Id": "version-a", "Name": "Theatrical"], ["Id": "version-b", "Name": "Extended"]]
        BrowseProtocol.handler = { _ in .init(body: full) }
        model.resumeWatching(try decode(summary))
        try await wait { model.detail?.id == "movie" && !model.detailLoading }
        XCTAssertFalse(launched); XCTAssertNil(model.recoveryPrompt)
        XCTAssertNil(model.resumeLoadingID); XCTAssertFalse(model.launchingPlayback)
        XCTAssertEqual(model.detail?.mediaSources.map(\.id), ["version-a", "version-b"])
    }

    func testAmbiguousVersionChoiceDoesNotStopAnotherActiveMovie() async throws {
        let (model, connection) = makeModel()
        let previous = NativePlaybackController(item: try decode(item("previous")), connection: connection,
                                                client: try model.client(for: connection)) { _, _ in true }
        model.player = previous
        var full = item("movie", ticks: 900_000_000)
        full["MediaSources"] = [["Id": "version-a"], ["Id": "version-b"]]
        BrowseProtocol.handler = { _ in .init(body: full) }
        model.resumeWatching(try decode(item("movie", ticks: 900_000_000)))
        try await wait { model.detail?.id == "movie" && !model.detailLoading }
        XCTAssertTrue(model.player === previous); XCTAssertTrue(previous.isActive)
        XCTAssertFalse(previous.stopping)
        await previous.stop()
    }

    func testVersionChoiceFallbackPreservesActiveEpisodeCompletionGeneration() async throws {
        try await assertEpisodeContinuationSurvivesResumePreflight(cancel: false)
    }

    func testCancelledResumePreflightPreservesActiveEpisodeCompletionGeneration() async throws {
        try await assertEpisodeContinuationSurvivesResumePreflight(cancel: true)
    }

    private func assertEpisodeContinuationSurvivesResumePreflight(cancel: Bool) async throws {
        var launches: [String] = []
        let (model, connection) = makeModel(launch: { item, _, _, _, _ in launches.append(item.id) })
        let seed = item("seed")
        BrowseProtocol.handler = { _ in .init(body: seed) }
        XCTAssertTrue(model.saveRecovery(item: "seed", connection: connection, ticks: 100_000_000, confirmed: false))
        model.requestPlayback(try decode(seed))
        try await wait { model.recoveryPrompt != nil }
        // This token is what an actual player's onNaturalCompletion closure
        // captures. A browser preflight must leave it valid until that EOF fires.
        let playbackID = try XCTUnwrap(model.recoveryPrompt).generation
        model.recoveryPrompt = nil
        let first = try decode(item("e1", type: "Episode"))
        let nextJSON = item("e2", type: "Episode", episode: 2)
        let sequence = EpisodeSequence(seriesID: "show", episodes: [first, try decode(nextJSON)])
        var completion = PlaybackCompletionGate()
        XCTAssertTrue(completion.beginNaturalEnd(started: true, stopped: false, failed: false))
        let controller = NativePlaybackController(item: first, connection: connection, client: try model.client(for: connection), completionGate: completion) { _, _ in true }
        controller.episodeSequence = sequence
        controller.onNaturalCompletion = { completed in
            await model.advanceEpisode(after: completed, sequence: sequence, requestID: playbackID)
        }
        model.player = controller
        var multiVersionMovie = item("movie", ticks: 900_000_000)
        multiVersionMovie["MediaSources"] = [["Id": "version-a"], ["Id": "version-b"]]
        BrowseProtocol.handler = { request in
            if request.url!.lastPathComponent == "e2" { return .init(body: nextJSON) }
            return .init(body: multiVersionMovie, delay: cancel ? 0.2 : 0)
        }
        model.resumeWatching(try decode(item("movie", ticks: 900_000_000)))
        if cancel {
            try await Task.sleep(for: .milliseconds(30))
            model.page = "library"
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertNil(model.detail)
        } else {
            try await wait { model.detail?.id == "movie" && !model.detailLoading }
        }
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.canAutomaticallyContinue, "Preflight must not cancel the existing episode's natural-end gate")
        XCTAssertNil(model.resumeLoadingID)
        await controller.stop(naturalEnd: true)
        await controller.onNaturalCompletion?(controller)
        XCTAssertEqual(launches, ["e2"], "The actual completion closure must still accept its original playback generation")
    }

    func testResolvedSeriesEpisodeWithMultipleFreshVersionsOpensEpisodeChoice() async throws {
        var launched = false
        let (model, _) = makeModel(launch: { _, _, _, _, _ in launched = true })
        let episode = item("e2", type: "Episode", episode: 2, ticks: 170_000_000)
        var full = episode
        full["MediaSources"] = [["Id": "episode-version-a"], ["Id": "episode-version-b"]]
        let seasons = [item("season-1", type: "Season")]
        BrowseProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Seasons") { return .init(body: ["Items": seasons, "TotalRecordCount": 1]) }
            if request.url!.path.hasSuffix("/Episodes") { return .init(body: ["Items": [episode], "TotalRecordCount": 1]) }
            return .init(body: full)
        }
        model.resumeWatching(try decode(item("show", type: "Series", ticks: 999_000_000)))
        try await wait { model.detail?.id == "e2" && !model.detailLoading }
        XCTAssertFalse(launched); XCTAssertNil(model.resumeLoadingID)
        XCTAssertEqual(model.detail?.mediaSources.count, 2)
        XCTAssertEqual(model.detailBackTitle, "返回首页")
    }

    func testContinueFocusesActiveVersionRatherThanRestartingWithAutomaticSource() async throws {
        var focused = 0, launches = 0
        let (model, connection) = makeModel(focus: { focused += 1 }, launch: { _, _, _, _, _ in launches += 1 })
        let movie = try decode(item("movie", ticks: 100_000_000))
        BrowseProtocol.handler = { _ in .init(status: 500, body: [:], delay: 0.3) }
        let controller = NativePlaybackController(item: movie, connection: connection, client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        let loading = Task { await controller.load(mode: .automatic, mediaSourceID: "chosen-version", startTicks: 100_000_000) }
        try await wait { controller.requestedMediaSourceID == "chosen-version" }
        model.resumeWatching(movie)
        XCTAssertEqual(focused, 1); XCTAssertEqual(launches, 0)
        XCTAssertTrue(controller.isActive); XCTAssertNil(model.resumeLoadingID); XCTAssertFalse(model.launchingPlayback)
        loading.cancel(); await loading.value
        await controller.stop()
    }

    func testMovieContinueStillRequiresRecoveryChoice() async throws {
        var launched: [Int64] = []
        let (model, connection) = makeModel(launch: { _, _, _, _, ticks in launched.append(ticks) })
        XCTAssertTrue(model.saveRecovery(item: "movie", connection: connection, ticks: 800_000_000, confirmed: false))
        let movie = item("movie", ticks: 120_000_000)
        BrowseProtocol.handler = { _ in .init(body: movie) }
        model.resumeWatching(try decode(movie))
        try await wait { model.recoveryPrompt != nil }
        XCTAssertTrue(launched.isEmpty); XCTAssertNil(model.resumeLoadingID)
        model.chooseRecovery(local: true)
        try await wait { launched == [800_000_000] }
        XCTAssertNil(model.detail)
    }

    func testLeavingPageCancelsPendingResumeRecovery() async throws {
        var launched = false
        let (model, connection) = makeModel(launch: { _, _, _, _, _ in launched = true })
        XCTAssertTrue(model.saveRecovery(item: "movie", connection: connection, ticks: 800_000_000, confirmed: false))
        let movie = item("movie", ticks: 120_000_000)
        BrowseProtocol.handler = { _ in .init(body: movie) }
        model.resumeWatching(try decode(movie))
        try await wait { model.recoveryPrompt != nil }
        model.page = "library"
        model.chooseRecovery(local: true)
        XCTAssertNil(model.recoveryPrompt); XCTAssertFalse(launched)
    }

    func testSeriesContinueResolvesConcreteEpisodeNeverParentProgress() async throws {
        var launched: [(String, Int64)] = []
        let (model, _) = makeModel(launch: { item, _, _, _, ticks in launched.append((item.id, ticks)) })
        installSeries(episodes: [item("e1", type: "Episode", played: true), item("e2", type: "Episode", episode: 2, ticks: 170_000_000)])
        model.resumeWatching(try decode(item("show", type: "Series", ticks: 999_000_000)))
        try await wait { launched.count == 1 }
        XCTAssertEqual(launched.first?.0, "e2"); XCTAssertEqual(launched.first?.1, 170_000_000)
        XCTAssertNil(model.detail)
    }

    func testAmbiguousSeriesContinueOpensDetailsWithoutStartingAnEpisode() async throws {
        var launched = false
        let (model, _) = makeModel(launch: { _, _, _, _, _ in launched = true })
        installSeries(episodes: [item("e1", type: "Episode", ticks: 100_000_000), item("e2", type: "Episode", episode: 2, ticks: 200_000_000)])
        model.resumeWatching(try decode(item("show", type: "Series", ticks: 999_000_000)))
        try await wait { model.detail?.id == "show" && !model.seriesLoading }
        XCTAssertFalse(launched); XCTAssertNil(model.resumeLoadingID)
        XCTAssertEqual(model.detailBackTitle, "返回首页")
    }

    func testPositiveSeriesProgressWithoutPlayedStateFallsBackToDetails() async throws {
        var launched = false
        let (model, _) = makeModel(launch: { _, _, _, _, _ in launched = true })
        var episode = item("e1", type: "Episode")
        episode["UserData"] = ["PlaybackPositionTicks": 170_000_000]
        installSeries(episodes: [episode])
        model.resumeWatching(try decode(item("show", type: "Series", ticks: 999_000_000)))
        try await wait { model.detail?.id == "show" && !model.seriesLoading }
        XCTAssertFalse(launched); XCTAssertNil(model.resumeLoadingID)
    }

    func testSeriesResolutionCannotLaunchAfterChangingPage() async throws {
        var launched = false
        let (model, _) = makeModel(launch: { _, _, _, _, _ in launched = true })
        installSeries(episodes: [item("e1", type: "Episode", ticks: 100_000_000)], delay: 0.2)
        model.resumeWatching(try decode(item("show", type: "Series", ticks: 999_000_000)))
        try await Task.sleep(for: .milliseconds(30))
        model.page = "library"
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(launched); XCTAssertNil(model.detail); XCTAssertNil(model.resumeLoadingID)
    }

    func testPlayableResumeCannotLaunchAfterChangingLibrary() async throws {
        var launched = false
        let (model, _) = makeModel(launch: { _, _, _, _, _ in launched = true })
        model.libraries = [.init(id: "library", name: "Movies"), .init(id: "other", name: "Other")]
        model.selectedLibraryID = "library"
        let movie = item("movie", ticks: 100_000_000)
        BrowseProtocol.handler = { request in
            if request.url!.lastPathComponent == "movie" { return .init(body: movie, delay: 0.2) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        model.resumeWatching(try decode(movie))
        try await Task.sleep(for: .milliseconds(30))
        model.changeLibrary("other")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(launched); XCTAssertNil(model.resumeLoadingID)
        XCTAssertEqual(model.selectedLibraryID, "other")
    }

    func testWindowHistoryTraversesPagesAndRealLibrariesAndDropsAbandonedBranch() async throws {
        BrowseProtocol.handler = { _ in .init(body: ["Items": [], "TotalRecordCount": 0]) }
        let (model, _) = makeModel()
        model.libraries = [.init(id: "library", name: "甲"), .init(id: "other", name: "乙")]
        model.changeLibrary("library")
        XCTAssertFalse(model.canNavigateBack)
        model.navigate(to: "recent")
        model.navigate(to: "library", libraryID: "other")
        model.query = "library-specific"
        model.favoritesOnly = true
        model.navigate(to: "library", libraryID: "library")
        model.navigate(to: "library", libraryID: "library")

        for (page, library) in [("library", "other"), ("recent", "library"), ("home", "library")] {
            XCTAssertTrue(model.canNavigateBack)
            model.navigateBack()
            XCTAssertEqual(model.page, page)
            XCTAssertEqual(model.selectedLibraryID, library)
            if library == "other" {
                XCTAssertEqual(model.query, "library-specific")
                XCTAssertTrue(model.favoritesOnly)
            }
        }
        XCTAssertFalse(model.canNavigateBack)
        model.navigateForward()
        XCTAssertEqual(model.page, "recent")
        model.navigateForward()
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.selectedLibraryID, "other")
        model.page = "servers"
        XCTAssertFalse(model.canNavigateForward)
        model.navigateBack()
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.selectedLibraryID, "other")
        await model.shutdown()
    }

    func testWindowHistoryRestoresNestedDetailAndItsSelectedSeasonAcrossPageNavigation() async throws {
        let second = item("e2", type: "Episode", season: 2)
        installSeries(episodes: [second])
        let (model, _) = makeModel()
        model.navigate(to: "library")
        model.showDetail(try decode(item("show", type: "Series")))
        try await wait { model.seasons.count == 2 }
        model.selectSeason("season-2")
        model.showDetail(try decode(second))
        model.navigate(to: "servers")
        model.navigateBack()
        XCTAssertEqual(model.detail?.id, "e2")
        XCTAssertEqual(model.detailBackTargetID, "show")
        model.goBackFromDetail()
        try await wait { model.detail?.id == "show" && model.selectedSeasonID == "season-2" }
        model.navigateBack()
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.page, "library")
        model.navigateForward()
        try await wait { model.detail?.id == "show" && model.selectedSeasonID == "season-2" }
        model.navigateForward()
        XCTAssertEqual(model.detail?.id, "e2")
        model.navigateForward()
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.page, "servers")
        XCTAssertFalse(model.canNavigateForward)
        await model.shutdown()
    }

    func testBackAndForwardRestoreSameLibraryFiltersAndSortWithoutChangingSavedSort() async throws {
        let (model, connection) = makeModel()
        model.libraries = [.init(id: "library", name: "Movies")]
        model.selectedLibraryID = "library"
        model.navigate(to: "library")
        model.query = "first"; model.filterYear = 1999; model.filterGenre = "Drama"
        model.watchFilter = .unwatched; model.favoritesOnly = true; model.sortOrder = .yearDescending
        model.navigate(to: "home")
        model.navigate(to: "library")
        model.query = "second"; model.filterYear = 2010; model.filterGenre = nil
        model.watchFilter = .watched; model.favoritesOnly = false; model.sortOrder = .nameDescending
        model.switchConnection(connection.id)
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.query, "second")
        let savedSort = model.saved.librarySortPreferences
        XCTAssertEqual(savedSort.first?.sort, .nameDescending)
        model.navigateBack()
        XCTAssertEqual(model.page, "home")
        model.navigateBack()
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.query, "first"); XCTAssertEqual(model.filterYear, 1999)
        XCTAssertEqual(model.filterGenre, "Drama"); XCTAssertEqual(model.watchFilter, .unwatched)
        XCTAssertTrue(model.favoritesOnly); XCTAssertEqual(model.sortOrder, .yearDescending)
        XCTAssertEqual(model.saved.librarySortPreferences, savedSort)
        model.navigateForward()
        model.navigateForward()
        XCTAssertEqual(model.query, "second"); XCTAssertEqual(model.filterYear, 2010)
        XCTAssertNil(model.filterGenre); XCTAssertEqual(model.watchFilter, .watched)
        XCTAssertFalse(model.favoritesOnly); XCTAssertEqual(model.sortOrder, .nameDescending)
        XCTAssertEqual(model.saved.librarySortPreferences, savedSort)
        await model.shutdown()
    }

    func testHistoryCannotReplayDetailOrForwardAcrossLostLibraryAccessOrServerSwitch() async throws {
        let (model, connection) = makeModel()
        BrowseProtocol.handler = { _ in .init(body: ["Items": [], "TotalRecordCount": 0]) }
        model.libraries = [.init(id: "library", name: "甲"), .init(id: "other", name: "乙")]
        model.selectedLibraryID = "library"
        model.navigate(to: "library", libraryID: "other")
        model.showDetail(try decode(item("private-movie")))
        model.navigateBack()
        XCTAssertTrue(model.canNavigateForward)
        model.libraries.removeAll { $0.id == "other" }
        XCTAssertFalse(model.canNavigateForward)
        XCTAssertFalse(model.canNavigateBack)
        model.navigateForward()
        XCTAssertNil(model.detail)

        model.selectedLibraryID = "library"
        model.navigate(to: "servers")
        model.navigateBack()
        XCTAssertTrue(model.canNavigateForward)
        var other = connection
        other.id = UUID()
        other.userID = "other-account"
        model.saved.connections.append(other)
        model.switchConnection(other.id)
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)
        model.switchConnection(connection.id)
        model.navigateForward()
        XCTAssertFalse(model.canNavigateForward)
        XCTAssertEqual(model.page, "home")
        XCTAssertNil(model.detail)
        await model.shutdown()
    }

    func testExplicitPermissionDenialOnReopenedDetailEvictsCachedNavigation() async throws {
        let (model, _) = makeModel()
        let movie = item("private-movie")
        BrowseProtocol.handler = { _ in .init(body: movie) }
        model.showDetail(try decode(movie))
        try await wait { !model.detailLoading }
        model.navigateBack()
        XCTAssertTrue(model.canNavigateForward)
        BrowseProtocol.handler = { _ in .init(status: 403, body: [:]) }
        model.navigateForward()
        try await wait { !model.detailLoading && model.errorMessage != nil }
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.canBrowseCurrentMedia, "A denied individual detail does not revoke an entire catalog")
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)
        await model.shutdown()
    }

    func testNestedBackRestoresSeasonFiltersAndCorrectOriginWithoutRefreshDuplicates() async throws {
        let first = item("e1", type: "Episode"), second = item("e2", type: "Episode", season: 2)
        installSeries(episodes: [first, second]); let (model, _) = makeModel()
        model.page = "library"; model.query = "needle"; model.filterYear = 2025; model.favoritesOnly = true
        let show = try decode(item("show", type: "Series"))
        model.showDetail(show)
        try await wait { model.seasons.count == 2 && !model.seriesLoading }
        model.selectSeason("season-2")
        model.showDetail(show)
        try await wait { model.selectedSeasonID == "season-2" && !model.seriesLoading }
        model.showDetail(try decode(second))
        try await wait { !model.detailLoading }
        XCTAssertEqual(model.detailBackTitle, "返回剧集")
        XCTAssertEqual(model.detailBackTargetID, "show")
        XCTAssertTrue(model.hasDetailHistory(itemID: "show"))
        model.goBackFromDetail()
        try await wait { model.detail?.id == "show" && model.selectedSeasonID == "season-2" && !model.seriesLoading }
        XCTAssertEqual(model.episodes.map(\.id), ["e2"])
        XCTAssertEqual(model.detailBackTitle, "返回媒体库")
        XCTAssertNil(model.detailBackTargetID)
        XCTAssertFalse(model.hasDetailHistory(itemID: "show"))
        model.goBackFromDetail()
        XCTAssertNil(model.detail); XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.query, "needle"); XCTAssertEqual(model.filterYear, 2025); XCTAssertTrue(model.favoritesOnly)
    }

    func testViewAllEpisodesReturnsToExistingSeriesWithoutNavigationLoop() async throws {
        let episodeJSON = item("e1", type: "Episode", season: 2)
        installSeries(episodes: [episodeJSON]); let (model, _) = makeModel()
        model.showDetail(try decode(item("show", type: "Series")))
        try await wait { !model.seriesLoading }
        model.selectSeason("season-2")
        let episode = try decode(episodeJSON)
        model.showDetail(episode)
        model.showSeries(for: episode)
        try await wait { !model.seriesLoading && model.detail?.id == "show" }
        XCTAssertTrue(model.seriesPresentation.showsAll)
        XCTAssertEqual(model.selectedSeasonID, "season-2")
        XCTAssertEqual(model.detailBackTitle, "返回首页")
        model.goBackFromDetail()
        XCTAssertNil(model.detail); XCTAssertEqual(model.page, "home")
    }

    func testFailedSeriesResolutionDoesNotCommitOrReplaceEpisodeReturnSource() async throws {
        let (model, _) = makeModel()
        model.selectedLibraryID = "library"
        let episode = try decode(item("episode", type: "Episode"))
        model.detail = episode
        let presentation = DetailPresentation()
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let source = CGRect(x: 20, y: 20, width: 100, height: 150)
        let original = presentation.prepareOpen(itemID: episode.id, from: nil, sourceID: "home-episode",
            scope: scope, context: "home", sourceFrame: source, bounds: bounds, reduceMotion: false)
        var commits = 0
        BrowseProtocol.handler = { _ in .init(status: 500, body: [:], delay: 0.1) }
        model.showSeries(for: episode) { resolved in
            commits += 1
            presentation.prepareOpen(itemID: resolved.id, from: model.detail?.id, sourceID: "all-episodes",
                scope: scope, context: "home", sourceFrame: source, bounds: bounds, reduceMotion: false)
            model.showDetail(resolved)
        }
        XCTAssertEqual(presentation.generation, original, "A pending lookup has not navigated")
        try await wait { !model.detailLoading }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(model.detail?.id, episode.id)
        XCTAssertEqual(presentation.generation, original)
        presentation.prepareBack(from: episode.id, to: nil, scope: scope, context: "home",
            sourceFrames: ["home-episode": source], bounds: bounds, reduceMotion: false)
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "home-episode",
                       "Failure must preserve the already-committed episode's original entrance")
        await model.shutdown()
    }

    func testBackDuringSeriesResolutionCancelsCommitAndKeepsReturnSource() async throws {
        let (model, _) = makeModel()
        model.selectedLibraryID = "library"
        let episode = try decode(item("episode", type: "Episode"))
        let series = item("show", type: "Series")
        model.detail = episode
        let presentation = DetailPresentation()
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let source = CGRect(x: 20, y: 20, width: 100, height: 150)
        presentation.prepareOpen(itemID: episode.id, from: nil, sourceID: "home-episode",
            scope: scope, context: "home", sourceFrame: source, bounds: bounds, reduceMotion: false)
        let requests = BrowseRequestRecorder()
        BrowseProtocol.handler = { request in
            requests.record(request.url!.path)
            return .init(body: series, delay: 0.2)
        }
        var commits = 0
        model.showSeries(for: episode) { resolved in commits += 1; model.showDetail(resolved) }
        try await wait("Parent lookup must start before returning") { requests.paths.count == 1 }
        let backToken = presentation.prepareBack(from: episode.id, to: model.detailBackTargetID,
            scope: scope, context: "home", sourceFrames: ["home-episode": source],
            bounds: bounds, reduceMotion: false)
        model.goBackFromDetail()
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertEqual(commits, 0, "A resolved parent cannot reopen detail after the user returned")
        XCTAssertNil(model.detail)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(presentation.generation, backToken)
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "home-episode")
        XCTAssertEqual(requests.paths.count, 1, "Cancelled navigation must not start detail or episode loads")
        await model.shutdown()
    }

    func testSeriesResolutionCommitsExactlyOnceAfterValidationAndRetainsEpisodeHistory() async throws {
        let (model, _) = makeModel()
        let episode = try decode(item("episode", type: "Episode"))
        let series = item("show", type: "Series")
        model.detail = episode
        let requests = BrowseRequestRecorder()
        BrowseProtocol.handler = { request in
            let path = request.url!.path
            requests.record(path)
            if path.hasSuffix("/Seasons") || path.hasSuffix("/Episodes") {
                return .init(body: ["Items": [], "TotalRecordCount": 0])
            }
            return .init(body: series, delay: 0.1)
        }
        var commits = 0
        model.showSeries(for: episode) { resolved in
            commits += 1
            XCTAssertEqual(model.detail?.id, episode.id, "The callback prepares the transition before changing detail")
            XCTAssertEqual(resolved.id, "show")
            XCTAssertEqual(resolved.type, "Series")
            model.showDetail(resolved)
        }
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(model.detail?.id, episode.id)
        try await wait { model.detail?.id == "show" && !model.detailLoading && !model.seriesLoading }
        XCTAssertEqual(commits, 1, "Follow-up metadata must not replay the visual commit")
        XCTAssertEqual(model.detailBackTargetID, episode.id)
        XCTAssertEqual(requests.paths.filter { $0.hasSuffix("/show") }.count, 2,
                       "One resolution and one normal detail load are expected")
        await model.shutdown()
    }

    func testShutdownRejectsLateDetailMetadataAndErrors() async throws {
        for status in [200, 500] {
            let requests = BrowseRequestRecorder()
            let original = try decode(item("movie"))
            var response = item("movie")
            response["Name"] = "Late metadata must not be published"
            BrowseProtocol.handler = { request in
                requests.record(request.url!.path)
                return .init(status: status, body: response, delay: 0.2)
            }
            let (model, _) = makeModel()
            model.showDetail(original)
            try await wait("Detail request must start before shutdown") { requests.paths.count == 1 }
            await model.shutdown()
            XCTAssertFalse(model.detailLoading)
            try await Task.sleep(for: .milliseconds(280))
            XCTAssertEqual(model.detail, original, "Shutdown must retain the visible snapshot without publishing late success")
            XCTAssertNil(model.errorMessage, "Shutdown must not publish a late detail error")
            XCTAssertEqual(requests.paths.count, 1)
        }
    }

    func testShutdownRejectsLateShowSeriesResolutionAndFollowUpRequests() async throws {
        for status in [200, 500] {
            let requests = BrowseRequestRecorder()
            let episode = try decode(item("episode", type: "Episode"))
            let series = item("show", type: "Series")
            BrowseProtocol.handler = { request in
                let path = request.url!.path
                requests.record(path)
                if path.hasSuffix("/show") { return .init(status: status, body: series, delay: 0.2) }
                return .init(body: ["Items": [], "TotalRecordCount": 0])
            }
            let (model, _) = makeModel()
            model.detail = episode
            model.showSeries(for: episode)
            try await wait("Series resolution must start before shutdown") { requests.paths.count == 1 }
            await model.shutdown()
            try await Task.sleep(for: .milliseconds(280))
            XCTAssertEqual(model.detail, episode, "A delayed series lookup must not reopen another detail while quitting")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.detailLoading)
            XCTAssertFalse(model.seriesLoading)
            XCTAssertEqual(requests.paths.count, 1, "A late lookup must not start new metadata, seasons or episodes requests")
        }
    }

    func testShutdownRejectsLateSeriesSeasonsEpisodesAndErrors() async throws {
        for episodeStatus in [200, 500] {
            let requests = BrowseRequestRecorder()
            let series = item("show", type: "Series")
            let season = item("season-1", type: "Season")
            let episode = item("episode", type: "Episode")
            BrowseProtocol.handler = { request in
                let path = request.url!.path
                requests.record(path)
                if path.hasSuffix("/Seasons") {
                    return .init(body: ["Items": [season], "TotalRecordCount": 1], delay: 0.2)
                }
                if path.hasSuffix("/Episodes") {
                    return .init(status: episodeStatus, body: ["Items": [episode], "TotalRecordCount": 1], delay: 0.2)
                }
                return .init(body: series)
            }
            let (model, _) = makeModel()
            model.showDetail(try decode(series))
            try await wait("Both series requests must start before shutdown") {
                !model.detailLoading && requests.paths.contains(where: { $0.hasSuffix("/Seasons") })
                    && requests.paths.contains(where: { $0.hasSuffix("/Episodes") })
            }
            XCTAssertTrue(model.seriesLoading)
            let visibleDetail = model.detail
            await model.shutdown()
            try await Task.sleep(for: .milliseconds(280))
            XCTAssertEqual(model.detail, visibleDetail)
            XCTAssertTrue(model.seasons.isEmpty)
            XCTAssertTrue(model.episodes.isEmpty)
            XCTAssertEqual(model.selectedSeasonID, "")
            XCTAssertNil(model.seriesPlaybackCandidate)
            XCTAssertNil(model.seriesError, "A cancelled series request must not publish an error")
            XCTAssertFalse(model.seriesLoading)
        }
    }

    func testShutdownPreventsNewDetailNavigationAndNetworkRequests() async throws {
        let requests = BrowseRequestRecorder()
        BrowseProtocol.handler = { request in
            requests.record(request.url!.path)
            return .init(body: [:])
        }
        let (model, _) = makeModel()
        let visible = try decode(item("visible"))
        model.detail = visible
        await model.shutdown()
        model.showDetail(try decode(item("new")))
        model.showSeries(for: try decode(item("episode", type: "Episode")))
        model.goBackFromDetail()
        await Task.yield()
        XCTAssertEqual(model.detail, visible)
        XCTAssertEqual(model.page, "home")
        XCTAssertFalse(model.detailLoading)
        XCTAssertFalse(model.seriesLoading)
        XCTAssertTrue(requests.paths.isEmpty, "Late UI callbacks must not start work after termination begins")
    }

    func testContinueWatchingAppearsBeforeSlowCatalogCompletes() async throws {
        let (model, _) = makeModel(), movie = item("movie", ticks: 100_000_000)
        BrowseProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": [movie], "TotalRecordCount": 1]) }
            return .init(body: ["Items": [movie], "TotalRecordCount": 1], delay: 0.4)
        }
        model.refresh()
        try await wait { model.continuing.count == 1 }
        XCTAssertTrue(model.catalogLoading); XCTAssertTrue(model.items.isEmpty)
        try await wait { model.catalogComplete && !model.catalogLoading }
    }

    func testHomeContinuingIgnoresLibrarySearchAndFiltersInBothModes() throws {
        let movie = try decode(item("movie", ticks: 100_000_000))
        for compatibility in [false, true] {
            let (model, _) = makeModel(compatibility: compatibility)
            model.items = [movie]; model.continuing = [movie]
            model.query = "no match"; model.filterYear = 1900; model.favoritesOnly = true
            XCTAssertTrue(model.displayedItems.isEmpty)
            XCTAssertEqual(model.displayedContinuing.map(\.id), ["movie"])
        }
    }

    func testSeriesTargetRejectsDuplicateAndUnknownStatesAndDoesNotRestartCompletedSeries() throws {
        let watched = try decode(item("e1", type: "Episode", played: true))
        let next = try decode(item("e2", type: "Episode", episode: 2))
        let sequence = EpisodeSequence(seriesID: "show", episodes: [watched, next])
        XCTAssertEqual(BrowseResumeSelection.target(in: sequence, rawEpisodes: [watched, next])?.id, "e2")
        XCTAssertNil(BrowseResumeSelection.target(in: sequence, rawEpisodes: [watched, next, next]))

        let completed = try decode(item("e2", type: "Episode", episode: 2, played: true))
        let completedEpisodes = [watched, completed]
        XCTAssertNil(BrowseResumeSelection.target(in: EpisodeSequence(seriesID: "show", episodes: completedEpisodes), rawEpisodes: completedEpisodes))

        var unknownJSON = item("unknown", type: "Episode")
        unknownJSON["UserData"] = [:]
        let unknown = try decode(unknownJSON)
        XCTAssertNil(BrowseResumeSelection.target(in: EpisodeSequence(seriesID: "show", episodes: [unknown]), rawEpisodes: [unknown]))

        var missingPositionJSON = item("missing-position", type: "Episode")
        missingPositionJSON["UserData"] = ["Played": false]
        let missingPosition = try decode(missingPositionJSON)
        XCTAssertNil(BrowseResumeSelection.target(in: EpisodeSequence(seriesID: "show", episodes: [missingPosition]), rawEpisodes: [missingPosition]))

        let invalidPosition = try decode(item("negative-position", type: "Episode", ticks: -1))
        XCTAssertNil(BrowseResumeSelection.target(in: EpisodeSequence(seriesID: "show", episodes: [invalidPosition]), rawEpisodes: [invalidPosition]))
    }
}

private final class BrowseRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []
    var paths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedPaths
    }
    func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        recordedPaths.append(path)
    }
}
