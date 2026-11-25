import AppKit
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

final class PlaybackInteractionTests: XCTestCase {
    private var activeKeyPlayback: PlaybackControlsVisibility.Conditions {
        .init(activePlayback: true, keyWindow: true)
    }

    func testControlsHideExactlyAtThreeSecondsAndTicksDoNotResetDeadline() {
        var policy = PlaybackControlsVisibility()
        policy.update(activeKeyPlayback, now: 100)
        XCTAssertTrue(policy.isVisible(now: 102.999))
        policy.update(activeKeyPlayback, now: 102.999)
        XCTAssertEqual(policy.lastActivity, 100, "Repeated state sampling must not postpone hiding")
        XCTAssertFalse(policy.isVisible(now: 103))
        XCTAssertFalse(policy.isVisible(now: 200))
    }

    func testActivityRevealsControlsAndStartsACompleteNewIdlePeriod() {
        var policy = PlaybackControlsVisibility()
        policy.update(activeKeyPlayback, now: 10)
        XCTAssertFalse(policy.isVisible(now: 13))
        policy.activity(now: 13.25)
        XCTAssertTrue(policy.isVisible(now: 13.25))
        XCTAssertTrue(policy.isVisible(now: 16.249))
        XCTAssertFalse(policy.isVisible(now: 16.25))
    }

    func testControlHideDelayCanChangeDuringPlaybackWithoutAnImmediateDisappearance() {
        var policy = PlaybackControlsVisibility()
        policy.update(activeKeyPlayback, now: 100)
        policy.configure(autoHide: true, delay: 8, now: 102)
        XCTAssertTrue(policy.isVisible(now: 109.999))
        XCTAssertFalse(policy.isVisible(now: 110))
        policy.configure(autoHide: true, delay: 2, now: 111)
        XCTAssertTrue(policy.isVisible(now: 112.999), "Reducing the setting still grants a complete new idle interval")
        XCTAssertFalse(policy.isVisible(now: 113))
        policy.configure(autoHide: true, delay: 2, now: 114)
        XCTAssertFalse(policy.isVisible(now: 114), "Unchanged preferences sampled on every playback tick must not reset the timer")
    }

    func testDisablingAutoHideKeepsControlsVisibleAndReenablingStartsFresh() {
        var policy = PlaybackControlsVisibility()
        policy.update(activeKeyPlayback, now: 0)
        XCTAssertFalse(policy.isVisible(now: 3))
        policy.configure(autoHide: false, delay: 5, now: 4)
        XCTAssertTrue(policy.isVisible(now: 100_000))
        policy.configure(autoHide: true, delay: 5, now: 100_001)
        XCTAssertTrue(policy.isVisible(now: 100_005.999))
        XCTAssertFalse(policy.isVisible(now: 100_006))
        var blocked = activeKeyPlayback
        blocked.blocked = true
        policy.update(blocked, now: 100_007)
        XCTAssertTrue(policy.isVisible(now: 1_000_000), "Configured hiding must preserve hover, scrubbing and menu protection")
    }

