import AppKit
import AVFoundation
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

final class PlaybackMinimizePausePolicyTests: XCTestCase {
    func testDefaultOffAndExplicitResumeAfterRestoration() {
        var policy = PlaybackMinimizePausePolicy()
        policy.setMiniaturized(true)
        XCTAssertFalse(policy.blocksAutomaticPlayback)
        policy.update(enabled: true)
        XCTAssertTrue(policy.blocksAutomaticPlayback)
        XCTAssertFalse(policy.requestExplicitPlayback())
        policy.setMiniaturized(false)
        XCTAssertTrue(policy.blocksAutomaticPlayback, "Restoring must preserve the user's pause")
        policy.update(enabled: false)
        XCTAssertTrue(policy.blocksAutomaticPlayback, "Disabling the preference must not resume playback")
        XCTAssertTrue(policy.requestExplicitPlayback())
        XCTAssertFalse(policy.blocksAutomaticPlayback)
    }

    func testReplacementInheritsPauseEvenAfterRestoreAndPreferenceDisable() {
        var previous = PlaybackMinimizePausePolicy(enabled: true)
        previous.setMiniaturized(true)
        previous.setMiniaturized(false)
        previous.update(enabled: false)
        var next = PlaybackMinimizePausePolicy()
        next.inheritPause(from: previous)
        XCTAssertTrue(next.blocksAutomaticPlayback)
        XCTAssertTrue(next.requestExplicitPlayback())
        XCTAssertFalse(next.blocksAutomaticPlayback)
    }
}

