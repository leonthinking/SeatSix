import AppKit
import XCTest
@testable import SeatSixApp

final class HomeCarouselScrollInputTests: XCTestCase {
    func testHorizontalGestureNavigatesOnceAndMomentumCannotTurnAnotherPage() {
        var gesture = HomeCarouselScrollGesture()
        XCTAssertEqual(gesture.receive(sample(-12, phase: .began)).navigation, nil)
        XCTAssertEqual(gesture.receive(sample(-40, phase: .changed, time: 0.1)), .init(consumesEvent: true, navigation: 1))
        XCTAssertEqual(gesture.receive(sample(-100, phase: .changed, time: 0.2)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(0, phase: .ended, time: 0.3)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(-200, momentum: .began, time: 0.4)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(-200, momentum: .changed, time: 0.5)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(0, momentum: .ended, time: 0.6)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(60, phase: .began, time: 0.7)), .init(consumesEvent: true, navigation: -1))
    }

    func testVerticalAxisLocksAndDiagonalMovementDoesNotStealPageScrolling() {
        var gesture = HomeCarouselScrollGesture()
        XCTAssertEqual(gesture.receive(sample(3, y: -20, phase: .began)), .pass)
        XCTAssertEqual(gesture.receive(sample(-100, y: -10, phase: .changed, time: 0.1)), .pass)
        XCTAssertEqual(gesture.receive(sample(0, phase: .ended, time: 0.2)), .pass)
        XCTAssertEqual(gesture.receive(sample(-100, momentum: .began, time: 0.3)), .pass)
        gesture.reset()
        for index in 0..<5 {
            XCTAssertEqual(gesture.receive(sample(-15, y: -15, phase: index == 0 ? .began : .changed,
                                                 time: Double(index) * 0.03)), .pass)
        }
    }

    func testJitterCancellationAndEnteringMidGestureCannotTriggerNavigation() {
        var gesture = HomeCarouselScrollGesture()
        XCTAssertEqual(gesture.receive(sample(-100, phase: .changed)), .pass)
        XCTAssertEqual(gesture.receive(sample(-4, phase: .began)), .pass)
        XCTAssertEqual(gesture.receive(sample(3, phase: .changed, time: 0.1)), .pass)
        XCTAssertNil(gesture.receive(sample(-20, phase: .changed, time: 0.2)).navigation)
        XCTAssertEqual(gesture.receive(sample(-100, phase: .cancelled, time: 0.3)), .init(consumesEvent: true))
        XCTAssertEqual(gesture.receive(sample(-100, phase: .changed, time: 0.4)), .pass)
        XCTAssertEqual(gesture.receive(sample(-60, phase: .began, time: 0.5)).navigation, 1)
        gesture.reset()
        XCTAssertNil(gesture.receive(sample(-20, phase: .began)).navigation)
        XCTAssertNil(gesture.receive(sample(0, phase: .ended, time: 0.1)).navigation)
        XCTAssertNil(gesture.receive(sample(-100, momentum: .began, time: 0.2)).navigation,
                     "Momentum cannot push a short gesture across the threshold")
    }

    func testUnphasedWheelEventsUsePointEquivalentThresholdAndQuietGrouping() {
        var gesture = HomeCarouselScrollGesture()
        XCTAssertEqual(gesture.receive(sample(-3, precise: false)).navigation, nil)
        XCTAssertEqual(gesture.receive(sample(-2, precise: false, time: 0.05)).navigation, 1)
        XCTAssertNil(gesture.receive(sample(-20, precise: false, time: 0.15)).navigation)
        XCTAssertEqual(gesture.receive(sample(5, precise: false, time: 0.5)).navigation, -1)
        XCTAssertEqual(gesture.receive(sample(-50, time: 1)).navigation, 1)
        XCTAssertNil(gesture.receive(sample(-100, time: 1.1)).navigation)
    }

    func testInvalidDeltasAndResetDoNotRetainPartialGesture() {
        var gesture = HomeCarouselScrollGesture()
        XCTAssertNil(gesture.receive(sample(-30, phase: .began)).navigation)
        XCTAssertEqual(gesture.receive(sample(.nan, phase: .changed, time: 0.1)), .pass)
        XCTAssertEqual(gesture.receive(sample(-30, phase: .changed, time: 0.2)), .pass)
        XCTAssertEqual(gesture.receive(sample(-60, phase: .began, time: 0.3)).navigation, 1)
        gesture.reset()
        XCTAssertEqual(gesture.receive(sample(-100, momentum: .changed, time: 0.4)), .pass)
        XCTAssertEqual(gesture.receive(sample(-50, phase: .began, time: .infinity)), .pass)
    }

