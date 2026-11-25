import XCTest
import SeatSixCore
@testable import SeatSixApp

final class SeatSixAppTests: XCTestCase {
    func testLateAcknowledgementCannotConfirmNewerLocalPosition() {
        var journal = PlaybackJournal()
        let first = journal.record(30_000_000)
        let latest = journal.record(90_000_000)
        XCTAssertFalse(journal.accepts(first))
        XCTAssertTrue(journal.accepts(latest))
        XCTAssertEqual(journal.ticks, 90_000_000)
        _ = journal.record(-1)
        XCTAssertEqual(journal.ticks, 0)
    }

    func testConnectionStorageContainsNoCredentialAndRoundTripsScope() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory)
        var saved = SavedApplication()
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test/emby")!, serverID: "server", userID: "user", username: "name", libraryIDs: ["selected"], compatibilityMode: true)
        saved.connections = [connection]; saved.selectedID = connection.id
        saved.recovery = [RecoveryPoint(serverID: "server", userID: "user", itemID: "movie", ticks: 70_000_000, updatedAt: Date(), confirmed: false)]
        try storage.save(saved)
        let loaded = try storage.load()
        XCTAssertEqual(loaded.connections, [connection])
        XCTAssertEqual(loaded.deviceID, saved.deviceID)
        XCTAssertFalse(loaded.recovery[0].confirmed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storage.file)) as? [String: Any])
        XCTAssertNil(json["token"])
        XCTAssertNil(json["password"])
        let attributes = try FileManager.default.attributesOfItem(atPath: storage.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptStorageIsNotOverwrittenWhileReading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory)
        let bytes = Data("broken saved configuration".utf8)
        try bytes.write(to: storage.file)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try Data(contentsOf: storage.file), bytes)
    }

    func testRecoveryIdentitySeparatesServersAndUsers() {
        let first = RecoveryPoint(serverID: "server-a", userID: "user", itemID: "1", ticks: 1, updatedAt: Date(), confirmed: false)
        let second = RecoveryPoint(serverID: "server-b", userID: "user", itemID: "1", ticks: 1, updatedAt: Date(), confirmed: false)
        let third = RecoveryPoint(serverID: "server-a", userID: "other", itemID: "1", ticks: 1, updatedAt: Date(), confirmed: false)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, third.id)
    }
}
