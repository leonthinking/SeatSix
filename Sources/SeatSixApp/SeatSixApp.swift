import AppKit
import SwiftUI

@MainActor
final class SeatSixApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: ApplicationModel?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SeatSixApp: App {
    @NSApplicationDelegateAdaptor(SeatSixApplicationDelegate.self) private var delegate
    @StateObject private var model = ApplicationModel()

    var body: some Scene {
        Window("SeatSix", id: "main") {
            SeatSixRootView(model: model)
                .preferredColorScheme(.dark)
                .tint(SeatSixStyle.accent)
                .modifier(MainWindowLayout())
                .onAppear { delegate.model = model; model.refresh() }
        }
        .defaultSize(width: MainWindowGeometry.preferredSize.width, height: MainWindowGeometry.preferredSize.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SeatSixNavigationCommands()
            CommandGroup(after: .newItem) {
                Button("添加媒体服务器…") { model.reauthenticate = nil; model.showLogin = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        Settings {
            SeatSixSettingsView(model: model)
                .preferredColorScheme(.dark)
                .tint(SeatSixStyle.accent)
        }
        .windowResizability(.contentSize)
    }
}
