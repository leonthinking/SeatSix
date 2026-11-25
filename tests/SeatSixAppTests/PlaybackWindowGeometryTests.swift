import AppKit
import XCTest
@testable import SeatSixApp

@MainActor
final class PlaybackWindowGeometryTests: XCTestCase {
    private let main = NSRect(x: 0, y: 25, width: 1440, height: 850)
    private let second = NSRect(x: -1920, y: -200, width: 1920, height: 1080)

    private func playerWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func assertOpening(_ window: NSWindow, on screen: NSRect, ratio: CGFloat,
                               file: StaticString = #filePath, line: UInt = #line) {
        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let titleBar = frame.height - content.height
        let expectedWidth = min(screen.width * 0.9, ratio * (screen.height - titleBar))
        XCTAssertEqual(content.width, expectedWidth, accuracy: 1, file: file, line: line)
        XCTAssertEqual(content.height, expectedWidth / ratio, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(frame.midY, screen.midY, accuracy: 1, file: file, line: line)
        XCTAssertTrue(screen.insetBy(dx: -1, dy: -1).contains(frame), file: file, line: line)
    }

    func testCenteredOpeningUsesNinetyPercentUnlessVideoHeightLimitsWidth() throws {
        let screens = [main, second, NSRect(x: 100, y: 35, width: 500, height: 305)]
        for screen in screens {
            for ratio in [2.39, 16.0 / 9, 4.0 / 3, 1, 9.0 / 16, 1.0 / 4, 5] {
                let frame = try XCTUnwrap(PlaybackWindowGeometry.openingFrame(aspectRatio: ratio,
                                                                             titleBarHeight: 28, screen: screen))
                let expectedWidth = min(screen.width * 0.9, ratio * (screen.height - 28))
                XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.0001)
                XCTAssertEqual(frame.width / (frame.height - 28), ratio, accuracy: 0.0001)
                XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.0001)
                XCTAssertEqual(frame.midY, screen.midY, accuracy: 0.0001)
                XCTAssertTrue(screen.insetBy(dx: -0.0001, dy: -0.0001).contains(frame))
            }
        }
    }

    func testFitToFilmKeepsWidthAndTopWhenPossibleAndRespectsPortraitAndSmallScreens() throws {
        let frame = NSRect(x: 70, y: 60, width: 1250, height: 720)
        let fitted = try XCTUnwrap(PlaybackWindowGeometry.fittedFrame(frame, aspectRatio: 2.35, titleBarHeight: 28, screen: main))
        XCTAssertEqual(fitted.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(fitted.maxY, frame.maxY)
        XCTAssertEqual(fitted.width / (fitted.height - 28), 2.35, accuracy: 0.001)
        let portrait = try XCTUnwrap(PlaybackWindowGeometry.fittedFrame(frame, aspectRatio: 9.0 / 16, titleBarHeight: 28, screen: main))
        XCTAssertEqual(portrait.height, main.height)
        XCTAssertEqual(portrait.width / (portrait.height - 28), 9.0 / 16, accuracy: 0.001)
        let small = NSRect(x: -580, y: -40, width: 480, height: 310)
        let fit = try XCTUnwrap(PlaybackWindowGeometry.fittedFrame(frame, aspectRatio: 2.35, titleBarHeight: 28, screen: small))
        XCTAssertEqual(fit.width, small.width)
        XCTAssertTrue(small.contains(fit))
        XCTAssertEqual(fit.width / (fit.height - 28), 2.35, accuracy: 0.001)
    }

    func testInvalidAspectsAndScreensNeverProduceNonfiniteGeometry() {
        for ratio in [0, -1, CGFloat.nan, .infinity] {
            XCTAssertNil(PlaybackWindowGeometry.openingFrame(aspectRatio: ratio, titleBarHeight: 28, screen: main))
            XCTAssertNil(PlaybackWindowGeometry.fittedFrame(main, aspectRatio: ratio, titleBarHeight: 28, screen: main))
        }
        for titleHeight in [-1, CGFloat.nan, main.height] {
            XCTAssertNil(PlaybackWindowGeometry.openingFrame(aspectRatio: 2, titleBarHeight: titleHeight, screen: main))
        }
        XCTAssertNil(PlaybackWindowGeometry.screen(for: nil, screens: []))
        let invalid = NSRect(x: CGFloat.nan, y: 0, width: 800, height: 600)
        XCTAssertEqual(PlaybackWindowGeometry.screen(for: invalid, screens: [invalid, main]), main)
    }

    func testEveryNewWindowUsesItsOpeningDisplayRegardlessOfTheLastWindow() {
        let first = playerWindow()
        let next = playerWindow()
        defer { first.close(); next.close() }
        let screens = [main, second]
        let firstGeometry = PlaybackWindowGeometryController(screens: { screens })
        firstGeometry.attach(to: first, openingScreen: second, aspectRatio: 9.0 / 16)
        firstGeometry.activate()
        assertOpening(first, on: second, ratio: 9.0 / 16)
        XCTAssertLessThan(first.frame.width, PlaybackWindowGeometry.minimumSize.width)
        let dragged = NSRect(x: -1700, y: 50, width: 1000, height: 500)
        first.setFrame(dragged, display: false)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)

        let nextGeometry = PlaybackWindowGeometryController(screens: { screens })
        nextGeometry.attach(to: next, openingScreen: main, aspectRatio: 2.39)
        nextGeometry.activate()
        assertOpening(next, on: main, ratio: 2.39)
        XCTAssertEqual(first.frame, dragged)
    }

    func testLateAspectCorrectsOnlyUntouchedOpeningWindow() {
        let window = playerWindow()
        defer { window.close() }
        let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
        geometry.attach(to: window, openingScreen: main, aspectRatio: nil)
        window.setFrame(NSRect(x: 0, y: 50, width: 550, height: 480), display: false)
        geometry.activate()
        assertOpening(window, on: main, ratio: 16.0 / 9)
        // Delayed notifications for the programmatically requested frame must not cancel the fit.
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        geometry.resolveOpeningAspectRatio(.nan)
        geometry.resolveOpeningAspectRatio(9.0 / 16)
        assertOpening(window, on: main, ratio: 9.0 / 16)
        let resolved = window.frame
        geometry.resolveOpeningAspectRatio(2.39)
        XCTAssertEqual(window.frame, resolved)
    }

    func testManualMoveResizeOrReusedWindowCancelsLateAspect() {
        for action in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, nil] {
            let window = playerWindow()
            defer { window.close() }
            let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
            geometry.attach(to: window, openingScreen: main, aspectRatio: 2)
            geometry.activate()
            if let action {
                let frame = action == NSWindow.didMoveNotification
                    ? window.frame.offsetBy(dx: 10, dy: -15)
                    : NSRect(x: 100, y: 80, width: 1000, height: 550)
                window.setFrame(frame, display: false)
                NotificationCenter.default.post(name: action, object: window)
            } else {
                geometry.cancelOpeningFit()
            }
            let userFrame = window.frame
            geometry.resolveOpeningAspectRatio(9.0 / 16)
            XCTAssertEqual(window.frame, userFrame)
        }
    }

    func testAspectReceivedInFullScreenAppliesOnExit() async throws {
        let window = playerWindow()
        defer { window.close() }
        let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
        geometry.attach(to: window, openingScreen: main, aspectRatio: nil)
        geometry.activate()
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(main, display: false)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        geometry.resolveOpeningAspectRatio(9.0 / 16)
        XCTAssertEqual(window.frame, main)
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        // A late AppKit frame update without a user gesture must still yield to the video fit.
        window.setFrame(NSRect(x: 75, y: 75, width: 900, height: 600), display: false)
        center.post(name: NSWindow.didMoveNotification, object: window)
        try await Task.sleep(for: .milliseconds(350))
        assertOpening(window, on: main, ratio: 9.0 / 16)
    }

    func testUserDragImmediatelyAfterFullScreenExitTakesPriorityOverPendingRestore() async throws {
        for gesture in [NSWindow.willMoveNotification, NSWindow.willStartLiveResizeNotification] {
            let window = playerWindow()
            defer { window.close() }
            let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
            geometry.attach(to: window, openingScreen: main, aspectRatio: nil)
            geometry.activate()
            let center = NotificationCenter.default
            center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            center.post(name: NSWindow.willExitFullScreenNotification, object: window)
            center.post(name: NSWindow.didExitFullScreenNotification, object: window)
            center.post(name: gesture, object: window)
            let manual = gesture == NSWindow.willMoveNotification
                ? window.frame.offsetBy(dx: 12, dy: -15)
                : NSRect(x: 50, y: 65, width: 900, height: 600)
            window.setFrame(manual, display: false)
            center.post(name: gesture == NSWindow.willMoveNotification ? NSWindow.didMoveNotification : NSWindow.didResizeNotification,
                        object: window)
            geometry.resolveOpeningAspectRatio(9.0 / 16)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(window.frame, manual, "\(gesture.rawValue) must take priority over both delayed adjustments")
        }
    }

    func testResetWhileNewEpisodeIsLoadingAcceptsItsDecodedAspectOnce() {
        let window = playerWindow()
        defer { window.close() }
        let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
        geometry.attach(to: window, openingScreen: main, aspectRatio: 2.39)
        geometry.activate()
        geometry.cancelOpeningFit()
        geometry.reset(aspectRatio: 16.0 / 9, awaitingDecodedAspect: true)
        assertOpening(window, on: main, ratio: 16.0 / 9)
        geometry.resolveOpeningAspectRatio(9.0 / 16)
        assertOpening(window, on: main, ratio: 9.0 / 16)
        geometry.resolveOpeningAspectRatio(2.39)
        assertOpening(window, on: main, ratio: 9.0 / 16)
    }

    func testExplicitFitPreservesWidthAndAllowsManualResizeAndFullscreenReturn() async throws {
        let window = playerWindow()
        defer { window.close() }
        let geometry = PlaybackWindowGeometryController(screens: { [self.main] })
        geometry.attach(to: window, openingScreen: main, aspectRatio: nil)
        geometry.activate()
        let manual = NSRect(x: 100, y: 100, width: 1100, height: 650)
        window.setFrame(manual, display: false)
        let center = NotificationCenter.default
        center.post(name: NSWindow.didResizeNotification, object: window)
        geometry.fitToVideo(aspectRatio: 2.35)
        let fitted = window.frame
        XCTAssertEqual(fitted.width, manual.width, accuracy: 1)
        XCTAssertEqual(fitted.maxY, manual.maxY, accuracy: 1)
        let content = window.contentRect(forFrameRect: fitted)
        XCTAssertEqual(content.width / content.height, 2.35, accuracy: 0.01)
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(main, display: false)
        geometry.fitToVideo(aspectRatio: 1)
        XCTAssertEqual(window.frame, main)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(window.frame, fitted)
        window.setFrame(manual, display: false)
        XCTAssertEqual(window.frame, manual)
    }

    func testResetCentersOnCurrentMonitorAndDefersDuringFullScreenTransition() async throws {
        let window = playerWindow()
        defer { window.close() }
        let screens = [main, second]
        let geometry = PlaybackWindowGeometryController(screens: { screens })
        geometry.attach(to: window, openingScreen: main, aspectRatio: nil)
        geometry.activate()
        window.setFrame(NSRect(x: -1500, y: 50, width: 900, height: 600), display: false)
        let center = NotificationCenter.default
        center.post(name: NSWindow.didMoveNotification, object: window)
        geometry.reset(aspectRatio: 2.35)
        assertOpening(window, on: second, ratio: 2.35)
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(second, display: false)
        geometry.reset(aspectRatio: 9.0 / 16)
        XCTAssertEqual(window.frame, second)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try await Task.sleep(for: .milliseconds(350))
        assertOpening(window, on: second, ratio: 9.0 / 16)
    }

    func testDisconnectedDisplayRecalculatesAutomaticWindowAndClampsManualWindow() {
        let window = playerWindow()
        defer { window.close() }
        var screens = [main, second]
        let geometry = PlaybackWindowGeometryController(screens: { screens })
        geometry.attach(to: window, openingScreen: second, aspectRatio: 2.39)
        geometry.activate()
        screens = [main]
        let center = NotificationCenter.default
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        assertOpening(window, on: main, ratio: 2.39)
        let manual = NSRect(x: 20, y: 75, width: 1150, height: 650)
        window.setFrame(manual, display: false)
        center.post(name: NSWindow.didResizeNotification, object: window)
        screens = [NSRect(x: -200, y: 100, width: 600, height: 400)]
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(window.frame, screens[0])
    }
}
