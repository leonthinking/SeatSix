import AppKit

enum PlaybackWindowGeometry {
    static let minimumSize = NSSize(width: 700, height: 460)
    // Allows the three native window buttons and the 44-point information accessory to coexist.
    static let minimumTitlebarInfoWidth: CGFloat = 120
    static let provisionalAspectRatio: CGFloat = 16.0 / 9

    static func isValid(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.size.width > 0 && frame.size.height > 0
    }

    static func screen(for frame: NSRect?, screens: [NSRect]) -> NSRect? {
        let usable = screens.filter(isValid)
        guard let first = usable.first else { return nil }
        guard let frame, isValid(frame) else { return first }
        let overlapping = usable.max { area(frame.intersection($0)) < area(frame.intersection($1)) }!
        if area(frame.intersection(overlapping)) > 0 { return overlapping }
        return usable.min { distance(frame, $0) < distance(frame, $1) }
    }

    static func openingFrame(aspectRatio: CGFloat, titleBarHeight: CGFloat, screen: NSRect) -> NSRect? {
        guard let size = videoWindowSize(width: screen.width * 0.9, aspectRatio: aspectRatio,
                                         titleBarHeight: titleBarHeight, screen: screen) else { return nil }
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The explicit fit command keeps the user's width and top edge when the available space permits it.
    static func fittedFrame(_ frame: NSRect, aspectRatio: CGFloat, titleBarHeight: CGFloat, screen: NSRect) -> NSRect? {
        guard isValid(frame), let size = videoWindowSize(width: frame.width, aspectRatio: aspectRatio,
                                                         titleBarHeight: titleBarHeight, screen: screen) else { return nil }
        return clamped(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                              width: size.width, height: size.height), to: screen)
    }

    private static func videoWindowSize(width: CGFloat, aspectRatio: CGFloat,
                                        titleBarHeight: CGFloat, screen: NSRect) -> NSSize? {
        guard isValid(screen), aspectRatio.isFinite, aspectRatio > 0,
              titleBarHeight.isFinite, titleBarHeight >= 0, titleBarHeight < screen.height else { return nil }
        let availableHeight = screen.height - titleBarHeight
        let targetWidth = min(width, screen.width)
        let videoHeight = min(targetWidth / aspectRatio, availableHeight)
        return NSSize(width: min(targetWidth, videoHeight * aspectRatio), height: videoHeight + titleBarHeight)
    }

    static func clamped(_ frame: NSRect, to screen: NSRect) -> NSRect {
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let x = a.midX - b.midX, y = a.midY - b.midY
        return x * x + y * y
    }
}

/// The ordinary window frame is kept only for the life of this player, including trips through full screen.
@MainActor
final class PlaybackWindowGeometryController: NSObject {
    private enum Phase { case initial, normal, fullScreenOrTransitioning }
    private let screens: () -> [NSRect]
    private weak var window: NSWindow?
    private var phase = Phase.initial
    private var normalFrame: NSRect?
    private var automaticAspectRatio: CGFloat?
    private var awaitingOpeningAspect = true
    private var titleBarHeight: CGFloat = 0
    private var pendingTransition: Task<Void, Never>?
    private var applyingFrame = false

