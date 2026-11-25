import SwiftUI
import SeatSixPlayback

enum PlaybackTimeLabel {
    static func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 1_000_000_000 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func playhead(_ value: Double, dragging: Bool) -> String {
        dragging ? clock(value) : elapsedClock(value)
    }

    static func elapsedClock(_ value: Double) -> String {
        clock(value.rounded(.up))
    }

    static func trailing(elapsed: Double, duration: Double, display: PlaybackTimeDisplay) -> String {
        guard display == .remaining else { return clock(duration) }
        let duration = duration.isFinite && duration >= 0 ? duration : 0
        let elapsed = elapsed.isFinite ? min(duration, max(0, elapsed)) : 0
        return "−" + clock(duration - elapsed)
    }
}

enum PlaybackTrackLabel {
    static func text(_ track: LocalPlaybackTrack) -> String {
        text(id: track.id, kind: track.kind, title: track.title, language: track.language,
             codec: track.codec, channels: track.channelCount, external: track.isExternal, forced: track.isForced)
    }
    static func text(id: Int, kind: LocalPlaybackTrack.Kind, title: String?, language: String?, codec: String?, channels: Int?, external: Bool, forced: Bool) -> String {
        let languages = ["eng": "英语", "en": "英语", "chi": "中文", "zho": "中文", "cmn": "中文", "zh": "中文", "hin": "印地语", "hi": "印地语", "jpn": "日语", "ja": "日语", "kor": "韩语", "ko": "韩语"]
        var parts: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty, language != "und" {
            let name = languages[language.lowercased()] ?? language
            if !parts.contains(where: { $0.localizedCaseInsensitiveContains(name) }) { parts.append(name) }
        }
        if parts.isEmpty { parts.append("\(kind == .audio ? "音轨" : "字幕") \(id)") }
        if let codec, !codec.isEmpty {
            let codecs = ["subrip": "SRT", "hdmv_pgs_subtitle": "PGS", "pgssub": "PGS", "webvtt": "VTT", "ac3": "AC-3", "eac3": "E-AC-3"]
            parts.append(codecs[codec.lowercased()] ?? codec.uppercased())
        }
        if kind == .audio, let channels, channels > 0 { parts.append("\(channels) 声道") }
        if external { parts.append("外挂") }
        if forced { parts.append("强制") }
        return parts.joined(separator: " · ")
    }
}

/// Mouse tracking produces a live time preview and one seek on release. Keyboard
/// and accessibility actions commit immediately without requiring a drag gesture.
final class PlaybackSeekSlider: NSSlider {
    var preview: (Double?) -> Void = { _ in }
    var seek: (Double) -> Void = { _ in }
    var pendingPosition: () -> Double? = { nil }
    var preferences = ApplicationPreferences()
    private(set) var isDragging = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        preview(doubleValue)
        super.mouseDown(with: event)
        let target = doubleValue
        isDragging = false
        preview(nil)
        seek(target)
    }

    @objc func valueChanged() {
        if isDragging { preview(doubleValue) } else { seek(doubleValue) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty, event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
        guard !event.isARepeat else { return }
        if event.keyCode == 123 { _ = accessibilityPerformDecrement() }
        else { _ = accessibilityPerformIncrement() }
    }

    override func accessibilityValue() -> Any? { doubleValue }
    override func accessibilityValueDescription() -> String? { PlaybackTimeLabel.playhead(doubleValue, dragging: isDragging) }
    override func setAccessibilityValue(_ value: Any?) {
        guard let value = value as? NSNumber else { return }
        _ = commit(value.doubleValue)
    }
    override func accessibilityPerformIncrement() -> Bool {
        commit(PlaybackSeekDirection.forward.target(from: pendingPosition() ?? doubleValue, preferences: preferences))
    }
    override func accessibilityPerformDecrement() -> Bool {
        commit(PlaybackSeekDirection.backward.target(from: pendingPosition() ?? doubleValue, preferences: preferences))
    }

    private func commit(_ value: Double) -> Bool {
        guard isEnabled, value.isFinite else { return false }
        doubleValue = min(maxValue, max(minValue, value))
        seek(doubleValue)
        return true
    }
}

