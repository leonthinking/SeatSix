import AppKit
import SwiftUI
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

final class PlaybackChromeLayoutTests: XCTestCase {
    @MainActor
    func testTransportIsCenteredIndependentlyOfUnequalSideGroups() async throws {
        let controller = try makeController()
        for width: CGFloat in [280, 320, 350, 390, 480, 500, 700, 1024, 1600, 2560] {
            var frames: [String: CGRect] = [:]
            let root = LocalPlaybackControls(controller: controller, interaction: PlaybackInteractionController())
                .frame(width: width, height: 220)
                .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 220),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            defer { window.contentViewController = nil; window.close() }
            for _ in 0..<3 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let transport = try XCTUnwrap(frames["hud-transport"])
            let leading = try XCTUnwrap(frames["hud-leading"])
            let trailing = try XCTUnwrap(frames["hud-trailing"])
            XCTAssertEqual(transport.midX, width / 2, accuracy: 1)
            let dock = try XCTUnwrap(frames["hud-dock"])
            XCTAssertEqual(dock.midX, width / 2, accuracy: 1)
            XCTAssertLessThanOrEqual(dock.width, 860)
            XCTAssertTrue(dock.contains(leading) && dock.contains(trailing) && dock.contains(transport))
            XCTAssertGreaterThanOrEqual(dock.minX, 0)
            XCTAssertLessThanOrEqual(dock.maxX, width)
            XCTAssertFalse(leading.intersects(trailing), "Side controls overlap at width \(width)")
            if width >= 700 {
                XCTAssertEqual(leading.midY, transport.midY, accuracy: 1)
                XCTAssertLessThan(leading.maxX, transport.minX)
                XCTAssertGreaterThan(trailing.minX, transport.maxX)
            } else {
                XCTAssertLessThan(transport.maxY, leading.minY)
                XCTAssertLessThan(transport.maxY, trailing.minY)
            }
            for title in ["音量", "播放速度", "字幕", "音轨", "更多播放选项", "进入全屏",
                          "播放", "上一集", "下一集", PlaybackSeekDirection.forward.label(in: controller.interfacePreferences),
                          PlaybackSeekDirection.backward.label(in: controller.interfacePreferences)] {
                let action = try XCTUnwrap(frames[title])
                XCTAssertTrue(dock.contains(action), "\(title) extends beyond the dock at width \(width)")
            }
        }
    }

    @MainActor
    func testVeryNarrowPlayerKeepsPlaybackAndExpandedControlsReachable() async throws {
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        var frames: [String: CGRect] = [:]
        let root = PlaybackContent(controller: controller, interaction: PlaybackInteractionController())
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 205, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.close() }
        for width: CGFloat in [205, 175, 150, 69] {
            window.setContentSize(NSSize(width: width, height: 360))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let dock = try XCTUnwrap(frames["hud-dock"])
            let play = try XCTUnwrap(frames["播放"])
            let more = try XCTUnwrap(frames["更多播放选项"])
            XCTAssertGreaterThanOrEqual(dock.minX, 0)
            XCTAssertLessThanOrEqual(dock.maxX, width)
            XCTAssertTrue(dock.contains(play) && dock.contains(more))
            XCTAssertFalse(play.intersects(more))
            XCTAssertNil(frames["hud-leading"], "Full-width controls should open in the panel at width \(width)")
        }
    }

    @MainActor
    func testPlaybackAndEpisodeControlsFitTheMinimumSupportedWindow() throws {
        _ = NSApplication.shared
        let controller = try makeController()
        let interaction = PlaybackInteractionController()
        let availableWidth = PlaybackWindowGeometry.minimumSize.width - 24
        let episodes = NSHostingView(rootView: PlaybackEpisodeNavigation(controller: controller, interaction: interaction)
            .preferredColorScheme(.dark))

        for interval: Double in [5, 10, 15, 30, 60] {
            var preferences = ApplicationPreferences()
            preferences.seekBackwardSeconds = interval
            preferences.seekForwardSeconds = interval
            preferences.timeDisplay = .remaining
            controller.updateInterfacePreferences(preferences)
            let footer = NSHostingView(rootView: LocalPlaybackControls(controller: controller, interaction: interaction)
                .preferredColorScheme(.dark))
            XCTAssertGreaterThan(footer.fittingSize.width, 0)
            XCTAssertLessThanOrEqual(footer.fittingSize.width, availableWidth,
                                     "All configured transport intervals and remaining time must fit without clipping at the window minimum")
        }
        XCTAssertGreaterThan(episodes.fittingSize.width, 0)
        XCTAssertLessThanOrEqual(episodes.fittingSize.width, availableWidth - 32,
                                 "Episode switching and autoplay share one header without requiring a wider player window")
    }

    @MainActor
    func testMovieAndEpisodeOfferDistinctReachablePlaybackActions() async throws {
        for type in ["Movie", "Episode"] {
            let controller = try makeController(type: type)
            controller.preparing = false
            var actions: [String: CGRect] = [:]
            let root = LocalPlaybackControls(controller: controller, interaction: PlaybackInteractionController())
                .frame(width: 700)
                .onPreferenceChange(SeatSixSidebarFrameKey.self) { actions = $0 }
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.isReleasedWhenClosed = false
            defer { window.contentViewController = nil; window.close() }
            for _ in 0..<3 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let back = PlaybackSeekDirection.backward.label(in: controller.interfacePreferences)
            let forward = PlaybackSeekDirection.forward.label(in: controller.interfacePreferences)
            var required = ["音量", "播放速度", back, "播放", forward, "字幕", "音轨", "更多播放选项", "进入全屏"]
            if type == "Episode" { required += ["上一集", "下一集"] }
            else {
                XCTAssertNil(actions["上一集"])
                XCTAssertNil(actions["下一集"])
            }
            for title in required {
                let frame = try XCTUnwrap(actions[title], "Missing \(title) in \(actions.keys.sorted())")
                XCTAssertGreaterThanOrEqual(frame.width, 32, "\(title) must be easy to click")
                XCTAssertGreaterThanOrEqual(frame.height, 32, "\(title) must be easy to click")
            }
            XCTAssertGreaterThan(try XCTUnwrap(actions["播放"]).height, try XCTUnwrap(actions[forward]).height)
        }
    }

    @MainActor
    func testPlaybackMenusRemainUniqueAndMetadataStaysOutOfTheMovie() async throws {
        let restoreAccessibility = enableAccessibilityTree()
        defer { restoreAccessibility() }

        let controller = try makeController(type: "Movie")
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        controller.syncMessage = "进度已同步"
        let root = PlaybackContent(controller: controller, interaction: PlaybackInteractionController())
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close() }

        let expected = ["播放速度，1×", "字幕", "音轨", "更多播放选项"].sorted()
        for width in [320, 700, 1600] {
            window.setContentSize(NSSize(width: width, height: 460))
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            let nodes = snapshot(host.view)
            let menus = nodes.filter { ["AXMenuButton", "AXPopUpButton"].contains($0.role) }
            XCTAssertEqual(menus.map(\.name).sorted(), expected)
            let statuses = nodes.filter { $0.name == "播放进度同步状态" }
            XCTAssertTrue(statuses.isEmpty, "Healthy sync belongs in playback information, outside the movie")
            XCTAssertFalse(nodes.contains { $0.name == "窗口置顶" })
        }
        window.setContentSize(NSSize(width: 175, height: 500))
        window.orderFront(nil)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let narrow = snapshot(host.view)
        let openButtons = narrow.filter { $0.name == "更多播放选项" }
        XCTAssertEqual(openButtons.map(\.role), [NSAccessibility.Role.button.rawValue])
        let trigger = try XCTUnwrap(openButtons.first?.element)
        XCTAssertTrue((trigger as AnyObject).accessibilityPerformPress?() == true)
        let required = Set(expected + ["音量", "进入全屏", "播放"])
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let panels = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
            for panel in panels {
                guard let view = panel.contentView else { continue }
                let controls = snapshot(view)
                if controls.contains(where: { $0.role == NSAccessibility.Role.slider.rawValue }),
                   required.isSubset(of: Set(controls.map(\.name))) { return }
            }
        }
        XCTFail("Expanded controls must expose the timeline, transport, volume and named menus")

    }

    @MainActor
    func testNormalWindowVideoUsesEntireContentAreaAtTwoSizes() async throws {
        let controller = try makeController()
        let engine = try LocalPlaybackEngine()
        await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
        controller.preparing = false
        let interaction = PlaybackInteractionController()
        var frames: [String: CGRect] = [:]
        let root = PlaybackContent(controller: controller, interaction: interaction)
            .background(SeatSixSidebarGeometry(id: "content"))
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close(); engine.shutdown() }
        for size in [NSSize(width: 700, height: 460), NSSize(width: 1200, height: 540)] {
            window.setContentSize(size)
            for atTop in [false, true] {
                interaction.controlsAtTop = atTop
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(60))
                let video = engine.videoView
                XCTAssertTrue(video.window === window)
                XCTAssertEqual(video.convert(video.bounds, to: host.view), host.view.bounds)
                let dock = try XCTUnwrap(frames["hud-dock"])
                let stage = try XCTUnwrap(frames["content"])
                if atTop {
                    XCTAssertLessThan(dock.maxY, stage.midY, "Moving controls must free the subtitle area")
                } else {
                    XCTAssertGreaterThan(dock.minY, stage.midY, "The default control bar belongs at the bottom")
                }
            }
        }
    }

    @MainActor
    func testSeekSliderCommitsAccessibleAndFocusedKeyboardAdjustmentsWithoutADrag() throws {
        let slider = PlaybackSeekSlider()
        slider.maxValue = 600
        slider.doubleValue = 90
        var positions: [Double] = []
        slider.seek = { positions.append($0) }
        slider.preview = { _ in XCTFail("Discrete input must commit without starting a mouse preview") }
        slider.preferences.seekForwardSeconds = 30
        slider.preferences.seekBackwardSeconds = 5
        slider.doubleValue = 11.762
        XCTAssertEqual(slider.accessibilityValueDescription(), "00:12")
        XCTAssertEqual(PlaybackTimeLabel.playhead(11.762, dragging: true), "00:11")
        slider.setAccessibilityValue(NSNumber(value: 120))
        XCTAssertEqual(slider.accessibilityValue() as? Double, 120)
        XCTAssertEqual(slider.accessibilityValueDescription(), "02:00")
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 123))
        slider.keyDown(with: left)
        for code: UInt16 in [123, 124] {
            let repeated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: true, keyCode: code))
            slider.keyDown(with: repeated)
        }
        slider.setAccessibilityValue(NSNumber(value: -1))
        slider.setAccessibilityValue(NSNumber(value: 999))
        slider.setAccessibilityValue(NSNumber(value: Double.nan))
        slider.isEnabled = false
        XCTAssertFalse(slider.accessibilityPerformDecrement())
        slider.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(positions, [120, 150, 145, 140, 0, 600])
    }

    @MainActor
    func testPlaybackDockShowsVideoColourAndHonorsReadabilityPreferences() async throws {
        let controller = try makeController(type: "Movie")
        controller.preparing = false
        let size = NSSize(width: 860, height: 150)
        let supportsGlass: Bool
        if #available(macOS 26, *) { supportsGlass = true } else { supportsGlass = false }
        // The last case exercises the older macOS material path on the current SDK.
        for (available, reducedTransparency, highContrast) in [(supportsGlass, false, false),
                (supportsGlass, true, false), (supportsGlass, false, true), (false, false, false)] {
            let policy = SeatSixMaterialPolicy(supportsLiquidGlass: available,
                                               reduceTransparency: reducedTransparency,
                                               increasedContrast: highContrast, reduceMotion: true)
            var frames: [String: CGRect] = [:]
            let root = ZStack {
                HStack(spacing: 0) {
                    Color.white.frame(width: 120)
                    Color.red
                    Color.blue
                }
                LocalPlaybackControls(controller: controller, interaction: PlaybackInteractionController(),
                                      materialPolicy: policy)
            }
            .overlay(alignment: .top) {
                if policy.surface == .material {
                    Rectangle().fill(.regularMaterial).frame(height: 16)
                }
            }
            .background(SeatSixSidebarGeometry(id: "capture"))
            .preferredColorScheme(.dark)
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            defer { window.contentViewController = nil; window.close() }
            host.view.frame = NSRect(origin: .zero, size: size)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let origin = try XCTUnwrap(frames["capture"]).origin
            func rect(_ key: String) throws -> CGRect {
                try XCTUnwrap(frames[key]).offsetBy(dx: -origin.x, dy: -origin.y)
            }
            let transport = try rect("hud-transport")
            let leading = try rect("hud-leading")
            let trailing = try rect("hud-trailing")
            func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
                let pixelX = Int(x * CGFloat(bitmap.pixelsWide) / size.width)
                let pixelY = Int(y * CGFloat(bitmap.pixelsHigh) / size.height)
                return try XCTUnwrap(bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB))
            }
            // Sample empty space between groups, away from the controls, edges and colour transition.
            let leftX = (leading.maxX + transport.minX) / 2
            let rightX = (transport.maxX + trailing.minX) / 2
            let left = try sample(leftX, transport.midY)
            let right = try sample(rightX, transport.midY)
            if policy.surface == .liquidGlass {
                // Offscreen drawing preserves the dock's local scrim. Its
                // WindowServer refraction is separately checked in the signed app.
                XCTAssertGreaterThan(left.redComponent - right.redComponent, 0.22,
                                     "A dark navigation fill obscures the underlying video. \(left) vs \(right)")
                XCTAssertGreaterThan(right.blueComponent - left.blueComponent, 0.22)
                XCTAssertLessThan(left.redComponent, 0.96, "Bright scenes need local dimming behind the controls")
                XCTAssertLessThan(right.blueComponent, 0.96)
            } else if policy.surface == .material {
                // A neutral scrim should dim SwiftUI's regular material consistently
                // on both colours, while keeping the underlying video recognizable.
                let untreated = try sample(leftX, 8)
                let dimming = left.redComponent / untreated.redComponent
                XCTAssertGreaterThan(dimming, 0.5)
                XCTAssertLessThan(dimming, 0.98)
                for (x, fill) in [(leftX, left), (rightX, right)] {
                    let reference = try sample(x, 8)
                    XCTAssertEqual(fill.redComponent, reference.redComponent * dimming, accuracy: 0.04)
                    XCTAssertEqual(fill.greenComponent, reference.greenComponent * dimming, accuracy: 0.04)
                    XCTAssertEqual(fill.blueComponent, reference.blueComponent * dimming, accuracy: 0.04)
                }
            } else {
                XCTAssertEqual(left.redComponent, right.redComponent, accuracy: 0.02)
                XCTAssertEqual(left.greenComponent, right.greenComponent, accuracy: 0.02)
                XCTAssertEqual(left.blueComponent, right.blueComponent, accuracy: 0.02)
                if highContrast {
                    let dock = try rect("hud-dock")
                    let border = try sample(dock.midX, dock.minY + 0.5)
                    XCTAssertGreaterThan(border.greenComponent - left.greenComponent, 0.2,
                                         "Increased contrast must mark the boundary of the opaque dock")
                }
            }
            for (control, minimumContrast) in [("音量", 3.0), ("播放速度", 4.5)] {
                let region = try rect(control)
                XCTAssertLessThan(region.maxX, 120, "The contrast probe must sit over the white video region")
                let contrast = try renderedContrast(bitmap, in: region, viewSize: size)
                XCTAssertGreaterThan(contrast, minimumContrast, "\(control) over white, surface = \(policy.surface)")
            }
        }
    }

    @MainActor
    func testEpisodeHeaderUsesTheSameVideoMaterialAsThePlaybackDock() async throws {
        let controller = try makeController(type: "Episode")
        let size = CGSize(width: 600, height: 180)
        var frames: [String: CGRect] = [:]
        let root = ZStack {
            HStack(spacing: 0) { Color.red; Color.blue }
            VStack(spacing: 12) {
                PlaybackEpisodeHeader(controller: controller, interaction: PlaybackInteractionController())
                    .background(SeatSixSidebarGeometry(id: "header"))
                Color.clear.frame(height: 24)
                    .playbackControlGlass(cornerRadius: 12)
                    .background(SeatSixSidebarGeometry(id: "reference"))
            }
        }
        .background(SeatSixSidebarGeometry(id: "capture")).preferredColorScheme(.dark)
        .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close() }
        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let origin = try XCTUnwrap(frames["capture"]).origin
        let header = try XCTUnwrap(frames["header"]).offsetBy(dx: -origin.x, dy: -origin.y)
        let reference = try XCTUnwrap(frames["reference"]).offsetBy(dx: -origin.x, dy: -origin.y)
        func sample(x: CGFloat, y: CGFloat) throws -> NSColor {
            let pixelX = Int(x * CGFloat(bitmap.pixelsWide) / size.width)
            let pixelY = Int(y * CGFloat(bitmap.pixelsHigh) / size.height)
            return try XCTUnwrap(bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.sRGB))
        }
        for x in [header.midX - header.width / 4, header.midX + header.width / 4] {
            // Both readings are inside the material, clear of text, edges and the colour split.
            let actual = try sample(x: x, y: header.maxY - 5)
            let expected = try sample(x: x, y: reference.midY)
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.05)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.05)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.05)
        }
    }

    @MainActor
    func testTitleBarInformationRemainsAvailableAcrossEnginesAndAfterAnError() async throws {
        let restoreAccessibility = enableAccessibilityTree()
        defer { restoreAccessibility() }
        for (local, width) in [(false, 700), (true, 700), (false, 100), (true, 100),
                               (false, 69), (true, 119), (true, 120)] {
            let controller = try makeController(type: "Movie")
            if local {
                let engine = try LocalPlaybackEngine()
                await controller.restorePreferences(engine: engine, mediaSourceID: "fixture")
            }
            controller.preparing = false
            controller.syncMessage = "进度已同步"
            controller.playbackLabel = local ? "本地解码 · 原画直放" : "兼容播放 · 服务器转码"
            controller.errorMessage = "播放中断"
            let owner = PlaybackWindowController(controller: controller, onClosing: { _ in }, onClose: { _ in })
            let window = try XCTUnwrap(owner.window)
            defer {
                owner.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
                window.delegate = nil
                window.close()
                controller.localEngine?.shutdown()
            }
            window.minSize = NSSize(width: 1, height: 1)
            window.setContentSize(NSSize(width: width, height: 460))
            window.orderFront(nil)
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(window.title, controller.item.name)
            let nodes = snapshot(content)
            XCTAssertFalse(nodes.contains { $0.name == "播放进度同步状态" })
            let titlebarNodes = window.titlebarAccessoryViewControllers
                .filter { !$0.isHidden && !$0.view.isHiddenOrHasHiddenAncestor }
                .flatMap { snapshot($0.view) }
            func infoButtons(in nodes: [AccessibilityNode]) -> [AccessibilityNode] {
                nodes.filter { $0.role == NSAccessibility.Role.button.rawValue && $0.name == "播放信息" }
            }
            let overlayButtons = infoButtons(in: nodes)
            let titlebarButtons = infoButtons(in: titlebarNodes)
            let usesOverlay = CGFloat(width) < PlaybackWindowGeometry.minimumTitlebarInfoWidth
            XCTAssertEqual(overlayButtons.count, usesOverlay ? 1 : 0)
            XCTAssertEqual(titlebarButtons.count, usesOverlay ? 0 : 1)
            let buttons = overlayButtons + titlebarButtons
            let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            let button = try XCTUnwrap(buttons.first?.element)
            let buttonFrame = try XCTUnwrap(button.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertTrue(window.frame.insetBy(dx: -1, dy: -1).contains(buttonFrame),
                          "The complete system button must be reachable at \(width) points: \(buttonFrame), window \(window.frame), content \(content.bounds)")
            XCTAssertGreaterThanOrEqual(buttonFrame.height, 22)
            XCTAssertTrue((button as AnyObject).accessibilityPerformPress?() == true)

            let panelNodes = try await popoverNodes(after: before, containing: "播放进度同步状态")
            let statuses = panelNodes.filter { $0.name == "播放进度同步状态" }
            XCTAssertEqual(statuses.map(\.role), [NSAccessibility.Role.staticText.rawValue])
            XCTAssertEqual(statuses.first?.value, controller.syncMessage)
            XCTAssertEqual(panelNodes.filter { $0.name == "来源" }.map(\.value), [controller.connection.name])
            XCTAssertEqual(panelNodes.filter { $0.name == "播放方式" }.map(\.value), [controller.playbackLabel])
            let pin = try XCTUnwrap(panelNodes.first { $0.name == "窗口置顶" && $0.role == NSAccessibility.Role.checkBox.rawValue }?.element)
            let wasPinned = controller.isWindowOnTop
            // NSSwitch can return false from its in-process AX press even while changing its binding.
            _ = (pin as AnyObject).accessibilityPerformPress?()
            XCTAssertEqual(controller.isWindowOnTop, !wasPinned)
        }
    }

    @MainActor
    func testCompactEpisodeHeaderShowsPlaybackFeedbackAndPromptsForRecovery() async throws {
        let restoreAccessibility = enableAccessibilityTree()
        defer { restoreAccessibility() }
        let controller = try makeController(type: "Episode")
        controller.preparing = false
        let host = NSHostingController(rootView: PlaybackContent(controller: controller, interaction: PlaybackInteractionController()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 175, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 175, height: 460))
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        controller.nextEpisodeMessage = "切换未能完成，可在播放器中重新选集。"
        controller.configureSeriesSkip(.init(load: { .init() }, save: { _ in }))
        XCTAssertTrue(controller.saveSeriesSkipSettings(.init(outroSeconds: 60)))
        XCTAssertNotNil(controller.seriesSkipMessage, "Unknown episode duration should suspend automatic skipping")
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let nodes = snapshot(host.view)
        XCTAssertEqual(nodes.filter { $0.name == "分集控制" && $0.role == NSAccessibility.Role.button.rawValue }.count, 1)
        for message in [controller.nextEpisodeMessage, controller.seriesSkipMessage].compactMap({ $0 }) {
            XCTAssertEqual(nodes.filter { $0.value == message || $0.name == message }.count, 1,
                           "Episode feedback must appear even while the controls are collapsed")
        }

        var usedLocalPosition = false
        controller.onChooseEpisodeRecovery = { usedLocalPosition = $0 }
        controller.episodeRecoveryChoice = .init(localTicks: 120_000_000, remoteTicks: 400_000_000)
        let choices = try await popoverNodes(after: before, containing: "取消切换")
        for name in ["本机 00:12", "服务器 00:40", "取消切换"] {
            XCTAssertEqual(choices.filter { $0.name == name && $0.role == NSAccessibility.Role.button.rawValue }.count, 1)
        }
        let local = try XCTUnwrap(choices.first { $0.name == "本机 00:12" }?.element)
        _ = (local as AnyObject).accessibilityPerformPress?()
        XCTAssertTrue(usedLocalPosition)
    }

    @MainActor
    func testFullScreenMovieShowsOneTitleAndInformationButton() async throws {
        // Supply the AppKit state observed after entry without switching the test runner's desktop Space.
        final class FullScreenWindow: NSWindow {
            var reportingFullScreen = false
            override var styleMask: NSWindow.StyleMask {
                get { reportingFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
                set { super.styleMask = newValue }
            }
        }
        let restoreAccessibility = enableAccessibilityTree()
        defer { restoreAccessibility() }
        let controller = try makeController(type: "Movie")
        controller.preparing = false
        let interaction = PlaybackInteractionController()
        let window = FullScreenWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.reportingFullScreen = true
        interaction.attach(to: window, controller: controller)
        window.reportingFullScreen = false
        defer { interaction.detach(); window.contentView = nil; window.close() }
        XCTAssertTrue(interaction.isFullScreen)
        let host = NSHostingView(rootView: PlaybackContent(controller: controller, interaction: interaction))
        host.sizingOptions = []
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        let nodes = snapshot(host)
        XCTAssertEqual(nodes.filter { $0.name == controller.item.name || $0.value == controller.item.name }.count, 1)
        let buttons = nodes.filter { $0.name == "播放信息" && $0.role == NSAccessibility.Role.button.rawValue }
        XCTAssertEqual(buttons.count, 1)
        XCTAssertFalse(nodes.contains { $0.name == "窗口置顶" || $0.name == "播放进度同步状态" })
        let before = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let button = try XCTUnwrap(buttons.first?.element)
        XCTAssertTrue((button as AnyObject).accessibilityPerformPress?() == true)
        let panel = try await popoverNodes(after: before, containing: "播放进度同步状态")
        XCTAssertFalse(panel.contains { $0.name == "窗口置顶" })
    }

    @MainActor
    func testSyncWarningAppearsWithoutOpeningPlaybackInformation() async throws {
        let restoreAccessibility = enableAccessibilityTree()
        defer { restoreAccessibility() }
        var canSaveLocally = true
        let controller = try makeController(type: "Movie") { _, _ in canSaveLocally }
        controller.preparing = false
        let host = NSHostingController(rootView: PlaybackContent(controller: controller, interaction: PlaybackInteractionController()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 460),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close() }
        func warnings() async throws -> [String] {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            return snapshot(host.view).filter { $0.name == "播放进度提醒" }.map(\.value)
        }
        var values = try await warnings()
        XCTAssertTrue(values.isEmpty)
        canSaveLocally = false
        XCTAssertFalse(controller.persistSnapshot(ticks: 10, confirmed: false))
        values = try await warnings()
        XCTAssertEqual(values, [controller.syncMessage])
        canSaveLocally = true
        XCTAssertTrue(controller.persistSnapshot(ticks: 10, confirmed: true))
        controller.syncMessage = "进度已同步"
        values = try await warnings()
        XCTAssertTrue(values.isEmpty)
        controller.markUncertain()
        values = try await warnings()
        XCTAssertEqual(values, [controller.syncMessage])
    }

    @MainActor
    func testPlaybackInformationKeepsSourceAndSyncStatusLegibleOnDarkAppearance() async throws {
        let controller = try makeController(type: "Movie")
        controller.syncMessage = "进度已同步"
        var frames: [String: CGRect] = [:]
        let root = PlaybackInformationView(controller: controller, interaction: PlaybackInteractionController())
            .background(Color(nsColor: .windowBackgroundColor))
            .background(SeatSixSidebarGeometry(id: "capture"))
            .preferredColorScheme(.dark)
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { frames = $0 }
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let origin = try XCTUnwrap(frames["capture"]).origin
        for key in ["player-source", "player-sync"] {
            let frame = try XCTUnwrap(frames[key]).offsetBy(dx: -origin.x, dy: -origin.y)
            let contrast = try renderedContrast(bitmap, in: frame, viewSize: host.view.bounds.size)
            XCTAssertGreaterThan(contrast, 4.5, "Playback information must keep its small text readable")
        }
    }

    private func renderedContrast(_ bitmap: NSBitmapImageRep, in region: NSRect, viewSize: NSSize) throws -> Double {
        let scaleX = Double(bitmap.pixelsWide) / viewSize.width
        let scaleY = Double(bitmap.pixelsHigh) / viewSize.height
        let bounds = NSRect(origin: .zero, size: viewSize)
        let region = try XCTUnwrap(bounds.contains(region) && !region.isEmpty ? region : nil,
                                   "Glyph frame \(region) must be inside captured view \(bounds)")
        var luminances: [Double] = []
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        for y in Int(region.minY * scaleY)..<Int(region.maxY * scaleY) {
            for x in Int(region.minX * scaleX)..<Int(region.maxX * scaleX) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                luminances.append(0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                                  + 0.0722 * linear(color.blueComponent))
            }
        }
        luminances.sort()
        // Median is the fill; the 99th percentile samples solid glyph pixels,
        // excluding isolated antialiasing specks. Compare actual rendered output.
        return (luminances[Int(Double(luminances.count - 1) * 0.99)] + 0.05)
            / (luminances[luminances.count / 2] + 0.05)
    }

    @MainActor
    private func enableAccessibilityTree() -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let app = NSApplication.shared
        let wasEnabled = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        return { app.accessibilitySetValue(wasEnabled, forAttribute: attribute) }
    }

    private typealias AccessibilityNode = (role: String, name: String, value: String, element: NSObject)

    @MainActor
    private func popoverNodes(after visibleWindows: Set<ObjectIdentifier>, containing name: String) async throws -> [AccessibilityNode] {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let panels = NSApp.windows.filter { $0.isVisible && !visibleWindows.contains(ObjectIdentifier($0)) }
            let nodes = panels.compactMap(\.contentView).flatMap { snapshot($0) }
            if nodes.contains(where: { $0.name == name }) { return nodes }
        }
        XCTFail("The open popover must contain \(name)")
        return []
    }

    @MainActor
    private func snapshot(_ element: NSObject) -> [AccessibilityNode] {
        // SwiftUI accessibility nodes implement AppKit's accessibility
        // selectors without declaring NSAccessibilityProtocol conformance.
        func attribute(_ key: String) -> Any? {
            element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
        }
        func string(_ key: String) -> String? {
            let value = attribute(key)
            return (value as? NSAttributedString)?.string ?? value as? String
        }
        let role = string("accessibilityRole") ?? ""
        let name = string("accessibilityLabel") ?? string("accessibilityTitle") ?? ""
        let children = attribute("accessibilityChildren") as? [NSObject] ?? []
        return [(role, name, string("accessibilityValue") ?? "", element)] + children.flatMap(snapshot)
    }

    @MainActor
    private func makeController(type: String = "Episode", save: @escaping (Int64, Bool) -> Bool = { _, _ in true }) throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"fixture","Name":"Test title","Type":"\#(type)","IndexNumber":2,"ParentIndexNumber":1}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!,
                                          serverID: "server", userID: "user", username: "test")
        return NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "fixture"), save: save)
    }
}