    init(screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.screens = screens
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self); pendingTransition?.cancel() }

    func attach(to window: NSWindow, openingScreen: NSRect?, aspectRatio: CGFloat?) {
        precondition(self.window == nil)
        self.window = window
        titleBarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        normalFrame = PlaybackWindowGeometry.screen(for: openingScreen, screens: screens())
        automaticAspectRatio = validAspect(aspectRatio) ?? PlaybackWindowGeometry.provisionalAspectRatio
        applyNormalFrame()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didMoveNotification, object: window)
        center.addObserver(self, selector: #selector(frameChanged), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(userBeganAdjustingWindow), name: NSWindow.willMoveNotification, object: window)
        center.addObserver(self, selector: #selector(userBeganAdjustingWindow), name: NSWindow.willStartLiveResizeNotification, object: window)
        center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(beginFullScreenTransition), name: NSWindow.willExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(settleNormalWindow), name: NSWindow.didExitFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func activate() {
        guard phase == .initial else { return }
        // Showing the hosting view can resize it. Restore our calculated frame before honoring user changes.
        applyNormalFrame()
        phase = .normal
    }

    func resolveOpeningAspectRatio(_ ratio: CGFloat) {
        guard awaitingOpeningAspect, let ratio = validAspect(ratio) else { return }
        awaitingOpeningAspect = false
        automaticAspectRatio = ratio
        applyNormalFrame()
    }

    func cancelOpeningFit() {
        awaitingOpeningAspect = false
        automaticAspectRatio = nil
    }

    func fitToVideo(aspectRatio: CGFloat) {
        guard phase == .normal, let window, !window.styleMask.contains(.fullScreen),
              let screen = PlaybackWindowGeometry.screen(for: window.frame, screens: screens()),
              let frame = PlaybackWindowGeometry.fittedFrame(window.frame, aspectRatio: aspectRatio,
                                                            titleBarHeight: titleBarHeight, screen: screen) else { return }
        cancelOpeningFit()
        normalFrame = frame
        applyNormalFrame()
    }

    func reset(aspectRatio: CGFloat? = nil, awaitingDecodedAspect: Bool = false) {
        guard let window else { return }
        normalFrame = window.frame
        let ratio = validAspect(aspectRatio) ?? automaticAspectRatio
        awaitingOpeningAspect = awaitingDecodedAspect
        automaticAspectRatio = ratio ?? PlaybackWindowGeometry.provisionalAspectRatio
        applyNormalFrame()
    }

    private func validAspect(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }

    private func applyNormalFrame() {
        guard let window, phase != .fullScreenOrTransitioning, !window.styleMask.contains(.fullScreen),
              let screen = PlaybackWindowGeometry.screen(for: normalFrame, screens: screens()) else { return }
        let frame: NSRect
        if let ratio = automaticAspectRatio {
            guard let fit = PlaybackWindowGeometry.openingFrame(aspectRatio: ratio, titleBarHeight: titleBarHeight,
                                                               screen: screen) else { return }
            frame = fit
        } else if let normalFrame {
            frame = PlaybackWindowGeometry.clamped(normalFrame, to: screen)
        } else { return }
        applyingFrame = true
        defer { applyingFrame = false }
        // A tall film or a small display may require a smaller window than the usual controls.
        window.minSize = NSSize(width: min(PlaybackWindowGeometry.minimumSize.width, frame.width),
                                height: min(PlaybackWindowGeometry.minimumSize.height, frame.height))
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
        normalFrame = window.frame // AppKit aligns the requested rectangle to display pixels.
    }

    @objc private func frameChanged() {
        guard phase == .normal, !applyingFrame, let window, !window.styleMask.contains(.fullScreen),
              PlaybackWindowGeometry.isValid(window.frame), window.frame != normalFrame else { return }
        cancelOpeningFit()
        normalFrame = window.frame
    }

    @objc private func willEnterFullScreen() {
        frameChanged()
        beginFullScreenTransition()
    }

    @objc private func beginFullScreenTransition() {
        pendingTransition?.cancel()
        pendingTransition = nil
        phase = .fullScreenOrTransitioning
    }

    @objc private func userBeganAdjustingWindow() {
        // After didExit, AppKit can still send automatic move/resize events.
        // Only an explicit drag may interrupt the pending normal-frame restore.
        guard pendingTransition != nil, let window, !window.styleMask.contains(.fullScreen) else { return }
        pendingTransition?.cancel()
        pendingTransition = nil
        phase = .normal
        cancelOpeningFit()
        normalFrame = window.frame
    }

    func fullScreenTransitionFailed() {
        if window?.styleMask.contains(.fullScreen) == true { beginFullScreenTransition() }
        else { settleNormalWindow() }
    }

    @objc private func settleNormalWindow() {
        pendingTransition?.cancel()
        // AppKit may still restore its own frame after the didExit notification.
        pendingTransition = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.window?.styleMask.contains(.fullScreen) == false else { return }
            self.pendingTransition = nil
            self.phase = .normal
            self.applyNormalFrame()
        }
    }

    @objc private func screensChanged() {
        if phase == .normal { applyNormalFrame() }
    }
}
