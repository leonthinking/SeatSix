import Darwin
import Foundation
import XCTest
@testable import SeatSixApp

final class LocalCredentialStoreTests: XCTestCase {
    private var root: URL!
    private var application: URL!
    private var directory: URL!
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixCredentials-\(UUID().uuidString)")
        let support = root.appendingPathComponent("Application Support")
        application = support.appendingPathComponent("SeatSix")
        directory = application.appendingPathComponent("Credentials")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ connectionID: UUID? = nil) -> URL {
        directory.appendingPathComponent((connectionID ?? id).uuidString.lowercased() + ".json")
    }

    private func fixture(_ bytes: Data, connectionID: UUID? = nil) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try bytes.write(to: file(connectionID))
        XCTAssertEqual(chmod(file(connectionID).path, mode_t(0o600)), 0)
    }

    private func record(token: Any = "fixture-token", version: Any = 1, connectionID: UUID? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": version,
                                                   "connectionID": (connectionID ?? id).uuidString,
                                                   "token": token])
    }

    private func assertError<T>(_ expression: @autoclosure () throws -> T, _ expected: CredentialStoreError,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual($0 as? CredentialStoreError, expected, file: file, line: line)
        }
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }

    private func assertNoTemporaryFiles(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".credential-") },
                       file: file, line: line)
    }

    private func addACL(_ entry: String, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", entry, url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "chmod failed"
            XCTFail("The real macOS ACL fixture could not be installed: \(message)")
            throw SyntheticFailure.expected
        }
        XCTAssertTrue(try hasExtendedACL(url), "The fixture must contain a real ACL, not only POSIX permissions")
    }

    private func hasExtendedACL(_ url: URL) throws -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyntheticFailure.expected }
        defer { Darwin.close(descriptor) }
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return false }
            throw SyntheticFailure.expected
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    func testMissingCredentialsAreDistinctAndReadOrRemoveDoNotCreateStorage() throws {
        let store = LocalCredentialStore(directory: directory)
        assertError(try store.read(for: id), .notFound)
        try store.remove(for: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAccessTokenPersistsAcrossInstancesWithVersionAndConnectionScopeOnly() throws {
        let access = CredentialAccess.local(directory: directory)
        try access.save("fixture-access-token", id)
        let reopened = LocalCredentialStore(directory: directory)
        XCTAssertEqual(try reopened.read(for: id), "fixture-access-token")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file())) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "connectionID", "token"])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["connectionID"] as? String, id.uuidString)
        XCTAssertNil(json["password"])
        try access.remove(id)
        assertError(try reopened.read(for: id), .notFound)
    }

    func testConnectionsAndStoreDirectoriesAreIsolated() throws {
        let first = LocalCredentialStore(directory: directory)
        let otherID = UUID()
        try first.save("first", for: id)
        try first.save("second", for: otherID)
        let otherDirectory = application.appendingPathComponent("OtherCredentials")
        let second = LocalCredentialStore(directory: otherDirectory)
        try second.save("other-store", for: id)
        try first.remove(for: otherID)
        XCTAssertEqual(try first.read(for: id), "first")
        XCTAssertEqual(try second.read(for: id), "other-store")
        assertError(try first.read(for: otherID), .notFound)
        assertError(try second.read(for: otherID), .notFound)
    }

    func testDirectoryAndNewTemporaryFileArePrivateBeforeTokenWrite() throws {
        let support = application.deletingLastPathComponent()
        let supportMode = try mode(support)
        var observedEmptyPrivateFile = false
        let store = LocalCredentialStore(directory: directory, writeHook: { stage, descriptor in
            guard stage == .beforeWrite else { return }
            var metadata = stat()
            XCTAssertEqual(fstat(descriptor, &metadata), 0)
            XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
            XCTAssertEqual(metadata.st_uid, geteuid())
            XCTAssertEqual(metadata.st_nlink, 1)
            XCTAssertEqual(metadata.st_size, 0)
            observedEmptyPrivateFile = true
        })
        try store.save("token", for: id)
        XCTAssertTrue(observedEmptyPrivateFile)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(file()), 0o600)
        XCTAssertEqual(try mode(support), supportMode, "Public ancestors must not be chmodded")
        try assertNoTemporaryFiles()
    }

    func testExistingCredentialDirectoryPermissionsAreTightenedWithoutChangingPublicAncestors() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let support = application.deletingLastPathComponent()
        let supportMode = try mode(support)
        try LocalCredentialStore(directory: directory).save("token", for: id)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(support), supportMode)
    }

    func testPrivateParentInheritedACLIsRejectedBeforeCreatingCredentialDirectory() throws {
        try addACL("everyone allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit", to: application)
        XCTAssertEqual(chmod(application.path, mode_t(0o700)), 0)
        XCTAssertTrue(try hasExtendedACL(application), "chmod 0700 must not be mistaken for removal of inherited ACLs")
        let store = LocalCredentialStore(directory: directory)
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("new-secret", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try hasExtendedACL(application), "The store must reject, not rewrite, the existing ACL")
    }

    func testCredentialDirectoryACLIsRejectedDespitePrivateModeBits() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        try addACL("everyone allow list,search,readattr,readextattr,readsecurity", to: directory)
        XCTAssertEqual(chmod(directory.path, mode_t(0o700)), 0)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertTrue(try hasExtendedACL(directory))
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("replacement", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertEqual(try Data(contentsOf: file()), original)
        XCTAssertTrue(try hasExtendedACL(directory))
        try assertNoTemporaryFiles()
    }

    func testCredentialFileACLRejectsReadSaveAndRemoveDespiteMode0600() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        try addACL("everyone allow read,readattr,readextattr,readsecurity", to: file())
        XCTAssertEqual(chmod(file().path, mode_t(0o600)), 0)
        XCTAssertEqual(try mode(file()), 0o600)
        XCTAssertTrue(try hasExtendedACL(file()))
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("replacement", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertEqual(try Data(contentsOf: file()), original)
        XCTAssertTrue(try hasExtendedACL(file()))
        try assertNoTemporaryFiles()
    }

    func testACLOnNewTemporaryDescriptorPreventsSecretWriteAndCleansFile() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        var checkedEmptyTemporary = false
        var retainedTemporary: Int32 = -1
        defer { if retainedTemporary >= 0 { Darwin.close(retainedTemporary) } }
        let guarded = LocalCredentialStore(directory: directory, writeHook: { stage, descriptor in
            guard stage == .beforeWrite else { return }
            var metadata = stat()
            XCTAssertEqual(fstat(descriptor, &metadata), 0)
            XCTAssertEqual(metadata.st_size, 0)
            let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: self.directory.path)
                .first { $0.hasPrefix(".credential-") })
            try self.addACL("everyone allow read,readattr,readextattr,readsecurity", to: self.directory.appendingPathComponent(name))
            retainedTemporary = dup(descriptor)
            XCTAssertGreaterThanOrEqual(retainedTemporary, 0)
            checkedEmptyTemporary = true
        })
        assertError(try guarded.save("must-not-be-written", for: id), .unsafeLocation)
        XCTAssertTrue(checkedEmptyTemporary)
        // Retain the inode after cleanup to prove failure happened before any
        // secret bytes were written, not merely before publishing the filename.
        var rejectedTemporary = stat()
        XCTAssertEqual(fstat(retainedTemporary, &rejectedTemporary), 0)
        XCTAssertEqual(rejectedTemporary.st_size, 0)
        XCTAssertEqual(try Data(contentsOf: file()), original)
        XCTAssertEqual(try store.read(for: id), "original")
        try assertNoTemporaryFiles()
    }

    func testPublicAncestorACLIsPreservedWithoutBlockingPrivateStorage() throws {
        let support = application.deletingLastPathComponent()
        try addACL("everyone allow list,search,readattr,readextattr,readsecurity", to: support)
        let originalMode = try mode(support)
        let store = LocalCredentialStore(directory: directory)
        try store.save("token", for: id)
        XCTAssertEqual(try store.read(for: id), "token")
        XCTAssertTrue(try hasExtendedACL(support))
        XCTAssertEqual(try mode(support), originalMode)
        XCTAssertFalse(try hasExtendedACL(application))
        XCTAssertFalse(try hasExtendedACL(directory))
        XCTAssertFalse(try hasExtendedACL(file()))
    }

    func testCredentialDirectorySymlinkIsRejectedWithoutTouchingOutsideDirectory() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let store = LocalCredentialStore(directory: directory)
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("new", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try mode(outside), 0o755)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
    }

    func testPrivateParentSymlinkIsRejectedWithoutFollowingIntoOutsideDirectory() throws {
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.removeItem(at: application)
        try FileManager.default.createSymbolicLink(at: application, withDestinationURL: outside)
        let store = LocalCredentialStore(directory: directory)
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("new", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testTokenSymlinkAndHardLinkAreRejectedForReadSaveAndRemove() throws {
        let outside = root.appendingPathComponent("outside-token")
        try Data("outside-unchanged".utf8).write(to: outside)
        XCTAssertEqual(chmod(outside.path, mode_t(0o600)), 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for symbolic in [true, false] {
            if symbolic { try FileManager.default.createSymbolicLink(at: file(), withDestinationURL: outside) }
            else { try FileManager.default.linkItem(at: outside, to: file()) }
            let store = LocalCredentialStore(directory: directory)
            assertError(try store.read(for: id), .unsafeLocation)
            assertError(try store.save("new", for: id), .unsafeLocation)
            assertError(try store.remove(for: id), .unsafeLocation)
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside-unchanged".utf8))
            try FileManager.default.removeItem(at: file())
        }
    }

    func testNonRegularFilesAreRejectedWithoutBlockingOrDeletingThem() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        for directoryEntry in [true, false] {
            if directoryEntry { try FileManager.default.createDirectory(at: file(), withIntermediateDirectories: false) }
            else { XCTAssertEqual(mkfifo(file().path, mode_t(0o600)), 0) }
            let store = LocalCredentialStore(directory: directory)
            assertError(try store.read(for: id), .unsafeLocation)
            assertError(try store.save("new", for: id), .unsafeLocation)
            assertError(try store.remove(for: id), .unsafeLocation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file().path))
            try FileManager.default.removeItem(at: file())
        }
    }

    func testUnsafeFileOrPrivateParentPermissionsFailClosed() throws {
        try fixture(record())
        let store = LocalCredentialStore(directory: directory)
        XCTAssertEqual(chmod(file().path, mode_t(0o644)), 0)
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("new", for: id), .unsafeLocation)
        assertError(try store.remove(for: id), .unsafeLocation)
        XCTAssertEqual(chmod(file().path, mode_t(0o600)), 0)
        XCTAssertEqual(chmod(application.path, mode_t(0o777)), 0)
        assertError(try store.read(for: id), .unsafeLocation)
        assertError(try store.save("new", for: id), .unsafeLocation)
        XCTAssertEqual(chmod(application.path, mode_t(0o700)), 0)
        XCTAssertEqual(try store.read(for: id), "fixture-token")
    }

    func testForeignOwnedPrivateParentIsRejectedBeforeCreatingAnything() throws {
        if geteuid() == 0 {
            XCTAssertEqual(chown(application.path, uid_t(501), gid_t.max), 0)
            defer { _ = chown(application.path, uid_t(0), gid_t.max) }
            assertError(try LocalCredentialStore(directory: directory).save("token", for: id), .unsafeLocation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        } else {
            let candidate = URL(fileURLWithPath: "/usr/bin").appendingPathComponent("SeatSix-Credentials-Test-\(UUID().uuidString)")
            assertError(try LocalCredentialStore(directory: candidate).save("token", for: id), .unsafeLocation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        }
    }

    func testInvalidRecordsRemainUnchangedOnReadAndSave() throws {
        let invalid = [Data(), Data("not-json".utf8), Data([0xff, 0xfe]),
                       try record(version: 2), try record(version: true),
                       try record(connectionID: UUID()), try record(token: ""),
                       try record(token: " \n "), try record(token: 12),
                       Data(repeating: 65, count: LocalCredentialStore.maximumRecordBytes + 1)]
        let store = LocalCredentialStore(directory: directory)
        for bytes in invalid {
            try fixture(bytes)
            assertError(try store.read(for: id), .invalidData)
            assertError(try store.save("replacement", for: id), .invalidData)
            XCTAssertEqual(try Data(contentsOf: file()), bytes)
            try assertNoTemporaryFiles()
        }
    }

    func testEmptyAndOversizedNewTokensPreserveExistingCredential() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        for token in ["", " \n", String(repeating: "a", count: LocalCredentialStore.maximumRecordBytes),
                      String(repeating: "😀", count: LocalCredentialStore.maximumRecordBytes / 2)] {
            assertError(try store.save(token, for: id), .invalidData)
            XCTAssertEqual(try Data(contentsOf: file()), original)
        }
        let accepted = String(repeating: "x", count: 63_000)
        try store.save(accepted, for: id)
        XCTAssertEqual(try store.read(for: id), accepted)
    }

    func testWriteStageFailuresKeepOriginalAndCleanTemporaryFiles() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        for failureStage in [LocalCredentialStore.WriteStage.beforeWrite, .beforeSynchronize, .beforePublish] {
            let failing = LocalCredentialStore(directory: directory, writeHook: { stage, _ in
                if stage == failureStage { throw SyntheticFailure.expected }
            })
            assertError(try failing.save("replacement", for: id), .saveFailed)
            XCTAssertEqual(try Data(contentsOf: file()), original)
            XCTAssertEqual(try store.read(for: id), "original")
            try assertNoTemporaryFiles()
        }
    }

    func testFileSyncFailureKeepsOriginalAndCleansTemporaryFile() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let original = try Data(contentsOf: file())
        var attemptedSync = false
        let failing = LocalCredentialStore(directory: directory, synchronizeFile: { _ in
            attemptedSync = true
            return -1
        })
        assertError(try failing.save("replacement", for: id), .saveFailed)
        XCTAssertTrue(attemptedSync)
        XCTAssertEqual(try Data(contentsOf: file()), original)
        try assertNoTemporaryFiles()
    }

    func testDestinationChangedToLinkBeforePublishIsNotFollowedOrOverwritten() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("original", for: id)
        let outside = root.appendingPathComponent("outside-token")
        try Data("outside-unchanged".utf8).write(to: outside)
        let destination = file()
        let racing = LocalCredentialStore(directory: directory, writeHook: { stage, _ in
            guard stage == .beforePublish else { return }
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        })
        assertError(try racing.save("replacement", for: id), .unsafeLocation)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-unchanged".utf8))
        try assertNoTemporaryFiles()
    }

    func testConcurrentStoresReadOnlyCompleteRecordsAndLeaveNoTemporaryFiles() throws {
        let shared = LocalCredentialStore(directory: directory)
        try shared.save("token-seed", for: id)
        let directory = try XCTUnwrap(directory)
        let id = self.id
        let failures = CredentialFailures()
        DispatchQueue.concurrentPerform(iterations: 60) { index in
            do {
                let store = index.isMultiple(of: 2) ? shared : LocalCredentialStore(directory: directory)
                try store.save("token-\(index)", for: id)
                let value = try store.read(for: id)
                if !value.hasPrefix("token-") { failures.record("Incomplete record") }
            } catch { failures.record(String(describing: error)) }
        }
        XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "; "))
        XCTAssertTrue(try shared.read(for: id).hasPrefix("token-"))
        try assertNoTemporaryFiles()
    }

    func testRemoveIsIdempotentAndDoesNotRemoveOtherFilesOrDirectories() throws {
        let store = LocalCredentialStore(directory: directory)
        try store.save("token", for: id)
        let unrelated = directory.appendingPathComponent("unrelated")
        try Data("preserved".utf8).write(to: unrelated)
        try store.remove(for: id)
        try store.remove(for: id)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("preserved".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnsafeURLAndMissingPrivateParentFailWithoutCreatingDirectories() throws {
        assertError(try LocalCredentialStore(directory: URL(string: "https://example.test/Credentials")!).save("token", for: id), .unsafeLocation)
        for spelling in [directory.absoluteString + "?query=fixture", directory.absoluteString + "#fragment",
                         "file://fixture-user@localhost" + directory.path,
                         "file://example.test" + directory.path] {
            let unsafe = try XCTUnwrap(URL(string: spelling))
            assertError(try LocalCredentialStore(directory: unsafe).save("token", for: id), .unsafeLocation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        let missing = root.appendingPathComponent("missing/Credentials")
        assertError(try LocalCredentialStore(directory: missing).save("token", for: id), .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }
}

private enum SyntheticFailure: Error { case expected }

private final class CredentialFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; stored.append(message) }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