private struct PlaybackTimelineSlider: NSViewRepresentable {
    let position: Double
    let duration: Double
    let preferences: ApplicationPreferences
    let pendingPosition: () -> Double?
    let preview: (Double?) -> Void
    let seek: (Double) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> PlaybackSeekSlider {
        let slider = PlaybackSeekSlider()
        slider.setAccessibilityLabel("播放进度")
        slider.trackFillColor = NSColor(SeatSixChrome.accent)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.isVertical = false
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(PlaybackSeekSlider.valueChanged)
        return slider
    }
    func updateNSView(_ slider: PlaybackSeekSlider, context: Context) {
        let known = duration.isFinite && duration > 0
        slider.isEnabled = isEnabled && known
        slider.maxValue = known ? duration : 1
        if !slider.isDragging { slider.doubleValue = min(slider.maxValue, max(0, position)) }
        slider.preferences = preferences
        slider.pendingPosition = pendingPosition
        slider.preview = preview
        slider.seek = seek
    }
}

/// Measure the actual groups. The transport stays centered even when the utility
/// menus are wider than the volume controls, and can keep its own row in a narrow window.
private struct PlaybackActionLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = singleRowWidth(sizes)
        let width = proposal.width ?? ideal
        let height: CGFloat
        if width >= ideal {
            height = sizes.map(\.height).max() ?? 0
        } else if sideGroupsFit(in: width, sizes: sizes) {
            height = sizes[1].height + spacing + max(sizes[0].height, sizes[2].height)
        } else {
            height = sizes.reduce(2 * spacing) { $0 + $1.height }
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if !sideGroupsFit(in: bounds.width, sizes: sizes) {
            var y = bounds.minY
            for index in [1, 0, 2] {
                subviews[index].place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: .unspecified)
                y += sizes[index].height + spacing
            }
            return
        }
        let stacked = bounds.width < singleRowWidth(sizes)
        let sideY = stacked ? bounds.maxY - max(sizes[0].height, sizes[2].height) / 2 : bounds.midY
        let middleY = stacked ? bounds.minY + sizes[1].height / 2 : bounds.midY
        subviews[0].place(at: CGPoint(x: bounds.minX, y: sideY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: middleY), anchor: .center, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: sideY), anchor: .trailing, proposal: .unspecified)
    }

    private func singleRowWidth(_ sizes: [CGSize]) -> CGFloat {
        2 * (max(sizes[0].width, sizes[2].width) + spacing) + sizes[1].width
    }

    private func sideGroupsFit(in width: CGFloat, sizes: [CGSize]) -> Bool {
        sizes[0].width + spacing + sizes[2].width <= width
    }
}

struct LocalPlaybackControls: View {
    @ObservedObject var controller: NativePlaybackController
    @ObservedObject var interaction: PlaybackInteractionController
    var materialPolicy: SeatSixMaterialPolicy? = nil
    @State private var showingSubtitleSettings = false
    @State private var showingVolume = false
    @State private var showingCompactOptions = false
    @State private var aspectError: String?
    @State private var changingAspect = false
    @State private var showingKeyboardHelp = false
    @State private var scrubPosition: Double?
    private var position: Double { scrubPosition ?? controller.manualSeekTarget ?? controller.elapsedSeconds }
    private var hasDuration: Bool { controller.durationSeconds.isFinite && controller.durationSeconds > 0 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedControls
                .padding(.horizontal, 16)
                .frame(minWidth: 250, idealWidth: 250, maxWidth: .infinity)
            compactControls
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .padding(.vertical, 9)
        .frame(maxWidth: 860)
        .playbackControlGlass(cornerRadius: 16, policyOverride: materialPolicy)
        .background {
            Color.clear.contentShape(RoundedRectangle(cornerRadius: 16))
                .onTapGesture { interaction.activity() }.accessibilityHidden(true)
        }
        .background(SeatSixSidebarGeometry(id: "hud-dock"))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .disabled(controller.preparing || controller.stopping || controller.errorMessage != nil)
        .onChange(of: showingCompactOptions || showingVolume || showingSubtitleSettings || showingKeyboardHelp) { _, open in
            interaction.setPopoverOpen(open)
        }
        .onDisappear { interaction.setPopoverOpen(false); interaction.setScrubbing(false); interaction.setControlsHovered(false) }
    }

