import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixProbe

@MainActor
final class UserStateProbeTests: XCTestCase {
    func testCompleteRoundTripChecksFullCatalogAndRestoresEntireState() async throws {
        let fixture = try Fixture()
        var saved: [[String: Any]] = []
        let report = await fixture.run { saved.append($0) }
        XCTAssertEqual(report["passed"] as? Bool, true)
        XCTAssertEqual(report["entireOriginalUserDataRestored"] as? Bool, true)
        XCTAssertEqual(report["mutationAttemptCount"] as? Int, 6)
        XCTAssertEqual(fixture.actions, ["movie.favorite.true", "movie.favorite.false", "series.favorite.true", "series.favorite.false", "movie.played.true", "movie.played.false"])
        XCTAssertEqual(fixture.catalogReads, 7)
        XCTAssertFalse(saved.isEmpty)
        XCTAssertEqual(saved.last?["passed"] as? Bool, true)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        XCTAssertTrue(checks.contains { $0["name"] as? String == "movie.markedWatched.watchedFilters" && $0["passed"] as? Bool == true })
        let publicJSON = String(data: try JSONSerialization.data(withJSONObject: report), encoding: .utf8)!
        XCTAssertFalse(publicJSON.contains("private-"))
        XCTAssertFalse(publicJSON.contains("ItemId"))
    }

    func testFailedWriteAfterServerAppliedItRestoresOnlyAttemptedAction() async throws {
        let fixture = try Fixture()
        fixture.failFirstFavoriteAfterApplying = true
        let report = await fixture.run()
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual(report["entireOriginalUserDataRestored"] as? Bool, true)
        XCTAssertEqual(fixture.actions, ["movie.favorite.true", "movie.favorite.false"])
        XCTAssertFalse(fixture.actions.contains { $0.contains("played") || $0.hasPrefix("series") })
    }

    func testUnsafeBaselineIssuesNoMutations() async throws {
        let fixture = try Fixture()
        fixture.states["movie"]?["PlaybackPositionTicks"] = 100
        let report = await fixture.run()
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(report["mutationAttemptCount"] as? Int, 0)
    }

