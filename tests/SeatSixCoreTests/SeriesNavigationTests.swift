import XCTest
@testable import SeatSixCore

final class SeriesNavigationTests: XCTestCase {
    private var session: URLSession!
    private var recorder: SeriesRequestRecorder!

    override func setUp() {
        super.setUp()
        recorder = SeriesRequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() { session.invalidateAndCancel(); SeriesURLProtocol.handler = nil; super.tearDown() }

    func testBothServerKindsEnumerateAllEpisodePagesWithAuthenticatedUserAndBasePath() async throws {
        for kind in ServerKind.allCases {
            let requests = SeriesRequestRecorder()
            SeriesURLProtocol.handler = { request in
                requests.append(request)
                let offset = Int(request.seriesQuery["StartIndex"] ?? "-1")!
                return ["Items": [Self.episodeJSON("episode-\(offset)", season: 1, index: offset + 1)], "StartIndex": offset, "TotalRecordCount": 3]
            }
            let items = try await client(kind).episodes(seriesID: "series-1", seasonID: "season-1")
            XCTAssertEqual(items.map(\.id), ["episode-0", "episode-1", "episode-2"])
            XCTAssertEqual(requests.values.map { $0.seriesQuery["StartIndex"] }, ["0", "1", "2"])
            for request in requests.values {
                XCTAssertEqual(request.url?.path, "/base/Shows/series-1/Episodes")
                XCTAssertEqual(request.seriesQuery["Limit"], "100")
                XCTAssertEqual(request.seriesQuery["UserId"], "user-1")
                XCTAssertEqual(request.seriesQuery["SeasonId"], "season-1")
                XCTAssertEqual(request.seriesQuery["EnableUserData"], "true")
                XCTAssertEqual(request.seriesQuery["IsMissing"], "false")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
            }
        }
    }

    func testJellyfinSeasonsAreUnpagedAndEmbySeasonsUsePagination() async throws {
        for kind in ServerKind.allCases {
            let requests = SeriesRequestRecorder()
            SeriesURLProtocol.handler = { request in
                requests.append(request)
                return ["Items": [Self.seasonJSON("season-1", index: 1)], "TotalRecordCount": 1, "StartIndex": 0]
            }
            let items = try await client(kind).seasons(seriesID: "series-1")
            XCTAssertEqual(items.map(\.id), ["season-1"])
            XCTAssertEqual(requests.values.first?.url?.path, "/base/Shows/series-1/Seasons")
            XCTAssertEqual(requests.values.first?.seriesQuery["StartIndex"], kind == .emby ? "0" : nil)
        }
    }

    func testCompatibilityChildrenUseSingleUnpagedRequestAndActualSeasonID() async throws {
        let recorder = self.recorder!
        SeriesURLProtocol.handler = { request in
            recorder.append(request)
            let item = request.url!.lastPathComponent == "Seasons" ? Self.seasonJSON("actual-season", index: 1) : Self.episodeJSON("actual-episode", season: 1, index: 1, seasonID: "actual-season")
            return ["Items": [item], "TotalRecordCount": 1, "StartIndex": 0]
        }
        let api = client(.emby, compatibility: true)
        let seasons = try await api.seasons(seriesID: "series-1")
        let episodes = try await api.episodes(seriesID: "series-1", seasonID: "actual-season")
        XCTAssertEqual(seasons.count, 1)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(recorder.values.count, 2)
        for request in recorder.values {
            XCTAssertNil(request.seriesQuery["StartIndex"])
            XCTAssertNil(request.seriesQuery["Limit"])
            XCTAssertNil(request.seriesQuery["SortBy"])
            XCTAssertNil(request.seriesQuery["IsMissing"])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(recorder.values[1].seriesQuery["SeasonId"], "actual-season")
    }

    func testTopLevelLibrariesReturnSeriesInsteadOfFlatteningEpisodes() async throws {
        let recorder = self.recorder!
        SeriesURLProtocol.handler = { recorder.append($0); return ["Items": []] }
        _ = try await client(.jellyfin).items(libraryID: "library-1")
        _ = try await client(.emby, compatibility: true).items(libraryID: "library-1")
        XCTAssertEqual(recorder.values[0].seriesQuery["IncludeItemTypes"], "Movie,Series,Video")
        XCTAssertEqual(recorder.values[1].seriesQuery["IncludeItemTypes"], "Movie,Series")
    }

    func testMissingTotalContinuesUntilEmptyPageInsteadOfTreatingFirstPageAsComplete() async throws {
        let recorder = self.recorder!
        SeriesURLProtocol.handler = { request in
            recorder.append(request)
            if request.seriesQuery["StartIndex"] == "0" { return ["Items": [Self.episodeJSON("one", season: 1, index: 1)]] }
            return ["Items": []]
        }
        let items = try await client(.jellyfin).episodes(seriesID: "series-1")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(recorder.values.count, 2)
    }

    func testRepeatedPagesFailClosedInsteadOfOfferingWrongSuccessor() async throws {
        SeriesURLProtocol.handler = { request in ["Items": [Self.episodeJSON("one", season: 1, index: 1)], "StartIndex": Int(request.seriesQuery["StartIndex"]!)!, "TotalRecordCount": 3] }
        await assertInvalid { try await self.client(.jellyfin).episodes(seriesID: "series-1") }
    }

    func testEarlyEmptyAndChangingTotalAndOversizedTotalFailClosed() async throws {
        for failure in ["empty", "changed", "oversized", "offset"] {
            SeriesURLProtocol.handler = { request in
                let offset = Int(request.seriesQuery["StartIndex"]!)!
                return ["Items": offset == 0 || failure != "empty" ? [Self.episodeJSON("episode-\(offset)", season: 1, index: offset + 1)] : [],
                        "StartIndex": failure == "offset" ? 5 : offset,
                        "TotalRecordCount": failure == "oversized" ? 10_001 : (failure == "changed" && offset > 0 ? 2 : 3)]
            }
            await assertInvalid { try await self.client(.emby).episodes(seriesID: "series-1") }
        }
    }

    func testUnpagedTruncationFailsForCompatibilityAndJellyfinSeasons() async throws {
        SeriesURLProtocol.handler = { _ in ["Items": [], "TotalRecordCount": 2] }
        await assertInvalid { try await self.client(.emby, compatibility: true).episodes(seriesID: "series-1") }
        await assertInvalid { try await self.client(.jellyfin).seasons(seriesID: "series-1") }
    }

    func testWrongSeriesOrSeasonCannotEnterQueue() async throws {
        for mismatch in ["SeriesId", "SeasonId", "ParentId"] {
            SeriesURLProtocol.handler = { _ in
                var item = Self.episodeJSON("one", season: 1, index: 1)
                item[mismatch] = "another-parent"
                return ["Items": [item], "TotalRecordCount": 1]
            }
            await assertInvalid { try await self.client(.jellyfin).episodes(seriesID: "series-1", seasonID: "season-1") }
        }
    }

    func testNullableMetadataKeepsEpisodesPlayableAndSeriesUnplayable() throws {
        let item = try decode(["Id": "episode", "Type": "Episode", "SeriesId": NSNull(), "SeasonId": NSNull(), "ParentId": NSNull(), "ParentIndexNumber": NSNull(), "IndexNumber": NSNull()])
        XCTAssertTrue(item.isPlayable)
        XCTAssertNil(item.seriesID); XCTAssertNil(item.seasonID); XCTAssertNil(item.parentID)
        XCTAssertNil(item.indexNumberEnd)
        XCTAssertFalse(try decode(["Id": "series", "Type": "Series"]).isPlayable)
    }

    func testSequenceUsesActualIDsNumericalOrderingAndCrossesRegularSeasons() throws {
        let episodes = try [Self.episodeJSON("third", season: 2, index: 1, seasonID: "season-2"), Self.episodeJSON("second", season: 1, index: 9), Self.episodeJSON("first", season: 1, index: 2)].map(decode)
        let queue = EpisodeSequence(seriesID: "series-1", episodes: episodes)
        XCTAssertEqual(queue.orderedEpisodes.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(queue.next(after: "first")?.id, "second")
        XCTAssertEqual(queue.next(after: "second")?.id, "third")
        XCTAssertNil(queue.next(after: "third"))
        XCTAssertNil(queue.next(after: "not-an-id"))
    }

    func testPreviousUsesActualIDsAndNumericalOrderingAcrossRegularSeasons() throws {
        let items = try [Self.episodeJSON("third", season: 2, index: 1, seasonID: "season-2"), Self.episodeJSON("first", season: 1, index: 2), Self.episodeJSON("second", season: 1, index: 9)].map(decode)
        let queue = EpisodeSequence(seriesID: "series-1", episodes: items)
        XCTAssertEqual(queue.previous(before: "third")?.id, "second")
        XCTAssertEqual(queue.previous(before: "second")?.id, "first")
        XCTAssertNil(queue.previous(before: "first"))
        XCTAssertNil(queue.previous(before: "not-an-id"))
        XCTAssertNil(EpisodeSequence(seriesID: "series-1", episodes: []).previous(before: "first"))
    }

    func testSeasonMetadataSuppliesMissingIndexAndGroupsNumberOnlyEpisode() throws {
        let season = try decode(Self.seasonJSON("actual-season", index: 3))
        var first = Self.episodeJSON("first", season: 3, index: 1, seasonID: "actual-season")
        first.removeValue(forKey: "ParentIndexNumber")
        var second = Self.episodeJSON("second", season: 3, index: 2)
        second.removeValue(forKey: "SeasonId"); second.removeValue(forKey: "ParentId")
        let queue = EpisodeSequence(seriesID: "series-1", episodes: try [second, first].map(decode), seasons: [season])
        XCTAssertEqual(queue.episodes(in: "actual-season").map(\.id), ["first", "second"])
        XCTAssertEqual(queue.next(after: "first")?.id, "second")
        XCTAssertEqual(queue.previous(before: "second")?.id, "first")
        XCTAssertTrue(queue.episodes(in: "unknown").isEmpty)
    }

    func testSpecialsAreBrowsableButDoNotAutomaticallyCrossIntoRegularSeason() throws {
        let items = try [Self.episodeJSON("special-1", season: 0, index: 1, seasonID: "specials"), Self.episodeJSON("special-2", season: 0, index: 2, seasonID: "specials"), Self.episodeJSON("regular", season: 1, index: 1)].map(decode)
        let queue = EpisodeSequence(seriesID: "series-1", episodes: items)
        XCTAssertEqual(queue.next(after: "special-1")?.id, "special-2")
        XCTAssertNil(queue.next(after: "special-2"))
        XCTAssertEqual(queue.resumeCandidate?.id, "regular")
        XCTAssertEqual(queue.episodes(in: "specials").count, 2)
    }

    func testPreviousStaysWithinSpecialsAndDoesNotCrossFromRegularSeason() throws {
        let items = try [Self.episodeJSON("special-1", season: 0, index: 1, seasonID: "specials"), Self.episodeJSON("special-2", season: 0, index: 2, seasonID: "specials"), Self.episodeJSON("regular", season: 1, index: 1)].map(decode)
        let queue = EpisodeSequence(seriesID: "series-1", episodes: items)
        XCTAssertEqual(queue.previous(before: "special-2")?.id, "special-1")
        XCTAssertNil(queue.previous(before: "special-1"))
        XCTAssertNil(queue.previous(before: "regular"))
    }

    func testDuplicateCoordinatesAndOverlappingCombinedEpisodesAreNotAutoSelected() throws {
        for combined in [false, true] {
            var first = Self.episodeJSON("version-a", season: 1, index: 1)
            if combined { first["IndexNumberEnd"] = 2 }
            let second = Self.episodeJSON("version-b", season: 1, index: combined ? 2 : 1)
            let queue = EpisodeSequence(seriesID: "series-1", episodes: try [first, second, Self.episodeJSON("third", season: 1, index: 3)].map(decode))
            XCTAssertNil(queue.next(after: "version-a"))
            XCTAssertNil(queue.next(after: "version-b"))
            XCTAssertEqual(queue.orderedEpisodes.count, 3)
        }
    }

    func testUnknownConflictingOrDuplicateIDMetadataDisablesUnsafeAutomaticNavigation() throws {
        let first = Self.episodeJSON("first", season: 1, index: 1)
        for problem in ["missing-index", "conflicting-season", "negative-season", "duplicate-id"] {
            var second = Self.episodeJSON(problem == "duplicate-id" ? "first" : "second", season: 1, index: 2)
            if problem == "missing-index" { second.removeValue(forKey: "IndexNumber") }
            if problem == "conflicting-season" { second["ParentIndexNumber"] = 2 }
            if problem == "negative-season" { second["ParentIndexNumber"] = -1 }
            let queue = EpisodeSequence(seriesID: "series-1", episodes: try [first, second].map(decode), seasons: [try decode(Self.seasonJSON("season-1", index: 1))])
            XCTAssertNil(queue.next(after: "first"))
        }
    }

    func testPreviousRejectsDuplicateCoordinatesAndOverlappingCombinedEpisodes() throws {
        for combined in [false, true] {
            var first = Self.episodeJSON("version-a", season: 1, index: 1)
            if combined { first["IndexNumberEnd"] = 2 }
            let second = Self.episodeJSON("version-b", season: 1, index: combined ? 2 : 1)
            let queue = EpisodeSequence(seriesID: "series-1", episodes: try [first, second, Self.episodeJSON("third", season: 1, index: 3)].map(decode))
            XCTAssertNil(queue.previous(before: "third"))
            XCTAssertNil(queue.previous(before: "version-b"))
            XCTAssertEqual(queue.orderedEpisodes.count, 3)
        }
    }

    func testPreviousFailsClosedForIncompleteConflictingOrDuplicateMetadata() throws {
        let first = Self.episodeJSON("first", season: 1, index: 1)
        for problem in ["missing-index", "missing-season", "conflicting-season", "conflicting-parent", "negative-season", "duplicate-id"] {
            var second = Self.episodeJSON(problem == "duplicate-id" ? "first" : "second", season: 1, index: 2)
            if problem == "missing-index" { second.removeValue(forKey: "IndexNumber") }
            if problem == "missing-season" {
                second.removeValue(forKey: "ParentIndexNumber")
                second.removeValue(forKey: "SeasonId")
                second.removeValue(forKey: "ParentId")
            }
            if problem == "conflicting-season" { second["ParentIndexNumber"] = 2 }
            if problem == "conflicting-parent" { second["ParentId"] = "other-season" }
            if problem == "negative-season" { second["ParentIndexNumber"] = -1 }
            let queue = EpisodeSequence(seriesID: "series-1", episodes: try [first, second, Self.episodeJSON("third", season: 1, index: 3)].map(decode), seasons: [try decode(Self.seasonJSON("season-1", index: 1))])
            XCTAssertNil(queue.previous(before: "third"), problem)
            XCTAssertNil(queue.previous(before: "second"), problem)
        }
    }

    func testDisplaySeasonsAreUniqueSortedAndScopedWithoutHidingGroupingAmbiguity() throws {
        let one = Self.seasonJSON("season-1", index: 1)
        let ten = Self.seasonJSON("season-10", index: 10)
        var unknown = Self.seasonJSON("unknown", index: 1)
        unknown.removeValue(forKey: "IndexNumber")
        var foreign = Self.seasonJSON("foreign", index: 2)
        foreign["SeriesId"] = "other-series"
        var wrongParent = Self.seasonJSON("wrong-parent", index: 3)
        wrongParent["ParentId"] = "other-series"
        var wrongType = Self.seasonJSON("not-a-season", index: 4)
        wrongType["Type"] = "Episode"
        var numberOnly = Self.episodeJSON("number-only", season: 1, index: 1)
        numberOnly.removeValue(forKey: "SeasonId"); numberOnly.removeValue(forKey: "ParentId")
        let queue = EpisodeSequence(seriesID: "series-1", episodes: try [numberOnly, Self.episodeJSON("explicit", season: 1, index: 2)].map(decode), seasons: try [ten, unknown, one, ten, Self.seasonJSON("specials", index: 0), Self.seasonJSON("negative", index: -1), one, foreign, wrongParent, wrongType].map(decode))
        XCTAssertEqual(queue.displaySeasons.map(\.id), ["specials", "season-1", "season-10", "unknown", "negative"])
        XCTAssertEqual(queue.episodes(in: "season-1").map(\.id), ["explicit"])
        XCTAssertEqual(queue.orderedEpisodes.count, 2)
    }

    func testDisplaySeasonDeduplicationPreservesConflictingCoordinateChecks() throws {
        let items = try [Self.episodeJSON("first", season: 1, index: 1), Self.episodeJSON("second", season: 3, index: 1, seasonID: "season-3")].map(decode)
        let seasons = try [Self.seasonJSON("season-1", index: 1), Self.seasonJSON("season-1", index: 2), Self.seasonJSON("season-3", index: 3)].map(decode)
        let queue = EpisodeSequence(seriesID: "series-1", episodes: items, seasons: seasons)
        XCTAssertEqual(queue.displaySeasons.map(\.id), ["season-1", "season-3"])
        XCTAssertNil(queue.next(after: "first"))
        XCTAssertNil(queue.previous(before: "second"))
        XCTAssertEqual(queue.orderedEpisodes.count, 2)
    }

    func testMissingEpisodeNumberStaysInKnownSeasonAndAmbiguousSeasonNumberIsNotGrouped() throws {
        var unknown = Self.episodeJSON("unknown-index", season: 1, index: 1)
        unknown.removeValue(forKey: "IndexNumber")
        let queue = EpisodeSequence(seriesID: "series-1", episodes: try [Self.episodeJSON("season-two", season: 2, index: 1, seasonID: "season-2"), unknown].map(decode))
        XCTAssertEqual(queue.orderedEpisodes.map(\.id), ["unknown-index", "season-two"])
        XCTAssertNil(queue.next(after: "unknown-index"))
        var numberOnly = Self.episodeJSON("number-only", season: 1, index: 1)
        numberOnly.removeValue(forKey: "SeasonId"); numberOnly.removeValue(forKey: "ParentId")
        let ambiguous = EpisodeSequence(seriesID: "series-1", episodes: [try decode(numberOnly)], seasons: try [Self.seasonJSON("season-a", index: 1), Self.seasonJSON("season-b", index: 1)].map(decode))
        XCTAssertTrue(ambiguous.episodes(in: "season-a").isEmpty)
        XCTAssertTrue(ambiguous.episodes(in: "season-b").isEmpty)
    }

    func testResumeUsesEachEpisodesUserDataAndNeverParentSeriesProgress() throws {
        var watched = Self.episodeJSON("watched", season: 1, index: 1)
        watched["UserData"] = ["Played": true, "PlaybackPositionTicks": 80_000_000]
        let unplayed = Self.episodeJSON("unplayed", season: 1, index: 2)
        var partial = Self.episodeJSON("partial", season: 1, index: 3)
        partial["UserData"] = ["Played": false, "PlaybackPositionTicks": 123_000_000]
        var foreign = Self.episodeJSON("foreign", season: 1, index: 0)
        foreign["SeriesId"] = "other-series"
        let queue = EpisodeSequence(seriesID: "series-1", episodes: try [watched, unplayed, partial, foreign].map(decode))
        XCTAssertEqual(queue.resumeCandidate?.id, "partial")
        XCTAssertEqual(queue.resumeCandidate?.userData.playbackPositionTicks, 123_000_000)
        XCTAssertEqual(queue.orderedEpisodes.count, 3)
        XCTAssertEqual(EpisodeSequence(seriesID: "series-1", episodes: try [watched, unplayed].map(decode)).resumeCandidate?.id, "unplayed")
    }

    private func client(_ kind: ServerKind, compatibility: Bool = false) -> MediaServerClient {
        let connection = ServerConnection(kind: kind, name: "fixture", baseURL: URL(string: "https://media.example:9443/base")!, serverID: "server-1", userID: "user-1", username: "fixture", libraryIDs: ["library-1"], compatibilityMode: compatibility)
        return MediaServerClient(connection: connection, token: "fixture-token", deviceID: "test", session: session)
    }
    private func decode(_ json: [String: Any]) throws -> MediaItem { try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json)) }
    private static func episodeJSON(_ id: String, season: Int, index: Int, seasonID: String = "season-1") -> [String: Any] {
        ["Id": id, "Name": "episode", "Type": "Episode", "SeriesId": "series-1", "SeasonId": seasonID, "ParentId": seasonID, "ParentIndexNumber": season, "IndexNumber": index]
    }
    private static func seasonJSON(_ id: String, index: Int) -> [String: Any] { ["Id": id, "Name": "", "Type": "Season", "ParentId": "series-1", "IndexNumber": index] }
    private func assertInvalid(_ operation: () async throws -> [MediaItem], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Unsafe partial or mismatched series accepted", file: file, line: line) }
        catch { XCTAssertEqual(error as? MediaServerError, .invalidResponse, file: file, line: line) }
    }
}

private final class SeriesRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}
private final class SeriesURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.handler!(request))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    var seriesQuery: [String: String] { Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }) }
}
