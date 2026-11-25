import Darwin
import Foundation
import SeatSixCore
import SeatSixPlayback

struct FilmPlaybackIdentity: Codable, Hashable, Sendable {
    let connectionID: UUID
    let serverID: String
    let userID: String
    let itemID: String
    let mediaSourceID: String

    init(connectionID: UUID, serverID: String, userID: String, itemID: String, mediaSourceID: String) {
        self.connectionID = connectionID; self.serverID = serverID; self.userID = userID
        self.itemID = itemID; self.mediaSourceID = mediaSourceID
    }

    init(connection: ServerConnection, itemID: String, mediaSourceID: String) {
        self.init(connectionID: connection.id, serverID: connection.serverID, userID: connection.userID,
                  itemID: itemID, mediaSourceID: mediaSourceID)
    }
}

/// mpv track IDs belong to one loaded file. A persisted choice instead identifies
/// the track's metadata, with an occurrence only for truly identical signatures.
struct SavedTrackSelection: Codable, Equatable, Sendable {
    struct Signature: Codable, Equatable, Sendable {
        let kind: String
        let title: String?
        let language: String?
        let codec: String?
        let isDefault: Bool
        let isForced: Bool
        let isExternal: Bool
        let channelCount: Int?

        init(_ track: LocalPlaybackTrack) {
            kind = track.kind.rawValue
            title = Self.normalized(track.title)
            language = Self.normalized(track.language)
            codec = Self.normalized(track.codec)
            isDefault = track.isDefault; isForced = track.isForced; isExternal = track.isExternal
            channelCount = track.channelCount
        }
        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return result.isEmpty ? nil : result
        }
    }
    let signature: Signature
    let occurrence: Int
    let matchingCount: Int

    init(track: LocalPlaybackTrack, among tracks: [LocalPlaybackTrack]) {
        let signature = Signature(track)
        self.signature = signature
        let matching = tracks.filter { Signature($0) == signature }
        occurrence = matching.firstIndex { $0.id == track.id } ?? 0
        matchingCount = matching.count
    }

    func resolve(in tracks: [LocalPlaybackTrack]) -> Int? {
        let matching = tracks.filter { Signature($0) == signature }
        // A formerly ambiguous signature becoming unique may mean the chosen
        // track was deleted. Falling back to the remaining track would be wrong.
        guard matchingCount > 0, matching.count == matchingCount,
              occurrence >= 0, occurrence < matching.count else { return nil }
        return matching[occurrence].id
    }
}

struct ArchivedSubtitle: Codable, Equatable, Hashable, Sendable {
    let connectionID: UUID
    let id: UUID
    let displayName: String
    let fileExtension: String
}

/// A server may reuse a stream index after replacing a sidecar subtitle. Keep
/// descriptive metadata as well as the scoped ID, and never guess a replacement.
struct SavedServerSubtitleSelection: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let language: String?
    let fileExtension: String
    let isDefault: Bool
    let isForced: Bool

    init(_ subtitle: ServerSubtitle) {
        id = subtitle.id; title = subtitle.title; language = subtitle.language
        fileExtension = subtitle.fileExtension; isDefault = subtitle.isDefault; isForced = subtitle.isForced
    }

    func resolve(in subtitles: [ServerSubtitle]) -> ServerSubtitle? {
        // An older record containing only an ID is intentionally unverifiable.
        guard !fileExtension.isEmpty else { return nil }
        let matching = subtitles.filter { Self($0) == self }
        return matching.count == 1 ? matching[0] : nil
    }

    private enum CodingKeys: String, CodingKey { case id, title, language, fileExtension, isDefault, isForced }
    init(from decoder: Decoder) throws {
        if let legacyID = try? decoder.singleValueContainer().decode(String.self) {
            id = legacyID; title = ""; language = nil; fileExtension = ""; isDefault = false; isForced = false
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        fileExtension = try values.decode(String.self, forKey: .fileExtension)
        isDefault = try values.decode(Bool.self, forKey: .isDefault)
        isForced = try values.decode(Bool.self, forKey: .isForced)
    }
}

enum SavedSubtitleSelection: Codable, Equatable, Sendable {
    case off
    case embedded(SavedTrackSelection)
    case server(SavedServerSubtitleSelection)
    case local(ArchivedSubtitle)
}

