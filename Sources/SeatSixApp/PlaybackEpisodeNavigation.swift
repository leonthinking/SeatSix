import SwiftUI
import SeatSixCore

enum EpisodeNavigationPresentation {
    static func episodes(in sequence: EpisodeSequence, selectedSeasonID: String) -> [MediaItem] {
        guard !selectedSeasonID.isEmpty,
              sequence.displaySeasons.contains(where: { $0.id == selectedSeasonID }) else {
            return sequence.orderedEpisodes
        }
        return sequence.episodes(in: selectedSeasonID)
    }

    static func seasonID(for episodeID: String, in sequence: EpisodeSequence) -> String {
        let candidates = sequence.displaySeasons.filter { season in
            sequence.episodes(in: season.id).contains { $0.id == episodeID }
        }
        return candidates.count == 1 ? candidates[0].id : ""
    }

    static func recoveryTime(ticks: Int64) -> String {
        let seconds = max(0, ticks) / 10_000_000
        if seconds >= 3_600 {
            return String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}

/// Shared by both playback engines; actions replace the episode inside the existing window.
struct PlaybackEpisodeNavigation: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController
    var showsTransport = true
    @State private var showingEpisodes = false
    @State private var showingSkipSettings = false
    @State private var selectedSeasonID = ""
    private let selectionOwner = "episode-selection"
    private let recoveryOwner = "episode-recovery"
    private let skipSettingsOwner = "episode-skip-settings"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if showsTransport {
                    Button {
                        if let previous = controller.episodeSequence?.previous(before: controller.item.id) {
                            select(previous)
                        }
                    } label: {
                        Label("上一集", systemImage: "backward.end.fill")
                    }
                    .disabled(!controller.canSelectEpisode || controller.episodeSequence?.previous(before: controller.item.id) == nil)
                    .help("保存当前集进度，播放上一集")
                    .accessibilityLabel("上一集")
                }

                Button { showingEpisodes.toggle() } label: {
                    Label("选集", systemImage: "list.bullet")
                }
                .disabled(!controller.canSelectEpisode)
                .accessibilityLabel("播放器内选集")
                .popover(isPresented: $showingEpisodes, arrowEdge: .bottom) {
                    if let sequence = controller.episodeSequence { episodePicker(sequence) }
                }

                if showsTransport {
                    Button {
                        if let next = controller.episodeSequence?.next(after: controller.item.id) {
                            select(next)
                        }
                    } label: {
                        Label("下一集", systemImage: "forward.end.fill")
                    }
                    .disabled(!controller.canSelectEpisode || controller.episodeSequence?.next(after: controller.item.id) == nil)
                    .help("保存当前集进度，播放下一集")
                    .accessibilityLabel("下一集")
                }

                Button { showingSkipSettings.toggle() } label: {
                    Label("片头片尾", systemImage: "forward.frame")
                }
                .disabled(!controller.canConfigureSeriesSkip)
                .help("为这部剧设置跳过片头和片尾的时长")
                .accessibilityLabel("片头片尾设置")
                .popover(isPresented: $showingSkipSettings, arrowEdge: .bottom) {
                    PlaybackEpisodeSkipSettings(controller: controller)
                }

                Spacer(minLength: 0)
                Toggle("自动播放下一集", isOn: $controller.autoPlayNextEpisode)
                    .toggleStyle(.checkbox).font(.caption)
            }.controlSize(.small).buttonStyle(.borderless)

