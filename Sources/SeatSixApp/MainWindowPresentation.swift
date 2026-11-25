import AppKit
import SwiftUI

enum MainWindowGeometry {
    /// This is the outer window frame in points, including the title bar.
    static let preferredSize = NSSize(width: 1607, height: 978)

    static func frame(in visibleFrame: NSRect) -> NSRect? {
        guard visibleFrame.origin.x.isFinite, visibleFrame.origin.y.isFinite,
              visibleFrame.size.width.isFinite, visibleFrame.size.height.isFinite,
              visibleFrame.size.width > 0, visibleFrame.size.height > 0 else { return nil }
        let size = NSSize(width: min(preferredSize.width, visibleFrame.width),
                          height: min(preferredSize.height, visibleFrame.height))
        return NSRect(x: visibleFrame.midX - size.width / 2,
                      y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// Owns presentation of the main scene only. It never replaces SwiftUI's window
/// delegate or infers its target from the application's key window.
@MainActor
final class MainWindowPresentationController: NSObject {
    private weak var window: NSWindow?
    private let visibleFrame: @MainActor (NSWindow) -> NSRect?
    private let updateMinimumContentSize: @MainActor (NSSize) -> Void
    private var needsPresentation = false
    private var awaitingReopen = false
    private var fullScreenTransitioning = false
    private var minimumUpdatePending = false
    private var scheduled = false
    private var generation = 0

    init(visibleFrame: @escaping @MainActor (NSWindow) -> NSRect? = { window in
        (window.screen ?? NSScreen.main)?.visibleFrame
    }, updateMinimumContentSize: @escaping @MainActor (NSSize) -> Void = { _ in }) {
        self.visibleFrame = visibleFrame
        self.updateMinimumContentSize = updateMinimumContentSize
        super.init()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        needsPresentation = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willClose), name: NSWindow.willCloseNotification, object: window)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(self, selector: #selector(didPresent), name: name, object: window)
        }
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(beginFullScreenTransition), name: name, object: window)
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(endFullScreenTransition), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        schedulePresentation()
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        generation += 1
        scheduled = false
        needsPresentation = false
        awaitingReopen = false
        fullScreenTransitioning = false
        minimumUpdatePending = false
        window = nil
    }

    @objc private func willClose() {
        // Invalidate an initial layout callback if the scene was closed before
        // that callback ran. A retained SwiftUI window may reopen later.
        generation += 1
        scheduled = false
        needsPresentation = true
        awaitingReopen = true
        fullScreenTransitioning = false
    }

    @objc private func didPresent() {
        if needsPresentation {
            awaitingReopen = false
            schedulePresentation()
        }
        scheduleMinimumUpdate()
    }

    @objc private func beginFullScreenTransition() {
        fullScreenTransitioning = true
    }

    @objc private func endFullScreenTransition() {
        fullScreenTransitioning = false
        scheduleMinimumUpdate()
        schedulePresentation()
    }

    @objc private func screenChanged() {
        minimumUpdatePending = true
        scheduleMinimumUpdate()
        schedulePresentation()
    }

    private func scheduleMinimumUpdate() {
        guard minimumUpdatePending else { return }
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expectedGeneration,
                  self.minimumUpdatePending, !self.awaitingReopen, !self.fullScreenTransitioning,
                  let window = self.window, !window.styleMask.contains(.fullScreen),
                  let visible = self.visibleFrame(window),
                  MainWindowGeometry.frame(in: visible) != nil else { return }
            self.updateMinimum(for: window, visibleFrame: visible)
        }
    }

    private func updateMinimum(for window: NSWindow, visibleFrame: NSRect) {
        let contentSize = window.contentRect(forFrameRect: visibleFrame).size
        minimumUpdatePending = false
        updateMinimumContentSize(NSSize(width: min(930, max(0, contentSize.width)),
                                        height: min(650, max(0, contentSize.height))))
    }

    private func schedulePresentation() {
        guard needsPresentation, !awaitingReopen, !scheduled else { return }
        scheduled = true
        let expectedGeneration = generation
        // SwiftUI installs its initial/restored frame while attaching the root.
        // Apply after that layout, once per opening, rather than on every update.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            guard self.needsPresentation, !self.awaitingReopen, !self.fullScreenTransitioning,
                  let window = self.window,
                  !window.styleMask.contains(.fullScreen),
                  let visibleFrame = self.visibleFrame(window),
                  MainWindowGeometry.frame(in: visibleFrame) != nil else {
                self.scheduled = false
                return
            }
            // Reduce SwiftUI's minimum content constraints before resizing a
            // small-screen window; otherwise its hosting view grows it back.
            self.updateMinimum(for: window, visibleFrame: visibleFrame)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.generation == expectedGeneration else { return }
                self.scheduled = false
                guard self.needsPresentation, !self.awaitingReopen, !self.fullScreenTransitioning,
                      let window, self.window === window, !window.styleMask.contains(.fullScreen) else { return }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let currentVisibleFrame = self.visibleFrame(window),
                      let frame = MainWindowGeometry.frame(in: currentVisibleFrame) else { return }
                // A display may change between preparing SwiftUI's constraints
                // and applying the outer frame. Restart rather than publishing
                // geometry computed for the old display with the new minimum.
                guard currentVisibleFrame == visibleFrame else {
                    self.schedulePresentation()
                    return
                }
                self.needsPresentation = false
                window.setFrame(frame, display: true)
            }
        }
    }
}

struct MainWindowLayout: ViewModifier {
    var visibleFrame: @MainActor (NSWindow) -> NSRect? = { window in
        (window.screen ?? NSScreen.main)?.visibleFrame
    }
    @State private var minimumContentSize = NSSize(width: 930, height: 650)

    func body(content: Content) -> some View {
        content
            .frame(minWidth: minimumContentSize.width, minHeight: minimumContentSize.height)
            .background(MainWindowPresentation(visibleFrame: visibleFrame, updateMinimumContentSize: { size in
                if minimumContentSize != size { minimumContentSize = size }
            }).frame(width: 0, height: 0))
    }
}

struct MainWindowPresentation: NSViewRepresentable {
    var visibleFrame: @MainActor (NSWindow) -> NSRect? = { window in
        (window.screen ?? NSScreen.main)?.visibleFrame
    }
    var updateMinimumContentSize: @MainActor (NSSize) -> Void = { _ in }

    func makeNSView(context: Context) -> WindowProbe {
        WindowProbe(presentation: MainWindowPresentationController(visibleFrame: visibleFrame,
                                                                   updateMinimumContentSize: updateMinimumContentSize))
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        if let window = view.window { view.presentation.attach(to: window) }
    }

    static func dismantleNSView(_ view: WindowProbe, coordinator: ()) {
        view.presentation.detach()
    }

    final class WindowProbe: NSView {
        let presentation: MainWindowPresentationController

        init(presentation: MainWindowPresentationController) {
            self.presentation = presentation
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presentation.attach(to: window) }
        }
    }
}
