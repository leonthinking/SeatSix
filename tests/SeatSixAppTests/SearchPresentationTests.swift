import XCTest
import SeatSixCore
@testable import SeatSixApp

final class SearchPresentationTests: XCTestCase {
    func testRecommendationBatchWrapsWithoutDuplicateCardsAndKeepsEveryMatchingResult() throws {
        let items = try (0..<30).map { try item("Movie", "Title \($0)") }
        let first = SearchPresentation.results(items, query: " ", offset: 0)
        let second = SearchPresentation.results(items, query: "", offset: 24)
        XCTAssertEqual(first.count, 24)
        XCTAssertEqual(second.prefix(6).map(\.id), items.suffix(6).map(\.id))
        XCTAssertEqual(Set(second.map(\.id)).count, 24)
        XCTAssertEqual(SearchPresentation.results(items, query: "title", offset: 24).map(\.id), items.map(\.id))
        XCTAssertTrue(SearchPresentation.results([], query: "", offset: 44).isEmpty)
    }

    func testSearchGroupsIncludeOnlyMatchedTypesAndTreatSpecialCharactersAsText() throws {
        let items = try [item("Series", "星[图]"), item("Movie", "星[图] Movie"), item("Video", "其他")]
        let results = SearchPresentation.results(items, query: " [图] ", offset: 100)
        XCTAssertEqual(SearchPresentation.groups(results).map(\.title), ["电影", "电视剧"])
        XCTAssertEqual(SearchPresentation.groups(results).flatMap(\.items).map(\.type), ["Movie", "Series"])
    }

    func testOptionalServerScoreUsesValidObservedValueAndToleratesMalformedMetadata() throws {
        for (raw, expected) in [("8.7", Optional(8.7)), ("11", nil), ("-1", nil), ("null", nil), (#""bad""#, nil)] {
            let data = Data(#"{"Id":"1","Name":"Fixture","CommunityRating":"#.appending(raw).appending("}").utf8)
            XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: data).communityRating, expected)
        }
    }

    private func item(_ type: String, _ name: String) throws -> MediaItem {
        let object = ["Type": type, "Name": name, "Id": type + name]
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
