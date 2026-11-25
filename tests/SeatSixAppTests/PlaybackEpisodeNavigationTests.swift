import XCTest
import SeatSixCore
@testable import SeatSixApp

final class PlaybackEpisodeNavigationTests: XCTestCase {
    func testOpeningPickerSelectsCurrentSeasonUsingResolvedMembership() throws {
        let special = try item(#"{"Id":"special","Type":"Season","Name":"Specials","IndexNumber":0,"SeriesId":"series"}"#)
        let season = try item(#"{"Id":"season-one","Type":"Season","Name":"Season 1","IndexNumber":1,"SeriesId":"series"}"#)
        let specialEpisode = try item(#"{"Id":"special-ep","Type":"Episode","Name":"Special","ParentIndexNumber":0,"IndexNumber":1,"SeriesId":"series"}"#)
        let regular = try item(#"{"Id":"regular-ep","Type":"Episode","Name":"Regular","SeasonId":"season-one","IndexNumber":1,"SeriesId":"series"}"#)
        let sequence = EpisodeSequence(seriesID: "series", episodes: [regular, specialEpisode], seasons: [season, special])
        XCTAssertEqual(EpisodeNavigationPresentation.seasonID(for: specialEpisode.id, in: sequence), special.id)
        XCTAssertEqual(EpisodeNavigationPresentation.seasonID(for: regular.id, in: sequence), season.id)
        XCTAssertEqual(EpisodeNavigationPresentation.episodes(in: sequence, selectedSeasonID: season.id).map(\.id), [regular.id])
    }

    func testUnknownSeasonAndUnknownCurrentEpisodeFallBackToCompleteList() throws {
        let first = try item(#"{"Id":"ep1","Type":"Episode","Name":"Episode 1","ParentIndexNumber":1,"IndexNumber":1,"SeriesId":"series"}"#)
        let second = try item(#"{"Id":"ep2","Type":"Episode","Name":"Episode 2","ParentIndexNumber":1,"IndexNumber":2,"SeriesId":"series"}"#)
        let sequence = EpisodeSequence(seriesID: "series", episodes: [second, first])
        XCTAssertEqual(EpisodeNavigationPresentation.seasonID(for: "not-in-sequence", in: sequence), "")
        XCTAssertEqual(EpisodeNavigationPresentation.episodes(in: sequence, selectedSeasonID: "stale-season").map(\.id), [first.id, second.id])
        XCTAssertEqual(EpisodeNavigationPresentation.episodes(in: sequence, selectedSeasonID: "").map(\.id), [first.id, second.id])
    }

    func testEmptyKnownSeasonRemainsEmptyInsteadOfShowingAnotherSeason() throws {
        let empty = try item(#"{"Id":"season-empty","Type":"Season","Name":"Empty","IndexNumber":2,"SeriesId":"series"}"#)
        let episode = try item(#"{"Id":"ep1","Type":"Episode","Name":"Episode 1","ParentIndexNumber":1,"IndexNumber":1,"SeriesId":"series"}"#)
        let sequence = EpisodeSequence(seriesID: "series", episodes: [episode], seasons: [empty])
        XCTAssertTrue(EpisodeNavigationPresentation.episodes(in: sequence, selectedSeasonID: empty.id).isEmpty)
        XCTAssertEqual(EpisodeNavigationPresentation.seasonID(for: episode.id, in: sequence), "")
    }

    func testRecoveryTimeClampsInvalidNegativeTicksAndTruncatesSubseconds() {
        XCTAssertEqual(EpisodeNavigationPresentation.recoveryTime(ticks: -1), "00:00")
        XCTAssertEqual(EpisodeNavigationPresentation.recoveryTime(ticks: 0), "00:00")
        XCTAssertEqual(EpisodeNavigationPresentation.recoveryTime(ticks: 101_999_999), "00:10")
        XCTAssertEqual(EpisodeNavigationPresentation.recoveryTime(ticks: 36_619_999_999), "1:01:01")
        XCTAssertEqual(EpisodeNavigationPresentation.recoveryTime(ticks: .max), "256204778:48:05")
    }

    private func item(_ json: String) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8))
    }
}
