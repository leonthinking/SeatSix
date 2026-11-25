import XCTest
import SeatSixCore
@testable import SeatSixApp

final class BrowsePresentationTests: XCTestCase {
    private func item(type: String = "Movie", played: Bool = false, ticks: Int64 = 0) throws -> MediaItem {
        let json: [String: Any] = ["Id": "item", "Name": "Fixture", "Type": type,
            "ParentIndexNumber": 2, "IndexNumber": 4, "RunTimeTicks": 18_000_000_000,
            "UserData": ["Played": played, "PlaybackPositionTicks": ticks]]
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testWatchedItemWithResidualProgressIsOfferedAsRewatch() throws {
        let media = try item(played: true, ticks: 600_000_000)
        XCTAssertEqual(BrowsePresentation.playbackTitle(media), "重新观看")
        XCTAssertFalse(BrowsePresentation.playbackTitle(media).contains("继续"))
    }

    func testEpisodePrimaryActionIdentifiesTheActualEpisodeAndPosition() throws {
        let media = try item(type: "Episode", ticks: 600_000_000)
        let title = BrowsePresentation.playbackTitle(media)
        XCTAssertTrue(title.contains("第 2 季")); XCTAssertTrue(title.contains("第 4 集"))
        XCTAssertTrue(title.contains("01:00")); XCTAssertTrue(title.contains("继续"))
    }

    func testSeriesSummaryDoesNotPresentParentTicksAsAnEpisodeClock() throws {
        XCTAssertEqual(BrowsePresentation.continueSubtitle(try item(type: "Series", ticks: 600_000_000)), "确认分集后继续观看")
        XCTAssertTrue(BrowsePresentation.continueSubtitle(try item(ticks: 600_000_000)).contains("剩余 29:00"))
    }

    func testCollapsedFiltersDiscloseEveryActiveConstraintAndSort() {
        let summary = BrowsePresentation.filterSummary(query: " space ", year: 2024, genre: "剧情",
            watched: .unwatched, favoritesOnly: true, sort: .yearDescending)
        for value in ["搜索：space", "2024", "剧情", "未看", "只看收藏", "年份从新到旧"] {
            XCTAssertTrue(summary.contains(value), "A collapsed panel must not hide \(value)")
        }
    }

    func testSingleVersionSummaryDoesNotCountAsExplicitMultiVersionChoice() {
        var selection = PlaybackVersionSelection()
        selection.update(sourceIDs: ["A"])
        XCTAssertEqual(selection.id, "A")
        selection.update(sourceIDs: ["A", "B"])
        XCTAssertEqual(selection.id, "")
        XCTAssertTrue(selection.requiresChoice)
        selection.select("B")
        selection.update(sourceIDs: ["A", "B"])
        XCTAssertEqual(selection.id, "B")
        XCTAssertFalse(selection.requiresChoice)
    }

    func testVanishedExplicitVersionCannotSilentlySwitchToRemainingCut() {
        var selection = PlaybackVersionSelection()
        selection.select("B")
        selection.update(sourceIDs: ["A"])
        selection.update(sourceIDs: ["A"])
        XCTAssertEqual(selection.id, "")
        XCTAssertTrue(selection.requiresChoice)
        selection.select("A")
        selection.update(sourceIDs: ["A"])
        XCTAssertFalse(selection.requiresChoice)
    }
}
