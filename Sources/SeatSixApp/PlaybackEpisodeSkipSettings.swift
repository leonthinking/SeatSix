import SwiftUI
import SeatSixCore

enum EpisodeSkipSettingsPresentation {
    static let maximumSeconds = 1_800

    static func seconds(from text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (48...57).contains($0) }),
              let seconds = Int(value),
              (0...maximumSeconds).contains(seconds) else { return nil }
        return seconds
    }

    static func settings(intro: String, outro: String) -> SeriesSkipSettings? {
        guard let introSeconds = seconds(from: intro), let outroSeconds = seconds(from: outro) else { return nil }
        return SeriesSkipSettings(introSeconds: introSeconds, outroSeconds: outroSeconds)
    }

    static func summary(_ settings: SeriesSkipSettings) -> String {
        "片头\(duration(settings.introSeconds)) · 片尾\(duration(settings.outroSeconds))"
    }

    private static func duration(_ seconds: Int) -> String {
        seconds == 0 ? "关闭" : " \(seconds) 秒"
    }
}

struct PlaybackEpisodeSkipSettings: View {
    @ObservedObject var controller: NativePlaybackController
    @State private var introText: String
    @State private var outroText: String
    @State private var lastSaved: SeriesSkipSettings?

    init(controller: NativePlaybackController) {
        self.controller = controller
        _introText = State(initialValue: String(controller.seriesSkipSettings.introSeconds))
        _outroText = State(initialValue: String(controller.seriesSkipSettings.outroSeconds))
    }

    private var draft: SeriesSkipSettings? {
        EpisodeSkipSettingsPresentation.settings(intro: introText, outro: outroText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本剧片头片尾").font(.headline)
            Text("只应用于这部剧，在本机记住。每项支持 0–1800 秒，0 表示关闭。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            durationField("片头时长（秒）", text: $introText)
            durationField("片尾时长（秒）", text: $outroText)
            if draft == nil {
                Text("请输入 0 到 1800 之间的整数秒数。")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("片头：下次开始播放时生效。超过片头的续播位置保持不变，手动回退可观看片头。")
                Text("片尾：保存后本次播放即生效。播放进入片尾时结束本集；开启“自动播放下一集”后继续下一集。")
            }.font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("当前设置：\(EpisodeSkipSettingsPresentation.summary(controller.seriesSkipSettings))")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("当前跳过设置，\(EpisodeSkipSettingsPresentation.summary(controller.seriesSkipSettings))")
            if let lastSaved, lastSaved == draft, lastSaved == controller.seriesSkipSettings {
                Label("已保存，本剧所有单集都会使用。", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
            if let message = controller.seriesSkipMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("关闭片头片尾跳过") {
                    introText = "0"
                    outroText = "0"
                    save(SeriesSkipSettings())
                }
                Spacer()
                Button("保存") {
                    if let draft { save(draft) }
                }
                .disabled(draft == nil)
                .accessibilityLabel("保存片头片尾设置")
            }
        }
        .font(.system(size: 13)).padding(20).frame(width: 400)
        .disabled(!controller.canConfigureSeriesSkip)
    }

    private func durationField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder).monospacedDigit()
                .multilineTextAlignment(.trailing).frame(width: 90)
                .accessibilityLabel(title)
        }
    }

    private func save(_ settings: SeriesSkipSettings) {
        lastSaved = controller.saveSeriesSkipSettings(settings) ? settings : nil
    }
}