    func testNewLastPlayedDateFailsFullEqualityDespiteMatchingFlags() async throws {
        let fixture = try Fixture()
        fixture.leaveChangedLastPlayedDate = true
        let report = await fixture.run()
        XCTAssertEqual(report["operationCompleted"] as? Bool, true)
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual(report["entireOriginalUserDataRestored"] as? Bool, false)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first { $0["name"] as? String == "movie.entireUserDataRestored" }?["passed"] as? Bool, false)
    }

    func testStaleCatalogFailsAndStillRestoresMovieFavorite() async throws {
        let fixture = try Fixture()
        fixture.staleCatalog = true
        let report = await fixture.run()
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual(report["entireOriginalUserDataRestored"] as? Bool, true)
        XCTAssertEqual(fixture.actions, ["movie.favorite.true", "movie.favorite.false"])
    }

    func testBaselineChangesDuringCatalogTraversalAreNeverOverwritten() async throws {
        let fixture = try Fixture()
        fixture.changeMovieDuringCatalog = true
        let report = await fixture.run()
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.states["movie"]?["IsFavorite"] as? Bool, true)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first { $0["name"] as? String == "movie.baselineUnchangedBeforeWrite" }?["passed"] as? Bool, false)
    }

    func testSeriesBaselineChangeDoesNotTriggerSeriesOrFinishedMovieCleanupWrites() async throws {
        let fixture = try Fixture()
        fixture.changeSeriesDuringCatalog = true
        let report = await fixture.run()
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual(fixture.actions, ["movie.favorite.true", "movie.favorite.false"])
        XCTAssertEqual(fixture.states["series"]?["IsFavorite"] as? Bool, true)
        XCTAssertFalse(fixture.actions.contains { $0.hasPrefix("series") || $0.contains("played") })
    }

    func testProgressPersistenceFailurePreventsFirstWrite() async throws {
        let fixture = try Fixture()
        let report = await fixture.run { report in
            if report["mutationAttemptCount"] as? Int == 1 { throw URLError(.cannotWriteToFile) }
        }
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testProgressPersistenceFailureAfterWriteDoesNotPreventCleanup() async throws {
        let fixture = try Fixture()
        let report = await fixture.run { report in
            if (report["writeDispatchCount"] as? Int ?? 0) > 0 { throw URLError(.cannotWriteToFile) }
        }
        XCTAssertEqual(report["passed"] as? Bool, false)
        XCTAssertEqual(report["entireOriginalUserDataRestored"] as? Bool, true)
        XCTAssertEqual(fixture.actions, ["movie.favorite.true", "movie.favorite.false"])
    }

    func testRawComparisonIncludesExtraKeysAndRejectsNumericBooleans() throws {
        let initial: [String: Any] = ["Played": false, "IsFavorite": false, "PlaybackPositionTicks": 0, "PlayCount": 0, "Key": "private-original"]
        let before = try UserStateProbe.RawState(initial)
        var changed = initial; changed["Key"] = "private-changed"
        XCTAssertFalse(before.isIdentical(to: try UserStateProbe.RawState(changed)))
        changed = initial; changed["Played"] = 0
        XCTAssertThrowsError(try UserStateProbe.RawState(changed))
        changed = initial; changed.removeValue(forKey: "IsFavorite")
        XCTAssertThrowsError(try UserStateProbe.RawState(changed))
    }

    private final class Fixture {
        var states: [String: [String: Any]] = [:]
        var actions: [String] = []
        var catalogReads = 0
        var failFirstFavoriteAfterApplying = false
        var leaveChangedLastPlayedDate = false
        var staleCatalog = false
        var changeMovieDuringCatalog = false
        var changeSeriesDuringCatalog = false

        init() throws {
            for role in ["movie", "series"] {
                states[role] = ["Played": false, "IsFavorite": false, "PlaybackPositionTicks": 0, "PlayCount": 0, "ItemId": "private-" + role, "Key": "private-key"]
            }
        }
        func item(_ role: String, favoriteOverride: Bool? = nil) throws -> MediaItem {
            var state = states[role]!
            if let favoriteOverride { state["IsFavorite"] = favoriteOverride }
            return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: [
                "Id": "private-" + role, "Name": "private-title-" + role, "Type": role == "movie" ? "Movie" : "Series", "UserData": state]))
        }
        func role(_ item: MediaItem) -> String { item.type == "Movie" ? "movie" : "series" }
        func run(persist: @escaping ([String: Any]) throws -> Void = { _ in }) async -> [String: Any] {
            await UserStateProbe.verify(libraryIDs: ["private-library"], movieID: "private-movie", seriesID: "private-series",
                dependencies: .init(item: { id in try self.item(id == "private-movie" ? "movie" : "series") },
                    rawState: { item in try UserStateProbe.RawState(self.states[self.role(item)]!) },
                    catalog: { _ in
                        self.catalogReads += 1
                        if self.catalogReads == 1 {
                            if self.changeMovieDuringCatalog { self.states["movie"]?["IsFavorite"] = true }
                            if self.changeSeriesDuringCatalog { self.states["series"]?["IsFavorite"] = true }
                        }
                        return try LibraryCatalogSnapshot(items: [self.item("movie", favoriteOverride: self.staleCatalog ? false : nil), self.item("series")], total: 2, isComplete: true)
                    }, favorite: { item, enabled in
                        let role = self.role(item)
                        self.actions.append(role + ".favorite." + String(enabled))
                        self.states[role]?["IsFavorite"] = enabled
                        if self.failFirstFavoriteAfterApplying && self.actions.count == 1 { throw URLError(.timedOut) }
                        return try self.item(role)
                    }, played: { item, enabled in
                        let role = self.role(item)
                        self.actions.append(role + ".played." + String(enabled))
                        self.states[role]?["Played"] = enabled
                        self.states[role]?["PlayCount"] = enabled ? 1 : 0
                        if self.leaveChangedLastPlayedDate { self.states[role]?["LastPlayedDate"] = "private-date" }
                        return try self.item(role)
                    }), persist: persist)
        }
    }
}
