import Darwin
import Foundation

enum CredentialStoreError: LocalizedError, Equatable {
    case notFound, unavailable, invalidData, unsafeLocation, saveFailed

    var errorDescription: String? {
        switch self {
        case .notFound: return "此服务器尚未在本机保存登录凭据，请重新登录。"
        case .unavailable: return "本机登录凭据暂不可用，请检查目录权限后重试。"
        case .invalidData: return "本机登录凭据已损坏或格式不受支持，未覆盖原文件。请先恢复或移除对应的本机凭据文件，再重新登录。"
        case .unsafeLocation: return "本机登录凭据的存储位置或权限不安全，未读取或修改凭据。"
        case .saveFailed: return "无法保存本机登录凭据，请检查磁盘空间和目录权限后重试。"
        }
    }
}

/// Stores access tokens only. It never reads, migrates, or removes Keychain items.
/// Every operation resolves the two private directory components without following
/// links, then uses that directory descriptor for all file operations.
final class LocalCredentialStore: @unchecked Sendable {
    static let maximumRecordBytes = 64 * 1024

    enum WriteStage { case beforeWrite, beforeSynchronize, beforePublish }
    typealias WriteHook = (WriteStage, Int32) throws -> Void

    private struct Record: Codable {
        let version: Int
        let connectionID: UUID
        let token: String
    }

    private let directory: URL
    private let lock = NSLock()
    private let writeHook: WriteHook?
    private let synchronizeFile: (Int32) -> Int32

    init(directory: URL, writeHook: WriteHook? = nil,
         synchronizeFile: @escaping (Int32) -> Int32 = { fsync($0) }) {
        self.directory = directory
        self.writeHook = writeHook
        self.synchronizeFile = synchronizeFile
    }

    func read(for id: UUID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let directoryFD = try openDirectory(create: false)
        defer { Darwin.close(directoryFD) }
        return try Self.readToken(in: directoryFD, for: id)
    }