    private var compactControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { playPauseButton; compactOptionsButton }
            VStack(spacing: 5) { playPauseButton; compactOptionsButton }
        }
    }

    private var compactOptionsButton: some View {
        Button { showingCompactOptions.toggle() } label: {
            toolbarIcon("更多播放选项", symbol: "ellipsis.circle")
        }
        .help("展开完整播控栏")
        .popover(isPresented: $showingCompactOptions) {
            VStack(spacing: 12) {
                expandedControls
                if controller.item.type == "Episode" {
                    Divider()
                    PlaybackEpisodeNavigation(controller: controller, interaction: interaction, showsTransport: false)
                }
            }
            .buttonStyle(.plain).menuStyle(.button).menuIndicator(.hidden)
            .padding(14).frame(width: 360)
            .preferredColorScheme(.dark)
        }
    }

    private var expandedControls: some View {
        VStack(spacing: 5) {
            timeline
            PlaybackActionLayout {
                HStack(spacing: 3) {
                    volumeControl
                    rateMenu
                    if controller.isBuffering {
                        ProgressView().controlSize(.small).accessibilityLabel("正在缓冲").help("正在缓冲")
                    }
                }.background(SeatSixSidebarGeometry(id: "hud-leading"))
                transportControls.background(SeatSixSidebarGeometry(id: "hud-transport"))
                HStack(spacing: 4) {
                    subtitleMenu
                    audioMenu
                    settingsMenu
                    Button { interaction.toggleFullScreen() } label: {
                        toolbarIcon(fullScreenTitle, symbol: interaction.isFullScreen
                                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .help("\(fullScreenTitle)（F）")
                }.background(SeatSixSidebarGeometry(id: "hud-trailing"))
            }
            feedback(aspectError)
            feedback(controller.trackMessage)
            feedback(controller.playbackControlMessage)
        }
    }

    @ViewBuilder private func feedback(_ message: String?) -> some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fullScreenTitle: String { interaction.isFullScreen ? "退出全屏" : "进入全屏" }

    private var timeline: some View {
        let elapsed = PlaybackTimeLabel.playhead(position, dragging: scrubPosition != nil)
        let trailing = hasDuration ? PlaybackTimeLabel.trailing(elapsed: position, duration: controller.durationSeconds,
                                                               display: controller.interfacePreferences.timeDisplay) : "–:––"
        return HStack(spacing: 10) {
            Text(elapsed).frame(minWidth: hasDuration && controller.durationSeconds >= 3600 ? 49 : 33, alignment: .leading)
                .accessibilityLabel("已播放").accessibilityValue(elapsed)
            PlaybackTimelineSlider(position: position, duration: controller.durationSeconds,
                                   preferences: controller.interfacePreferences, pendingPosition: { controller.manualSeekTarget }, preview: { value in
                scrubPosition = value
                interaction.setScrubbing(value != nil)
            }, seek: { value in controller.requestSeek(to: value) })
            .disabled(!controller.canSeek)
            .frame(height: 20)
            Text(trailing).frame(minWidth: hasDuration && controller.durationSeconds >= 3600 ? 56 : 40, alignment: .trailing)
                .accessibilityLabel(controller.interfacePreferences.timeDisplay == .remaining ? "剩余时间" : "总时长")
                .accessibilityValue(hasDuration ? trailing : "未知")
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
    }

    private var volumeControl: some View {
        let symbol = controller.volume == 0 ? "speaker.slash.fill" : controller.volume <= 0.33 ? "speaker.wave.1.fill"
            : controller.volume <= 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        let percent = controller.volume.formatted(.percent.precision(.fractionLength(0)))
        return Button { showingVolume.toggle() } label: { toolbarIcon("音量", symbol: symbol) }
            .accessibilityValue(percent).help("音量 \(percent)（M 静音）")
            .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
                HStack {
                    Button(controller.volume > 0 ? "静音" : "恢复音量") { controller.toggleMute() }
                    Slider(value: Binding(get: { controller.volume }, set: { controller.setVolume($0) }), in: 0...1)
                        .frame(width: 130).accessibilityLabel("音量").accessibilityValue(percent)
                    Text(percent).monospacedDigit()
                }.padding(14)
            }
    }

    private var transportControls: some View {
        HStack(spacing: 5) {
            if controller.item.type == "Episode" { episodeStep(previous: true) }
            seekButton(.backward)
            playPauseButton
            seekButton(.forward)
            if controller.item.type == "Episode" { episodeStep(previous: false) }
        }
    }

    private var playPauseButton: some View {
        Button { controller.togglePause() } label: {
            let title = controller.isPaused ? "播放" : "暂停"
            Label(title, systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                .labelStyle(.iconOnly).font(.system(size: 17, weight: .bold))
                .foregroundStyle(SeatSixChrome.canvas)
                .frame(width: 42, height: 42)
                .background(Color.white, in: Circle())
                .background(SeatSixSidebarGeometry(id: title))
        }
        .help(controller.isPaused ? "播放（空格）" : "暂停（空格）")
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PlaybackRate.presets, id: \.self) { rate in
                Button { Task { await controller.setPlaybackRate(rate) } } label: {
                    trackLabel(rateLabel(rate), selected: abs(controller.playbackRate - rate) < 0.001)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(rateLabel(controller.playbackRate)).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).accessibilityHidden(true)
            }.font(.system(size: 13, weight: .semibold)).frame(minWidth: 44, minHeight: 34)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("播放速度，\(rateLabel(controller.playbackRate))")
        }
        .fixedSize().disabled(controller.changingPlaybackRate)
        .background(SeatSixSidebarGeometry(id: "播放速度"))
        .help("播放速度（[ 减速、] 加速、0 恢复）")
    }

    private var settingsMenu: some View {
        Menu {
            if let chapters = controller.localEngine?.snapshot.chapters, !chapters.isEmpty {
                Menu("章节") {
                    let current = chapters.last { $0.start <= controller.elapsedSeconds }?.id
                    ForEach(chapters) { chapter in
                        let title = chapter.title.flatMap { $0.isEmpty ? nil : $0 } ?? "第 \(chapter.id + 1) 章"
                        Button { controller.requestSeek(to: chapter.start) } label: {
                            trackLabel("\(PlaybackTimeLabel.clock(chapter.start))  \(title)", selected: current == chapter.id)
                        }
                    }
                }.disabled(!controller.canSeek)
            }
            aspectMenu
            Button("窗口适配画面") { controller.fitWindowToVideo() }
                .disabled(!controller.canFitWindowToVideo || interaction.isFullScreen)
            Button(interaction.controlsAtTop ? "将播控栏移到底部" : "将播控栏移到顶部") {
                interaction.controlsAtTop.toggle()
                interaction.activity()
            }
            Divider()
            Button("播放帮助与键盘快捷键") { showingKeyboardHelp = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 34, height: 34).contentShape(Rectangle())
                .accessibilityLabel("更多播放选项")
        }
        .background(SeatSixSidebarGeometry(id: "更多播放选项"))
        .help("更多播放选项")
        .popover(isPresented: $showingKeyboardHelp) { keyboardHelp }
    }

    private var aspectMenu: some View {
        let engine = controller.localEngine
        let choices = ["原始比例", "16:9", "4:3", "2.35:1", "1:1"]
        return Menu("画面比例") {
            ForEach(choices.indices, id: \.self) { index in
                Button {
                    guard let engine, !changingAspect else { return }
                    changingAspect = true
                    Task {
                        defer { changingAspect = false }
                        do { try await engine.adjust(.aspect, to: Double(index)); aspectError = nil }
                        catch { aspectError = error.localizedDescription }
                    }
                } label: { trackLabel(choices[index], selected: Double(index) == (engine?.adjustments[.aspect] ?? 0)) }
            }
        }
        .disabled(engine == nil || changingAspect)
    }

    private func episodeStep(previous: Bool) -> some View {
        let target = previous ? controller.episodeSequence?.previous(before: controller.item.id)
                              : controller.episodeSequence?.next(after: controller.item.id)
        let title = previous ? "上一集" : "下一集"
        return Button {
            if let target { controller.selectEpisode(id: target.id) }
        } label: { toolbarIcon(title, symbol: previous ? "backward.end.fill" : "forward.end.fill") }
        .disabled(!controller.canSelectEpisode || target == nil)
        .help(title)
    }

    private func seekButton(_ direction: PlaybackSeekDirection) -> some View {
        let title = direction.label(in: controller.interfacePreferences)
        return Button {
            controller.requestSeek(direction)
        } label: { toolbarIcon(title, symbol: direction.symbol(in: controller.interfacePreferences)) }
        .disabled(!controller.canSeek)
        .help(title + (direction == .backward ? "（←）" : "（→）"))
    }

    private func toolbarIcon(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).labelStyle(.iconOnly)
            .frame(width: 34, height: 34).contentShape(Rectangle())
            .background(SeatSixSidebarGeometry(id: title))
    }

    private func trackMenuLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 4).frame(minHeight: 34).contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
    private func rateLabel(_ rate: Double) -> String { String(format: "%g×", rate) }
    private var keyboardHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放快捷键").font(.headline)
            shortcutRow("空格", "播放 / 暂停")
            shortcutRow("←", PlaybackSeekDirection.backward.label(in: controller.interfacePreferences))
            shortcutRow("→", PlaybackSeekDirection.forward.label(in: controller.interfacePreferences))
            shortcutRow("↓ / ↑", "音量减少 / 增加 5%")
            shortcutRow("M", "静音 / 恢复原音量")
            shortcutRow("[ / ]", "降低 / 提高一档速度")
            shortcutRow("0", "恢复 1× 速度")
            shortcutRow("F / Esc", "切换全屏 / 退出全屏")
            shortcutRow("单击画面", "播放 / 暂停")
            shortcutRow("双击画面", "切换全屏")
            Text("快捷键仅作用于当前播放窗口。菜单、输入框及对话框打开时保留其正常操作。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 13)).padding(20).frame(width: 340)
    }
    private func shortcutRow(_ key: String, _ description: String) -> some View {
        HStack { Text(key).monospaced().frame(width: 90, alignment: .leading); Text(description) }
    }
    private var audioMenu: some View {
        Menu {
            Button { Task { await controller.useApplicationAudioSelection() } } label: {
                trackLabel("按应用偏好选择", selected: controller.followsApplicationAudio)
            }
            Divider()
            if controller.audioTracks.isEmpty { Text("没有可用音轨") }
            ForEach(controller.audioTracks) { track in
                Button { Task { await controller.selectAudioTrack(track.id) } } label: {
                    trackLabel(PlaybackTrackLabel.text(track), selected: controller.selectedAudioTrackID == track.id)
                }
            }
        } label: { trackMenuLabel("音轨", symbol: "waveform") }
        .fixedSize().disabled(controller.changingTrack)
        .background(SeatSixSidebarGeometry(id: "音轨"))
        .help("音轨")
    }
    private var subtitleMenu: some View {
        Menu {
            Button { Task { await controller.useApplicationSubtitleSelection() } } label: {
                trackLabel("按应用偏好选择", selected: controller.followsApplicationSubtitle)
            }
            Divider()
            Button { Task { await controller.selectSubtitleTrack(nil) } } label: {
                trackLabel("关闭字幕", selected: controller.selectedSubtitleTrackID == nil)
            }
            if !controller.subtitleTracks.isEmpty {
                Divider()
                ForEach(controller.subtitleTracks) { track in
                    Button { Task { await controller.selectSubtitleTrack(track.id) } } label: {
                        trackLabel(PlaybackTrackLabel.text(track), selected: controller.selectedSubtitleTrackID == track.id)
                    }
                }
            }
            if !controller.serverSubtitles.isEmpty {
                Divider()
                Section("服务器外挂字幕") {
                    ForEach(controller.serverSubtitles) { subtitle in
                        Button { Task { await controller.selectServerSubtitle(subtitle) } } label: {
                            trackLabel(subtitle.title, selected: controller.serverSubtitleIsSelected(subtitle))
                        }
                    }
                }
            }
            Divider()
            Button("添加外挂字幕…") { Task { await controller.importExternalSubtitle() } }
            Button("字幕设置…") { showingSubtitleSettings = true }
        } label: { trackMenuLabel("字幕", symbol: "captions.bubble") }
        .fixedSize().disabled(controller.changingTrack)
        .background(SeatSixSidebarGeometry(id: "字幕"))
        .help("字幕")
        .popover(isPresented: $showingSubtitleSettings, arrowEdge: .bottom) {
            SubtitleSettingsPanel(controller: controller)
        }
    }
    @ViewBuilder private func trackLabel(_ text: String, selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}


