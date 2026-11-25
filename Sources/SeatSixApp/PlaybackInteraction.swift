import AppKit
import Combine
import SeatSixPlayback

/// Monotonic-time policy shared by the live window and deterministic regression tests.
struct PlaybackControlsVisibility {
    static let idleSeconds: TimeInterval = 3
    struct Conditions: Equatable {
        var activePlayback = false
        var keyWindow = false
        var blocked = false
        var transitioning = false
        var canHide: Bool { activePlayback && keyWindow && !blocked && !transitioning }
    }
    private(set) var conditions = Conditions()
    private(set) var lastActivity: TimeInterval = 0
    private(set) var autoHideEnabled = true
    private(set) var hideDelay: TimeInterval = Self.idleSeconds
    mutating func configure(autoHide: Bool, delay: TimeInterval, now: TimeInterval) {
        let delay = delay.isFinite && delay > 0 ? delay : Self.idleSeconds
        if autoHide != autoHideEnabled || delay != hideDelay { lastActivity = now }
        autoHideEnabled = autoHide
        hideDelay = delay
    }
    mutating func update(_ value: Conditions, now: TimeInterval) {
        if value != conditions { lastActivity = now }
        conditions = value
    }
    mutating func activity(now: TimeInterval) { lastActivity = now }
    func isVisible(now: TimeInterval) -> Bool {
        !autoHideEnabled || !conditions.canHide || now - lastActivity < hideDelay
    }
}

/// The transport buttons, keyboard shortcuts and help use the same live intervals.
enum PlaybackSeekDirection: CaseIterable {
    case backward, forward

    func seconds(in preferences: ApplicationPreferences) -> Double {
        self == .backward ? preferences.seekBackwardSeconds : preferences.seekForwardSeconds
    }
    func target(from elapsed: Double, preferences: ApplicationPreferences) -> Double {
        elapsed + seconds(in: preferences) * (self == .backward ? -1 : 1)
    }
    func label(in preferences: ApplicationPreferences) -> String {
        "\(self == .backward ? "后退" : "前进") \(Int(seconds(in: preferences))) 秒"
    }
    func symbol(in preferences: ApplicationPreferences) -> String {
        "\(self == .backward ? "gobackward" : "goforward").\(Int(seconds(in: preferences)))"
    }
}

/// Header and bottom controls can receive interleaved hover-exit callbacks.
struct PlaybackControlsHover {
    private var owners: Set<String> = []
    var isHovered: Bool { !owners.isEmpty }
    mutating func set(_ value: Bool, owner: String) {
        if value { owners.insert(owner) } else { owners.remove(owner) }
    }
    mutating func reset() { owners.removeAll() }
}

enum PlaybackShortcut: Equatable {
    case togglePause, backward, forward, volumeDown, volumeUp, mute
    case toggleFullScreen, exitFullScreen, slower, faster, normalSpeed

    static func resolve(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags,
                        isRepeat: Bool, eligible: Bool, fullScreen: Bool) -> Self? {
        guard eligible, modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        let action: Self?
        switch keyCode {
        case 49: action = .togglePause
        case 123: action = .backward
        case 124: action = .forward
        case 125: action = .volumeDown
        case 126: action = .volumeUp
        case 53: action = fullScreen ? .exitFullScreen : nil
        default:
            switch characters?.lowercased() {
            case "m": action = .mute
            case "f": action = .toggleFullScreen
            case "[": action = .slower
            case "]": action = .faster
            case "0": action = .normalSpeed
            default: action = nil
            }
        }
        // A physical press performs one seek/toggle; holding volume remains useful.
        if isRepeat, action != .volumeDown, action != .volumeUp { return nil }
        return action
    }
}

