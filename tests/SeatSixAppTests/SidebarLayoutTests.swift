import AppKit
import SwiftUI
import XCTest
@testable import SeatSixApp

@MainActor
final class SidebarLayoutTests: XCTestCase {
    func testWindowConstraintsClampPresentationWithoutChangingSavedPreference() {
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: 320, availableWidth: 930), 192)
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: 320, availableWidth: 1000), 262)
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: 320, availableWidth: 1220), 320)
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: 192, availableWidth: 1607), 192)
        for size in [CGFloat.nan, -.infinity, .infinity, -1, 0, 600] {
            XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: 320, availableWidth: size), 0)
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(SidebarLayout.normalizedWidth(bad), 192)
        }
    }

    func testResizingMergesLatestPreferencesAndSkipsUnchangedWrites() {
        let storage = SidebarLayoutStorage(), model = makeModel(storage)
        var changed = model.applicationPreferences
        changed.posterSize = .large
        XCTAssertTrue(model.updateApplicationPreferences(changed))
        XCTAssertTrue(SidebarPreferenceUpdate.width(272, model: model, onError: { XCTFail($0) }))
        XCTAssertEqual(storage.writes, 2)
        XCTAssertEqual(model.applicationPreferences.posterSize, .large)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, 272)
        XCTAssertTrue(SidebarPreferenceUpdate.width(272, model: model, onError: { XCTFail($0) }))
        XCTAssertEqual(storage.writes, 2, "Releasing the divider without a width change must not save again")
    }

    func testFailedWidthWriteLeavesSavedWidthIntactAndCanRetry() {
        let storage = SidebarLayoutStorage(), model = makeModel(storage)
        var errors: [String] = []
        storage.failWrites = true
        XCTAssertFalse(SidebarPreferenceUpdate.width(300, model: model, onError: { errors.append($0) }))
        XCTAssertEqual(errors.count, 1)
        XCTAssertFalse(errors[0].isEmpty)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, 192)
        XCTAssertEqual(storage.saved.applicationPreferences.sidebarWidth, 192)
        storage.failWrites = false
        XCTAssertTrue(SidebarPreferenceUpdate.width(300, model: model, onError: { errors.append($0) }))
        XCTAssertEqual(storage.writes, 1)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, 300)
        XCTAssertNil(model.preferencesError)
        XCTAssertEqual(errors.count, 1)
    }

    func testReopeningRestoresCollapsedStateAndUnclampedWidth() {
        let storage = SidebarLayoutStorage(), model = makeModel(storage)
        var preferences = model.applicationPreferences
        preferences.sidebarWidth = 320
        preferences.sidebarCollapsed = true
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        let reopened = makeModel(storage)
        XCTAssertTrue(reopened.applicationPreferences.sidebarCollapsed)
        XCTAssertEqual(reopened.applicationPreferences.sidebarWidth, 320)
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: reopened.applicationPreferences.sidebarWidth, availableWidth: 930), 192)
        XCTAssertEqual(reopened.applicationPreferences.sidebarWidth, 320, "A compact window does not rewrite the saved width")
        XCTAssertEqual(SidebarLayout.effectiveWidth(preferredWidth: reopened.applicationPreferences.sidebarWidth, availableWidth: 1607), 320)
        XCTAssertEqual(storage.writes, 1)
    }

    func testNativeSplitClampsPresentationAndRestoresSavedWidthOnWindowResize() async throws {
        let storage = SidebarLayoutStorage()
        storage.saved.applicationPreferences.sidebarWidth = 320
        let model = makeModel(storage)
        let host = makeHost(model, width: 930)
        defer { host.close() }
        let split = try await nativeSplit(in: host)
        XCTAssertTrue(split.isVertical)
        for (windowWidth, expected) in [(930.0, 192.0), (1220, 320), (1607, 320), (930, 192)] {
            host.setContentSize(CGSize(width: windowWidth, height: 650))
            try await waitForLayout(host) {
                abs(split.bounds.width - windowWidth) <= 1 &&
                abs((split.arrangedSubviews.last?.frame.minX ?? -1000) - expected) <= 1
            }
            let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
            let detail = try XCTUnwrap(split.arrangedSubviews.last)
            XCTAssertFalse(sidebar === detail, "The native split must own both columns")
            XCTAssertEqual(sidebar.frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(sidebar.frame.width + split.dividerThickness, expected, accuracy: 0.5)
            XCTAssertEqual(detail.frame.minX - sidebar.frame.maxX, split.dividerThickness, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(detail.frame.width, SidebarLayout.rightContentMin - 0.5)
            XCTAssertEqual(detail.frame.maxX, windowWidth, accuracy: 1)
            XCTAssertEqual(storage.saved.applicationPreferences.sidebarWidth, 320)
            XCTAssertEqual(storage.writes, 0, "Window resizing must not replace the user's preferred divider width")
        }
    }

    func testNativeSplitHonorsInitialCollapseAndLatestToggleDuringReversal() async throws {
        let storage = SidebarLayoutStorage()
        storage.saved.applicationPreferences.sidebarWidth = 280
        storage.saved.applicationPreferences.sidebarCollapsed = true
        let model = makeModel(storage)
        let host = makeHost(model, width: 1220)
        defer { host.close() }
        let split = try await nativeSplit(in: host)
        let detail = try XCTUnwrap(split.arrangedSubviews.last)
        try await waitForLayout(host) { abs(detail.frame.minX) <= 1 && detail.frame.width >= 1219 }
        XCTAssertEqual(storage.writes, 0, "Restoring a collapsed split must not write a new width or reopen it")
        for collapsed in [false, true, false] {
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = collapsed
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            // Deliver each intent in a separate AppKit update while a system
            // animation can still be running. No timing assumes motion is on.
            await Task.yield()
            host.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(32))
        }
        try await waitForLayout(host) { abs(detail.frame.minX - 280) <= 1 }
        // A completion from either superseded animation must not undo the last click.
        try await Task.sleep(for: .milliseconds(500))
        host.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(split.arrangedSubviews.last === detail)
        XCTAssertEqual(detail.frame.minX, 280, accuracy: max(1, split.dividerThickness))
        XCTAssertFalse(model.applicationPreferences.sidebarCollapsed)
        XCTAssertEqual(storage.saved.applicationPreferences.sidebarWidth, 280)
        XCTAssertEqual(storage.writes, 3, "Animation frames must not write out intermediate sidebar widths")
    }

    func testNativeDividerDragPersistsOnceAndFollowsLaterSettingsWidth() async throws {
        let storage = SidebarLayoutStorage()
        storage.saved.applicationPreferences.sidebarWidth = 240
        let model = makeModel(storage)
        let window = makeHost(model, width: 1220)
        defer { window.close() }
        let split = try await nativeSplit(in: window)
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        try await waitForLayout(window) { abs(sidebar.frame.width + split.dividerThickness - 240) <= 0.5 }

        try trackDivider(in: split, window: window, dragOffsets: [20, 50])
        try await waitForLayout(window) {
            abs(sidebar.frame.width + split.dividerThickness - 290) <= 0.5 && abs(model.applicationPreferences.sidebarWidth - 290) <= 0.5
        }
        XCTAssertEqual(storage.writes, 1, "The drag must persist its final position once on release")

        try trackDivider(in: split, window: window, dragOffsets: [-32, 0])
        // Let the release callback and the next native layout finish before checking the no-op.
        try await Task.sleep(for: .milliseconds(50))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(sidebar.frame.width + split.dividerThickness, 290, accuracy: 0.5)
        XCTAssertEqual(storage.saved.applicationPreferences.sidebarWidth, 290)
        XCTAssertEqual(storage.writes, 1, "Returning the divider to its origin must not save an intermediate width")

        var settings = model.applicationPreferences
        settings.sidebarWidth = 260
        settings.posterSize = .large
        XCTAssertTrue(model.updateApplicationPreferences(settings))
        try await waitForLayout(window) { abs(sidebar.frame.width + split.dividerThickness - 260) <= 0.5 }
        XCTAssertEqual(storage.saved.applicationPreferences.posterSize, .large)
        XCTAssertEqual(storage.writes, 2, "Applying a Settings edit to the split must not write its width back")

        try trackDivider(in: split, window: window, dragOffsets: [], clickCount: 2)
        try await waitForLayout(window) { storage.writes == 3 && abs(sidebar.frame.width + split.dividerThickness - SidebarLayout.defaultWidth) <= 0.5 }
        XCTAssertEqual(sidebar.frame.width + split.dividerThickness, SidebarLayout.defaultWidth, accuracy: 0.5)
        XCTAssertEqual(model.applicationPreferences.sidebarWidth, SidebarLayout.defaultWidth)
        XCTAssertFalse(model.applicationPreferences.sidebarCollapsed, "Double-click restores width while keeping the sidebar open")
        XCTAssertEqual(storage.writes, 3)
    }

    func testNativeLayoutKeepsPreferredWidthAndAccessibilityResizePersists() async throws {
        let storage = SidebarLayoutStorage()
        storage.saved.applicationPreferences.sidebarWidth = 240
        let model = makeModel(storage)
        let window = makeHost(model, width: 1220)
        defer { window.close() }
        let split = try await nativeSplit(in: window)
        let content = try XCTUnwrap(split.arrangedSubviews.last)
        for (width, expected) in [(1220.0, 240.0), (930, 192), (1220, 240)] {
            window.setContentSize(CGSize(width: width, height: 650))
            try await waitForLayout(window) { abs(content.frame.minX - expected) <= 0.5 }
            XCTAssertEqual(storage.saved.applicationPreferences.sidebarWidth, 240)
            XCTAssertEqual(storage.writes, 0)
        }

        let divider = try XCTUnwrap(split.accessibilitySplitters()?.first) as AnyObject
        divider.setAccessibilityValue?(NSNumber(value: 270))
        let adjusted = 270 + split.dividerThickness
        try await waitForLayout(window) {
            abs(content.frame.minX - adjusted) <= 0.5 && abs(model.applicationPreferences.sidebarWidth - adjusted) <= 0.5
        }
        XCTAssertEqual(storage.writes, 1, "Changing the native splitter through Accessibility must save the new width once")
    }

    private func trackDivider(in split: NSSplitView, window: NSWindow, dragOffsets: [CGFloat], clickCount: Int = 1) throws {
        let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
        let divider = sidebar.frame.maxX + split.dividerThickness / 2
        func mouse(_ type: NSEvent.EventType, delta: CGFloat, sequence: Int) throws -> NSEvent {
            let point = split.convert(CGPoint(x: divider + delta, y: split.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: sequence, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try mouse(.leftMouseDown, delta: 0, sequence: 1)
        let drags = try dragOffsets.enumerated().map { try mouse(.leftMouseDragged, delta: $0.element, sequence: $0.offset + 2) }
        let up = try mouse(.leftMouseUp, delta: dragOffsets.last ?? 0, sequence: drags.count + 2)
        if drags.isEmpty {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
        } else {
            // Only this process' AppKit tracking loop sees the drag and release.
            let root = try XCTUnwrap(window.contentView)
            let point = root.superview?.convert(down.locationInWindow, from: nil) ?? down.locationInWindow
            let target = try XCTUnwrap(root.hitTest(point), "The divider must have a receiver in the real window hierarchy")
            guard target === split || target.superview === split else {
                XCTFail("The window must hit the native divider. It hit \(type(of: target)) instead")
                return
            }
            for event in ([up] + drags.reversed()) { NSApp.postEvent(event, atStart: true) }
            target.mouseDown(with: down)
        }
    }

    func testDisabledMotionTransactionChangesNativeColumnsWithoutIntermediatePositions() async throws {
        let storage = SidebarLayoutStorage()
        storage.saved.applicationPreferences.sidebarWidth = 280
        let model = makeModel(storage)
        let window = makeHost(model, width: 1220, disablesAnimations: true)
        defer { window.close() }
        let split = try await nativeSplit(in: window)
        let detail = try XCTUnwrap(split.arrangedSubviews.last)
        try await waitForLayout(window) { abs(detail.frame.minX - 280) <= 1 }
        for collapsed in [true, false] {
            var settings = model.applicationPreferences
            settings.sidebarCollapsed = collapsed
            XCTAssertTrue(model.updateApplicationPreferences(settings))
            let target: CGFloat = collapsed ? 0 : 280
            var intermediate: [CGFloat] = []
            try await waitForLayout(window) {
                let boundary = detail.frame.minX
                if boundary > 1 && boundary < 279 && intermediate.last != boundary { intermediate.append(boundary) }
                return abs(boundary - target) <= 1
            }
            XCTAssertTrue(intermediate.isEmpty, "Disabled motion must not move through partial column widths: \(intermediate)")
        }
    }

    private func makeHost(_ model: ApplicationModel, width: CGFloat, disablesAnimations: Bool = false) -> NSWindow {
        _ = NSApplication.shared
        let size = CGSize(width: width, height: 650)
        let root = NSHostingController(rootView: SeatSixRootView(model: model)
            .transaction { if disablesAnimations { $0.disablesAnimations = true } })
        root.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = root
        window.setContentSize(size)
        root.view.frame = CGRect(origin: .zero, size: size)
        return window
    }

    private func nativeSplit(in window: NSWindow) async throws -> NSSplitView {
        let root = try XCTUnwrap(window.contentView)
        try await waitForLayout(window) { root.testSidebarSplit != nil }
        return try XCTUnwrap(root.testSidebarSplit, "The sidebar and detail must be laid out by macOS")
    }

    private func waitForLayout(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line,
                               until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertTrue(ready(), "Native split did not reach the requested layout", file: file, line: line)
    }

    private func makeModel(_ storage: SidebarLayoutStorage) -> ApplicationModel {
        ApplicationModel(storage: storage,
            credentials: CredentialAccess(read: { _ in throw CredentialStoreError.notFound }, save: { _, _ in }, remove: { _ in }))
    }
}

private final class SidebarLayoutStorage: ApplicationPersisting {
    var saved = SavedApplication()
    var writes = 0
    var failWrites = false
    func load() throws -> SavedApplication { saved }
    func save(_ data: SavedApplication) throws {
        if failWrites { throw ApplicationPersistenceError.saveFailed }
        writes += 1
        saved = data
    }
}

extension NSView {
    @MainActor var testSidebarSplit: NSSplitView? {
        if let split = self as? NSSplitView { return split }
        return subviews.lazy.compactMap { $0.testSidebarSplit }.first
    }
}