struct FilmPlaybackPreferences: Codable, Equatable, Sendable {
    let identity: FilmPlaybackIdentity
    var audio: SavedTrackSelection?
    var subtitle: SavedSubtitleSelection?
    private var subtitleDelaySeconds: Double
    private(set) var subtitleFontSizeOverride: Double?
    private(set) var subtitleStyleOverride: SubtitlePresentation.Style?
    /// Compatibility for explicit callers: assigning a complete presentation
    /// intentionally overrides both appearance fields, even at standard values.
    var presentation: SubtitlePresentation {
        get { resolvedPresentation(defaults: .init()) }
        set {
            subtitleDelaySeconds = newValue.delaySeconds
            subtitleFontSizeOverride = newValue.fontSize
            subtitleStyleOverride = newValue.style
        }
    }
    var updatedAt: Date

    init(identity: FilmPlaybackIdentity, audio: SavedTrackSelection? = nil,
         subtitle: SavedSubtitleSelection? = nil, presentation: SubtitlePresentation? = nil, updatedAt: Date = Date()) {
        self.identity = identity; self.audio = audio; self.subtitle = subtitle
        subtitleDelaySeconds = presentation?.delaySeconds ?? 0
        subtitleFontSizeOverride = presentation?.fontSize
        subtitleStyleOverride = presentation?.style
        self.updatedAt = updatedAt
    }

    func resolvedPresentation(defaults: SubtitlePresentation) -> SubtitlePresentation {
        SubtitlePresentation(delaySeconds: subtitleDelaySeconds,
                             fontSize: subtitleFontSizeOverride ?? defaults.fontSize,
                             style: subtitleStyleOverride ?? defaults.style)
    }

    mutating func setSubtitleDelay(_ seconds: Double) { subtitleDelaySeconds = seconds }
    mutating func setSubtitleFontSize(_ size: Double) { subtitleFontSizeOverride = size }
    mutating func setSubtitleStyle(_ style: SubtitlePresentation.Style) { subtitleStyleOverride = style }
    mutating func useApplicationSubtitleDefaults() {
        subtitleFontSizeOverride = nil
        subtitleStyleOverride = nil
    }

    /// An empty object explicitly means inheritance. Without this marker, an old
    /// presentation is retained in full: its standard values may be intentional.
    private struct PresentationOverrides: Codable {
        var fontSize: Double?
        var style: SubtitlePresentation.Style?
    }
    private enum CodingKeys: String, CodingKey { case identity, audio, subtitle, presentation, presentationOverrides, updatedAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(FilmPlaybackIdentity.self, forKey: .identity)
        audio = try values.decodeIfPresent(SavedTrackSelection.self, forKey: .audio)
        subtitle = try values.decodeIfPresent(SavedSubtitleSelection.self, forKey: .subtitle)
        let previous = try values.decodeIfPresent(SubtitlePresentation.self, forKey: .presentation)
        subtitleDelaySeconds = previous?.delaySeconds ?? 0
        if values.contains(.presentationOverrides) {
            let overrides = try values.decode(PresentationOverrides.self, forKey: .presentationOverrides)
            subtitleFontSizeOverride = overrides.fontSize
            subtitleStyleOverride = overrides.style
        } else {
            subtitleFontSizeOverride = previous?.fontSize
            subtitleStyleOverride = previous?.style
        }
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(identity, forKey: .identity)
        try values.encodeIfPresent(audio, forKey: .audio)
        try values.encodeIfPresent(subtitle, forKey: .subtitle)
        try values.encode(presentation, forKey: .presentation)
        try values.encode(PresentationOverrides(fontSize: subtitleFontSizeOverride, style: subtitleStyleOverride), forKey: .presentationOverrides)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

@MainActor
struct PlaybackPreferencesAccess {
    var load: (String) -> FilmPlaybackPreferences
    var save: (FilmPlaybackPreferences) throws -> Void
    var archive: (URL) async throws -> ArchivedSubtitle
    var url: (ArchivedSubtitle) throws -> URL
    var discard: (ArchivedSubtitle) -> Void
}

enum SubtitleArchiveError: LocalizedError {
    case invalidReference, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidReference: return "上次选择的外挂字幕已不可用，请重新添加。"
        case .unavailable: return "无法保存外挂字幕，请检查磁盘空间和目录权限后重试。"
        }
    }
}