    func testInvalidHideDelayUsesSafeDefaultInsteadOfDisablingVisibilityPolicy() {
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 0, -5] {
            var policy = PlaybackControlsVisibility()
            policy.update(activeKeyPlayback, now: 10)
            policy.configure(autoHide: true, delay: invalid, now: 10)
            XCTAssertTrue(policy.isVisible(now: 12.999))
            XCTAssertFalse(policy.isVisible(now: 13))
        }
    }

    @MainActor
    func testSeekActionsUseIndependentLiveIntervalsAndSupportedSymbols() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        var preferences = ApplicationPreferences()
        preferences.seekBackwardSeconds = 5
        preferences.seekForwardSeconds = 60
        controller.updateInterfacePreferences(preferences)
        XCTAssertEqual(PlaybackSeekDirection.backward.target(from: 100, preferences: controller.interfacePreferences), 95)
        XCTAssertEqual(PlaybackSeekDirection.forward.target(from: 100, preferences: controller.interfacePreferences), 160)
        XCTAssertEqual(PlaybackSeekDirection.backward.label(in: controller.interfacePreferences), "后退 5 秒")
        XCTAssertEqual(PlaybackSeekDirection.forward.label(in: controller.interfacePreferences), "前进 60 秒")
        XCTAssertEqual(controller.playbackDefaults.seekForwardSeconds, 10, "Live controls must not be read from the session's earlier defaults")

        for interval: Double in [5, 10, 15, 30, 60] {
            preferences.seekBackwardSeconds = interval
            preferences.seekForwardSeconds = interval
            controller.updateInterfacePreferences(preferences)
            for direction in PlaybackSeekDirection.allCases {
                XCTAssertNotNil(NSImage(systemSymbolName: direction.symbol(in: controller.interfacePreferences), accessibilityDescription: nil),
                                "Every interval offered by Settings needs a real transport symbol")
                XCTAssertEqual(direction.seconds(in: controller.interfacePreferences), interval)
            }
        }
    }

    func testHeaderAndBottomHoverExitsCannotReleaseAnotherActiveRegion() {
        var hover = PlaybackControlsHover()
        XCTAssertFalse(hover.isHovered)
        hover.set(true, owner: "playback-controls")
        hover.set(true, owner: "episode-header")
        hover.set(false, owner: "playback-controls")
        XCTAssertTrue(hover.isHovered, "A delayed bottom-bar exit must preserve the header hover")
        hover.set(false, owner: "playback-controls")
        XCTAssertTrue(hover.isHovered, "Repeated exits are idempotent")
        hover.set(true, owner: "playback-controls")
        hover.set(false, owner: "episode-header")
        XCTAssertTrue(hover.isHovered, "A delayed header exit must preserve the bottom-bar hover")
        hover.set(false, owner: "playback-controls")
        XCTAssertFalse(hover.isHovered)
        hover.set(true, owner: "episode-header")
        hover.reset()
        XCTAssertFalse(hover.isHovered, "Window detach/fullscreen transitions clear obsolete regions")
    }

    func testLastHoverExitStartsACompleteNewHideDelay() {
        var hover = PlaybackControlsHover()
        var policy = PlaybackControlsVisibility()
        var conditions = activeKeyPlayback
        policy.update(conditions, now: 0)
        XCTAssertFalse(policy.isVisible(now: 3))
        hover.set(true, owner: "episode-header")
        hover.set(true, owner: "playback-controls")
        conditions.blocked = hover.isHovered
        policy.update(conditions, now: 4)
        XCTAssertTrue(policy.isVisible(now: 100))
        hover.set(false, owner: "playback-controls")
        conditions.blocked = hover.isHovered
        policy.update(conditions, now: 101)
        XCTAssertTrue(policy.isVisible(now: 1_000), "The remaining header hover keeps controls visible beyond the idle deadline")
        hover.set(false, owner: "episode-header")
        conditions.blocked = hover.isHovered
        policy.update(conditions, now: 1_001)
        XCTAssertTrue(policy.isVisible(now: 1_003.999))
        XCTAssertFalse(policy.isVisible(now: 1_004))
    }

    func testPausedUnfocusedBlockedAndTransitioningConditionsEachPreventHiding() {
        var exceptions: [PlaybackControlsVisibility.Conditions] = []
        var state = activeKeyPlayback; state.activePlayback = false; exceptions.append(state)
        state = activeKeyPlayback; state.keyWindow = false; exceptions.append(state)
        state = activeKeyPlayback; state.blocked = true; exceptions.append(state)
        state = activeKeyPlayback; state.transitioning = true; exceptions.append(state)
        for exception in exceptions {
            var policy = PlaybackControlsVisibility()
            policy.update(activeKeyPlayback, now: 0)
            XCTAssertFalse(policy.isVisible(now: 3))
            policy.update(exception, now: 5)
            XCTAssertTrue(policy.isVisible(now: 5))
            XCTAssertTrue(policy.isVisible(now: 1_000), "Every individual blocker must hold visibility")
            policy.update(activeKeyPlayback, now: 1_001)
            XCTAssertTrue(policy.isVisible(now: 1_003.999), "Resuming eligible playback grants a fresh idle period")
            XCTAssertFalse(policy.isVisible(now: 1_004))
        }
    }

    func testFullscreenTransitionKeepsControlsVisibleAndRestartsWindowedIdleDeadline() {
        var policy = PlaybackControlsVisibility()
        XCTAssertTrue(policy.isVisible(now: 1_000_000))
        policy.update(activeKeyPlayback, now: 20)
        XCTAssertFalse(policy.isVisible(now: 24))
        var leaving = activeKeyPlayback; leaving.transitioning = true
        policy.update(leaving, now: 25)
        XCTAssertTrue(policy.isVisible(now: 100))
        leaving.transitioning = false
        policy.update(leaving, now: 101)
        XCTAssertTrue(policy.isVisible(now: 103.999))
        XCTAssertFalse(policy.isVisible(now: 104))
    }

    func testAllDocumentedShortcutsResolveToTheirActions() {
        let mappings: [(UInt16, String?, PlaybackShortcut)] = [
            (49, " ", .togglePause), (123, nil, .backward), (124, nil, .forward),
            (125, nil, .volumeDown), (126, nil, .volumeUp), (46, "m", .mute),
            (3, "f", .toggleFullScreen), (33, "[", .slower), (30, "]", .faster),
            (29, "0", .normalSpeed), (53, nil, .exitFullScreen)
        ]
        for (code, characters, expected) in mappings {
            XCTAssertEqual(resolve(code, characters: characters), expected)
        }
        XCTAssertEqual(resolve(0, characters: "M"), .mute, "Caps Lock should not remove letter shortcuts")
        XCTAssertEqual(resolve(0, characters: "F"), .toggleFullScreen)
        XCTAssertEqual(resolve(49, characters: "m"), .togglePause, "Physical navigation keys take priority over translated characters")
        XCTAssertNil(resolve(0, characters: "x"))
        XCTAssertNil(resolve(0, characters: nil))
    }

    func testEditingAndModifiedShortcutsAreReturnedToTheirOriginalResponder() {
        let keys: [(UInt16, String?)] = [(49, " "), (123, nil), (124, nil), (125, nil), (126, nil),
                                       (53, nil), (46, "m"), (3, "f"), (33, "["), (30, "]"), (29, "0")]
        for (code, characters) in keys {
            XCTAssertNil(resolve(code, characters: characters, eligible: false))
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift, [.command, .shift]] {
                XCTAssertNil(resolve(code, characters: characters, modifiers: modifier))
            }
        }
        XCTAssertEqual(resolve(126, modifiers: [.numericPad, .function]), .volumeUp,
                       "AppKit's standard arrow-key flags are not user shortcut modifiers")
        XCTAssertEqual(resolve(46, characters: "M", modifiers: .capsLock), .mute)
    }

    func testEscapeOnlyExitsFullScreenAndNeverClosesANormalWindow() {
        XCTAssertNil(resolve(53, fullScreen: false))
        XCTAssertEqual(resolve(53, fullScreen: true), .exitFullScreen)
        XCTAssertNil(resolve(53, eligible: false, fullScreen: true))
    }

    func testOnlyVolumeKeysAcceptAutomaticKeyRepeat() {
        XCTAssertEqual(resolve(125, isRepeat: true), .volumeDown)
        XCTAssertEqual(resolve(126, isRepeat: true), .volumeUp)
        for (code, characters): (UInt16, String?) in [(49, " "), (123, nil), (124, nil), (53, nil),
                                                    (46, "m"), (3, "f"), (33, "["), (30, "]"), (29, "0")] {
            XCTAssertNil(resolve(code, characters: characters, isRepeat: true))
        }
    }

    @MainActor
    func testVolumeClampingAndMuteRestoreTheLastNonzeroVolume() throws {
        let controller = try makeController()
        controller.setVolume(0.35)
        controller.toggleMute()
        XCTAssertEqual(controller.volume, 0)
        controller.toggleMute()
        XCTAssertEqual(controller.volume, 0.35, accuracy: 0.0001)
        controller.setVolume(4)
        XCTAssertEqual(controller.volume, 1)
        controller.setVolume(-4)
        XCTAssertEqual(controller.volume, 0)
        controller.toggleMute()
        XCTAssertEqual(controller.volume, 1)
        controller.setVolume(0.2)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] { controller.setVolume(invalid) }
        XCTAssertEqual(controller.volume, 0.2)
        controller.setVolume(0)
        controller.toggleMute()
        XCTAssertEqual(controller.volume, 0.2, "Dragging the slider to zero keeps the earlier audible level")
    }

    @MainActor
    func testWindowHandlerDispatchesOnlyItsOwnKeyWindowAndDetachesCleanly() async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        let other = makeWindow()
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        let interaction = PlaybackInteractionController()
        let previousMouseMoved = window.acceptsMouseMovedEvents
        interaction.attach(to: window, controller: controller)
        defer { interaction.detach(); engine.shutdown() }
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        controller.setVolume(0.5)
        let down = try event(window, keyCode: 125)
        XCTAssertTrue(down.window === window, "Test event must belong to the actual hidden NSWindow")
        XCTAssertNil(interaction.handle(down))
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
        let wrongWindow = try event(other, keyCode: 125)
        XCTAssertTrue(interaction.handle(wrongWindow) === wrongWindow)
        window.simulatedKeyWindow = false
        XCTAssertTrue(interaction.handle(down) === down)
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
        window.simulatedKeyWindow = true
        interaction.detach()
        XCTAssertEqual(window.acceptsMouseMovedEvents, previousMouseMoved)
        XCTAssertTrue(interaction.controlsVisible)
        XCTAssertTrue(interaction.handle(down) === down)
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
    }

    @MainActor
    func testWindowHandlerDoesNotSwallowKeysWhileEditingOrInteractingWithMenus() async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        controller.setVolume(0.5)
        let interaction = PlaybackInteractionController()
        interaction.attach(to: window, controller: controller)
        defer { interaction.detach(); engine.shutdown() }
        let down = try event(window, keyCode: 125)
        for editor: NSResponder in [NSTextField(), NSTextView()] {
            window.simulatedFirstResponder = editor
            XCTAssertTrue(interaction.handle(down) === down)
        }
        let left = try event(window, keyCode: 123)
        let space = try event(window, keyCode: 49)
        window.simulatedFirstResponder = NSSlider()
        XCTAssertTrue(interaction.handle(left) === left, "A focused timeline must receive its own arrow keys")
        XCTAssertTrue(interaction.handle(down) === down)
        window.simulatedFirstResponder = NSPopUpButton()
        XCTAssertTrue(interaction.handle(down) === down, "Arrow keys open a focused menu")
        window.simulatedFirstResponder = NSButton()
        XCTAssertTrue(interaction.handle(space) === space, "Space activates the focused button")
        window.simulatedFirstResponder = nil
        interaction.setPopoverOpen(true)
        XCTAssertTrue(interaction.handle(down) === down)
        interaction.setPopoverOpen(false)
        interaction.setScrubbing(true)
        XCTAssertTrue(interaction.handle(down) === down)
        interaction.setScrubbing(false)
        let menu = NSMenu()
        let submenu = NSMenu()
        let center = NotificationCenter.default
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        XCTAssertTrue(interaction.handle(down) === down, "Closing a submenu must leave its parent menu protected")
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(controller.volume, 0.5)
        XCTAssertNil(interaction.handle(down))
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
    }

    @MainActor
    func testVirtualControlsReceiveTheirOwnKeysWhileTheHostingViewHasFocus() async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        controller.setVolume(0.5)
        let interaction = PlaybackInteractionController()
        interaction.attach(to: window, controller: controller)
        defer { interaction.detach(); engine.shutdown() }

        window.simulatedFirstResponder = NSView()
        let controls: [(NSAccessibility.Role, [UInt16])] = [
            (.menuButton, [49, 125, 126]), (.popUpButton, [49, 125, 126]),
            (.slider, [49, 123, 124, 125, 126]), (.button, [49]), (.checkBox, [49]),
            (.textField, [49, 125]), (.textArea, [49, 125])
        ]
        for (role, keys) in controls {
            window.simulatedFocusedElement = VirtualControl(role)
            for key in keys {
                let input = try event(window, keyCode: key)
                XCTAssertTrue(interaction.handle(input) === input, "\(role.rawValue) should receive key \(key)")
            }
        }
        XCTAssertEqual(controller.volume, 0.5)
        window.simulatedFocusedElement = VirtualControl(.staticText)
        XCTAssertNil(interaction.handle(try event(window, keyCode: 125)))
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
    }

    @MainActor
    func testClosingOneControlGroupKeepsOtherEpisodePopoverAndRecoveryProtected() async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        controller.setVolume(0.5)
        let interaction = PlaybackInteractionController()
        interaction.attach(to: window, controller: controller)
        defer { interaction.detach(); engine.shutdown() }
        let down = try event(window, keyCode: 125)

        interaction.setPopoverOpen(true)
        interaction.setPopoverOpen(true, owner: "episode-selection")
        interaction.setPopoverOpen(false)
        XCTAssertTrue(interaction.handle(down) === down, "Bottom controls disappearing must not release an open episode picker")
        interaction.setPopoverOpen(true, owner: "episode-recovery")
        interaction.setPopoverOpen(false, owner: "episode-selection")
        interaction.setPopoverOpen(false, owner: "episode-selection")
        XCTAssertTrue(interaction.handle(down) === down, "Repeated dismissal of a picker must leave its independent recovery prompt protected")
        interaction.setPopoverOpen(true)
        interaction.setPopoverOpen(false, owner: "episode-recovery")
        XCTAssertTrue(interaction.handle(down) === down, "Dismissing recovery must not release an open subtitle/help popover")
        XCTAssertEqual(controller.volume, 0.5)
        interaction.setPopoverOpen(false)
        XCTAssertNil(interaction.handle(down))
        XCTAssertEqual(controller.volume, 0.45, accuracy: 0.0001)
    }

    @MainActor
    func testWindowHandlerPreservesCompatibilityPlaybackAndUnavailableActions() async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        let controller = try makeController()
        let interaction = PlaybackInteractionController()
        interaction.attach(to: window, controller: controller)
        defer { interaction.detach() }
        let down = try event(window, keyCode: 125)
        XCTAssertTrue(interaction.handle(down) === down, "The AVPlayer fallback keeps its own keyboard handling")
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        XCTAssertTrue(interaction.handle(down) === down, "Preparing playback does not swallow commands that cannot run")
        controller.preparing = false
        controller.stopping = true
        XCTAssertTrue(interaction.handle(down) === down)
        controller.stopping = false
        controller.errorMessage = "fixture error"
        XCTAssertTrue(interaction.handle(down) === down)
        controller.errorMessage = nil
        let escape = try event(window, keyCode: 53)
        XCTAssertTrue(interaction.handle(escape) === escape, "Escape in a normal window is not consumed")
        let modified = try event(window, keyCode: 125, modifiers: .command)
        XCTAssertTrue(interaction.handle(modified) === modified)
        XCTAssertEqual(controller.volume, 1)
    }

    @MainActor
    func testVideoSingleClickWaitsForDoubleClickAndDetachPreservesUnrelatedGestures() throws {
        let surface = NSView()
        let unrelated = NSPanGestureRecognizer()
        surface.addGestureRecognizer(unrelated)
        let handler = PlaybackSurfaceClicks(onSingle: {}, onDouble: {})
        handler.attach(to: surface)
        let recognizers = surface.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
        let single = try XCTUnwrap(recognizers.first { $0.numberOfClicksRequired == 1 })
        let double = try XCTUnwrap(recognizers.first { $0.numberOfClicksRequired == 2 })
        XCTAssertTrue(single.delegate === handler)
        XCTAssertTrue(handler.gestureRecognizer(single, shouldRequireFailureOf: double))
        XCTAssertFalse(handler.gestureRecognizer(double, shouldRequireFailureOf: single))
        XCTAssertEqual(single.buttonMask, 1)
        XCTAssertEqual(double.buttonMask, 1)
        handler.detach(from: surface)
        XCTAssertEqual(surface.gestureRecognizers, [unrelated])
    }

    private func resolve(_ code: UInt16, characters: String? = nil, modifiers: NSEvent.ModifierFlags = [],
                         isRepeat: Bool = false, eligible: Bool = true, fullScreen: Bool = true) -> PlaybackShortcut? {
        PlaybackShortcut.resolve(keyCode: code, characters: characters, modifiers: modifiers,
                                 isRepeat: isRepeat, eligible: eligible, fullScreen: fullScreen)
    }

    @MainActor
    private func makeController() throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"fixture","Name":"Test","Type":"Movie"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "test")
        return NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "fixture")) { _, _ in true }
    }

    @MainActor
    private func makeWindow() -> InteractionTestWindow {
        let window = InteractionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                           styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func event(_ window: NSWindow, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                       windowNumber: window.windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode))
    }
}

/// No window is shown and no system event is posted. Focus is deterministic for dispatch tests.
@MainActor
private final class InteractionTestWindow: NSWindow {
    var simulatedKeyWindow = true
    var simulatedFirstResponder: NSResponder?
    var simulatedFocusedElement: NSObject?
    override var isKeyWindow: Bool { simulatedKeyWindow }
    override var firstResponder: NSResponder? { simulatedFirstResponder ?? super.firstResponder }
    override var accessibilityFocusedUIElement: Any? { simulatedFocusedElement ?? super.accessibilityFocusedUIElement }
}

/// Like SwiftUI's virtual accessibility nodes, this object answers the role
/// selector without formally adopting NSAccessibilityProtocol.
private final class VirtualControl: NSObject {
    @objc let accessibilityRole: String
    init(_ role: NSAccessibility.Role) { accessibilityRole = role.rawValue }
}