private struct SubtitleSettingsPanel: View {
    @ObservedObject var controller: NativePlaybackController
    private var settings: SubtitlePresentation { controller.subtitlePresentation }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("字幕设置").font(.headline)
                Spacer()
                Button("外观使用应用默认") { Task { await controller.useApplicationSubtitleDefaults() } }
                    .help("字号和样式改为继承应用默认，保留时间偏移与音轨、字幕选择。")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("字幕时间")
                    Spacer()
                    Text(delayLabel).monospacedDigit().accessibilityLabel("字幕时间偏移，\(delayLabel)")
                }
                HStack {
                    Button("提前 0.5 秒") { Task { await controller.setSubtitleDelay(settings.delaySeconds - 0.5) } }
                        .disabled(settings.delaySeconds <= -30)
                    Spacer()
                    Button("归零") { Task { await controller.setSubtitleDelay(0) } }
                    Spacer()
                    Button("延后 0.5 秒") { Task { await controller.setSubtitleDelay(settings.delaySeconds + 0.5) } }
                        .disabled(settings.delaySeconds >= 30)
                }
                Text("字幕比声音早出现时，选择延后；支持前后 30 秒。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("字号")
                    Spacer()
                    Picker("字号", selection: Binding(get: { settings.fontSize }, set: { size in
                        Task { await controller.setSubtitleFontSize(size) }
                    })) {
                        Text("小 · 32").tag(32.0)
                        Text("标准 · 48").tag(48.0)
                        Text("大 · 60").tag(60.0)
                        Text("特大 · 72").tag(72.0)
                    }.labelsHidden().frame(width: 160)
                }
                Picker("样式", selection: Binding(get: { settings.style }, set: { style in
                    Task { await controller.setSubtitleStyle(style) }
                })) {
                    Text("保留原样式").tag(SubtitlePresentation.Style.original)
                    Text("白字描边").tag(SubtitlePresentation.Style.outlined)
                    Text("黑底白字").tag(SubtitlePresentation.Style.boxed)
                    Text("黄色描边").tag(SubtitlePresentation.Style.yellow)
                }
                Text(controller.selectedSubtitleIsBitmap
                     ? "当前为图片字幕，仅支持时间调整；字号和样式适用于文字字幕。"
                     : "保留原样式时按比例缩放；其他样式会覆盖 ASS 的字体和颜色。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.disabled(controller.selectedSubtitleIsBitmap)
            Text("手动调整会为这部影片记住；“外观使用应用默认”只恢复字号和样式的继承。").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = controller.trackMessage {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 13)).padding(20).frame(width: 370).disabled(controller.changingTrack || controller.preparing || controller.stopping)
    }
    private var delayLabel: String {
        if abs(settings.delaySeconds) < 0.01 { return "无偏移" }
        return String(format: "%@ %.1f 秒", settings.delaySeconds > 0 ? "延后" : "提前", abs(settings.delaySeconds))
    }
}
