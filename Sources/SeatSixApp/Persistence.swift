import Darwin
import Foundation
import SeatSixCore

struct RecoveryPoint: Codable, Identifiable {
    var id: MediaIdentity { MediaIdentity(serverID: serverID, userID: userID, itemID: itemID) }
    let serverID: String
    let userID: String
    let itemID: String
    var ticks: Int64
    var updatedAt: Date
    var confirmed: Bool
}

/// A server mutation may succeed even when its response is lost. Persist its scope
/// before dispatch so restarting cannot silently re-enable stale recovery positions.
struct PendingUserState: Codable {
    let id: UUID
    let connectionID: UUID
    let serverID: String
    let userID: String
    let itemID: String
    let itemType: String
    let action: MediaUserStateAction
    let affectedIDs: Set<String>

    init(id: UUID = UUID(), connectionID: UUID, serverID: String, userID: String, itemID: String,
         itemType: String, action: MediaUserStateAction, affectedIDs: Set<String>) {
        self.id = id; self.connectionID = connectionID; self.serverID = serverID; self.userID = userID
        self.itemID = itemID; self.itemType = itemType; self.action = action; self.affectedIDs = affectedIDs
    }

    private enum CodingKeys: String, CodingKey { case id, connectionID, serverID, userID, itemID, itemType, action, affectedIDs }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older records gain an identity once loaded; subsequent saves retain it.
        // Matching payload fields cannot distinguish two identical user actions.
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        connectionID = try values.decode(UUID.self, forKey: .connectionID)
        serverID = try values.decode(String.self, forKey: .serverID)
        userID = try values.decode(String.self, forKey: .userID)
        itemID = try values.decode(String.self, forKey: .itemID)
        itemType = try values.decode(String.self, forKey: .itemType)
        action = try values.decode(MediaUserStateAction.self, forKey: .action)
        affectedIDs = try values.decode(Set<String>.self, forKey: .affectedIDs)
    }
}

struct SavedApplication: Codable {
    var connections: [ServerConnection] = []
    var selectedID: UUID?
    var deviceID: String = UUID().uuidString
    var recovery: [RecoveryPoint] = []
    var pendingUserStates: [PendingUserState] = []
    var playbackPreferences: [FilmPlaybackPreferences] = []
    var seriesPlaybackPreferences: [SeriesPlaybackPreferences] = []
    var applicationPreferences = ApplicationPreferences()
    var librarySortPreferences: [LibrarySortPreference] = []
    var playbackVolume = PlaybackVolumeState()
    var browsingLocations: [BrowsingLocation] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case connections, selectedID, deviceID, recovery, pendingUserStates, playbackPreferences, seriesPlaybackPreferences, applicationPreferences, librarySortPreferences, playbackVolume, browsingLocations }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        connections = try values.decodeIfPresent([ServerConnection].self, forKey: .connections) ?? []
        selectedID = try values.decodeIfPresent(UUID.self, forKey: .selectedID)
        deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID) ?? UUID().uuidString
        recovery = try values.decodeIfPresent([RecoveryPoint].self, forKey: .recovery) ?? []
        pendingUserStates = try values.decodeIfPresent([PendingUserState].self, forKey: .pendingUserStates) ?? []
        playbackPreferences = try values.decodeIfPresent([FilmPlaybackPreferences].self, forKey: .playbackPreferences) ?? []
        seriesPlaybackPreferences = (try? values.decodeIfPresent([SeriesPlaybackPreferences].self, forKey: .seriesPlaybackPreferences)) ?? []
        applicationPreferences = (try? values.decode(ApplicationPreferences.self, forKey: .applicationPreferences)) ?? .init()
        librarySortPreferences = (try? values.decode([LibrarySortPreference].self, forKey: .librarySortPreferences)) ?? []
        playbackVolume = ((try? values.decode(PlaybackVolumeState.self, forKey: .playbackVolume)) ?? .init()).normalized
        browsingLocations = (try? values.decode([BrowsingLocation].self, forKey: .browsingLocations)) ?? []
    }
}

