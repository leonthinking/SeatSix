import Foundation
import SeatSixCore
import SeatSixPlayback

enum PosterSize: String, Codable, CaseIterable, Sendable {
    case compact, standard, large
    var label: String { switch self { case .compact: return "紧凑"; case .standard: return "标准"; case .large: return "大" } }
    var gridMinimum: CGFloat { switch self { case .compact: return 120; case .standard: return 145; case .large: return 180 } }
    var gridMaximum: CGFloat { switch self { case .compact: return 160; case .standard: return 200; case .large: return 240 } }
    var homeWidth: CGFloat { switch self { case .compact: return 128; case .standard: return 152; case .large: return 184 } }
}

enum PlaybackTimeDisplay: String, Codable, CaseIterable, Sendable {
    case total, remaining
    var label: String { self == .total ? "总时长" : "剩余时长" }
}

enum DefaultSubtitleMode: String, Codable, CaseIterable, Sendable {
    case mediaDefault, preferredLanguage, off
    var label: String {
        switch self { case .mediaDefault: return "媒体默认"; case .preferredLanguage: return "按首选语言"; case .off: return "关闭" }
    }
}

enum MediaLanguage: String, Codable, CaseIterable, Sendable {
    case chinese, english, japanese, korean, french, german, spanish, cantonese
    var label: String {
        switch self {
        case .chinese: return "中文"; case .english: return "英语"; case .japanese: return "日语"
        case .korean: return "韩语"; case .french: return "法语"; case .german: return "德语"
        case .spanish: return "西班牙语"; case .cantonese: return "粤语"
        }
    }
}

enum StartupPage: String, Codable, CaseIterable, Sendable {
    case home, lastBrowsed
    var label: String { self == .home ? "首页" : "上次页面与片库" }
}

enum PlaybackWindowMode: String, Codable, CaseIterable, Sendable {
    case windowed, fullScreen
    var label: String { self == .windowed ? "普通窗口" : "全屏" }
}

extension LibrarySortOrder {
    var label: String {
        switch self {
        case .nameAscending: return "名称升序"
        case .nameDescending: return "名称降序"
        case .yearDescending: return "年份从新到旧"
        case .yearAscending: return "年份从旧到新"
        }
    }
}

/// Durable app defaults. Playback takes a snapshot; navigation and control
/// appearance consume the current value. Bad individual fields fall back safely.
struct ApplicationPreferences: Codable, Equatable, Sendable {
    var defaultLibrarySort: LibrarySortOrder = .nameAscending
    var posterSize: PosterSize = .standard
    var showRecentlyAdded = true
    var showHomeRecommendations = true
    var autoRotateHomeRecommendations = true
    var hideUnwatchedEpisodeOverview = false
    var startupPage: StartupPage = .home
    var sidebarWidth: Double = 192
    var sidebarCollapsed = false
    var autoPlayNextEpisode = true
    var rememberVolume = true
    var resumeRewindSeconds: Double = 0
    var playbackWindowMode: PlaybackWindowMode = .windowed
    var pauseWhenMinimized = false
    var keepPlaybackWindowOnTop = false
    var seekBackwardSeconds: Double = 10
    var seekForwardSeconds: Double = 10
    var autoHideControls = true
    var controlsHideDelay: Double = 3
    var timeDisplay: PlaybackTimeDisplay = .total
    var subtitleMode: DefaultSubtitleMode = .mediaDefault
    var preferredSubtitleLanguage: MediaLanguage = .chinese
    var preferredAudioLanguage: MediaLanguage?
    var subtitleFontSize: Double = 48
    var subtitleStyle: SubtitlePresentation.Style = .original

    var subtitlePresentation: SubtitlePresentation {
        SubtitlePresentation(fontSize: normalized.subtitleFontSize, style: subtitleStyle)
    }

    var normalized: Self {
        var result = self
        if ![5.0, 10, 15, 30, 60].contains(seekBackwardSeconds) { result.seekBackwardSeconds = 10 }
        if ![5.0, 10, 15, 30, 60].contains(seekForwardSeconds) { result.seekForwardSeconds = 10 }
        if ![2.0, 3, 5, 8].contains(controlsHideDelay) { result.controlsHideDelay = 3 }
        if ![32.0, 48, 60, 72].contains(subtitleFontSize) { result.subtitleFontSize = 48 }
        if ![0.0, 5, 10].contains(resumeRewindSeconds) { result.resumeRewindSeconds = 0 }
        result.sidebarWidth = Double(SidebarLayout.normalizedWidth(sidebarWidth))
        return result
    }

