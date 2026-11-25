import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

final class SeriesPlaybackPreferencesTests: XCTestCase {
    private func identity(connectionID: UUID = UUID(), serverID: String = "server", userID: String = "user", seriesID: String = "series") -> SeriesPlaybackIdentity {
        .init(connectionID: connectionID, serverID: serverID, userID: userID, seriesID: seriesID)
    }

    func testIdentitySeparatesSameSeriesAcrossConnectionsServersAndUsers() {
        let connectionID = UUID(), first = identity(connectionID: connectionID)
        let identities = Set([first, identity(), identity(connectionID: connectionID, serverID: "other"),
                              identity(connectionID: connectionID, userID: "other"), identity(connectionID: connectionID, seriesID: "other")])
        XCTAssertEqual(identities.count, 5)
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "test", libraryIDs: [])
        XCTAssertEqual(SeriesPlaybackIdentity(connection: connection, seriesID: "series"),
                       identity(connectionID: connection.id))
    }

    func testValidationAcceptsDisabledAndBoundariesButRejectsInvalidDrafts() throws {
        XCTAssertEqual(try SeriesSkipSettings().validated(), .init(introSeconds: 0, outroSeconds: 0))
        XCTAssertNoThrow(try SeriesSkipSettings(introSeconds: 1800, outroSeconds: 1800).validated())
        for settings in [SeriesSkipSettings(introSeconds: -1), .init(outroSeconds: -1),
                         .init(introSeconds: 1801), .init(outroSeconds: Int.max)] {
            XCTAssertNotNil(settings.validationError)
            XCTAssertThrowsError(try settings.validated())
        }
    }

    func testSettingsDecodeMalformedOrUnsafePairAsDisabled() throws {
        for json in [#"{"introSeconds":-1,"outroSeconds":90}"#,
                     #"{"introSeconds":90,"outroSeconds":1801}"#,
                     #"{"introSeconds":"90","outroSeconds":60}"#,
                     #"{"introSeconds":90,"outroSeconds":0.5}"#,
                     #"{"introSeconds":90,"outroSeconds":true}"#,
                     #"[90,60]"#] {
            XCTAssertEqual(try JSONDecoder().decode(SeriesSkipSettings.self, from: Data(json.utf8)), .init())
        }
        XCTAssertEqual(try JSONDecoder().decode(SeriesSkipSettings.self, from: Data(#"{"introSeconds":90}"#.utf8)),
                       .init(introSeconds: 90))
        XCTAssertEqual(try JSONDecoder().decode(SeriesSkipSettings.self, from: Data(#"{}"#.utf8)), .init())
    }

    func testLegacyApplicationHasDisabledSeriesPreferencesWithoutLosingIdentity() throws {
        let data = Data(#"{"connections":[],"deviceID":"existing-device","recovery":[]}"#.utf8)
        let saved = try JSONDecoder().decode(SavedApplication.self, from: data)
        XCTAssertTrue(saved.seriesPlaybackPreferences.isEmpty)
        XCTAssertEqual(saved.deviceID, "existing-device")
    }

    func testMalformedStoredSettingsPreserveOtherRecordsAndConnections() throws {
        let connection = ServerConnection(kind: .jellyfin, name: "Local test", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "test", libraryIDs: [])
        var saved = SavedApplication()
        saved.connections = [connection]
        saved.selectedID = connection.id
        saved.seriesPlaybackPreferences = [
            .init(identity: .init(connection: connection, seriesID: "first"), settings: .init(introSeconds: 90, outroSeconds: 45)),
            .init(identity: .init(connection: connection, seriesID: "second"), settings: .init(introSeconds: 30, outroSeconds: 60))
        ]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var records = try XCTUnwrap(json["seriesPlaybackPreferences"] as? [[String: Any]])
        records[0]["settings"] = ["introSeconds": -300, "outroSeconds": 45]
        json["seriesPlaybackPreferences"] = records
        let decoded = try JSONDecoder().decode(SavedApplication.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.connections, [connection])
        XCTAssertEqual(decoded.selectedID, connection.id)
        XCTAssertEqual(decoded.seriesPlaybackPreferences.count, 2)
        XCTAssertEqual(decoded.seriesPlaybackPreferences[0].settings, .init())
        XCTAssertEqual(decoded.seriesPlaybackPreferences[1].settings, .init(introSeconds: 30, outroSeconds: 60))
    }

    func testSettingsSurviveStorageReopenForEverySeries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeriesPreferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory)
        var saved = SavedApplication()
        saved.seriesPlaybackPreferences = [
            .init(identity: identity(), settings: .init(introSeconds: 93, outroSeconds: 64)),
            .init(identity: identity(seriesID: "second"), settings: .init(outroSeconds: 120))
        ]
        try storage.save(saved)
        let reopened = try ApplicationStorage(directory: directory).load()
        XCTAssertEqual(reopened.seriesPlaybackPreferences, saved.seriesPlaybackPreferences)
        let json = try String(contentsOf: storage.file, encoding: .utf8)
        XCTAssertFalse(json.contains("api_key"))
        XCTAssertFalse(json.contains("https:"))
    }

    func testRecordMissingSettingsAndDateDefaultsSafely() throws {
        let preference = SeriesPlaybackPreferences(identity: identity(), settings: .init(introSeconds: 90))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preference)) as? [String: Any])
        json.removeValue(forKey: "settings")
        json.removeValue(forKey: "updatedAt")
        let decoded = try JSONDecoder().decode(SeriesPlaybackPreferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.identity, preference.identity)
        XCTAssertEqual(decoded.settings, .init())
        XCTAssertEqual(decoded.updatedAt, .distantPast)
    }
}