/// Durable, private copies outlive the engine's temporary imports. References
/// contain no original path, bookmarks, server URLs, or credentials.
final class SubtitleArchive: @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func archive(url: URL, connectionID: UUID) async throws -> ArchivedSubtitle {
        // Await the real read even after cancellation, so the caller retains its
        // security scope until the descriptor has closed. Never read the source twice.
        let data = try await Task.detached(priority: .userInitiated) {
            try LocalPlaybackEngine.validatedSubtitleData(url: url)
        }.value
        try Task.checkCancellation()
        let reference = ArchivedSubtitle(connectionID: connectionID, id: UUID(),
                                         displayName: Self.safeDisplayName(url.deletingPathExtension().lastPathComponent),
                                         fileExtension: url.pathExtension.lowercased())
        let archive = self
        try await Task.detached(priority: .userInitiated) {
            try archive.write(data, reference: reference)
        }.value
        do { try Task.checkCancellation() }
        catch { discard(reference); throw error }
        return reference
    }

    func url(for reference: ArchivedSubtitle) throws -> URL {
        let url = try path(for: reference)
        try requireDirectory(directory)
        try requireDirectory(directory.appendingPathComponent(reference.connectionID.uuidString))
        try requireDirectory(url.deletingLastPathComponent())
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw SubtitleArchiveError.invalidReference
        }
        return url
    }

    func validateReference(_ reference: ArchivedSubtitle) throws {
        _ = try path(for: reference)
    }

    func discard(_ reference: ArchivedSubtitle) {
        guard let url = try? url(for: reference) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func removeConnection(_ connectionID: UUID) {
        let root = directory.appendingPathComponent(connectionID.uuidString, isDirectory: true)
        guard (try? requireDirectory(directory)) != nil, (try? requireDirectory(root)) != nil else { return }
        try? FileManager.default.removeItem(at: root)
    }

    /// Run when a new player starts, after the previous player has stopped.
    /// Keeping old imports during a live session lets its menu select them again.
    func prune(connectionID: UUID, keeping references: [ArchivedSubtitle]) {
        let root = directory.appendingPathComponent(connectionID.uuidString, isDirectory: true)
        guard (try? requireDirectory(directory)) != nil, (try? requireDirectory(root)) != nil,
              let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let keep = Set(references.filter { $0.connectionID == connectionID }.map(\.id))
        for child in contents {
            guard let id = UUID(uuidString: child.lastPathComponent), !keep.contains(id),
                  (try? requireDirectory(child)) != nil else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func write(_ data: Data, reference: ArchivedSubtitle) throws {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw SubtitleArchiveError.unavailable }
        let url = try path(for: reference)
        do {
            try makeDirectory(directory)
            try makeDirectory(directory.appendingPathComponent(reference.connectionID.uuidString, isDirectory: true))
            try makeDirectory(url.deletingLastPathComponent())
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw SubtitleArchiveError.unavailable }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            do { try handle.write(contentsOf: data); try handle.synchronize() }
            catch { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error }
        } catch { throw SubtitleArchiveError.unavailable }
    }

    private func path(for reference: ArchivedSubtitle) throws -> URL {
        guard ["srt", "ass", "ssa", "vtt"].contains(reference.fileExtension),
              reference.displayName == Self.safeDisplayName(reference.displayName), !reference.displayName.isEmpty else {
            throw SubtitleArchiveError.invalidReference
        }
        return directory.appendingPathComponent(reference.connectionID.uuidString, isDirectory: true)
            .appendingPathComponent(reference.id.uuidString, isDirectory: true)
            .appendingPathComponent(reference.displayName).appendingPathExtension(reference.fileExtension)
    }

    private func makeDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw SubtitleArchiveError.unavailable }
        try requireDirectory(url)
        guard chmod(url.path, 0o700) == 0 else { throw SubtitleArchiveError.unavailable }
    }

    private func requireDirectory(_ url: URL) throws {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
            throw SubtitleArchiveError.invalidReference
        }
    }

    private static func safeDisplayName(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) }
        let result = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { return "外挂字幕" }
        // Bound UTF-8 bytes as well as characters to stay below filesystem limits.
        var bounded = ""
        for character in result {
            let next = bounded + String(character)
            if next.utf8.count > 180 { break }
            bounded = next
        }
        return bounded.isEmpty ? "外挂字幕" : bounded
    }
}
