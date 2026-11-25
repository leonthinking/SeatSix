import SwiftUI
import SeatSixCore

/// Presentation derived from authoritative user state, without changing playback decisions.
enum BrowsePresentation {
    static func playbackTitle(_ item: MediaItem) -> String {
        let position = durationText(Double(max(0, item.userData.playbackPositionTicks)) / 10_000_000)
        let episode = item.type == "Episode" ? EpisodeDisplay.number(item) : nil
        if item.userData.played {
            return episode.map { "重新观看 · \($0)" } ?? "重新观看"
        }
        if item.userData.playbackPositionTicks > 0 {
            return episode.map { "继续 · \($0) · \(position)" } ?? "继续播放 · \(position)"
        }
        return episode.map { "播放 · \($0)" } ?? "播放影片"
    }

    static func continueSubtitle(_ item: MediaItem) -> String {
        // A series summary is not an episode clock. Resolve it before showing a time.
        guard item.isPlayable else { return "确认分集后继续观看" }
        let position = Double(max(0, item.userData.playbackPositionTicks)) / 10_000_000
        let clock = item.durationSeconds > position
            ? "剩余 " + durationText(item.durationSeconds - position)
            : "已观看 " + durationText(position)
        return item.type == "Episode" ? EpisodeDisplay.number(item) + " · " + clock : clock
    }

    static func filterSummary(query: String, year: Int?, genre: String?, watched: LibraryWatchFilter,
                              favoritesOnly: Bool, sort: LibrarySortOrder) -> String {
        var labels: [String] = []
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { labels.append("搜索：" + query.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let year { labels.append(String(year)) }
        if let genre { labels.append(genre) }
        if watched == .watched { labels.append("已看") }
        if watched == .unwatched { labels.append("未看") }
        if favoritesOnly { labels.append("只看收藏") }
        switch sort {
        case .nameAscending: labels.append("名称升序")
        case .nameDescending: labels.append("名称降序")
        case .yearDescending: labels.append("年份从新到旧")
        case .yearAscending: labels.append("年份从旧到新")
        }
        return labels.joined(separator: " · ")
    }
}

struct PlaybackVersionSelection {
    private(set) var id = ""
    private var explicit = false
    private var invalidated = false
    private(set) var requiresChoice = false

    mutating func select(_ id: String) {
        self.id = id; explicit = !id.isEmpty; invalidated = false; requiresChoice = id.isEmpty
    }
    mutating func update(sourceIDs: [String]) {
        if explicit, !sourceIDs.contains(id) { invalidated = true; explicit = false; id = "" }
        if explicit { requiresChoice = false; return }
        requiresChoice = invalidated || sourceIDs.count > 1
        id = !requiresChoice && sourceIDs.count == 1 ? sourceIDs[0] : ""
    }
}

extension View {
    /// Hiding a browse route must not destroy its NSScrollView or expose hidden controls.
    func browseVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .shelfRefreshRegionsVisible(visible)
            .allowsHitTesting(visible)
            // AppKit can expose an embedded scroll view's children even when
            // its SwiftUI route is hidden. Collapse that subtree at its root.
            .accessibilityElement(children: visible ? .contain : .ignore)
            .accessibilityHidden(!visible)
            .disabled(!visible)
    }
}