/// Click handling belongs to the video surface so that controls, menus and drags
/// keep AppKit's usual behavior. A single click waits for the system double-click interval.
@MainActor
final class PlaybackSurfaceClicks: NSObject, NSGestureRecognizerDelegate {
    private let onSingle: () -> Void
    private let onDouble: () -> Void
    private lazy var single = NSClickGestureRecognizer(target: self, action: #selector(singleClick))
    private lazy var double = NSClickGestureRecognizer(target: self, action: #selector(doubleClick))

    init(onSingle: @escaping () -> Void, onDouble: @escaping () -> Void) {
        self.onSingle = onSingle
        self.onDouble = onDouble
    }

    func attach(to view: NSView) {
        double.numberOfClicksRequired = 2
        single.delegate = self
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(single)
    }

    func detach(from view: NSView) {
        view.removeGestureRecognizer(single)
        view.removeGestureRecognizer(double)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer === single && otherGestureRecognizer === double
    }

    @objc private func singleClick() { onSingle() }
    @objc private func doubleClick() { onDouble() }
}

/// SwiftUI can keep its hosting view as first responder while a child control
/// has keyboard focus. Ask for the focused accessibility element in that case.
@MainActor
private enum PlaybackControlFocus {
    case editor, slider, button, menuButton

    init?(window: NSWindow) {
        let responder = window.firstResponder
        if responder is NSTextView || responder is NSTextField { self = .editor; return }
        if responder is NSSlider { self = .slider; return }
        if responder is NSPopUpButton { self = .menuButton; return }
        if responder is NSButton { self = .button; return }
        // SwiftUI's virtual controls expose AppKit's role selector without
        // declaring NSAccessibilityProtocol conformance.
        let element = window.accessibilityFocusedUIElement as AnyObject?
        switch element?.accessibilityRole?() {
        case .textField, .textArea: self = .editor
        case .slider: self = .slider
        case .menuButton, .popUpButton: self = .menuButton
        case .button, .checkBox: self = .button
        default: return nil
        }
    }

    func owns(keyCode: UInt16) -> Bool {
        switch self {
        case .editor: return true
        case .slider: return (123...126).contains(keyCode) || keyCode == 49
        case .button: return keyCode == 49
        case .menuButton: return keyCode == 49 || keyCode == 125 || keyCode == 126
        }
    }
}

/// Owns only this playback window's input and visibility; never installs a global monitor.
@MainActor
final class PlaybackInteractionController: NSObject, ObservableObject {
    @Published private(set) var isFullScreen = false
    @Published private(set) var controlsVisible = true
    @Published var controlsAtTop = false
    private weak var window: NSWindow?
    private weak var controller: NativePlaybackController?
    private var policy = PlaybackControlsVisibility()
    private var transitioning = false
    private var controlsHover = PlaybackControlsHover()
    private var scrubbing = false
    private var usingKeyboardFocus = false
    // Different control groups can present independent popovers. Closing one must not
    // release the visibility/keyboard protection still owned by another group.
    private var openPopoverOwners: Set<String> = []
    private var popoverOpen: Bool { !openPopoverOwners.isEmpty }
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var monitor: Any?
    private var ticker: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var previousMouseMoved = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func attach(to window: NSWindow, controller: NativePlaybackController) {
        precondition(self.window == nil)
        self.window = window; self.controller = controller
        isFullScreen = window.styleMask.contains(.fullScreen)
        transitioning = false; controlsHover.reset(); scrubbing = false; openPopoverOwners.removeAll()
        usingKeyboardFocus = false
        policy = PlaybackControlsVisibility()
        previousMouseMoved = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            center.addObserver(self, selector: #selector(stateChanged), name: name, object: window)
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(beginTransition), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(endTransition), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(menuOpened(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuClosed(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        observation = controller.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                self?.refresh()
            }
        }
        activity()
    }

    func detach() {
        ticker?.cancel(); ticker = nil; observation = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.removeObserver(self)
        window?.acceptsMouseMovedEvents = previousMouseMoved
        window = nil; controller = nil; trackingMenus.removeAll(); openPopoverOwners.removeAll(); controlsHover.reset()
        controlsVisible = true
    }

    deinit {
        ticker?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        NotificationCenter.default.removeObserver(self)
    }

    func setControlsHovered(_ value: Bool, owner: String = "playback-controls") {
        controlsHover.set(value, owner: owner)
        activity()
    }
    func setScrubbing(_ value: Bool) { scrubbing = value; activity() }
    func setPopoverOpen(_ value: Bool, owner: String = "playback-controls") {
        if value { openPopoverOwners.insert(owner) } else { openPopoverOwners.remove(owner) }
        activity()
    }
    func activity() { policy.activity(now: now); refresh() }
    func clickedVideo(doubleClick: Bool) {
        guard let window, window.isKeyWindow, !interactionBlocked(window), let controller,
              controller.localEngine != nil, controller.isActive, !controller.preparing, !controller.stopping else { return }
        activity()
        if doubleClick { toggleFullScreen() } else { controller.togglePause() }
    }

    private func interactionBlocked(_ window: NSWindow) -> Bool {
        popoverOpen || scrubbing || !trackingMenus.isEmpty || transitioning
            || window.attachedSheet != nil || NSApp.modalWindow != nil
    }

    func toggleFullScreen() {
        guard !transitioning, let window, window.attachedSheet == nil else { return }
        activity(); window.toggleFullScreen(nil)
    }
    func fullScreenTransitionFailed() { endTransition() }

    @objc private func stateChanged() { activity() }
    @objc private func beginTransition() { transitioning = true; controlsHover.reset(); activity() }
    @objc private func endTransition() {
        transitioning = false
        isFullScreen = window?.styleMask.contains(.fullScreen) == true
        controlsHover.reset()
        activity()
    }
    @objc private func menuOpened(_ notification: Notification) {
        guard window?.isKeyWindow == true, let menu = notification.object as? NSMenu else { return }
        trackingMenus.insert(ObjectIdentifier(menu)); activity()
    }
    @objc private func menuClosed(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        trackingMenus.remove(ObjectIdentifier(menu)); activity()
    }

    private func refresh() {
        guard let window, let controller else { return }
        policy.configure(autoHide: controller.interfacePreferences.autoHideControls,
                         delay: controller.interfacePreferences.controlsHideDelay, now: now)
        let active = controller.localEngine != nil && controller.isActive && !controller.preparing
            && !controller.stopping && !controller.isPaused && !controller.isBuffering
        policy.update(.init(activePlayback: active, keyWindow: window.isKeyWindow,
                            blocked: controlsHover.isHovered || scrubbing || popoverOpen || !trackingMenus.isEmpty
                                || window.attachedSheet != nil || NSApp.modalWindow != nil
                                || NSWorkspace.shared.isVoiceOverEnabled
                                || (usingKeyboardFocus && PlaybackControlFocus(window: window) != nil),
                            transitioning: transitioning), now: now)
        let visible = policy.isVisible(now: now)
        if controlsVisible != visible { controlsVisible = visible }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.isKeyWindow, let controller, controller.localEngine != nil else { return event }
        // A mouse click can leave a slider as AppKit's first responder even after
        // the pointer leaves it. Only keyboard navigation pins that focus on screen.
        if event.type == .keyDown { usingKeyboardFocus = true }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .mouseMoved {
            usingKeyboardFocus = false
        }
        activity()
        guard event.type == .keyDown else { return event }
        let focusedControl = PlaybackControlFocus(window: window)
        let eligible = !interactionBlocked(window) && focusedControl?.owns(keyCode: event.keyCode) != true
        guard let action = PlaybackShortcut.resolve(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags, isRepeat: event.isARepeat, eligible: eligible, fullScreen: isFullScreen) else { return event }
        switch action {
        case .toggleFullScreen: toggleFullScreen()
        case .exitFullScreen: if isFullScreen { toggleFullScreen() }
        default:
            guard controller.isActive, !controller.preparing, !controller.stopping else { return event }
            switch action {
            case .togglePause: controller.togglePause()
            case .backward, .forward:
                guard controller.canSeek else { return event }
                controller.requestSeek(action == .backward ? .backward : .forward)
            case .volumeDown: controller.setVolume(controller.volume - 0.05)
            case .volumeUp: controller.setVolume(controller.volume + 0.05)
            case .mute: controller.toggleMute()
            case .slower: Task { await controller.stepPlaybackRate(increasing: false) }
            case .faster: Task { await controller.stepPlaybackRate(increasing: true) }
            case .normalSpeed: Task { await controller.setPlaybackRate(1) }
            default: break
            }
        }
        return nil
    }
}
