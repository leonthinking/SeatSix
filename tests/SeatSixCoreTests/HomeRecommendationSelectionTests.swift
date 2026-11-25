import Foundation
import XCTest
@testable import SeatSixCore

final class HomeRecommendationSelectionTests: XCTestCase {
    func testRecommendationsRequireLandscapeArtworkAndExcludeEpisodesAndFolders() throws {
        let input = try [
            item("movie", type: "Movie", artwork: ["BackdropImageTags": ["wide"]]),
            item("series", type: "Series", artwork: ["ImageTags": ["Thumb": "wide"]]),
            item("video", type: "Video", artwork: ["ImageTags": ["Primary": "wide"], "PrimaryImageAspectRatio": 1.78]),
            item("portrait", artwork: ["ImageTags": ["Primary": "portrait"], "PrimaryImageAspectRatio": 0.67]),
            item("unknown-ratio", artwork: ["ImageTags": ["Primary": "unknown"]]),
            item("no-art"),
            item("episode", type: "Episode", artwork: ["BackdropImageTags": ["wide"]]),
            item("season", type: "Season", artwork: ["BackdropImageTags": ["wide"]]),
            item("folder", type: "Folder", artwork: ["BackdropImageTags": ["wide"]])
        ]
        XCTAssertEqual(Set(HomeRecommendationSelection.select(from: input).map(\.id)), ["movie", "series", "video"])
    }

    func testRecommendationLimitDeduplicationAndSmallLibraries() throws {
        let items = try (0..<14).map { try item("movie-\($0)", artwork: ["BackdropImageTags": ["wide-\($0)"]]) }
        let selection = HomeRecommendationSelection.select(from: items + items)
        XCTAssertEqual(selection.count, 10)
        XCTAssertEqual(Set(selection.map(\.id)).count, 10)
        XCTAssertEqual(HomeRecommendationSelection.select(from: items, limit: 100).count, 10)
        XCTAssertEqual(HomeRecommendationSelection.select(from: items, limit: 8).count, 8)
        XCTAssertEqual(Set(HomeRecommendationSelection.select(from: Array(items.prefix(3))).map(\.id)), Set(items.prefix(3).map(\.id)))
        XCTAssertTrue(HomeRecommendationSelection.select(from: []).isEmpty)
        XCTAssertTrue(HomeRecommendationSelection.select(from: items, limit: 0).isEmpty)
        XCTAssertTrue(HomeRecommendationSelection.select(from: items, limit: -10).isEmpty)
        let missingArt = try item("same")
        let withArt = try item("same", artwork: ["BackdropImageTags": ["wide"]])
        XCTAssertEqual(HomeRecommendationSelection.select(from: [missingArt, withArt]).map(\.id), ["same"])
    }

    func testSeededSelectionIsReproducibleAndDoesNotMutateCatalogOrder() throws {
        let items = try (0..<30).map { try item("movie-\($0)", artwork: ["BackdropImageTags": ["wide-\($0)"]]) }
        let original = items.map(\.id)
        var first = SeededGenerator(seed: 42), second = SeededGenerator(seed: 42)
        let selection = HomeRecommendationSelection.select(from: items, using: &first)
        XCTAssertEqual(selection.map(\.id), HomeRecommendationSelection.select(from: items, using: &second).map(\.id))
        XCTAssertEqual(items.map(\.id), original)
        XCTAssertTrue(Set(selection.map(\.id)).isSubset(of: Set(original)))
    }

    func testRetainedRecommendationsUseLatestEligibleItemsAndFillVacancies() throws {
        var kept = try item("kept", artwork: ["BackdropImageTags": ["new-image"]])
        kept.name = "Updated title"
        let current = try [item("lost-art"), item("wrong-type", type: "Episode", artwork: ["BackdropImageTags": ["wide"]])]
            + [kept] + (0..<20).map { try item("new-\($0)", artwork: ["BackdropImageTags": ["wide"]]) }
        let previous = ["deleted", "kept", "kept", "lost-art", "wrong-type", "new-19"]
        let selection = HomeRecommendationSelection.select(from: current, retainingIDs: previous)
        XCTAssertEqual(selection.count, 10)
        XCTAssertEqual(Array(selection.prefix(2).map(\.id)), ["kept", "new-19"])
        XCTAssertEqual(selection[0].name, "Updated title")
        XCTAssertEqual(selection[0].backdropImageTags, ["new-image"])
        XCTAssertEqual(Set(selection.map(\.id)).count, 10)
        XCTAssertFalse(selection.contains { ["deleted", "lost-art", "wrong-type"].contains($0.id) })
    }

    func testRetainedRecommendationsDropMissingItemsAndHonorSmallOrEmptyPools() throws {
        let surviving = try item("one", artwork: ["BackdropImageTags": ["wide"]])
        XCTAssertEqual(HomeRecommendationSelection.select(from: [surviving], retainingIDs: ["missing", "one"]).map(\.id), ["one"])
        XCTAssertTrue(HomeRecommendationSelection.select(from: [], retainingIDs: ["missing"]).isEmpty)
        XCTAssertTrue(HomeRecommendationSelection.select(from: [try item("one")], retainingIDs: ["one"]).isEmpty)
        XCTAssertTrue(HomeRecommendationSelection.select(from: [surviving], retainingIDs: ["one"], limit: 0).isEmpty)
    }

    private func item(_ id: String, type: String = "Movie", artwork: [String: Any] = [:]) throws -> MediaItem {
        var data: [String: Any] = ["Id": id, "Name": id, "Type": type]
        data.merge(artwork) { _, new in new }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: data))
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}
