import SwiftUI
import SeatSixCore
import SeatSixPlayback

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, playback, controls, subtitles

    static var availablePages: [Self] {
        LocalPlaybackEngine.isAvailable ? allCases : [.general, .playback, .controls]
    }

    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "通用"
        case .playback: return "播放"
        case .controls: return "播放器界面"
        case .subtitles: return "字幕与音轨"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .playback: return "play.circle"
        case .controls: return "rectangle.bottomthird.inset.filled"
        case .subtitles: return "captions.bubble"
        }
    }

    func restoringDefaults(in preferences: ApplicationPreferences) -> ApplicationPreferences {
        var result = preferences
        let defaults = ApplicationPreferences()
        switch self {
        case .general:
            result.startupPage = defaults.startupPage
            result.sidebarWidth = defaults.sidebarWidth
            result.sidebarCollapsed = defaults.sidebarCollapsed
            result.defaultLibrarySort = defaults.defaultLibrarySort
            result.posterSize = defaults.posterSize
            result.showRecentlyAdded = defaults.showRecentlyAdded
            result.showHomeRecommendations = defaults.showHomeRecommendations
            result.autoRotateHomeRecommendations = defaults.autoRotateHomeRecommendations
            result.hideUnwatchedEpisodeOverview = defaults.hideUnwatchedEpisodeOverview
        case .playback:
            result.rememberVolume = defaults.rememberVolume
            result.resumeRewindSeconds = defaults.resumeRewindSeconds
            result.pauseWhenMinimized = defaults.pauseWhenMinimized
            result.autoPlayNextEpisode = defaults.autoPlayNextEpisode
            if LocalPlaybackEngine.isAvailable {
                result.seekBackwardSeconds = defaults.seekBackwardSeconds
                result.seekForwardSeconds = defaults.seekForwardSeconds
            }
        case .controls:
            result.playbackWindowMode = defaults.playbackWindowMode
            result.keepPlaybackWindowOnTop = defaults.keepPlaybackWindowOnTop
            if LocalPlaybackEngine.isAvailable {
                result.autoHideControls = defaults.autoHideControls
                result.controlsHideDelay = defaults.controlsHideDelay
                result.timeDisplay = defaults.timeDisplay
            }
        case .subtitles:
            result.subtitleMode = defaults.subtitleMode
            result.preferredSubtitleLanguage = defaults.preferredSubtitleLanguage
            result.preferredAudioLanguage = defaults.preferredAudioLanguage
            result.subtitleFontSize = defaults.subtitleFontSize
            result.subtitleStyle = defaults.subtitleStyle
        }
        return result
    }
}

/// Each write merges with the latest saved value. A rejected save therefore
/// leaves every control reading the last successfully persisted preference.
@MainActor
enum ApplicationPreferenceBinding {
    static func value<Value>(_ keyPath: WritableKeyPath<ApplicationPreferences, Value>, model: ApplicationModel) -> Binding<Value> {
        Binding(get: { model.applicationPreferences[keyPath: keyPath] }, set: { value in
            var preferences = model.applicationPreferences
            preferences[keyPath: keyPath] = value
            _ = model.updateApplicationPreferences(preferences)
        })
    }
}

struct SeatSixSettingsView: View {
    @ObservedObject var model: ApplicationModel
    @State private var selection: SettingsPage

    init(model: ApplicationModel, initialPage: SettingsPage = .general) {
        self.model = model
        _selection = State(initialValue: SettingsPage.availablePages.contains(initialPage) ? initialPage : .general)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPage.availablePages) { page in
                SettingsPageView(model: model, page: page)
                    .tabItem { Label(page.title, systemImage: page.symbol) }
                    .tag(page)
            }
        }
        .padding(16)
        .frame(width: 620, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("设置")
        .background(SettingsWindowTitle().frame(width: 0, height: 0))
        .accessibilityIdentifier("application-settings")
    }
}

/// Settings adapts TabView to an AppKit tab controller whose default behavior
/// promotes the selected category title into the parent window title.
struct SettingsWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.applyTitle() }
    static func dismantleNSView(_ view: TitleView, coordinator: ()) { view.stopObserving() }

    final class TitleView: NSView {
        private var titleObservation: NSKeyValueObservation?

        func stopObserving() {
            titleObservation?.invalidate()
            titleObservation = nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            // Settings can also write the window title directly after selecting
            // a tab. Correct that write synchronously, before another frame.
            // AppKit window mutations and their KVO callbacks run on the main actor.
            titleObservation = window.observe(\.title, options: [.new]) { [weak self] changedWindow, _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === changedWindow, changedWindow.title != "设置" else { return }
                    self.applyTitle()
                }
            }
            applyTitle()
        }

        func applyTitle() {
            guard let window else { return }
            if let root = window.contentViewController { keepParentTitle(in: root) }
            if window.title != "设置" { window.title = "设置" }
        }

        private func keepParentTitle(in controller: NSViewController) {
            if let tabs = controller as? NSTabViewController {
                if tabs.canPropagateSelectedChildViewControllerTitle { tabs.canPropagateSelectedChildViewControllerTitle = false }
                if tabs.title != "设置" { tabs.title = "设置" }
                return
            }
            for child in controller.children { keepParentTitle(in: child) }
        }
    }
}

