import Darwin
import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

final class ApplicationStorageTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixConfiguration-\(UUID().uuidString)")
    }

    private func assertNoTemporaryFiles(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".connections-") },
                       file: file, line: line)
    }

    func testSeatSixUsesNewDirectoryForFreshInstallAndKeepsExistingProfileTogether() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let fresh = support.appendingPathComponent("SeatSix", isDirectory: true)
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), fresh)

        let legacy = support.appendingPathComponent("Theater", isDirectory: true)
        let original = try ApplicationStorage(directory: legacy)
        let connection = ServerConnection(kind: .jellyfin, name: "Old Library", baseURL: URL(string: "https://media.test")!,
                                          serverID: "server", userID: "user", username: "name", libraryIDs: ["movies"])
        var saved = SavedApplication()
        saved.connections = [connection]
        saved.selectedID = connection.id
        saved.deviceID = "existing-device"
        saved.recovery = [RecoveryPoint(serverID: "server", userID: "user", itemID: "movie",
                                        ticks: 456, updatedAt: Date(), confirmed: true)]
        try original.save(saved)
        try CredentialAccess.local(directory: legacy.appendingPathComponent("Credentials")).save("fixture", connection.id)

        let reopened = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        let profile = try reopened.load()
        XCTAssertEqual(reopened.directory, legacy)
        XCTAssertEqual(profile.connections, [connection])
        XCTAssertEqual(profile.selectedID, connection.id)
        XCTAssertEqual(profile.deviceID, "existing-device")
        XCTAssertEqual(profile.recovery.first?.ticks, 456)
        XCTAssertEqual(try CredentialAccess.local(directory: reopened.directory.appendingPathComponent("Credentials")).read(connection.id), "fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testUnusableLegacyProfileNeverFallsBackToAnEmptySeatSixProfile() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appendingPathComponent("Theater", isDirectory: true)
        let other = support.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: other)
        let selected = ApplicationStorage.defaultDirectory(in: support)
        XCTAssertEqual(selected, legacy)
        XCTAssertThrowsError(try ApplicationStorage(directory: selected))
        try FileManager.default.removeItem(at: legacy)
        let original = try ApplicationStorage(directory: legacy)
        try Data("damaged profile".utf8).write(to: original.file)
        let reopened = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        XCTAssertThrowsError(try reopened.load())
        XCTAssertEqual(try String(contentsOf: original.file), "damaged profile")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("SeatSix").path))
    }

    func testSavedSeatSixProfileWinsOverEmptyRestoredAndCorruptOlderProfiles() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let current = try ApplicationStorage(directory: support.appendingPathComponent("SeatSix", isDirectory: true))
        var profile = SavedApplication()
        profile.deviceID = "current-device"
        try current.save(profile)
        let legacy = try ApplicationStorage(directory: support.appendingPathComponent("Theater", isDirectory: true))
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), current.directory)

        var backup = SavedApplication()
        backup.deviceID = "old-device"
        try legacy.save(backup)
        let reopened = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        XCTAssertEqual(try reopened.load().deviceID, "current-device")
        try Data("damaged backup".utf8).write(to: legacy.file)
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), current.directory)

        try legacy.save(backup)
        try Data("damaged current profile".utf8).write(to: current.file)
        let broken = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        XCTAssertEqual(broken.directory, current.directory)
        XCTAssertThrowsError(try broken.load())
        XCTAssertEqual(try legacy.load().deviceID, "old-device")
        XCTAssertEqual(try String(contentsOf: current.file), "damaged current profile")
    }

    func testEmptySeatSixDirectoryPreservesLegacyDataAndIgnoresEmptyLegacyPlaceholder() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let current = support.appendingPathComponent("SeatSix", isDirectory: true)
        let legacy = try ApplicationStorage(directory: support.appendingPathComponent("Theater", isDirectory: true))
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), current)
        _ = try ApplicationStorage(directory: current)
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), current)
        try FileManager.default.createDirectory(at: legacy.directory.appendingPathComponent("Credentials"), withIntermediateDirectories: false)
        XCTAssertEqual(ApplicationStorage.defaultDirectory(in: support), legacy.directory)
        var backup = SavedApplication()
        backup.deviceID = "legacy-device"
        try legacy.save(backup)
        let reopened = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        XCTAssertEqual(try reopened.load().deviceID, "legacy-device")
        try Data("damaged".utf8).write(to: legacy.file)
        let broken = try ApplicationStorage(directory: ApplicationStorage.defaultDirectory(in: support))
        XCTAssertThrowsError(try broken.load())
    }

    func testConfigurationIsPrivateBeforeWriteAndPublishedWithoutLaterPermissionMutation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var observed = false
        let storage = try ApplicationStorage(directory: directory, writeHook: { stage, descriptor in
            if case .beforeWrite = stage {
                var metadata = stat()
                XCTAssertEqual(fstat(descriptor, &metadata), 0)
                XCTAssertEqual(metadata.st_mode & mode_t(0o777), mode_t(0o600))
                XCTAssertEqual(metadata.st_size, 0)
                observed = true
            }
        })
        var saved = SavedApplication(); saved.deviceID = "persisted-device"
        try storage.save(saved)
        XCTAssertTrue(observed)
        XCTAssertEqual(try ApplicationStorage(directory: directory).load().deviceID, saved.deviceID)
        let permissions = try FileManager.default.attributesOfItem(atPath: storage.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try assertNoTemporaryFiles(directory)
    }

    func testEveryPrecommitWriteFailurePreservesOriginalConfigurationAndCleansTemporaryFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalStorage = try ApplicationStorage(directory: directory)
        var original = SavedApplication(); original.deviceID = "original"
        try originalStorage.save(original)
        let originalBytes = try Data(contentsOf: originalStorage.file)
        for failureStage in [ApplicationStorage.WriteStage.beforeWrite, .beforeSynchronize, .beforePublish] {
            let failing = try ApplicationStorage(directory: directory, writeHook: { stage, _ in
                if stage == failureStage { throw ApplicationPersistenceError.saveFailed }
            })
            var changed = original; changed.deviceID = "replacement"
            XCTAssertThrowsError(try failing.save(changed))
            XCTAssertEqual(try Data(contentsOf: originalStorage.file), originalBytes)
            XCTAssertEqual(try originalStorage.load().deviceID, "original")
            try assertNoTemporaryFiles(directory)
        }
    }

    func testSyncFailureAndPublishFailureNeverReportAChangedConfigurationAsUnchanged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try ApplicationStorage(directory: directory)
        try original.save(SavedApplication())
        let bytes = try Data(contentsOf: original.file)
        let syncFailure = try ApplicationStorage(directory: directory, synchronizeFile: { _ in -1 })
        XCTAssertThrowsError(try syncFailure.save(SavedApplication()))
        XCTAssertEqual(try Data(contentsOf: original.file), bytes)
        try assertNoTemporaryFiles(directory)

        // A directory cannot be replaced by renameat's regular file. The
        // failure leaves the destination intact and cleans the candidate.
        try FileManager.default.removeItem(at: original.file)
        try FileManager.default.createDirectory(at: original.file, withIntermediateDirectories: false)
        let marker = original.file.appendingPathComponent("keep")
        try Data("marker".utf8).write(to: marker)
        XCTAssertThrowsError(try original.save(SavedApplication()))
        XCTAssertEqual(try Data(contentsOf: marker), Data("marker".utf8))
        try assertNoTemporaryFiles(directory)
    }

    @MainActor
    func testRealConfigurationFailureRollsBackTokenAndRestartLoadsOriginalConnection() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory)
        let connection = ServerConnection(kind: .emby, name: "Original", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "name", libraryIDs: ["library"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        try storage.save(saved)
        let credentials = CredentialAccess.local(directory: directory.appendingPathComponent("Credentials"))
        try credentials.save("old-fixture-token", connection.id)
        let failingStorage = try ApplicationStorage(directory: directory, writeHook: { stage, _ in
            if case .beforePublish = stage { throw ApplicationPersistenceError.saveFailed }
        })
        let model = ApplicationModel(storage: failingStorage)
        XCTAssertThrowsError(try model.add(AuthenticatedServer(connection: connection, token: "new-fixture-token"),
                                           libraryIDs: ["changed"], name: "Changed"))
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertEqual(try ApplicationStorage(directory: directory).load().connections, [connection])
        XCTAssertEqual(try credentials.read(connection.id), "old-fixture-token")
        try assertNoTemporaryFiles(directory)
    }
}