    @MainActor
    func testNativeScrollEventEntryDecodesDirectionPhasesAndMomentum() throws {
        _ = NSApplication.shared
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let bridge = HomeCarouselScrollInput.Coordinator()
        var navigations: [Int] = []
        bridge.configure(isEnabled: true, scope: "native", onNavigate: { navigations.append($0) })
        bridge.attach(fixture.probe)
        defer { bridge.detach() }

        func event(x: Int32, y: Int32 = 0, phase: CGScrollPhase? = nil,
                   momentum: CGMomentumScrollPhase = .none) throws -> NSEvent {
            // Construct native events in memory; never post them to the desktop.
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                          wheel1: y, wheel2: x, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
            return WindowedScrollTestEvent(native: try XCTUnwrap(NSEvent(cgEvent: cg)), window: fixture.window)
        }
        let first = try event(x: -60, phase: .began)
        XCTAssertTrue(first.hasPreciseScrollingDeltas)
        XCTAssertEqual(first.scrollingDeltaX, -60)
        XCTAssertEqual(first.phase, .began)
        XCTAssertNil(bridge.handle(first))
        XCTAssertEqual(navigations, [1])
        XCTAssertNil(bridge.handle(try event(x: -90, phase: .changed)))
        XCTAssertNil(bridge.handle(try event(x: 0, phase: .ended)))
        XCTAssertNil(bridge.handle(try event(x: -90, momentum: .begin)))
        let momentumEnd = try event(x: 0, momentum: .end)
        XCTAssertEqual(momentumEnd.momentumPhase, .ended)
        XCTAssertNil(bridge.handle(momentumEnd))
        XCTAssertEqual(navigations, [1])
        XCTAssertNil(bridge.handle(try event(x: 60, phase: .began)))
        XCTAssertEqual(navigations, [1, -1])
        let vertical = try event(x: 0, y: -60, phase: .began)
        XCTAssertTrue(bridge.handle(vertical) === vertical)
        let empty = try event(x: 0, phase: .began)
        XCTAssertTrue(bridge.handle(empty) === empty)
        fixture.window.simulatedKeyWindow = false
        let inactive = try event(x: -60, phase: .began)
        XCTAssertTrue(bridge.handle(inactive) === inactive)
        XCTAssertEqual(navigations, [1, -1])
    }