protocol ApplicationPersisting {
    func load() throws -> SavedApplication
    func save(_ data: SavedApplication) throws
}

enum ApplicationPersistenceError: LocalizedError {
    case unavailable, saveFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "本地配置不可用；为保护已有数据，未保存此次更改。"
        case .saveFailed: return "无法保存本地状态，请检查磁盘空间和目录权限后重试。"
        }
    }
}

struct CredentialAccess {
    var read: (UUID) throws -> String
    var save: (String, UUID) throws -> Void
    var remove: (UUID) throws -> Void
    static func local(directory: URL) -> CredentialAccess {
        let store = LocalCredentialStore(directory: directory)
        return CredentialAccess(
            read: { try store.read(for: $0) },
            save: { try store.save($0, for: $1) },
            remove: { try store.remove(for: $0) }
        )
    }
}

final class ApplicationStorage: ApplicationPersisting {
    enum WriteStage { case beforeWrite, beforeSynchronize, beforePublish }
    static func defaultDirectory(in support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        let current = support.appendingPathComponent("SeatSix", isDirectory: true)
        let legacy = support.appendingPathComponent("Theater", isDirectory: true)
        var metadata = stat()
        // A previously saved profile wins even if it cannot currently be read.
        // A later backup restore or launching the old app must not switch profiles.
        if lstat(current.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else { return current }
            if lstat(current.appendingPathComponent("connections.json").path, &metadata) == 0 || errno != ENOENT {
                return current
            }
        } else if errno != ENOENT {
            return current
        }

        // Prefer a fresh SeatSix directory over an empty legacy placeholder. Keep
        // any partial legacy profile (including credentials or subtitles) together.
        guard lstat(legacy.path, &metadata) == 0 else { return errno == ENOENT ? current : legacy }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return legacy }
        let entries = try? FileManager.default.contentsOfDirectory(atPath: legacy.path)
        return entries?.isEmpty == true ? current : legacy
    }

    let directory: URL
    let file: URL
    private let writeHook: ((WriteStage, Int32) throws -> Void)?
    private let synchronizeFile: (Int32) -> Int32
    init(directory: URL? = nil, writeHook: ((WriteStage, Int32) throws -> Void)? = nil,
         synchronizeFile: @escaping (Int32) -> Int32 = { fsync($0) }) throws {
        self.writeHook = writeHook
        self.synchronizeFile = synchronizeFile
        self.directory = directory ?? Self.defaultDirectory()
        file = self.directory.appendingPathComponent("connections.json")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(self.directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ApplicationPersistenceError.unavailable
        }
    }
    func load() throws -> SavedApplication {
        var metadata = stat()
        if lstat(file.path, &metadata) == -1 {
            if errno == ENOENT { return SavedApplication() }
            throw ApplicationPersistenceError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ApplicationPersistenceError.unavailable }
        return try JSONDecoder().decode(SavedApplication.self, from: Data(contentsOf: file))
    }
    func save(_ data: SavedApplication) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(data)
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ApplicationPersistenceError.saveFailed }
        defer { Darwin.close(directoryFD) }
        let temporary = ".connections-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ApplicationPersistenceError.saveFailed }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { _ = unlinkat(directoryFD, temporary, 0) }
        }
        // Permissions and every fallible write step precede the commit point.
        // Reporting failure after publishing would make callers roll back only
        // the credential while the new connection configuration remained saved.
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw ApplicationPersistenceError.saveFailed }
        do {
            try writeHook?(.beforeWrite, descriptor)
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ApplicationPersistenceError.saveFailed }
                    offset += count
                }
            }
            try writeHook?(.beforeSynchronize, descriptor)
            guard synchronizeFile(descriptor) == 0 else { throw ApplicationPersistenceError.saveFailed }
            try writeHook?(.beforePublish, descriptor)
        } catch { throw ApplicationPersistenceError.saveFailed }
        guard renameat(directoryFD, temporary, directoryFD, file.lastPathComponent) == 0 else {
            throw ApplicationPersistenceError.saveFailed
        }
        published = true
        // As with credentials, a successful rename is the commit point.
        _ = fsync(directoryFD)
    }
}
