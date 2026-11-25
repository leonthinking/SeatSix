import AppKit
import SwiftUI
import SeatSixCore

struct DetailFocusContext {
    var request: DetailReturnFocusRequest?
    var consume: (String, CGRect) -> Bool = { _, _ in false }
    var cancel: () -> Void = {}
}

struct ContentOverflowMenu<Actions: View>: View {
    let name: String
    let side: CGFloat
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        Menu(content: actions) {
            if let image = menuImage { Image(nsImage: image).accessibilityLabel(name) }
            else { Text("更多").accessibilityLabel(name) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: side, height: side)
        .help(name)
    }

    // The native borderless menu uses its image size for the actual button;
    // SwiftUI padding alone leaves only the small glyph responsive.
    private var menuImage: NSImage? {
        guard let symbol = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil) else { return nil }
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { bounds in
            let glyph = NSRect(origin: NSPoint(x: bounds.midX - symbol.size.width / 2,
                                               y: bounds.midY - symbol.size.height / 2), size: symbol.size)
            symbol.draw(in: glyph)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }
}

private struct DetailFocusContextKey: EnvironmentKey {
    static let defaultValue = DetailFocusContext()
}

extension EnvironmentValues {
    var detailFocusContext: DetailFocusContext {
        get { self[DetailFocusContextKey.self] }
        set { self[DetailFocusContextKey.self] = newValue }
    }
}

/// The same control owns its provenance and keyboard focus. Stable IDs survive
/// catalog insertions; a network response never chooses or scrolls to a card.
struct DetailEntryButton<Label: View>: View {
    enum Appearance { case card, action }

    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    let kind: String
    var showsSeries = false
    var beforeOpen: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var accessibilityName: String? = nil
    var accessibilityID: String? = nil
    var keyboardFocusRequest: LibraryKeyboardFocusRequest? = nil
    var consumeKeyboardFocus: (UUID) -> Bool = { _ in false }
    var keyboardMove: ((MoveCommandDirection) -> Void)? = nil
    var activationAllowed = true
    var appearance: Appearance = .card
    @ViewBuilder let label: () -> Label
    @Environment(\.detailInteractionActions) private var actions
    @Environment(\.detailFocusContext) private var focusContext
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var sourceFrame = CGRect.zero
    private var sourceID: String { DetailSourceKey(kind: kind, itemID: item.id).id }

    @ViewBuilder var body: some View {
        if let keyboardMove {
            control.onMoveCommand { direction in
                guard focused, isEnabled else { return }
                keyboardMove(direction)
            }
        } else {
            control
        }
    }

    @ViewBuilder private var styledButton: some View {
        let button = Button(action: activate) { label() }
        switch appearance {
        case .card:
            button.buttonStyle(SeatSixPressButtonStyle())
        case .action:
            button.seatSixGlassButton()
                .buttonBorderShape(.capsule)
        }
    }

    private var control: some View {
        styledButton
        .accessibilityLabel(accessibilityName ?? "查看 \(item.name) 详情")
        .accessibilityIdentifier(accessibilityID ?? "detail-entry-\(sourceID)")
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.return, .space]) { _ in
            guard focused, isEnabled else { return .ignored }
            activate()
            return .handled
        }
        .detailSource(id: sourceID)
        .onPreferenceChange(DetailSourceFrameKey.self) { sourceFrame = $0[sourceID] ?? .zero }
        .onChange(of: focused) { _, value in
            focusChanged(value)
            if value { focusContext.cancel() }
        }
        .task(id: keyboardFocusRequest?.id) {
            guard !Task.isCancelled, isEnabled,
                  let request = keyboardFocusRequest, request.itemID == item.id else { return }
            if consumeKeyboardFocus(request.id) { focused = true }
        }
        .task(id: focusContext.request?.id) {
            guard focusContext.request?.sourceID == sourceID, isEnabled else { return }
            let responder = NSApp.keyWindow?.firstResponder
            // Let the existing scroll-restoration bridge settle first. A user
            // who has already focused another control takes precedence.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, isEnabled, NSApp.keyWindow?.firstResponder === responder else { return }
            if focusContext.consume(sourceID, sourceFrame) { focused = true }
        }
    }

    private func activate() {
        guard activationAllowed else { return }
        beforeOpen()
        if showsSeries {
            if let action = actions.showSeries { action(item, sourceID, focused) }
            else { model.showSeries(for: item) }
        } else {
            if let action = actions.open { action(item, sourceID, focused) }
            else { model.showDetail(item) }
        }
    }
}

/// No delayed action: pressing only changes presentation, while Button owns
/// activation, disabled semantics, keyboard operation and cancellation.
struct SeatSixPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

struct SeatSixSidebarToggle: View {
    let collapsed: Bool
    let toggle: () -> Void

    private var title: String { collapsed ? "显示侧边栏" : "隐藏侧边栏" }

    var body: some View {
        Button(action: toggle) {
            NavigationToolbarIcon(symbol: "sidebar.leading")
        }
        .navigationIconButton()
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebar-toggle")
        .help(title + "（⌃⌘S）")
        .background(SeatSixSidebarGeometry(id: "sidebar-toggle"))
        .frame(width: 36, height: 36)
    }
}

struct NavigationLayoutKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard [next.minX, next.minY, next.width, next.height].allSatisfy(\.isFinite),
              next.width > 0, next.height > 0 else { return }
        // Backgrounds and overlays that do not report layout contribute the
        // default value; they must not erase the real window viewport.
        value = next
    }
}