final class EpisodeSkipPolicyTests: XCTestCase {
    private let settings = SeriesSkipSettings(introSeconds: 90, outroSeconds: 60)

    func testIntroAdvancesBeginningAndInsideIntroWithoutRewindingResume() {
        XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 0, duration: 1500, settings: settings), 90)
        XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 30, duration: 1500, settings: settings), 90)
        XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 90, duration: 1500, settings: settings), 90)
        XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 400, duration: 1500, settings: settings), 400)
        XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 0, duration: 1500, settings: .init(outroSeconds: 60)), 0)
    }

    func testUnknownNonfiniteAndTooShortDurationDisableBothSkips() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -1, 1, 150, 151] {
            XCTAssertFalse(EpisodeSkipPolicy.isApplicable(duration: duration, settings: settings))
            XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 30, duration: duration, settings: settings), 30)
            XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: 100, duration: duration, settings: settings, playing: true, seeking: false))
        }
        XCTAssertTrue(EpisodeSkipPolicy.isApplicable(duration: 151.01, settings: settings))
    }

    func testDisabledAndInvalidSettingsNeverSkip() {
        for settings in [SeriesSkipSettings(), .init(introSeconds: -1, outroSeconds: 30), .init(introSeconds: Int.max)] {
            XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: 10, duration: 1500, settings: settings), 10)
            XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: 1490, duration: 1500, settings: settings, playing: true, seeking: false))
        }
    }

    func testInitialPositionAlwaysFiniteAndNonnegative() {
        for resume in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: resume, duration: 0, settings: settings), 0)
            XCTAssertEqual(EpisodeSkipPolicy.initialPosition(resumeSeconds: resume, duration: 1500, settings: settings), 90)
        }
    }

    func testOutroStartsExactlyAtThresholdAndLeavesFinalHalfSecondForActualEOF() {
        XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: 1439.99, duration: 1500, settings: settings, playing: true, seeking: false))
        XCTAssertEqual(EpisodeSkipPolicy.outroTarget(seconds: 1440, duration: 1500, settings: settings, playing: true, seeking: false), 1499.5)
        XCTAssertEqual(EpisodeSkipPolicy.outroTarget(seconds: 1499.49, duration: 1500, settings: settings, playing: true, seeking: false), 1499.5)
        for seconds in [1499.5, 1499.9, 1500, 1600] {
            XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: seconds, duration: 1500, settings: settings, playing: true, seeking: false))
        }
    }

    func testOutroDoesNotActOnPauseSeekOrInvalidPosition() {
        XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: 1490, duration: 1500, settings: settings, playing: false, seeking: false))
        XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: 1490, duration: 1500, settings: settings, playing: true, seeking: true))
        for seconds in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertNil(EpisodeSkipPolicy.outroTarget(seconds: seconds, duration: 1500, settings: settings, playing: true, seeking: false))
        }
    }
}