    init() {}
    private enum CodingKeys: String, CodingKey {
        case defaultLibrarySort, posterSize, showRecentlyAdded, autoPlayNextEpisode
        case seekBackwardSeconds, seekForwardSeconds, autoHideControls, controlsHideDelay
        case timeDisplay, subtitleMode, subtitleFontSize, subtitleStyle
        case startupPage, rememberVolume, resumeRewindSeconds, playbackWindowMode
        case preferredSubtitleLanguage, preferredAudioLanguage
        case hideUnwatchedEpisodeOverview, pauseWhenMinimized, keepPlaybackWindowOnTop
        case showHomeRecommendations, autoRotateHomeRecommendations
        case sidebarWidth, sidebarCollapsed
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultLibrarySort = (try? values.decode(LibrarySortOrder.self, forKey: .defaultLibrarySort)) ?? defaultLibrarySort
        posterSize = (try? values.decode(PosterSize.self, forKey: .posterSize)) ?? posterSize
        showRecentlyAdded = (try? values.decode(Bool.self, forKey: .showRecentlyAdded)) ?? showRecentlyAdded
        showHomeRecommendations = (try? values.decode(Bool.self, forKey: .showHomeRecommendations)) ?? showHomeRecommendations
        autoRotateHomeRecommendations = (try? values.decode(Bool.self, forKey: .autoRotateHomeRecommendations)) ?? autoRotateHomeRecommendations
        autoPlayNextEpisode = (try? values.decode(Bool.self, forKey: .autoPlayNextEpisode)) ?? autoPlayNextEpisode
        seekBackwardSeconds = (try? values.decode(Double.self, forKey: .seekBackwardSeconds)) ?? seekBackwardSeconds
        seekForwardSeconds = (try? values.decode(Double.self, forKey: .seekForwardSeconds)) ?? seekForwardSeconds
        autoHideControls = (try? values.decode(Bool.self, forKey: .autoHideControls)) ?? autoHideControls
        controlsHideDelay = (try? values.decode(Double.self, forKey: .controlsHideDelay)) ?? controlsHideDelay
        timeDisplay = (try? values.decode(PlaybackTimeDisplay.self, forKey: .timeDisplay)) ?? timeDisplay
        subtitleMode = (try? values.decode(DefaultSubtitleMode.self, forKey: .subtitleMode)) ?? subtitleMode
        subtitleFontSize = (try? values.decode(Double.self, forKey: .subtitleFontSize)) ?? subtitleFontSize
        subtitleStyle = (try? values.decode(SubtitlePresentation.Style.self, forKey: .subtitleStyle)) ?? subtitleStyle
        startupPage = (try? values.decode(StartupPage.self, forKey: .startupPage)) ?? startupPage
        sidebarWidth = (try? values.decode(Double.self, forKey: .sidebarWidth)) ?? sidebarWidth
        sidebarCollapsed = (try? values.decode(Bool.self, forKey: .sidebarCollapsed)) ?? sidebarCollapsed
        rememberVolume = (try? values.decode(Bool.self, forKey: .rememberVolume)) ?? rememberVolume
        resumeRewindSeconds = (try? values.decode(Double.self, forKey: .resumeRewindSeconds)) ?? resumeRewindSeconds
        playbackWindowMode = (try? values.decode(PlaybackWindowMode.self, forKey: .playbackWindowMode)) ?? playbackWindowMode
        preferredSubtitleLanguage = (try? values.decode(MediaLanguage.self, forKey: .preferredSubtitleLanguage)) ?? preferredSubtitleLanguage
        preferredAudioLanguage = try? values.decode(MediaLanguage.self, forKey: .preferredAudioLanguage)
        hideUnwatchedEpisodeOverview = (try? values.decode(Bool.self, forKey: .hideUnwatchedEpisodeOverview)) ?? hideUnwatchedEpisodeOverview
        pauseWhenMinimized = (try? values.decode(Bool.self, forKey: .pauseWhenMinimized)) ?? pauseWhenMinimized
        keepPlaybackWindowOnTop = (try? values.decode(Bool.self, forKey: .keepPlaybackWindowOnTop)) ?? keepPlaybackWindowOnTop
        self = normalized
    }
}

/// Audio state is remembered separately from defaults, so resetting a settings
/// page never destroys the user's last volume or a muted player's return volume.
struct PlaybackVolumeState: Codable, Equatable, Sendable {
    var volume: Double = 1
    var isMuted = false
    var volumeBeforeMute: Double = 1
    var normalized: Self {
        .init(volume: volume.isFinite ? min(1, max(0, volume)) : 1,
              isMuted: isMuted,
              volumeBeforeMute: volumeBeforeMute.isFinite && volumeBeforeMute > 0 ? min(1, volumeBeforeMute) : 1)
    }
}

struct BrowsingLocation: Codable, Equatable, Sendable {
    let connectionID: UUID
    let serverID: String
    let userID: String
    var page: String
    var libraryID: String?
    init(connection: ServerConnection, page: String, libraryID: String?) {
        connectionID = connection.id; serverID = connection.serverID; userID = connection.userID
        self.page = page; self.libraryID = libraryID
    }
    func belongs(to connection: ServerConnection) -> Bool {
        connectionID == connection.id && serverID == connection.serverID && userID == connection.userID
    }
}

enum ResumeRewindPolicy {
    static func startTicks(_ ticks: Int64, seconds: Double, isContinuation: Bool) -> Int64 {
        let position = max(0, ticks)
        guard !isContinuation, [5.0, 10].contains(seconds) else { return position }
        return position - min(position, Int64(seconds * 10_000_000))
    }
}

struct LibrarySortIdentity: Codable, Equatable, Sendable {
    let connectionID: UUID
    let serverID: String
    let userID: String
    let libraryID: String
    init(connection: ServerConnection, libraryID: String) {
        connectionID = connection.id; serverID = connection.serverID
        userID = connection.userID; self.libraryID = libraryID
    }
}

struct LibrarySortPreference: Codable, Equatable, Sendable {
    let identity: LibrarySortIdentity
    var sort: LibrarySortOrder
}
