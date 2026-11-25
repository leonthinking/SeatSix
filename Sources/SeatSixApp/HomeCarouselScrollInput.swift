import AppKit
import SwiftUI

/// A two-finger scroll is a stream, including momentum after the fingers lift.
/// Decide the axis once and navigate at most once for each physical gesture.
struct HomeCarouselScrollGesture {
    struct Sample {
        var deltaX: CGFloat
        var deltaY: CGFloat
        var precise = true
        var phase: NSEvent.Phase = []
        var momentumPhase: NSEvent.Phase = []
        var timestamp: TimeInterval
    }

    struct Result: Equatable {
        var consumesEvent = false
        var navigation: Int?
        static let pass = Result()
    }

    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var navigated = false
    private var phasedGestureActive = false
    private var lastWasPhased = false
    private var lastTimestamp: TimeInterval?
    private let threshold: CGFloat = 48
    private let unphasedQuietInterval: TimeInterval = 0.28

    mutating func reset() { self = Self() }

    mutating func receive(_ sample: Sample) -> Result {
        guard sample.deltaX.isFinite, sample.deltaY.isFinite, sample.timestamp.isFinite else {
            reset(); return .pass
        }
        if !sample.momentumPhase.isEmpty {
            let consumed = axis == .horizontal
            // Momentum never starts or completes a navigation, even if the
            // gesture itself ended just short of the threshold.
            if sample.momentumPhase.contains(.ended) || sample.momentumPhase.contains(.cancelled) { reset() }
            return Result(consumesEvent: consumed)
        }
        let phased = !sample.phase.isEmpty
        if sample.phase.contains(.began) {
            reset(); phasedGestureActive = true; lastWasPhased = true
        } else if sample.phase.contains(.mayBegin) {
            reset(); return .pass
        } else if phased && !phasedGestureActive {
            // An already-running gesture can enter the banner, or the banner
            // can become visible mid-gesture. Wait for a fresh gesture start.
            return .pass
        } else if !phased {
            if lastWasPhased || lastTimestamp.map({ sample.timestamp < $0 || sample.timestamp - $0 > unphasedQuietInterval }) != false {
                reset()
            }
        }
        lastTimestamp = sample.timestamp
        lastWasPhased = phased
        if sample.phase.contains(.cancelled) {
            let consumed = axis == .horizontal
            reset(); return Result(consumesEvent: consumed)
        }

        // Precise trackpad deltas are points. Conventional wheels report lines.
        let scale: CGFloat = sample.precise ? 1 : 10
        accumulatedX += sample.deltaX * scale
        accumulatedY += sample.deltaY * scale
        if axis == .undecided {
            let x = abs(accumulatedX), y = abs(accumulatedY)
            if x >= 8 && x >= y * 1.35 { axis = .horizontal }
            else if y >= 8 && y >= x * 1.35 { axis = .vertical }
        }
        var result = Result(consumesEvent: axis == .horizontal)
        if axis == .horizontal && !navigated && abs(accumulatedX) >= threshold {
            navigated = true
            // AppKit has already applied the user's natural-scrolling setting.
            result.navigation = accumulatedX < 0 ? 1 : -1
        }
        if sample.phase.contains(.ended) { phasedGestureActive = false }
        return result
    }
}

/// A non-hit-testing probe observes only scroll events inside the visible hero.
/// Buttons retain their native input, and vertical scrolling reaches the parent.
struct HomeCarouselScrollInput: NSViewRepresentable {
    let isEnabled: Bool
    let scope: String
    let onNavigate: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.changed = { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.attach(view) }
        }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.configure(isEnabled: isEnabled, scope: scope, onNavigate: onNavigate)
        context.coordinator.attach(view)
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        view.changed = nil
        coordinator.detach()
    }

    final class Probe: NSView {
        var changed: (() -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed?() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); changed?() }
    }

    @MainActor
    final class Coordinator {
        private weak var probe: Probe?
        private weak var window: NSWindow?
        private var monitor: Any?
        private var isEnabled = false
        private var scope = ""
        private var onNavigate: (Int) -> Void = { _ in }
        private var gesture = HomeCarouselScrollGesture()
        private let modalWindow: () -> NSWindow?
        var isMonitoring: Bool { monitor != nil }

        init(modalWindow: @escaping () -> NSWindow? = { NSApplication.shared.modalWindow }) {
            self.modalWindow = modalWindow
        }

        func configure(isEnabled: Bool, scope: String, onNavigate: @escaping (Int) -> Void) {
            if self.isEnabled != isEnabled || self.scope != scope { gesture.reset() }
            self.isEnabled = isEnabled; self.scope = scope; self.onNavigate = onNavigate
        }

        func attach(_ view: Probe) {
            guard probe !== view || window !== view.window else { return }
            detach()
            probe = view; window = view.window
            guard view.window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; probe = nil; window = nil; gesture.reset()
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.type == .scrollWheel else { return event }
            let sample = HomeCarouselScrollGesture.Sample(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas, phase: event.phase,
                momentumPhase: event.momentumPhase, timestamp: event.timestamp)
            return consume(sample, eventWindow: event.window, locationInWindow: event.locationInWindow) ? nil : event
        }

        /// Separates native event decoding from the window/geometry gate so
        /// tests can exercise real NSViews without posting desktop events.
        func consume(_ sample: HomeCarouselScrollGesture.Sample, eventWindow: NSWindow?, locationInWindow: NSPoint) -> Bool {
            // Non-clipping SwiftUI hosts can report a visibleRect extending
            // outside this view. Never consume a neighboring row's scrolling.
            guard isEnabled, let probe, let window,
                  probe.window === window, eventWindow === window, window.isKeyWindow,
                  !probe.isHiddenOrHasHiddenAncestor, window.attachedSheet == nil, modalWindow() == nil,
                  !probe.visibleRect.intersection(probe.bounds).isEmpty,
                  probe.visibleRect.intersection(probe.bounds).contains(probe.convert(locationInWindow, from: nil)) else {
                gesture.reset(); return false
            }
            let result = gesture.receive(sample)
            if let navigation = result.navigation { onNavigate(navigation) }
            return result.consumesEvent
        }
    }
}