            if controller.switchingEpisode {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.episodeRecoveryChoice == nil ? "正在切换单集…" : "请选择续播位置")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if controller.episodeSequence == nil {
                Text("暂时没有完整分集列表，请返回剧集详情重新加载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let recovery = controller.episodeRecoveryChoice {
                recoveryChoices(localTicks: recovery.localTicks, remoteTicks: recovery.remoteTicks)
            }
        }
        .onAppear {
            chooseCurrentSeason()
            interaction.setPopoverOpen(showingEpisodes, owner: selectionOwner)
            interaction.setPopoverOpen(controller.episodeRecoveryChoice != nil, owner: recoveryOwner)
            interaction.setPopoverOpen(showingSkipSettings, owner: skipSettingsOwner)
        }
        .onChange(of: controller.item.id) { chooseCurrentSeason() }
        .onChange(of: showingEpisodes) { interaction.setPopoverOpen(showingEpisodes, owner: selectionOwner) }
        .onChange(of: showingSkipSettings) { interaction.setPopoverOpen(showingSkipSettings, owner: skipSettingsOwner) }
        .onChange(of: controller.episodeRecoveryChoice != nil) {
            interaction.setPopoverOpen(controller.episodeRecoveryChoice != nil, owner: recoveryOwner)
        }
        .onDisappear {
            interaction.setPopoverOpen(false, owner: selectionOwner)
            interaction.setPopoverOpen(false, owner: recoveryOwner)
            interaction.setPopoverOpen(false, owner: skipSettingsOwner)
        }
    }

    private func episodePicker(_ sequence: EpisodeSequence) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择单集").font(.headline)
                Spacer()
                if !sequence.displaySeasons.isEmpty {
                    Picker("选集季", selection: $selectedSeasonID) {
                        Text("全部季").tag("")
                        ForEach(sequence.displaySeasons) { season in
                            Text(EpisodeDisplay.season(season)).tag(season.id)
                        }
                    }.labelsHidden().frame(width: 150)
                }
            }
            let episodes = EpisodeNavigationPresentation.episodes(in: sequence, selectedSeasonID: selectedSeasonID)
            if episodes.isEmpty {
                Text("这一季还没有可播放的单集。").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(episodes) { episode in
                                episodeRow(episode).id(episode.id)
                            }
                        }
                    }
                    .frame(height: min(400, CGFloat(episodes.count) * 68))
                    .onAppear { proxy.scrollTo(controller.item.id, anchor: .center) }
                }
            }
            Divider()
            Text("切换前保存当前集，各集分别续播。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 440)
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        let current = episode.id == controller.item.id
        return HStack(spacing: 10) {
            Button { select(episode) } label: {
                HStack(spacing: 10) {
                    Image(systemName: current ? "play.circle.fill" : "play.circle")
                        .font(.system(size: 20)).foregroundStyle(current ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.name.isEmpty ? EpisodeDisplay.number(episode) : episode.name)
                            .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        HStack(spacing: 7) {
                            Text(EpisodeDisplay.number(episode))
                            if current { Text("当前集").foregroundStyle(Color.accentColor) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled((current && controller.isActive) || !controller.canSelectEpisode)
            .accessibilityLabel("\(EpisodeDisplay.number(episode))，\(episode.name)，\(current ? "当前集" : "播放本集")")

            Button("从头播放") { select(episode, fromBeginning: true) }
                .buttonStyle(.borderless).font(.caption)
                .disabled(!controller.canSelectEpisode)
                .accessibilityLabel("\(EpisodeDisplay.number(episode))，\(episode.name)，从头播放")
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(current ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func recoveryChoices(localTicks: Int64, remoteTicks: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("这集有两个续播位置").font(.system(size: 13, weight: .semibold))
            Text("当前集进度已保存，请选择目标单集的续播位置。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("本机 \(EpisodeNavigationPresentation.recoveryTime(ticks: localTicks))") {
                    controller.chooseEpisodeRecovery(local: true)
                }
                Button("服务器 \(EpisodeNavigationPresentation.recoveryTime(ticks: remoteTicks))") {
                    controller.chooseEpisodeRecovery(local: false)
                }
                Button("取消切换") { controller.cancelEpisodeRecovery() }
            }.controlSize(.small)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func chooseCurrentSeason() {
        guard let sequence = controller.episodeSequence else { selectedSeasonID = ""; return }
        selectedSeasonID = EpisodeNavigationPresentation.seasonID(for: controller.item.id, in: sequence)
    }

    private func select(_ episode: MediaItem, fromBeginning: Bool = false) {
        showingEpisodes = false
        interaction.setPopoverOpen(false, owner: selectionOwner)
        controller.selectEpisode(id: episode.id, fromBeginning: fromBeginning)
    }
}