    @MainActor
    func testNonClippingHostCannotExtendInputIntoNeighboringRows() {
        _ = NSApplication.shared
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        fixture.probe.removeFromSuperview()
        fixture.window.contentView = root
        fixture.probe.frame = NSRect(x: 0, y: 100, width: 300, height: 100)
        fixture.probe.clipsToBounds = false
        root.addSubview(fixture.probe)
        let outside = NSPoint(x: 50, y: 50)
        let localOutside = fixture.probe.convert(outside, from: nil)
        XCTAssertFalse(fixture.probe.bounds.contains(localOutside))
        XCTAssertTrue(fixture.probe.visibleRect.contains(localOutside), "Reproduce AppKit's non-clipping host geometry")
        let bridge = HomeCarouselScrollInput.Coordinator()
        var navigations: [Int] = []
        bridge.configure(isEnabled: true, scope: "bounds", onNavigate: { navigations.append($0) })
        bridge.attach(fixture.probe)
        defer { bridge.detach() }
        XCTAssertFalse(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window, locationInWindow: outside))
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertTrue(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window,
                                     locationInWindow: NSPoint(x: 50, y: 150)))
        XCTAssertEqual(navigations, [1])
    }

    @MainActor
    func testBridgeFiltersWrongWindowInactiveHiddenAndObstructedViews() throws {
        _ = NSApplication.shared
        let fixture = makeFixture(), other = makeFixture()
        defer { fixture.window.close(); other.window.close() }
        var modal: NSWindow?
        let bridge = HomeCarouselScrollInput.Coordinator(modalWindow: { modal })
        var navigations: [Int] = []
        bridge.configure(isEnabled: true, scope: "one", onNavigate: { navigations.append($0) })
        bridge.attach(fixture.probe)
        defer { bridge.detach() }
        XCTAssertTrue(bridge.isMonitoring)
        let event = sample(-60, phase: .began)
        let point = NSPoint(x: 50, y: 50)
        XCTAssertFalse(bridge.consume(event, eventWindow: other.window, locationInWindow: point))
        XCTAssertFalse(bridge.consume(event, eventWindow: fixture.window, locationInWindow: NSPoint(x: 400, y: 50)))
        fixture.window.simulatedKeyWindow = false
        XCTAssertFalse(bridge.consume(event, eventWindow: fixture.window, locationInWindow: point))
        fixture.window.simulatedKeyWindow = true
        fixture.probe.isHidden = true
        XCTAssertFalse(bridge.consume(event, eventWindow: fixture.window, locationInWindow: point))
        fixture.probe.isHidden = false
        fixture.window.simulatedSheet = other.window
        XCTAssertFalse(bridge.consume(event, eventWindow: fixture.window, locationInWindow: point))
        fixture.window.simulatedSheet = nil
        modal = other.window
        XCTAssertFalse(bridge.consume(event, eventWindow: fixture.window, locationInWindow: point))
        modal = nil
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertTrue(bridge.consume(event, eventWindow: fixture.window, locationInWindow: point))
        XCTAssertEqual(navigations, [1])
        XCTAssertNil(fixture.probe.hitTest(point), "The probe must never intercept native buttons")
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        XCTAssertTrue(bridge.handle(key) === key)
    }

    @MainActor
    func testBridgeScopeVisibilityAndDetachResetPartialGestures() {
        _ = NSApplication.shared
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let bridge = HomeCarouselScrollInput.Coordinator()
        var navigations: [Int] = []
        let action: (Int) -> Void = { navigations.append($0) }
        bridge.configure(isEnabled: true, scope: "one", onNavigate: action)
        bridge.attach(fixture.probe)
        let point = NSPoint(x: 50, y: 50)
        XCTAssertTrue(bridge.consume(sample(-30, phase: .began), eventWindow: fixture.window, locationInWindow: point))
        bridge.configure(isEnabled: true, scope: "two", onNavigate: action)
        XCTAssertFalse(bridge.consume(sample(-30, phase: .changed, time: 0.1), eventWindow: fixture.window, locationInWindow: point))
        bridge.configure(isEnabled: false, scope: "two", onNavigate: action)
        XCTAssertFalse(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window, locationInWindow: point))
        bridge.configure(isEnabled: true, scope: "two", onNavigate: action)
        XCTAssertFalse(bridge.consume(sample(-60, phase: .changed), eventWindow: fixture.window, locationInWindow: point))
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertTrue(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window, locationInWindow: point))
        XCTAssertEqual(navigations, [1])
        bridge.detach()
        XCTAssertFalse(bridge.isMonitoring)
        XCTAssertFalse(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window, locationInWindow: point))
        XCTAssertEqual(navigations, [1])
    }

    @MainActor
    func testBridgeUsesClippedVisibleRegionAndPassesVerticalScrollThrough() {
        _ = NSApplication.shared
        let fixture = makeFixture()
        defer { fixture.window.close() }
        let clip = NSClipView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        fixture.probe.removeFromSuperview()
        fixture.probe.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        clip.documentView = fixture.probe
        fixture.window.contentView = clip
        let bridge = HomeCarouselScrollInput.Coordinator()
        var navigations: [Int] = []
        bridge.configure(isEnabled: true, scope: "one", onNavigate: { navigations.append($0) })
        bridge.attach(fixture.probe)
        defer { bridge.detach() }
        // NSWindow can resize its content view; explicitly constrain the probe's
        // ancestor so visibleRect, not the probe's larger bounds, decides routing.
        clip.frame.size = NSSize(width: 100, height: 100)
        XCTAssertLessThanOrEqual(fixture.probe.visibleRect.width, 100)
        XCTAssertFalse(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window,
                                      locationInWindow: NSPoint(x: 160, y: 50)))
        XCTAssertFalse(bridge.consume(sample(0, y: -60, phase: .began), eventWindow: fixture.window,
                                      locationInWindow: NSPoint(x: 50, y: 50)))
        XCTAssertTrue(navigations.isEmpty)
        XCTAssertTrue(bridge.consume(sample(-60, phase: .began), eventWindow: fixture.window,
                                     locationInWindow: NSPoint(x: 50, y: 50)))
        XCTAssertEqual(navigations, [1])
    }

    private func sample(_ x: CGFloat, y: CGFloat = 0, precise: Bool = true, phase: NSEvent.Phase = [],
                        momentum: NSEvent.Phase = [], time: TimeInterval = 0) -> HomeCarouselScrollGesture.Sample {
        .init(deltaX: x, deltaY: y, precise: precise, phase: phase, momentumPhase: momentum, timestamp: time)
    }

    @MainActor
    private func makeFixture() -> (window: CarouselScrollTestWindow, probe: HomeCarouselScrollInput.Probe) {
        let window = CarouselScrollTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let probe = HomeCarouselScrollInput.Probe(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = probe
        return (window, probe)
    }
}

/// Native fields come from CGEvent→NSEvent. Only window routing is supplied by
/// the fixture because an unposted event has no application window association.
private final class WindowedScrollTestEvent: NSEvent {
    let native: NSEvent
    let target: NSWindow
    init(native: NSEvent, window: NSWindow) { self.native = native; target = window; super.init() }
    required init?(coder: NSCoder) { fatalError("Test event does not support decoding") }
    override var type: NSEvent.EventType { native.type }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { NSPoint(x: 50, y: 50) }
    override var scrollingDeltaX: CGFloat { native.scrollingDeltaX }
    override var scrollingDeltaY: CGFloat { native.scrollingDeltaY }
    override var hasPreciseScrollingDeltas: Bool { native.hasPreciseScrollingDeltas }
    override var phase: NSEvent.Phase { native.phase }
    override var momentumPhase: NSEvent.Phase { native.momentumPhase }
    override var timestamp: TimeInterval { native.timestamp }
}

@MainActor
private final class CarouselScrollTestWindow: NSWindow {
    var simulatedKeyWindow = true
    var simulatedSheet: NSWindow?
    override var isKeyWindow: Bool { simulatedKeyWindow }
    override var attachedSheet: NSWindow? { simulatedSheet ?? super.attachedSheet }
}
