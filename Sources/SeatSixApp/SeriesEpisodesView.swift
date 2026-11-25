import SwiftUI
import SeatSixCore

enum EpisodeDisplay {
    static func season(_ item: MediaItem) -> String {
        if let number = item.indexNumber { return number == 0 ? "特别篇" : "第 \(number) 季" }
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "未编号季" : name
    }
    static func number(_ item: MediaItem) -> String {
        var parts: [String] = []
        if let season = item.parentIndexNumber { parts.append(season == 0 ? "特别篇" : "第 \(season) 季") }
        if let episode = item.indexNumber { parts.append("第 \(episode) 集") }
        return parts.isEmpty ? "未编号单集" : parts.joined(separator: " · ")
    }
    static func progress(_ item: MediaItem) -> Double {
        guard item.durationSeconds > 0 else { return 0 }
        return min(1, max(0, Double(item.userData.playbackPositionTicks) / 10_000_000 / item.durationSeconds))
    }
}

struct SeriesEpisodesView: View {
    @ObservedObject var model: ApplicationModel
    @Environment(\.detailArtworkAppearance) private var appearance
    let series: MediaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("分季与分集").font(.system(size: 19, weight: .semibold)).shelfRefreshRegion()
                Spacer()
                if !model.seriesPresentation.showsAll && !model.episodes.isEmpty {
                    Button("查看全部") { model.showAllEpisodes() }.buttonStyle(.link)
                        .accessibilityIdentifier("series-view-all")
                }
                if !model.seasons.isEmpty {
                    Picker("选择季", selection: Binding(get: { model.selectedSeasonID }, set: { model.selectSeason($0) })) {
                        Text("全部季").tag("")
                        ForEach(model.seasons) { Text(EpisodeDisplay.season($0)).tag($0.id) }
                    }.frame(maxWidth: 240).shelfRefreshRegion()
                }
            }
            if model.seriesLoading && model.episodes.isEmpty {
                episodeShelf {
                    ForEach(0..<(model.seriesPresentation.showsAll ? 12 : 6), id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 8).fill(appearance.placeholderFill)
                                .aspectRatio(16.0 / 9, contentMode: .fit)
                                .shelfRefreshRegion(cornerRadius: 8)
                            DetailPlaceholderLine(width: 100, font: .callout)
                            DetailPlaceholderLine(width: 65, font: .caption)
                            DetailPlaceholderLine(width: 52, font: .callout).frame(minHeight: 20)
                        }.modifier(EpisodeCardSurface()).frame(width: previewCardWidth)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore).accessibilityLabel("正在加载分集")
            } else if let error = model.seriesError {
                Text(error).foregroundStyle(appearance.warningText)
                Button("重新加载分集") { model.showDetail(series) }
            } else if model.episodes.isEmpty {
                Text("这一季还没有可播放的单集。").foregroundStyle(appearance.secondaryText).padding(.vertical, 28)
            } else {
                let batch = min(model.seriesPresentation.batch, (model.episodes.count - 1) / 10)
                episodeShelf {
                    if model.seriesPresentation.showsAll {
                        ForEach(model.episodes) { episodeCard($0) }
                    } else {
                        ForEach(model.episodes.dropFirst(batch * 10).prefix(10)) { episode in
                            episodeCard(episode).frame(width: previewCardWidth)
                        }
                    }
                }
                if !model.seriesPresentation.showsAll && model.episodes.count > 10 {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(0..<((model.episodes.count + 9) / 10), id: \.self) { index in
                                let first = index * 10 + 1
                                let last = min(first + 9, model.episodes.count)
                                Button(first == last ? "\(first)" : "\(first)-\(last)") { model.selectEpisodeBatch(index) }
                                    .buttonStyle(.bordered).tint(index == batch ? appearance.accentText : .secondary)
                            }
                        }
                    }
                }
            }
        }.padding(22).background(appearance.panelFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var previewCardWidth: CGFloat? { model.seriesPresentation.showsAll ? nil : 160 }

    @ViewBuilder
    private func episodeShelf<Cards: View>(@ViewBuilder cards: () -> Cards) -> some View {
        if model.seriesPresentation.showsAll {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], alignment: .leading, spacing: 12) {
                cards()
            }
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) { cards() }
            }
        }
    }

    private func episodeCard(_ episode: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.preview(episode) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    MediaPoster(model: model, item: episode, role: .landscape)
                        .aspectRatio(16.0 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            if model.previewEpisode?.id == episode.id {
                                RoundedRectangle(cornerRadius: 8).strokeBorder(appearance.accentText, lineWidth: 2)
                            }
                        }
                    Text(episode.name).font(.callout).lineLimit(1)
                    Text(EpisodeDisplay.number(episode)).font(.caption).foregroundStyle(appearance.secondaryText)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("选择 \(EpisodeDisplay.number(episode)) \(episode.name)")
            HStack {
                Button { model.resumeWatching(episode) } label: {
                    Label(BrowsePresentation.playbackTitle(episode), systemImage: "play.fill")
                }
                Spacer()
                ContentOverflowMenu(name: "更多分集操作，\(EpisodeDisplay.number(episode))", side: 24) {
                    if episode.userData.playbackPositionTicks > 0 {
                        Button("从头播放") { model.requestEpisodePlayback(episode, fromBeginning: true) }
                    }
                    Button("单集详情") { model.showDetail(episode) }
                }
            }.font(.caption).disabled(model.launchingPlayback || model.resumeLoadingID != nil || model.userStateBusy || model.userStateNeedsRefresh)
            if !episode.userData.played && episode.userData.playbackPositionTicks > 0 {
                ProgressView(value: EpisodeDisplay.progress(episode)).tint(appearance.accentText)
            }
        }.modifier(EpisodeCardSurface())
    }
}

private struct EpisodeCardSurface: ViewModifier {
    @Environment(\.detailArtworkAppearance) private var appearance

    func body(content: Content) -> some View {
        content.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(appearance.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .shelfRefreshRegion(cornerRadius: 8, isBackdrop: true)
    }
}
