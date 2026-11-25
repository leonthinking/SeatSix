import AppKit
import SwiftUI
import XCTest
@testable import SeatSixApp

final class MainWindowGeometryTests: XCTestCase {
    func testPreferredOuterFrameIsGeometricallyCenteredInVisibleArea() throws {
        let visible = NSRect(x: 0, y: 40, width: 1920, height: 1040)
        let frame = try XCTUnwrap(MainWindowGeometry.frame(in: visible))
        XCTAssertEqual(frame.size, NSSize(width: 1607, height: 978))
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.midY, visible.midY)
        XCTAssertTrue(visible.contains(frame))
    }

    func testSmallScreensClampEachDimensionWithoutLeavingVisibleArea() throws {
        for visible in [NSRect(x: 25, y: 30, width: 800, height: 500),
                        NSRect(x: 0, y: 40, width: 1400, height: 1200),
                        NSRect(x: 0, y: 0, width: 1920, height: 700)] {
            let frame = try XCTUnwrap(MainWindowGeometry.frame(in: visible))
            XCTAssertEqual(frame.width, min(1607, visible.width))
            XCTAssertEqual(frame.height, min(978, visible.height))
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testSecondaryScreenOriginsArePreserved() throws {
        for visible in [NSRect(x: -2560, y: -260, width: 2560, height: 1400),
                        NSRect(x: 1920, y: 800, width: 1920, height: 1080)] {
            let frame = try XCTUnwrap(MainWindowGeometry.frame(in: visible))
            XCTAssertEqual(frame.size, MainWindowGeometry.preferredSize)
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.midY, visible.midY)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testUnavailableOrInvalidScreenGeometryIsNotApplied() {
        for visible in [NSRect.zero, NSRect(x: 0, y: 0, width: -1, height: 100),
                        NSRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                        NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            XCTAssertNil(MainWindowGeometry.frame(in: visible))
        }
    }
}

@MainActor
final class MainWindowPresentationTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 40, width: 1920, height: 1040)

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func nextMainQueueTurn() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func assertFrame(_ actual: NSRect, equals expected: NSRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        // AppKit rounds a half-point origin on a non-Retina/offscreen window.
        XCTAssertEqual(actual.origin.x, expected.origin.x, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.origin.y, expected.origin.y, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.size, expected.size, file: file, line: line)
    }

    func testFreshAttachmentOverridesRestoredFrameAfterInitialLayout() async throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: window)
        let restored = NSRect(x: 50, y: 50, width: 1110, height: 760)
        window.setFrame(restored, display: false)
        XCTAssertEqual(window.frame, restored, "The initial SwiftUI layout completes before presentation")
        await nextMainQueueTurn()
        assertFrame(window.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
    }

    func testScreenChangeBetweenPreparationAndApplicationRecomputesFrameAndMinimum() async throws {
        let window = makeWindow()
        defer { window.close() }
        var currentVisible = visible
        var minimums: [NSSize] = []
        let small = NSRect(x: 25, y: 30, width: 800, height: 500)
        let presentation = MainWindowPresentationController(visibleFrame: { _ in currentVisible },
                                                             updateMinimumContentSize: { minimums.append($0) })
        presentation.attach(to: window)
        // attach queued preparation A; this queues B before A queues its frame
        // application C, deterministically changing screens between the phases.
        DispatchQueue.main.async {
            currentVisible = small
            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        }
        await nextMainQueueTurn()
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, small)
        XCTAssertEqual(minimums.first, NSSize(width: 930, height: 650), "The original preparation ran before the display changed")
        XCTAssertEqual(minimums.last, window.contentRect(forFrameRect: small).size)
    }

    func testScreenAvailabilityRetriesPendingInitialPresentationWithoutFocus() async throws {
        let window = makeWindow()
        defer { window.close() }
        var currentVisible: NSRect?
        let original = window.frame
        let presentation = MainWindowPresentationController(visibleFrame: { _ in currentVisible })
        presentation.attach(to: window)
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, original)
        currentVisible = visible
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        assertFrame(window.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
    }

    func testFocusUpdatesAndManualResizeDoNotReapplyPresentation() async throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: window)
        await nextMainQueueTurn()
        let manualFrame = NSRect(x: 65, y: 75, width: 1150, height: 780)
        window.setFrame(manualFrame, display: false)
        for _ in 0..<3 {
            presentation.attach(to: window)
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.post(name: name, object: window)
            }
        }
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, manualFrame)
    }

    func testClosingThenReopeningRetainedWindowUsesCurrentScreenOnce() async throws {
        let window = makeWindow()
        defer { window.close() }
        var currentVisible = visible
        let presentation = MainWindowPresentationController(visibleFrame: { _ in currentVisible })
        presentation.attach(to: window)
        await nextMainQueueTurn()
        window.setFrame(NSRect(x: 100, y: 100, width: 1100, height: 720), display: false)
        window.close()
        let closedFrame = window.frame
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, closedFrame)
        currentVisible = NSRect(x: 0, y: 25, width: 1360, height: 850)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await nextMainQueueTurn()
        assertFrame(window.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: currentVisible)))
        let resized = NSRect(x: 80, y: 90, width: 1000, height: 700)
        window.setFrame(resized, display: false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, resized)
    }

    func testCloseBeforeDeferredPresentationWaitsForReopen() async throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: window)
        window.close()
        let closedFrame = window.frame
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, closedFrame)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await nextMainQueueTurn()
        assertFrame(window.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
    }

    func testSmallScreenClampsActualWindowOuterFrame() async throws {
        let window = makeWindow()
        defer { window.close() }
        let small = NSRect(x: 25, y: 30, width: 800, height: 500)
        let host = NSHostingView(rootView: Color.black.modifier(MainWindowLayout(visibleFrame: { _ in small })))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, small)
    }

    func testPendingPresentationWaitsThroughFullScreenTransitions() async throws {
        let window = makeWindow()
        defer { window.close() }
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: window)
        let original = window.frame
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, original, "A transition may begin before the fullScreen style bit is set")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, original, "Focus cannot resize the window while a transition owns it")
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await nextMainQueueTurn()
        assertFrame(window.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
    }

    func testOtherWindowsCannotTriggerPresentationAndKeepTheirDelegatesAndFrames() async throws {
        let main = makeWindow()
        let player = makeWindow()
        let settings = makeWindow()
        let delegate = UnmodifiedWindowDelegate()
        main.delegate = delegate
        defer { main.close(); player.close(); settings.close() }
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: main)
        await nextMainQueueTurn()
        XCTAssertTrue(main.delegate === delegate)
        main.close()
        let frames = [main.frame, player.frame, settings.frame]
        for other in [player, settings] {
            for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didExitFullScreenNotification] {
                NotificationCenter.default.post(name: name, object: other)
            }
        }
        await nextMainQueueTurn()
        XCTAssertEqual([main.frame, player.frame, settings.frame], frames)
        XCTAssertTrue(main.delegate === delegate)
    }

    func testReattachingToNewWindowInvalidatesOldDeferredWork() async throws {
        let previous = makeWindow()
        let current = makeWindow()
        defer { previous.close(); current.close() }
        let previousFrame = previous.frame
        let presentation = MainWindowPresentationController(visibleFrame: { _ in self.visible })
        presentation.attach(to: previous)
        presentation.attach(to: current)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: previous)
        await nextMainQueueTurn()
        XCTAssertEqual(previous.frame, previousFrame)
        assertFrame(current.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
        presentation.detach()
        let manual = NSRect(x: 70, y: 60, width: 1000, height: 750)
        current.setFrame(manual, display: false)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: current)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: current)
        await nextMainQueueTurn()
        XCTAssertEqual(current.frame, manual)
    }

    func testSwiftUIWindowProbeAttachesOnlyItsContainingWindow() async throws {
        let main = makeWindow()
        let other = makeWindow()
        defer { main.close(); other.close() }
        let otherFrame = other.frame
        let host = NSHostingView(rootView: Color.black.modifier(MainWindowLayout(visibleFrame: { _ in self.visible })))
        main.contentView = host
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        assertFrame(main.frame, equals: try XCTUnwrap(MainWindowGeometry.frame(in: visible)))
        XCTAssertEqual(other.frame, otherFrame)
    }

    func testScreenChangesUpdateSwiftUIMinimumWithoutRestoringPreferredFrame() async throws {
        let window = makeWindow()
        defer { window.close() }
        var currentVisible = visible
        let host = NSHostingView(rootView: Color.black.modifier(MainWindowLayout(visibleFrame: { _ in currentVisible })))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        let manual = NSRect(x: 70, y: 80, width: 1100, height: 760)
        window.setFrame(manual, display: false)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, manual, "Screen changes must not reset a manually sized normal window")
        XCTAssertEqual(host.fittingSize, NSSize(width: 930, height: 650))

        currentVisible = NSRect(x: 25, y: 30, width: 800, height: 500)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        window.setFrame(currentVisible, display: false)
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        XCTAssertEqual(window.frame, currentVisible, "The SwiftUI minimum must also fit the new small screen")

        currentVisible = visible
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize, NSSize(width: 930, height: 650))
        XCTAssertNotEqual(window.frame.size, MainWindowGeometry.preferredSize,
                          "Returning to a large screen restores the minimum, not the launch size")
    }

    func testScreenMinimumChangeWaitsUntilFullScreenTransitionsFinish() async throws {
        let window = makeWindow()
        defer { window.close() }
        let small = NSRect(x: 25, y: 30, width: 800, height: 500)
        var currentVisible = small
        let host = NSHostingView(rootView: Color.black.modifier(MainWindowLayout(visibleFrame: { _ in currentVisible })))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await nextMainQueueTurn()
        let smallContent = window.contentRect(forFrameRect: small).size
        XCTAssertEqual(host.fittingSize, smallContent)
        XCTAssertEqual(window.frame, small)

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        currentVisible = visible
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(host.fittingSize, smallContent)
        XCTAssertEqual(window.frame, small, "Changing SwiftUI's minimum must not enlarge a transitioning window")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
        await nextMainQueueTurn()
        XCTAssertEqual(host.fittingSize, smallContent)
        XCTAssertEqual(window.frame, small)

        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await nextMainQueueTurn()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize, NSSize(width: 930, height: 650), "The deferred screen update must be applied after leaving full screen")
        XCTAssertNotEqual(window.frame.size, MainWindowGeometry.preferredSize)
    }
}

@MainActor
private final class UnmodifiedWindowDelegate: NSObject, NSWindowDelegate {}
