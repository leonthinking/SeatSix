import XCTest
import SeatSixCore
@testable import SeatSixProbe

@MainActor
final class SeriesPlaybackProbeTests: XCTestCase {
    private func item(_ fields: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    private func episode(_ id: String, _ number: Int, series: String = "series") throws -> MediaItem {
        try item(["Id": id, "Type": "Episode", "SeriesId": series, "SeasonId": "season", "ParentIndexNumber": 1, "IndexNumber": number])
    }
    func testProbeUsesReturnedEpisodeIdentityAndOrderedPair() throws {
        let series = try item(["Id": "series", "Type": "Series"])
        let pair = try SeriesPlaybackProbe.selectedPair(series: series, seasons: [], episodes: [episode("actual-second", 2), episode("actual-first", 1)])
        XCTAssertEqual(pair.map(\.id), ["actual-first", "actual-second"])
    }
    func testProbeRefusesAmbiguousPairOrParentPlayback() throws {
        let series = try item(["Id": "series", "Type": "Series"])
        XCTAssertThrowsError(try SeriesPlaybackProbe.selectedPair(series: series, seasons: [], episodes: [episode("one", 1), episode("alternate", 1)]))
        XCTAssertThrowsError(try SeriesPlaybackProbe.selectedPair(series: series, seasons: [], episodes: [episode("one", 1), episode("other", 2, series: "foreign")]))
        XCTAssertThrowsError(try SeriesPlaybackProbe.selectedPair(series: episode("one", 1), seasons: [], episodes: [episode("one", 1), episode("two", 2)]))
    }
    func testProbeAcceptsSeasonMetadataWhenEpisodeOmitsParentIndex() throws {
        let series = try item(["Id": "series", "Type": "Series"])
        let season = try item(["Id": "season", "Type": "Season", "IndexNumber": 1, "ParentId": "series"])
        let episodes = try [1, 2].map { try item(["Id": "actual-\($0)", "Type": "Episode", "SeasonId": "season", "IndexNumber": $0]) }
        let pair = try SeriesPlaybackProbe.selectedPair(series: series, seasons: [season], episodes: episodes)
        XCTAssertEqual(pair.map(\.id), ["actual-1", "actual-2"])
    }
}
