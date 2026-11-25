import AppKit
import SwiftUI

struct ToolbarSourcePicker: View {
    @ObservedObject var model: ApplicationModel
    let maxWidth: CGFloat

    var body: some View {
        NativeToolbarSourcePicker(model: model, maxWidth: maxWidth)
            .navigationControlGlass()
    }
}

/// The real pop-up owns the menu, the whole capsule's hit area and keyboard focus.
private struct NativeToolbarSourcePicker: NSViewRepresentable {
    @ObservedObject var model: ApplicationModel
    let maxWidth: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    final class Coordinator: NSObject {
        var model: ApplicationModel
        init(_ model: ApplicationModel) { self.model = model }

        @MainActor @objc func selectServer(_ button: NSPopUpButton) {
            guard let id = button.selectedItem?.representedObject as? UUID, id != model.connection?.id else { return }
            model.switchConnection(id)
            if model.connection?.id != id {
                // AppKit changes the menu's checkmark before sending the action.
                let index = model.connection.map { button.indexOfItem(withRepresentedObject: $0.id) } ?? -1
                button.selectItem(at: index)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .large
        if #available(macOS 26, *) {
            // The toolbar supplies one continuous glass surface behind the label and arrows.
            button.isBordered = false
            button.borderShape = .capsule
            button.alignment = .center
        } else {
            button.bezelStyle = .rounded
        }
        button.lineBreakMode = .byTruncatingTail
        button.autoenablesItems = false
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectServer(_:))
        button.setAccessibilityIdentifier("toolbar-source")
        button.setAccessibilityLabel("切换影视服务器")
        button.toolTip = "切换影视服务器"
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.model = model
        let servers = model.saved.connections
        if button.numberOfItems != servers.count || !zip(button.itemArray, servers).allSatisfy({
            $0.representedObject as? UUID == $1.id && $0.title == $1.name
        }) {
            let menu = NSMenu()
            for server in servers {
                let item = menu.addItem(withTitle: server.name, action: nil, keyEquivalent: "")
                item.representedObject = server.id
            }
            button.menu = menu
        }
        let index = servers.firstIndex { $0.id == model.connection?.id } ?? -1
        if button.indexOfSelectedItem != index { button.selectItem(at: index) }
        button.isEnabled = isEnabled
        // AppKit applies system contrast to Aqua. The high-contrast names are for matching only.
        let appearance: NSAppearance.Name = colorScheme == .light ? .aqua : .darkAqua
        if button.appearance?.name != appearance { button.appearance = NSAppearance(named: appearance) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let font = nsView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large))
        let titleWidth = ((nsView.titleOfSelectedItem ?? "") as NSString).size(withAttributes: [.font: font]).width
        // Other servers in the menu shouldn't stretch the current label.
        return CGSize(width: min(maxWidth, max(64, ceil(titleWidth) + 42)), height: 36)
    }
}
