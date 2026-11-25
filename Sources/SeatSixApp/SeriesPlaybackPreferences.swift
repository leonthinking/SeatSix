import Foundation
import SeatSixCore

/// A series ID is meaningful only inside the account and connection that supplied it.
struct SeriesPlaybackIdentity: Codable, Hashable, Sendable {
    let connectionID: UUID
    let serverID: String
    let userID: String
    let seriesID: String

    init(connectionID: UUID, serverID: String, userID: String, seriesID: String) {
        self.connectionID = connectionID
        self.serverID = serverID
        self.userID = userID
        self.seriesID = seriesID
    }

    init(connection: ServerConnection, seriesID: String) {
        self.init(connectionID: connection.id, serverID: connection.serverID,
                  userID: connection.userID, seriesID: seriesID)
    }
}

struct SeriesSkipSettings: Codable, Equatable, Sendable {
    static let maximumSeconds = 1800
    var introSeconds: Int
    var outroSeconds: Int

    init(introSeconds: Int = 0, outroSeconds: Int = 0) {
        self.introSeconds = introSeconds
        self.outroSeconds = outroSeconds
    }

    var validationError: String? {
        let allowed = 0...Self.maximumSeconds
        return allowed.contains(introSeconds) && allowed.contains(outroSeconds)
            ? nil : "片头和片尾时长须为 0–1800 秒，0 表示关闭。"
    }

    @discardableResult
    func validated() throws -> Self {
        guard validationError == nil else { throw SeriesSkipSettingsError.invalidDuration }
        return self
    }

    private enum CodingKeys: String, CodingKey { case introSeconds, outroSeconds }
    init(from decoder: Decoder) throws {
        // A corrupt preference must not make saved connections or recovery points
        // unreadable. Disable this pair rather than guessing a different duration.
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let intro = try values.decodeIfPresent(Int.self, forKey: .introSeconds) ?? 0
            let outro = try values.decodeIfPresent(Int.self, forKey: .outroSeconds) ?? 0
            let candidate = Self(introSeconds: intro, outroSeconds: outro)
            self = candidate.validationError == nil ? candidate : Self()
        } catch {
            self.init()
        }
    }
}

enum SeriesSkipSettingsError: LocalizedError {
    case invalidDuration

    var errorDescription: String? { "片头和片尾时长须为 0–1800 秒，0 表示关闭。" }
}

struct SeriesPlaybackPreferences: Codable, Equatable, Sendable {
    let identity: SeriesPlaybackIdentity
    var settings: SeriesSkipSettings
    var updatedAt: Date

    init(identity: SeriesPlaybackIdentity, settings: SeriesSkipSettings = .init(), updatedAt: Date = Date()) {
        self.identity = identity
        self.settings = settings
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case identity, settings, updatedAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(SeriesPlaybackIdentity.self, forKey: .identity)
        settings = (try? values.decodeIfPresent(SeriesSkipSettings.self, forKey: .settings)) ?? .init()
        updatedAt = (try? values.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? .distantPast
    }
}

@MainActor
struct SeriesPlaybackPreferencesAccess {
    var load: () -> SeriesSkipSettings
    var save: (SeriesSkipSettings) throws -> Void
}

/// Time decisions are deliberately independent of playback state transitions.
/// Seeking near the actual end allows the engine's normal EOF path to own progress
/// reporting and automatic continuation, rather than inventing a second completion.
enum EpisodeSkipPolicy {
    static func initialPosition(resumeSeconds: Double, duration: Double, settings: SeriesSkipSettings) -> Double {
        let resume = resumeSeconds.isFinite && resumeSeconds >= 0 ? resumeSeconds : 0
        guard isApplicable(duration: duration, settings: settings) else { return resume }
        return max(resume, Double(settings.introSeconds))
    }

    static func outroTarget(seconds: Double, duration: Double, settings: SeriesSkipSettings,
                            playing: Bool, seeking: Bool) -> Double? {
        guard playing, !seeking, seconds.isFinite, seconds >= 0, settings.outroSeconds > 0,
              isApplicable(duration: duration, settings: settings) else { return nil }
        let target = duration - 0.5
        guard seconds >= duration - Double(settings.outroSeconds), seconds < target else { return nil }
        return target
    }

    static func isApplicable(duration: Double, settings: SeriesSkipSettings) -> Bool {
        guard duration.isFinite, duration > 1, settings.validationError == nil else { return false }
        return Double(settings.introSeconds) + Double(settings.outroSeconds) < duration - 1
    }
}
