import AppKit

/// Minimizing is an explicit pause request. Restoring the window or changing the
/// preference cannot undo that request while an asynchronous load is completing.
struct PlaybackMinimizePausePolicy {
    private(set) var enabled: Bool
    private(set) var isMiniaturized = false
    private(set) var requiresExplicitResume = false

    init(enabled: Bool = false) { self.enabled = enabled }
    var blocksExplicitPlayback: Bool { enabled && isMiniaturized }
    var blocksAutomaticPlayback: Bool { requiresExplicitResume || blocksExplicitPlayback }

    mutating func update(enabled: Bool) {
        self.enabled = enabled
        if blocksExplicitPlayback { requiresExplicitResume = true }
    }
    mutating func setMiniaturized(_ value: Bool) {
        isMiniaturized = value
        if blocksExplicitPlayback { requiresExplicitResume = true }
    }
    mutating func inheritPause(from previous: Self) {
        requiresExplicitResume = requiresExplicitResume || previous.requiresExplicitResume
    }
    @discardableResult mutating func requestExplicitPlayback() -> Bool {
        guard !blocksExplicitPlayback else { return false }
        requiresExplicitResume = false
        return true
    }
}

/// Window ownership keeps the pin choice stable when an episode replaces its
/// player. Notifications are synchronous so fullscreen never starts floating.
@MainActor
final class PlaybackWindowBehavior: NSObject {
    private weak var window: NSWindow?
    private(set) var keepOnTop: Bool
    private var fullScreenOrTransition = false
    private var presentingSheet = false
    private var anotherAppWindowIsKey = false
    var onMiniaturizedChange: ((Bool) -> Void)?
    var onPinChange: ((Bool) -> Void)?

    init(keepOnTop: Bool) { self.keepOnTop = keepOnTop; super.init() }
    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to window: NSWindow) {
        precondition(self.window == nil)
        self.window = window
        // AppKit otherwise infers a floating window is an auxiliary window:
        // its green button becomes Zoom and toggleFullScreen is ignored before
        // any transition notification can arrive. Keep the playback window a
        // fullscreen primary even while pinned, preserving unrelated behavior.
        window.collectionBehavior.subtract([.fullScreenAuxiliary, .fullScreenNone])
        window.collectionBehavior.insert(.fullScreenPrimary)
        fullScreenOrTransition = window.styleMask.contains(.fullScreen)
        presentingSheet = window.attachedSheet != nil
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willMiniaturize), name: NSWindow.willMiniaturizeNotification, object: window)
        center.addObserver(self, selector: #selector(didDeminiaturize), name: NSWindow.didDeminiaturizeNotification, object: window)
        center.addObserver(self, selector: #selector(beginFullScreenTransition), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(beginFullScreenTransition), name: NSWindow.willExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didEnterFullScreen), name: NSWindow.didEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(willBeginSheet), name: NSWindow.willBeginSheetNotification, object: window)
        center.addObserver(self, selector: #selector(didEndSheet), name: NSWindow.didEndSheetNotification, object: window)
        center.addObserver(self, selector: #selector(appWindowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(detach), name: NSWindow.willCloseNotification, object: window)
        applyLevel()
        onMiniaturizedChange?(window.isMiniaturized)
        onPinChange?(keepOnTop)
    }

    func togglePin() { keepOnTop.toggle(); applyLevel(); onPinChange?(keepOnTop) }
    func fullScreenTransitionFailed() {
        fullScreenOrTransition = window?.styleMask.contains(.fullScreen) == true
        applyLevel()
    }
    @objc func detach() {
        NotificationCenter.default.removeObserver(self)
        window?.level = .normal
        window = nil
        onMiniaturizedChange = nil
        onPinChange = nil
    }
    @objc private func willMiniaturize() { onMiniaturizedChange?(true) }
    @objc private func didDeminiaturize() { onMiniaturizedChange?(false) }
    @objc private func beginFullScreenTransition() { fullScreenOrTransition = true; applyLevel() }
    @objc private func didEnterFullScreen() { fullScreenOrTransition = true; applyLevel() }
    @objc private func didExitFullScreen() { fullScreenOrTransition = false; applyLevel() }
    @objc private func willBeginSheet() { presentingSheet = true; applyLevel() }
    @objc private func didEndSheet() { presentingSheet = false; applyLevel() }
    @objc private func appWindowBecameKey(_ notification: Notification) {
        guard let keyWindow = notification.object as? NSWindow else { return }
        anotherAppWindowIsKey = keyWindow !== window
        applyLevel()
    }
    @objc private func appBecameActive() {
        anotherAppWindowIsKey = NSApp.keyWindow.map { $0 !== window } ?? false
        applyLevel()
    }
    @objc private func appResignedActive() {
        // A Settings or library window must remain usable inside SeatSix. When
        // switching to another application, the user's floating choice resumes.
        anotherAppWindowIsKey = false
        applyLevel()
    }
    private func applyLevel() {
        guard let window else { return }
        window.level = keepOnTop && !fullScreenOrTransition && !window.styleMask.contains(.fullScreen) && !presentingSheet && !anotherAppWindowIsKey ? .floating : .normal
    }
}