    private static func readToken(in directoryFD: Int32, for id: UUID) throws -> String {
        let file = Self.fileName(for: id)
        guard try existingFile(in: directoryFD, named: file) != nil else { throw CredentialStoreError.notFound }
        let descriptor = openat(directoryFD, file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CredentialStoreError.notFound }
            if errno == ELOOP || errno == ENOTDIR { throw CredentialStoreError.unsafeLocation }
            throw CredentialStoreError.unavailable
        }
        defer { Darwin.close(descriptor) }
        // An atomic replacement can unlink the opened, otherwise valid old
        // inode before fstat. Reading that immutable open snapshot is safe.
        let metadata = try Self.fileMetadata(descriptor, allowUnlinked: true)
        guard metadata.st_size > 0, metadata.st_size <= Self.maximumRecordBytes else {
            throw CredentialStoreError.invalidData
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bytes.count <= Self.maximumRecordBytes {
            let remaining = Self.maximumRecordBytes + 1 - bytes.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, remaining))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw CredentialStoreError.unavailable
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard bytes.count <= Self.maximumRecordBytes,
              let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.version == 1, record.connectionID == id,
              Self.isValidToken(record.token) else { throw CredentialStoreError.invalidData }
        return record.token
    }

    func save(_ token: String, for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isValidToken(token), token.utf8.count <= Self.maximumRecordBytes else {
            throw CredentialStoreError.invalidData
        }
        let bytes: Data
        do { bytes = try JSONEncoder().encode(Record(version: 1, connectionID: id, token: token)) }
        catch { throw CredentialStoreError.invalidData }
        guard bytes.count <= Self.maximumRecordBytes else { throw CredentialStoreError.invalidData }
        let directoryFD = try openDirectory(create: true)
        defer { Darwin.close(directoryFD) }
        let file = Self.fileName(for: id)
        if try Self.existingFile(in: directoryFD, named: file) != nil {
            _ = try Self.readToken(in: directoryFD, for: id)
        }
        let temporary = ".credential-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw CredentialStoreError.saveFailed }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = unlinkat(directoryFD, temporary, 0) }
        }
        // O_CREAT starts at 0600 (or narrower under umask); never create a
        // readable temporary and tighten its permissions after writing secrets.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw CredentialStoreError.saveFailed }
        try Self.requireNoExtendedACL(descriptor)
        do {
            try writeHook?(.beforeWrite, descriptor)
            // POSIX mode bits do not remove inherited macOS ACL entries. Check
            // the actual open file again immediately before writing any token.
            try Self.requireNoExtendedACL(descriptor)
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw CredentialStoreError.saveFailed }
                    offset += count
                }
            }
            try writeHook?(.beforeSynchronize, descriptor)
            guard synchronizeFile(descriptor) == 0 else { throw CredentialStoreError.saveFailed }
            try writeHook?(.beforePublish, descriptor)
        } catch let error as CredentialStoreError { throw error }
        catch { throw CredentialStoreError.saveFailed }

        let written = try Self.fileMetadata(descriptor)
        guard let named = try Self.existingFile(in: directoryFD, named: temporary),
              named.st_dev == written.st_dev, named.st_ino == written.st_ino else {
            throw CredentialStoreError.unsafeLocation
        }
        // Revalidate the destination immediately before replacement. The rename
        // itself never follows a destination link, even if another process swaps it.
        if try Self.existingFile(in: directoryFD, named: file) != nil {
            _ = try Self.readToken(in: directoryFD, for: id)
        }
        guard renameat(directoryFD, temporary, directoryFD, file) == 0 else {
            throw CredentialStoreError.saveFailed
        }
        published = true
        // renameat is the commit point. A later directory-sync failure cannot be
        // reported as an unchanged token; power-loss durability is best effort.
        _ = fsync(directoryFD)
    }

    func remove(for id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let directoryFD: Int32
        do { directoryFD = try openDirectory(create: false) }
        catch CredentialStoreError.notFound { return }
        defer { Darwin.close(directoryFD) }
        let file = Self.fileName(for: id)
        guard try Self.existingFile(in: directoryFD, named: file) != nil else { return }
        guard unlinkat(directoryFD, file, 0) == 0 else {
            if errno == ENOENT { return }
            throw CredentialStoreError.saveFailed
        }
        _ = fsync(directoryFD)
    }

    private static func fileName(for id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    private static func isValidToken(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        guard directory.isFileURL, [nil, "", "localhost"].contains(directory.host),
              [directory.user, directory.password, directory.query, directory.fragment].allSatisfy({ $0 == nil })
        else { throw CredentialStoreError.unsafeLocation }
        let target = directory.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        let publicAncestor = parent.deletingLastPathComponent()
        guard !target.lastPathComponent.isEmpty, target.lastPathComponent != "/",
              !parent.lastPathComponent.isEmpty, parent.lastPathComponent != "/" else {
            throw CredentialStoreError.unsafeLocation
        }
        // Public ancestors (for example ~/Library/Application Support or the
        // system's /var alias) may have shared permissions. Do not chmod them.
        let ancestorFD = Darwin.open(publicAncestor.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard ancestorFD >= 0 else { throw CredentialStoreError.unavailable }
        defer { Darwin.close(ancestorFD) }
        let parentFD = openat(ancestorFD, parent.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw Self.directoryOpenError() }
        defer { Darwin.close(parentFD) }
        var parentMetadata = stat()
        guard fstat(parentFD, &parentMetadata) == 0 else { throw CredentialStoreError.unavailable }
        guard parentMetadata.st_mode & S_IFMT == S_IFDIR, parentMetadata.st_uid == geteuid(),
              parentMetadata.st_mode & mode_t(0o022) == 0 else { throw CredentialStoreError.unsafeLocation }
        try Self.requireNoExtendedACL(parentFD)

        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = openat(parentFD, target.lastPathComponent, flags)
        if descriptor < 0, errno == ENOENT, create {
            guard mkdirat(parentFD, target.lastPathComponent, mode_t(0o700)) == 0 || errno == EEXIST else {
                throw CredentialStoreError.saveFailed
            }
            descriptor = openat(parentFD, target.lastPathComponent, flags)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { throw CredentialStoreError.notFound }
            throw Self.directoryOpenError()
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw CredentialStoreError.unavailable }
            guard metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == geteuid() else {
                throw CredentialStoreError.unsafeLocation
            }
            try Self.requireNoExtendedACL(descriptor)
            guard fchmod(descriptor, mode_t(0o700)) == 0 else { throw CredentialStoreError.unavailable }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func directoryOpenError() -> CredentialStoreError {
        if errno == ELOOP || errno == ENOTDIR { return .unsafeLocation }
        return .unavailable
    }

    private static func fileMetadata(_ descriptor: Int32, allowUnlinked: Bool = false) throws -> stat {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw CredentialStoreError.unavailable }
        try validateFile(metadata, allowUnlinked: allowUnlinked)
        try requireNoExtendedACL(descriptor)
        return metadata
    }

    private static func existingFile(in directoryFD: Int32, named file: String) throws -> stat? {
        var metadata = stat()
        guard fstatat(directoryFD, file, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw CredentialStoreError.unavailable
        }
        // fstatat may resolve an entry just before another instance atomically
        // replaces it, then report the unlinked old inode. Zero links are safe;
        // more than one still indicates a hard link and must be rejected.
        try validateFile(metadata, allowUnlinked: true)
        // ACLs must be inspected through a no-follow descriptor too, including
        // for remove: mode 0600 alone does not establish exclusive access.
        let descriptor = openat(directoryFD, file, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR { throw CredentialStoreError.unsafeLocation }
            throw CredentialStoreError.unavailable
        }
        defer { Darwin.close(descriptor) }
        return try fileMetadata(descriptor, allowUnlinked: true)
    }

    private static func requireNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT when an existing open descriptor has no
            // extended ACL. Other retrieval errors must still fail closed.
            if errno == ENOENT { return }
            throw CredentialStoreError.unavailable
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw CredentialStoreError.unavailable }
        var entry: acl_entry_t?
        errno = 0
        let result = acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry)
        // Darwin returns 0 for an entry, and -1/EINVAL for an empty valid ACL.
        if result == 0 { throw CredentialStoreError.unsafeLocation }
        guard result == -1, errno == EINVAL else { throw CredentialStoreError.unavailable }
    }

    private static func validateFile(_ metadata: stat, allowUnlinked: Bool = false) throws {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), (metadata.st_nlink == 1 || (allowUnlinked && metadata.st_nlink == 0)),
              metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw CredentialStoreError.unsafeLocation
        }
    }
}
