import SwiftUI
import SeatSixCore

enum EpisodeOverviewContent: Equatable {
    case hidden
    case unavailable
    case overview(String)

    static func resolve(item: MediaItem, hideUnwatched: Bool, revealed: Bool) -> Self {
        guard let overview = item.overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        if hideUnwatched && item.type == "Episode" && !item.userData.played && !revealed {
            return .hidden
        }
        return .overview(overview)
    }
}

/// Reveal permission belongs to one detail visit and one account. A settings or
/// watched-state change starts a fresh permission, while metadata refreshes do not.
struct EpisodeOverviewScope: Hashable {
    let connectionID: UUID?
    let serverID: String?
    let userID: String?
    let itemID: String
    let itemType: String
    let played: Bool
    let hideUnwatched: Bool

    init(connection: ServerConnection?, item: MediaItem, hideUnwatched: Bool) {
        connectionID = connection?.id
        serverID = connection?.serverID
        userID = connection?.userID
        itemID = item.id
        itemType = item.type
        played = item.userData.played
        self.hideUnwatched = hideUnwatched
    }
}

struct MediaOverviewView: View {
    let connection: ServerConnection?
    let item: MediaItem
    let hideUnwatched: Bool
    @Binding var expanded: Bool
    var isLoading = false

    var body: some View {
        ScopedMediaOverviewView(item: item, hideUnwatched: hideUnwatched, expanded: $expanded, isLoading: isLoading)
            .id(EpisodeOverviewScope(connection: connection, item: item, hideUnwatched: hideUnwatched))
    }
}

private struct ScopedMediaOverviewView: View {
    let item: MediaItem
    let hideUnwatched: Bool
    @Binding var expanded: Bool
    let isLoading: Bool
    @State private var revealed = false
    @Environment(\.detailArtworkAppearance) private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch EpisodeOverviewContent.resolve(item: item, hideUnwatched: hideUnwatched, revealed: revealed) {
            case .hidden:
                // Do not construct the original Text: it must also be absent
                // from accessibility and text selection while concealed.
                Text("未看单集简介已隐藏")
                    .font(.system(size: 13)).foregroundStyle(appearance.secondaryText)
                    .accessibilityIdentifier("episode-overview-hidden")
                Button("显示本次简介") { revealed = true }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(appearance.accentText)
                    .accessibilityIdentifier("episode-overview-reveal")
            case .unavailable:
                if isLoading {
                    VStack(alignment: .leading, spacing: 6) {
                        DetailPlaceholderLine(width: 400, font: .system(size: 13))
                        DetailPlaceholderLine(width: 360, font: .system(size: 13))
                        DetailPlaceholderLine(width: 230, font: .system(size: 13))
                    }
                    .accessibilityElement(children: .ignore).accessibilityLabel("正在读取简介")
                } else {
                    overviewText("服务器尚未提供影片简介。")
                }
            case .overview(let overview):
                overviewText(overview)
                Button(expanded ? "收起简介" : "展开简介") { expanded.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(appearance.accentText)
                    .accessibilityIdentifier("episode-overview-expansion")
            }
        }
        .onDisappear { revealed = false }
    }

    private func overviewText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13)).lineSpacing(6).foregroundStyle(appearance.secondaryText)
            .lineLimit(expanded ? nil : 3).textSelection(.enabled)
            .accessibilityIdentifier("media-overview-text")
    }
}