struct SettingsPageView: View {
    @ObservedObject var model: ApplicationModel
    let page: SettingsPage

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch page {
                case .general: general
                case .playback: playback
                case .controls: controls
                case .subtitles: subtitles
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let error = model.preferencesError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .accessibilityIdentifier("settings-save-error")
            }
            HStack {
                Text("设置仅保存在此 Mac 上。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复此页默认") {
                    _ = model.updateApplicationPreferences(page.restoringDefaults(in: model.applicationPreferences))
                }
                .accessibilityIdentifier("settings-reset-\(page.rawValue)")
                .help("仅恢复本页设置，保留服务器、观看进度和单片偏好")
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
        .accessibilityIdentifier("settings-page-\(page.rawValue)")
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<ApplicationPreferences, Value>) -> Binding<Value> {
        ApplicationPreferenceBinding.value(keyPath, model: model)
    }

    private var general: some View {
        Group {
            Section {
                Picker("启动时打开", selection: preference(\.startupPage)) {
                    ForEach(StartupPage.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("settings-startup-page")
            } header: {
                Text("启动")
            } footer: {
                Text("可恢复上次的首页、分类、继续观看、最近添加或片库；不恢复影片详情、搜索和滚动位置。来源或片库不可用时返回首页。")
            }
            Section {
                Toggle("显示首页推荐轮播", isOn: preference(\.showHomeRecommendations))
                    .accessibilityIdentifier("settings-show-home-recommendations")
                Toggle("自动轮播", isOn: preference(\.autoRotateHomeRecommendations))
                    .disabled(!model.applicationPreferences.showHomeRecommendations)
                    .accessibilityIdentifier("settings-auto-rotate-home-recommendations")
            } header: {
                Text("首页推荐")
            } footer: {
                Text("点按推荐封面可查看详情。要手动切换推荐，可以在封面上左右滑动，或右键点按封面选择上一部、下一部。")
            }
            Section {
                Picker("默认片库排序", selection: preference(\.defaultLibrarySort)) {
                    ForEach(LibrarySortOrder.allCases) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("settings-library-sort")
                Picker("海报大小", selection: preference(\.posterSize)) {
                    ForEach(PosterSize.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("settings-poster-size")
                Toggle("首页显示最近添加", isOn: preference(\.showRecentlyAdded))
                    .accessibilityIdentifier("settings-show-recent")
            } header: {
                Text("浏览")
            } footer: {
                Text("默认排序用于新打开的片库。海报大小和首页内容立即更新，继续观看和媒体库入口始终保留。")
            }
            Section {
                Toggle("隐藏未看单集简介", isOn: preference(\.hideUnwatchedEpisodeOverview))
                    .accessibilityIdentifier("settings-hide-episode-overview")
            } header: {
                Text("简介")
            } footer: {
                Text("可在单集详情中临时显示。影片与整剧简介不受影响。")
            }
        }
    }

    private var playback: some View {
        Group {
            Section {
                Toggle("记住播放器音量和静音状态", isOn: preference(\.rememberVolume))
                    .accessibilityIdentifier("settings-remember-volume")
                Picker("续播时回看", selection: preference(\.resumeRewindSeconds)) {
                    Text("关闭").tag(0.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                }.accessibilityIdentifier("settings-resume-rewind")
            } header: {
                Text("开始播放")
            } footer: {
                Text("回看只用于新开影片时的续播，从头播放和连续选集不受影响。片头跳过优先；开始播放后正常同步进度。")
            }
            Section {
                Toggle("自动播放下一集", isOn: preference(\.autoPlayNextEpisode))
                    .accessibilityIdentifier("settings-auto-next")
            } header: {
                Text("连续播放")
            } footer: {
                Text("下次开始新的播放时生效。当前播放和连续选集沿用本次选择。")
            }
            Section {
                Toggle("最小化播放窗口时暂停", isOn: preference(\.pauseWhenMinimized))
                    .accessibilityIdentifier("settings-pause-minimized")
            } header: {
                Text("离开观看")
            } footer: {
                Text("立即生效，切换应用不受影响。恢复窗口后需要手动播放。")
            }
            if LocalPlaybackEngine.isAvailable {
                Section {
                    secondsPicker("快退步长", value: preference(\.seekBackwardSeconds), choices: [5, 10, 15, 30, 60])
                        .accessibilityIdentifier("settings-seek-backward")
                    secondsPicker("快进步长", value: preference(\.seekForwardSeconds), choices: [5, 10, 15, 30, 60])
                        .accessibilityIdentifier("settings-seek-forward")
                } header: {
                    Text("跳转")
                } footer: {
                    Text("立即应用于本地播放器的快进、快退按钮和方向键。")
                }
            }
        }
    }

    private var controls: some View {
        Group {
            Section {
                Picker("新播放窗口", selection: preference(\.playbackWindowMode)) {
                    ForEach(PlaybackWindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("settings-playback-window-mode")
                Toggle("新播放窗口保持最前", isOn: preference(\.keepPlaybackWindowOnTop))
                    .accessibilityIdentifier("settings-window-on-top")
                Button("重置播放器大小与位置") { model.resetPlaybackWindow() }
                    .disabled(model.player == nil)
                    .accessibilityIdentifier("settings-reset-player-window")
                    .help("按当前屏幕和影片比例重新居中。全屏时在退出全屏后应用")
            } header: {
                Text("窗口")
            } footer: {
                Text("普通播放窗口居中打开，宽度取当前屏幕可用宽度的 90%。高度放不下时按影片比例缩小。连续选集保留当前窗口。")
            }
            if LocalPlaybackEngine.isAvailable {
                Section {
                    Toggle("播放时自动隐藏控制栏", isOn: preference(\.autoHideControls))
                        .accessibilityIdentifier("settings-auto-hide-controls")
                    secondsPicker("隐藏前等待", value: preference(\.controlsHideDelay), choices: [2, 3, 5, 8])
                        .disabled(!model.applicationPreferences.autoHideControls)
                        .accessibilityIdentifier("settings-controls-delay")
                    Picker("进度条右侧显示", selection: preference(\.timeDisplay)) {
                        ForEach(PlaybackTimeDisplay.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.accessibilityIdentifier("settings-time-display")
                } header: {
                    Text("控制栏")
                } footer: {
                    Text("普通窗口和全屏播放共用此设置。暂停或操作控件时，控制栏保持显示。兼容播放使用系统控制栏。")
                }
            }
        }
    }

    private var subtitles: some View {
        Group {
            Section {
                Picker("默认字幕", selection: preference(\.subtitleMode)) {
                    ForEach(DefaultSubtitleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.accessibilityIdentifier("settings-subtitle-mode")
                Picker("首选字幕语言", selection: preference(\.preferredSubtitleLanguage)) {
                    ForEach(MediaLanguage.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(model.applicationPreferences.subtitleMode != .preferredLanguage)
                .accessibilityIdentifier("settings-subtitle-language")
                Picker("首选音轨语言", selection: preference(\.preferredAudioLanguage)) {
                    Text("媒体默认").tag(Optional<MediaLanguage>.none)
                    ForEach(MediaLanguage.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }.accessibilityIdentifier("settings-audio-language")
            } header: {
                Text("语言选择")
            } footer: {
                Text("下次开始新的本地播放时生效。单片选择优先；没有匹配语言时使用媒体默认。可在播放器的字幕、音轨菜单中重新跟随应用偏好。")
            }
            Section {
                Picker("默认字号", selection: preference(\.subtitleFontSize)) {
                    ForEach([32.0, 48.0, 60.0, 72.0], id: \.self) { size in
                        Text("\(Int(size))").tag(size)
                    }
                }.accessibilityIdentifier("settings-subtitle-font-size")
                Picker("默认样式", selection: preference(\.subtitleStyle)) {
                    ForEach(SubtitlePresentation.Style.allCases, id: \.self) { style in
                        Text(style.settingsLabel).tag(style)
                    }
                }.accessibilityIdentifier("settings-subtitle-style")
            } header: {
                Text("文字外观")
            } footer: {
                Text("仅用于本地播放器的文字字幕，图片字幕不支持字号和样式调整。单片字幕外观仍会保留。")
            }
        }
    }

    private func secondsPicker(_ title: String, value: Binding<Double>, choices: [Double]) -> some View {
        Picker(title, selection: value) {
            ForEach(choices, id: \.self) { Text("\(Int($0)) 秒").tag($0) }
        }
    }
}

private extension SubtitlePresentation.Style {
    var settingsLabel: String {
        switch self {
        case .original: return "原始样式"
        case .outlined: return "白字描边"
        case .boxed: return "黑底白字"
        case .yellow: return "黄色描边"
        }
    }
}
