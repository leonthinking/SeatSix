import XCTest
import SeatSixCore
@testable import SeatSixApp

final class EpisodeDisplayTests: XCTestCase {
    private func item(_ fields: [String: Any]) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: ["Id": "sample", "Type": "Episode"].merging(fields) { _, new in new }))
    }
    func testEmptyCompatibilitySeasonNameUsesMetadataAndSpecialsStayExplicit() throws {
        XCTAssertEqual(EpisodeDisplay.season(try item(["Name": "", "IndexNumber": 2])), "第 2 季")
        XCTAssertEqual(EpisodeDisplay.season(try item(["Name": "", "IndexNumber": 0])), "特别篇")
        XCTAssertEqual(EpisodeDisplay.season(try item(["Name": "  "])), "未编号季")
    }
    func testUnknownEpisodeNumbersAreNotInferredFromTitle() throws {
        XCTAssertEqual(EpisodeDisplay.number(try item(["Name": "第99集"])), "未编号单集")
        XCTAssertEqual(EpisodeDisplay.number(try item(["ParentIndexNumber": 0, "IndexNumber": 3])), "特别篇 · 第 3 集")
    }
    func testInvalidProgressCannotOverflowTheEpisodeBar() throws {
        XCTAssertEqual(EpisodeDisplay.progress(try item(["UserData": ["PlaybackPositionTicks": 30_000_000]])), 0)
        XCTAssertEqual(EpisodeDisplay.progress(try item(["RunTimeTicks": 10_000_000, "UserData": ["PlaybackPositionTicks": 30_000_000]])), 1)
        XCTAssertEqual(EpisodeDisplay.progress(try item(["RunTimeTicks": 10_000_000, "UserData": ["PlaybackPositionTicks": -1]])), 0)
    }
}
