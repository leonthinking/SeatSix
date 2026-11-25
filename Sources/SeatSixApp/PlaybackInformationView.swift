import SwiftUI

struct PlaybackInfoButton: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController
    @State private var showingInfo = false
    // The window accessory and the full-screen overlay may briefly coexist during a transition.
    @State private var owner = UUID().uuidString

    var body: some View {
        Button { showingInfo.toggle() } label: {
            Image(systemName: "info")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .seatSixGlassButton()
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .frame(width: 32, height: 28)
        .accessibilityLabel("播放信息")
        .help("播放信息")
        .popover(isPresented: $showingInfo, arrowEdge: .top) {
            PlaybackInformationView(controller: controller, interaction: interaction)
        }
        .onChange(of: showingInfo) { _, open in interaction.setPopoverOpen(open, owner: owner) }
        .onChange(of: interaction.isFullScreen) { showingInfo = false }
        .onHover { interaction.setControlsHovered($0, owner: owner) }
        .onDisappear {
            interaction.setPopoverOpen(false, owner: owner)
            interaction.setControlsHovered(false, owner: owner)
        }
    }
}

struct PlaybackInformationView: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("播放信息").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                informationRow("来源", value: controller.connection.name, marker: "player-source")
                informationRow("播放方式", value: controller.playbackLabel)
                if controller.item.type == "Episode" {
                    informationRow("当前集", value: EpisodeDisplay.number(controller.item))
                }
                informationRow("进度同步", value: controller.syncMessage,
                               accessibilityLabel: "播放进度同步状态", marker: "player-sync")
            }
            if !interaction.isFullScreen {
                Divider()
                Toggle("窗口置顶", isOn: Binding(get: { controller.isWindowOnTop }, set: { pinned in
                    if pinned != controller.isWindowOnTop { controller.toggleWindowOnTop() }
                }))
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("窗口置顶")
            }
        }
        .font(.body)
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .background(SeatSixChrome.raised)
        .preferredColorScheme(.dark)
    }

    private func informationRow(_ title: String, value: String, accessibilityLabel: String? = nil,
                                marker: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                .background {
                    if let marker { SeatSixSidebarGeometry(id: marker) }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(value)
    }
}