@MainActor
final class PlaybackWindowBehaviorTests: XCTestCase {
    func testVideoFillsTransparentNativeTitlebarAndReplacementKeepsOneAccessory() async throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        let owner = PlaybackWindowController(controller: controller, onClosing: { _ in }, onClose: { _ in })
        let window = try XCTUnwrap(owner.window)
        defer {
            owner.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
            window.delegate = nil
            window.close()
        }
        XCTAssertTrue(window.styleMask.contains([.titled, .fullSizeContentView]))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.title, controller.item.name)
        XCTAssertTrue(window.isMovable)
        let content = try XCTUnwrap(window.contentView)
        let threshold = PlaybackWindowGeometry.minimumTitlebarInfoWidth
        for size in [NSSize(width: 930, height: 480), NSSize(width: 270, height: 540),
                     NSSize(width: threshold - 1, height: 560), NSSize(width: threshold, height: 560)] {
            window.minSize = .zero
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(window.frame.size, size)
            XCTAssertEqual(content.frame.size, size)
            XCTAssertGreaterThan(content.safeAreaInsets.top, 0)
            XCTAssertEqual(engine.videoView.convert(engine.videoView.bounds, to: content), content.bounds,
                           "The picture must occupy the titlebar as well as the content layout guide")
            if size.width < threshold {
                XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty,
                              "An ultra-narrow titlebar must leave the traffic lights accessible")
                continue
            }
            let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first)
            let info = accessory.view.convert(accessory.view.bounds, to: nil)
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            XCTAssertFalse(zoom.convert(zoom.bounds, to: nil).intersects(info))
            XCTAssertTrue(NSRect(origin: .zero, size: size).contains(info))
        }
        let previousView = window.titlebarAccessoryViewControllers.first?.view
        let replacement = try makeController()
        owner.replaceController(replacement)
        XCTAssertEqual(window.titlebarAccessoryViewControllers.count, 1)
        XCTAssertFalse(window.titlebarAccessoryViewControllers.first?.view === previousView)
        XCTAssertNil(previousView?.window)
        await controller.stop()
        await replacement.stop()
    }

    func testPinnedWindowKeepsFullscreenEligibilityAndExistingCollectionBehavior() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        let behavior = PlaybackWindowBehavior(keepOnTop: true)
        behavior.attach(to: window)
        defer { behavior.detach(); window.close() }
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
        _ = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        // In-process AppKit reports a nil AX subrole for these unshown titlebar
        // controls. Keep native window eligibility assertions unconditional;
        // the visible window's AXFullScreenButton is checked in UI acceptance.
        behavior.togglePin()
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        behavior.togglePin()
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenAuxiliary))
        _ = try XCTUnwrap(window.standardWindowButton(.zoomButton))
    }

    func testDefaultFullscreenPinnedPlayerIsEligibleBeforeInitialPresentation() async throws {
        _ = NSApplication.shared
        var defaults = ApplicationPreferences()
        defaults.keepPlaybackWindowOnTop = true
        defaults.playbackWindowMode = .fullScreen
        let controller = try makeController(preferences: defaults)
        let owner = PlaybackWindowController(controller: controller, onClosing: { _ in }, onClose: { _ in })
        let window = try XCTUnwrap(owner.window)
        // showWindow's first-presentation toggle must already be eligible even
        // though the pin default was applied during window construction.
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        _ = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        owner.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        window.delegate = nil; window.close()
        await controller.stop()
    }

    func testPinSuspendsForFullscreenTransitionsAndSheetsAndCleansUp() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let behavior = PlaybackWindowBehavior(keepOnTop: true)
        behavior.attach(to: window)
        defer { behavior.detach(); window.close() }
        func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: window) }
        XCTAssertEqual(window.level, .floating)
        post(NSWindow.willEnterFullScreenNotification)
        XCTAssertEqual(window.level, .normal)
        post(NSWindow.didEnterFullScreenNotification)
        XCTAssertEqual(window.level, .normal)
        post(NSWindow.willExitFullScreenNotification)
        XCTAssertEqual(window.level, .normal)
        post(NSWindow.didExitFullScreenNotification)
        XCTAssertEqual(window.level, .floating)
        post(NSWindow.willBeginSheetNotification)
        XCTAssertEqual(window.level, .normal)
        post(NSWindow.didEndSheetNotification)
        XCTAssertEqual(window.level, .floating)
        let settings = NSWindow()
        settings.isReleasedWhenClosed = false
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        XCTAssertEqual(window.level, .normal, "SeatSix Settings must not be hidden behind the pinned player")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertEqual(window.level, .floating, "Switching applications keeps the user's pin choice")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        post(NSWindow.didBecomeKeyNotification)
        XCTAssertEqual(window.level, .floating)
        settings.close()
        post(NSWindow.willEnterFullScreenNotification)
        behavior.fullScreenTransitionFailed()
        XCTAssertEqual(window.level, .floating)
        behavior.togglePin()
        XCTAssertEqual(window.level, .normal)
        behavior.togglePin()
        behavior.detach()
        XCTAssertEqual(window.level, .normal)
        post(NSWindow.didExitFullScreenNotification)
        XCTAssertEqual(window.level, .normal, "Detached observers must not float a closed window")
    }

    func testOnlyOwningWindowMinimizationChangesPauseIntent() throws {
        _ = NSApplication.shared
        let window = NSWindow(), otherWindow = NSWindow()
        window.isReleasedWhenClosed = false; otherWindow.isReleasedWhenClosed = false
        let behavior = PlaybackWindowBehavior(keepOnTop: false)
        var changes: [Bool] = []
        behavior.onMiniaturizedChange = { changes.append($0) }
        behavior.attach(to: window)
        defer { behavior.detach(); window.close(); otherWindow.close() }
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: otherWindow)
        XCTAssertEqual(changes, [false])
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertEqual(changes, [false, true, false])
    }

    func testWindowChoiceAndPauseSurviveEpisodeReplacementWithoutChangingDefaults() async throws {
        _ = NSApplication.shared
        var defaults = ApplicationPreferences()
        defaults.keepPlaybackWindowOnTop = true
        defaults.pauseWhenMinimized = true
        let first = try makeController(preferences: defaults, naturallyEnded: true)
        let next = try makeController(preferences: defaults, naturallyEnded: true)
        let owner = PlaybackWindowController(controller: first, onClosing: { _ in }, onClose: { _ in })
        let window = try XCTUnwrap(owner.window)
        XCTAssertTrue(first.isWindowOnTop)
        XCTAssertEqual(window.level, .floating)
        first.toggleWindowOnTop()
        XCTAssertFalse(first.isWindowOnTop)
        XCTAssertTrue(first.playbackDefaults.keepPlaybackWindowOnTop)
        XCTAssertEqual(window.level, .normal)
        var changedDefaults = defaults
        changedDefaults.keepPlaybackWindowOnTop = false
        first.updateInterfacePreferences(changedDefaults)
        first.toggleWindowOnTop()
        XCTAssertEqual(window.level, .floating)
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        XCTAssertFalse(first.canAutomaticallyContinue)
        XCTAssertNotNil(first.onFitWindowToVideo)
        XCTAssertFalse(first.canFitWindowToVideo, "An attached window still needs a decoded display ratio")
        owner.replaceController(next)
        XCTAssertNil(first.onFitWindowToVideo, "A detached episode must be unable to resize the current window")
        XCTAssertNotNil(next.onFitWindowToVideo)
        XCTAssertTrue(owner.window === window)
        XCTAssertTrue(next.isWindowOnTop)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(next.canAutomaticallyContinue, "Restored episode replacement must inherit the pause request")
        first.toggleWindowOnTop()
        XCTAssertTrue(next.isWindowOnTop, "Detached episode cannot change the replacement's window")
        next.toggleWindowOnTop()
        XCTAssertEqual(window.level, .normal)
        owner.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        XCTAssertNil(next.onToggleWindowOnTop)
        XCTAssertNil(next.onFitWindowToVideo)
        window.delegate = nil; window.close()
        await first.stop(); await next.stop()
    }

    func testDelayedLocalPreparationAndSeekCannotResumeUntilExplicitPlay() async throws {
        _ = NSApplication.shared
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var defaults = ApplicationPreferences(); defaults.pauseWhenMinimized = true
        let owner = try makeController(preferences: defaults)
        owner.setWindowMiniaturized(true)
        owner.setWindowMiniaturized(false)
        let engine = try LocalPlaybackEngine()
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 0)
        await owner.restorePreferences(engine: engine, mediaSourceID: "source")
        owner.preparing = false
        owner.resumeAutomatically()
        XCTAssertTrue(engine.snapshot.paused, "Delayed preparation must honor an earlier minimize")
        await owner.performOutroSkip(to: 2)
        XCTAssertTrue(engine.snapshot.paused, "The outro seek completion is another automatic resume path")
        owner.togglePause()
        try await waitUntil { !engine.snapshot.paused }
        owner.setWindowMiniaturized(true)
        XCTAssertTrue(engine.snapshot.paused)
        owner.togglePause()
        XCTAssertTrue(engine.snapshot.paused, "Explicit Play is suppressed while minimized with the option enabled")
        defaults.pauseWhenMinimized = false
        owner.updateInterfacePreferences(defaults)
        owner.setWindowMiniaturized(false)
        owner.resumeAutomatically()
        XCTAssertTrue(engine.snapshot.paused, "Disabling while paused does not start audio")
        owner.togglePause()
        try await waitUntil { !engine.snapshot.paused }
        await owner.stop()
    }

    func testCompatibilityLoadAndNativePlayHonorPauseAndClearItAfterRestore() async throws {
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var defaults = ApplicationPreferences(); defaults.pauseWhenMinimized = true
        let owner = try makeController(preferences: defaults)
        owner.player.isMuted = true
        owner.setWindowMiniaturized(true)
        owner.setWindowMiniaturized(false)
        owner.player.replaceCurrentItem(with: AVPlayerItem(url: movie))
        try await waitUntil { owner.player.currentItem?.status == .readyToPlay }
        owner.preparing = false
        owner.resumeAutomatically()
        XCTAssertEqual(owner.player.rate, 0)
        owner.setWindowMiniaturized(true)
        owner.player.play() // Native AVPlayerView's system control bypasses togglePause.
        try await waitUntil { owner.player.rate == 0 }
        owner.setWindowMiniaturized(false)
        XCTAssertEqual(owner.player.rate, 0)
        owner.player.play()
        try await waitUntil { owner.player.timeControlStatus == .playing }
        for _ in 0..<5 { await Task.yield() }
        let next = try makeController(preferences: defaults, naturallyEnded: true)
        next.inheritWindowPause(from: owner)
        XCTAssertTrue(next.canAutomaticallyContinue, "System Play after restoration releases the old minimize pause")
        owner.setWindowMiniaturized(true)
        XCTAssertEqual(owner.player.rate, 0)
        await owner.stop(); await next.stop()
    }

    func testDefaultOffDoesNotPauseAndEnablingWhileMinimizedDoes() async throws {
        let owner = try makeController()
        owner.preparing = false
        owner.player.play()
        let oldRate = owner.player.rate
        XCTAssertGreaterThan(oldRate, 0)
        owner.setWindowMiniaturized(true)
        XCTAssertEqual(owner.player.rate, oldRate)
        var enabled = ApplicationPreferences(); enabled.pauseWhenMinimized = true
        owner.updateInterfacePreferences(enabled)
        XCTAssertEqual(owner.player.rate, 0)
        await owner.stop()
    }

    func testStoppedOwnerStillNotifiesOnceAndCancelsAutomaticContinuation() async throws {
        var defaults = ApplicationPreferences(); defaults.pauseWhenMinimized = true
        let owner = try makeController(preferences: defaults, naturallyEnded: true)
        await owner.stop(naturalEnd: true)
        XCTAssertTrue(owner.canAutomaticallyContinue)
        var pauses = 0
        owner.onMinimizePause = { pauses += 1 }
        owner.setWindowMiniaturized(true)
        owner.setWindowMiniaturized(true)
        owner.setWindowMiniaturized(false)
        XCTAssertEqual(pauses, 1)
        XCTAssertFalse(owner.canAutomaticallyContinue)
        defaults.pauseWhenMinimized = false
        owner.updateInterfacePreferences(defaults)
        XCTAssertFalse(owner.canAutomaticallyContinue)
        XCTAssertEqual(pauses, 1)
    }

    private func makeController(preferences: ApplicationPreferences = .init(), naturallyEnded: Bool = false) throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        var completion = PlaybackCompletionGate()
        if naturallyEnded { _ = completion.beginNaturalEnd(started: true, stopped: false, failed: false) }
        return NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test"),
            applicationPreferences: preferences, completionGate: completion) { _, _ in true }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Playback condition did not settle")
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("window-behavior.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=navy:size=160x90:rate=24", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "8", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-movflags", "+faststart", movie.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else { process.terminate(); throw LocalPlaybackError.timeout }
        guard process.terminationStatus == 0 else { throw LocalPlaybackError.invalidSubtitle }
        return (directory, movie)
    }
}
