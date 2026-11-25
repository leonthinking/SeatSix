import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

/// Layout-only acceptance using synthetic content. These tests never load the
/// user's application storage, credentials, media servers, or playback engine.
final class BrowseViewLayoutTests: XCTestCase {
    @MainActor
    func testDetailResumeHasOneNamedMenuSeparateFromThePrimaryAction() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }

        let model = try makeFixture()
        model.detail = model.items[0]
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        host.window.orderFront(nil)
        try await settle(host.controller.view)

        let play = try XCTUnwrap(frames["detail-primary-play"])
        let menu = try XCTUnwrap(frames["detail-more-playback"])
        XCTAssertGreaterThanOrEqual(menu.minX - play.maxX, 8)
        XCTAssertEqual(menu.midY, play.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(menu.width, 28)
        XCTAssertGreaterThanOrEqual(menu.height, 28)

        let items = menuItems(in: host.controller.view)
        let more = items.filter { $0.name == "更多播放操作" }
        XCTAssertEqual(more.count, 1, "Expected one localized menu in \(items)")
        let target = try XCTUnwrap(more.first?.frame)
        XCTAssertGreaterThanOrEqual(target.width, 28)
        XCTAssertGreaterThanOrEqual(target.height, 28)
        XCTAssertFalse(items.contains { $0.name == "More" })
        func playbackMenu(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.pullsDown && popup.toolTip == "更多播放操作" { return popup }
            return view.subviews.lazy.compactMap { playbackMenu(in: $0) }.first
        }
        let popup = try XCTUnwrap(playbackMenu(in: host.controller.view))
        XCTAssertTrue(host.window.makeFirstResponder(popup))
        XCTAssertTrue(host.window.firstResponder === popup)
        XCTAssertNotNil(popup.itemArray.first?.image)
        let restart = try XCTUnwrap(popup.item(withTitle: "从头播放"))
        XCTAssertNotNil(restart.target)
        XCTAssertNotNil(restart.action)
        model.launchingPlayback = true
        try await settle(host.controller.view)
        XCTAssertFalse(popup.isEnabled)
        model.launchingPlayback = false
        model.detail = model.items[4]
        try await settle(host.controller.view)
        XCTAssertNil(frames["detail-more-playback"], "A film without saved progress already starts at the beginning")
    }

    @MainActor
    func testServerAndEpisodeMenusExposeFullSizeNamedControls() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let connection = try XCTUnwrap(model.connection)
        model.navigate(to: "servers")
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        host.window.orderFront(nil)
        try await settle(host.controller.view)
        func check(_ name: String, in view: NSView, size: CGFloat) throws -> NSPopUpButton {
            let matches = menuItems(in: view).filter { $0.name == name }
            XCTAssertEqual(matches.count, 1, name)
            let target = try XCTUnwrap(matches.first?.frame)
            XCTAssertGreaterThanOrEqual(target.width, size, name)
            XCTAssertGreaterThanOrEqual(target.height, size, name)
            let parent = try XCTUnwrap(view.superview)
            let center = host.window.convertPoint(fromScreen: CGPoint(x: target.midX, y: target.midY))
            let popup = try XCTUnwrap(view.hitTest(parent.convert(center, from: nil)) as? NSPopUpButton, name)
            for edge in [CGPoint(x: target.minX + 1, y: target.midY), CGPoint(x: target.maxX - 1, y: target.midY),
                         CGPoint(x: target.midX, y: target.minY + 1), CGPoint(x: target.midX, y: target.maxY - 1)] {
                let point = parent.convert(host.window.convertPoint(fromScreen: edge), from: nil)
                XCTAssertTrue(view.hitTest(point) === popup, name)
            }
            XCTAssertTrue(host.window.makeFirstResponder(popup))
            XCTAssertTrue(host.window.firstResponder === popup)
            return popup
        }
        _ = try check("更多服务器操作，\(connection.name)", in: host.controller.view, size: 28)
        let series = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
        model.showDetail(series)
        try await waitUntil("Load the synthetic episode controls") { !model.seriesLoading && !model.episodes.isEmpty }
        let episode = try XCTUnwrap(model.episodes.first)
        let episodes = NSHostingController(rootView: SeriesEpisodesView(model: model, series: series))
        episodes.sizingOptions = []
        host.window.contentViewController = episodes
        host.window.setContentSize(NSSize(width: 930, height: 650))
        try await settle(episodes.view)
        let episodeMenu = try check("更多分集操作，\(EpisodeDisplay.number(episode))", in: episodes.view, size: 24)
        model.launchingPlayback = true
        try await settle(episodes.view)
        XCTAssertFalse(episodeMenu.isEnabled)
        await model.shutdown()
    }

    @MainActor
    func testRecommendationCarouselWithTenWorksFitsCompactAndWideHome() async throws {
        _ = NSApplication.shared
        let fixture = try makeFixture()
        let recommendations = try (0..<10).map { index in
            try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: [
                "Id": "hero-\(index)", "Name": "横版推荐长标题，用于检查十部推荐在紧凑窗口中的影片信息排版 \(index)",
                "Type": index == 0 ? "Series" : "Movie", "ProductionYear": 2026,
                "Overview": String(repeating: "很长的合成简介用于确保标题和故事介绍在紧凑窗口中仍有清晰的阅读空间。", count: 8),
                "BackdropImageTags": ["synthetic-backdrop"]
            ]))
        }
        for width in [CGFloat(666), 1100] {
            var actions: [String: CGRect] = [:]
            let root = GeometryReader { window in
                ScrollView {
                    HomeHeroCarousel(model: fixture, items: recommendations, libraryName: "合成电影库", isVisible: true,
                                     toolbarBottom: window.frame(in: .global).minY + SeatSixSidebarMetrics.titlebarHeight)
                }.coordinateSpace(name: "home-scroll-viewport")
            }.preferredColorScheme(.dark)
                .onPreferenceChange(DetailSourceFrameKey.self) { actions = $0 }
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 550),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 550)
            defer { window.contentViewController = nil; window.close() }
            try await settle(controller.view)
            let hero = try XCTUnwrap(heroInput(in: controller.view))
            let detail = try XCTUnwrap(actions[DetailSourceKey(kind: "hero-detail", itemID: "hero-0").id])
            XCTAssertEqual(detail.width, hero.bounds.width, accuracy: 1)
            XCTAssertEqual(detail.height, hero.bounds.height - SeatSixSidebarMetrics.titlebarHeight, accuracy: 1)
            XCTAssertNil(actions[DetailSourceKey(kind: "hero-primary", itemID: "hero-0").id])
            let fitting = controller.sizeThatFits(in: NSSize(width: width, height: 550))
            XCTAssertGreaterThan(controller.view.bounds.width, 0)
            XCTAssertGreaterThan(controller.view.bounds.height, 0)
            XCTAssertLessThanOrEqual(fitting.width, width + 1)
            XCTAssertLessThanOrEqual(fitting.height, 551)
            assertVerticalScrollDocumentsFit(controller.view, route: "recommendations")
            try savePreviewIfRequested(controller.view, name: "recommendations-\(Int(width))")
        }
    }

    @MainActor
    func testRecommendationCoverOpensDetailWithoutStartingPlayback() async throws {
        let app = NSApplication.shared
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(enhanced) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhanced)
        defer { app.accessibilitySetValue(previous, forAttribute: enhanced) }

        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        fixture.server.setMovieResumePosition(1_200_000_000) // Two minutes into each recommendation.
        var preferences = model.applicationPreferences
        preferences.autoRotateHomeRecommendations = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        let host = makeHost(model: model, size: NSSize(width: 1220, height: 820))
        defer { host.window.contentViewController = nil; host.window.close() }
        host.window.orderFront(nil)
        model.refresh()
        try await waitUntil("The home catalog must contain several navigable recommendations") {
            model.homeRecommendations.count > 1 && model.catalogComplete
        }
        try await settleNavigationChange(host.controller.view)
        let movie = try XCTUnwrap(model.homeRecommendations.first)
        XCTAssertGreaterThan(movie.userData.playbackPositionTicks, 0)
        let hero = try XCTUnwrap(heroInput(in: host.controller.view))
        let screenFrame = host.window.convertToScreen(hero.convert(hero.bounds, to: nil))
        // SwiftUI's AX objects implement the AppKit selectors without always
        // declaring conformance to NSAccessibilityProtocol in hosted windows.
        func nodes(in view: NSObject) -> [NSObject] {
            let children = view.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? view.value(forKey: "accessibilityChildren") as? [NSObject] ?? [] : []
            return [view] + children.flatMap(nodes)
        }
        func name(_ element: NSObject) -> String {
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] where element.responds(to: NSSelectorFromString(key)) {
                if let value = element.value(forKey: key) as? String, !value.isEmpty { return value }
            }
            return ""
        }
        let homeNodes = nodes(in: host.controller.view)
        let onCover = homeNodes.filter { element in
            guard let frame = (element as AnyObject).accessibilityFrame?(), !frame.isEmpty else { return false }
            return screenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        let buttons = onCover.filter { ($0 as AnyObject).accessibilityRole?() == .button }
            .filter { element in
                guard let frame = (element as AnyObject).accessibilityFrame?() else { return false }
                return frame.midY < screenFrame.maxY - SeatSixSidebarMetrics.titlebarHeight
            }
        XCTAssertEqual(buttons.map(name), ["查看推荐 \(movie.name) 详情"], "Only the active cover should act as a button")
        XCTAssertFalse(onCover.contains { name($0).contains("推荐第") || name($0).contains("继续播放") })
        let cover = try XCTUnwrap(buttons.first)
        let actions = (cover as AnyObject).accessibilityCustomActions?() ?? []
        XCTAssertEqual(Set(actions.map(\.name)), ["上一部推荐", "下一部推荐"],
                       "Manual navigation stays available to assistive technology when automatic rotation is off")
        XCTAssertTrue((cover as AnyObject).accessibilityPerformPress?() == true)
        try await waitUntil("The cover must open the same film's detail") { model.detail?.id == movie.id && !model.detailLoading }
        try await settleNavigationChange(host.controller.view)
        XCTAssertNil(model.player)
        XCTAssertNil(model.resumeLoadingID)
        let expectedResume = BrowsePresentation.playbackTitle(movie)
        XCTAssertTrue(expectedResume.contains("02:00"), "The detail should show the saved two-minute position")
        let detailButtons = nodes(in: host.controller.view).filter { ($0 as AnyObject).accessibilityRole?() == .button }
        XCTAssertTrue(detailButtons.map(name).contains(expectedResume))
        model.goBackFromDetail()
        try await settleNavigationChange(host.controller.view)
        let returned = nodes(in: host.controller.view).filter { name($0) == "查看推荐 \(movie.name) 详情" }
        XCTAssertEqual(returned.count, 1)
        XCTAssertNil(model.player)
    }

    @MainActor
    func testRecommendationHitAreaTracksFixedToolbarWhenScrolledAndWhenErrorBannerDisplacesIt() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        var frames: [String: CGRect] = [:]
        var sources: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 1100, height: 700),
                            windowStyle: [.titled, .closable, .resizable, .fullSizeContentView],
                            rawSidebarReport: { frames = $0 }, sourceReport: { sources = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Recommendations must be present in the real scroll hierarchy") {
            model.catalogComplete && !model.homeRecommendations.isEmpty
        }
        try await settleNavigationChange(host.controller.view)
        let hero = try XCTUnwrap(heroInput(in: host.controller.view))
        let scroll = try XCTUnwrap(hero.enclosingScrollView)
        let item = try XCTUnwrap(model.homeRecommendations.first)
        let sourceKey = DetailSourceKey(kind: "hero-detail", itemID: item.id).id
        func bounds() throws -> (picture: CGRect, toolbar: CGRect, entry: CGRect) {
            let origin = try XCTUnwrap(frames["test-root"]).origin
            let picture = hero.convert(hero.bounds, to: host.controller.view).offsetBy(dx: origin.x, dy: origin.y)
            return (picture, try XCTUnwrap(frames["navigation-toolbar"]), try XCTUnwrap(sources[sourceKey]))
        }
        let initial = try bounds()
        XCTAssertLessThan(initial.picture.minY, initial.toolbar.maxY)
        XCTAssertGreaterThanOrEqual(initial.entry.minY, initial.toolbar.maxY - 1)

        scroll.contentView.scroll(to: CGPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settleNavigationChange(host.controller.view)
        let scrolled = try bounds()
        XCTAssertLessThan(scrolled.picture.minY, initial.picture.minY - 150)
        XCTAssertEqual(scrolled.toolbar.maxY, initial.toolbar.maxY, accuracy: 1)
        XCTAssertEqual(scrolled.entry.minY, scrolled.toolbar.maxY, accuracy: 1,
                       "The fixed titlebar must not activate a cover that scrolled behind it")
        // The AppKit scroll probe rounds its origin and size to backing pixels,
        // while the measured SwiftUI picture may end at a fractional point.
        XCTAssertEqual(scrolled.entry.maxY, scrolled.picture.maxY, accuracy: 2)

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        model.errorMessage = "合成服务器暂时无法访问。"
        try await settleNavigationChange(host.controller.view)
        let displaced = try bounds()
        XCTAssertGreaterThan(displaced.picture.minY, displaced.toolbar.maxY)
        XCTAssertEqual(displaced.entry.minY, displaced.picture.minY, accuracy: 1,
                       "The banner below an error notice should be clickable from its first visible row")
        XCTAssertEqual(displaced.entry.maxY, displaced.picture.maxY, accuracy: 2)
    }

    @MainActor
    func testHomeAtmosphereKeepsLoadedArtworkAcrossRoutesAndHiddenRecommendations() async throws {
        _ = NSApplication.shared
        for color in [NSColor.red, NSColor.blue, NSColor.white] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            color.setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill()
            NSGraphicsContext.restoreGraphicsState()
            fixture.server.configureArtwork(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
            var reportedArtwork: HomeArtworkSnapshot?
            var sidebarFrames: [String: CGRect] = [:]
            let model = fixture.model
            let host = makeHost(model: model, size: NSSize(width: 1220, height: 820),
                                artworkReport: { reportedArtwork = $0 }, sidebarReport: { sidebarFrames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            try await settle(host.controller.view)
            let neutral = try sampleBackgroundColor(host.controller.view)
            model.refresh()
            try await waitUntil("Loaded hero must supply the shared background") { reportedArtwork != nil }
            try await settle(host.controller.view)
            XCTAssertTrue(reportedArtwork?.matches(scope: HomeArtworkScope(model: model)) == true)
            func probe(in view: NSView) -> HomeCarouselScrollInput.Probe? {
                (view as? HomeCarouselScrollInput.Probe) ?? view.subviews.lazy.compactMap { probe(in: $0) }.first
            }
            let input = try XCTUnwrap(probe(in: host.controller.view))
            XCTAssertGreaterThan(input.bounds.width, 500)
            XCTAssertGreaterThan(input.bounds.height, 300, "The native input region must fill the actual hero")
            XCTAssertNil(input.hitTest(NSPoint(x: 30, y: 30)), "The bridge must not intercept native button clicks")
            let recommendationIDs = model.homeRecommendations.map(\.id)
            XCTAssertEqual(recommendationIDs.count, 10)
            let expectedPreloadedIDs = Set(Array(recommendationIDs.prefix(2)) + recommendationIDs.suffix(1))
            try await waitUntil("Only the current recommendation and its two neighbors should preload") {
                fixture.server.heroArtworkRequestsByItem.count == expectedPreloadedIDs.count
            }
            let preloadedRequests = fixture.server.heroArtworkRequestsByItem
            XCTAssertEqual(Set(preloadedRequests.keys), expectedPreloadedIDs)
            XCTAssertTrue(preloadedRequests.values.allSatisfy { $0 == 1 },
                          "Each hero image must be requested once; the ambient backdrop reuses it")
            let tinted = try sampleBackgroundColor(host.controller.view)
            if color == .red { XCTAssertGreaterThan(tinted.redComponent, tinted.blueComponent + 0.03) }
            else if color == .blue { XCTAssertGreaterThan(tinted.blueComponent, tinted.redComponent + 0.03) }
            else { XCTAssertGreaterThan(tinted.redComponent, neutral.redComponent + 0.01) }
            let size = host.controller.view.bounds.size
            func snapshot() throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
                host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
                return bitmap
            }
            let expanded = try snapshot()
            let selectedConnection = try XCTUnwrap(model.connection)
            for key in ["media-header", "navigation-library", "navigation-home",
                        "server-\(selectedConnection.id.uuidString)", "source-header"] {
                let row = try XCTUnwrap(sidebarFrames[key])
                let text = CGRect(x: row.minX + 40, y: row.midY - 9, width: min(72, row.width - 60), height: 18)
                XCTAssertGreaterThan(try renderedContrast(expanded, in: text, viewSize: size), 4.5,
                                     "\(key) title must stay legible over \(color) artwork")
            }
            for key in ["sidebar-toggle", "toolbar-search"] {
                let control = try XCTUnwrap(sidebarFrames[key])
                let region = control.insetBy(dx: 9, dy: 8)
                XCTAssertGreaterThan(try renderedContrast(expanded, in: region, viewSize: size), 4.5,
                                     "\(key) must stay legible over \(color) artwork")
            }
            var collapsed = model.applicationPreferences
            collapsed.sidebarCollapsed = true
            XCTAssertTrue(model.updateApplicationPreferences(collapsed))
            try await settleNavigationChange(host.controller.view)
            let source = try XCTUnwrap(sidebarFrames["toolbar-source"])
            let sourceTitle = CGRect(x: source.minX + 14, y: source.midY - 8, width: min(75, source.width - 28), height: 16)
            XCTAssertGreaterThan(try renderedContrast(try snapshot(), in: sourceTitle, viewSize: size), 4.5,
                                 "The current server name must stay legible over \(color) artwork")
            collapsed.sidebarCollapsed = false
            XCTAssertTrue(model.updateApplicationPreferences(collapsed))
            try await settleNavigationChange(host.controller.view)
            try savePreviewIfRequested(host.controller.view, name: color == .red ? "ambient-red" : color == .blue ? "ambient-blue" : "ambient-white")

            model.page = "library"
            try await settle(host.controller.view)
            let otherRoute = try sampleBackgroundColor(host.controller.view)
            assertSameColor(otherRoute, tinted, "The library keeps the color that was visible on home")
            model.page = "home"
            var preferences = model.applicationPreferences; preferences.showHomeRecommendations = false
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            try await settle(host.controller.view)
            XCTAssertNil(reportedArtwork)
            let hidden = try sampleBackgroundColor(host.controller.view)
            assertSameColor(hidden, tinted, "Hiding the banner clears its image while preserving the session color")
            XCTAssertEqual(fixture.server.heroArtworkRequestsByItem, preloadedRequests,
                           "Hiding the carousel or changing routes must not refetch preloaded images")
            XCTAssertEqual(fixture.server.unexpectedPaths, [])
        }
    }

    @MainActor
    func testImmersiveHomeArtworkFillsTopAndPreservesSubjectAcrossWindowSizes() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1440, height: 1000)] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            fixture.server.configureArtwork(try solidArtwork(.white))
            var artwork: HomeArtworkSnapshot?
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: fixture.model, size: size, artworkReport: { artwork = $0 }, sidebarReport: { frames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            fixture.model.refresh()
            try await waitUntil("The synthetic hero image must be loaded before measuring it") { artwork != nil }
            try await settle(host.controller.view)

            let input = try XCTUnwrap(heroInput(in: host.controller.view))
            let frame = input.convert(input.bounds, to: host.controller.view)
            XCTAssertEqual(frame.minY, 0, accuracy: 1,
                           "The image must start at the top of the content rather than below a separate toolbar")
            XCTAssertEqual(frame.maxX, size.width, accuracy: 1,
                           "The hero must extend to the right edge without an inset card border")
            XCTAssertGreaterThan(frame.width, size.width * 0.74)
            if size.width > 1400 {
                XCTAssertGreaterThan(frame.height, 640,
                                     "A wide home must use its available cinematic image area instead of the old 560pt cap")
            }
            let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
            host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
            // The white source makes excessive global dimming or early fading
            // observable. Sample clear picture regions, outside text and controls.
            let tabs = try XCTUnwrap(frames["toolbar-tabs"])
            for (name, relative, minimum) in [
                ("upper picture", CGPoint(x: 0.55, y: max(76 / frame.height, 0.08)), 0.75),
                ("subject", CGPoint(x: 0.92, y: 0.52), 0.9),
                ("lower subject", CGPoint(x: 0.92, y: 0.72), 0.85)
            ] {
                var point = CGPoint(x: frame.minX + frame.width * relative.x,
                                    y: frame.minY + frame.height * relative.y)
                if tabs.insetBy(dx: -4, dy: -4).contains(point) {
                    point.y = tabs.maxY + 6
                }
                let color = try renderedColor(bitmap, at: point, viewSize: size)
                XCTAssertGreaterThan(min(color.redComponent, color.greenComponent, color.blueComponent), minimum,
                                     "The \(name) should retain the source picture's brightness")
            }
            assertVerticalScrollDocumentsFit(host.controller.view, route: "immersive home")
            try savePreviewIfRequested(host.controller.view, name: "immersive-white-\(Int(size.width))")

            let film = try XCTUnwrap(fixture.model.homeRecommendations.first)
            // The white recommendation and green detail image are separate requests.
            fixture.server.configureArtwork(try solidArtwork(.green), itemID: film.id, delay: 0)
            fixture.model.showDetail(film)
            try await waitUntil("The detail sidebar must use the film's green art over the mounted white home") {
                guard !fixture.model.detailLoading, let color = try? self.sampleBackgroundColor(host.controller.view) else { return false }
                return color.greenComponent > color.redComponent + 0.08
            }
            let filmColor = try sampleBackgroundColor(host.controller.view)
            fixture.server.configureArtwork(try solidArtwork(.white), itemID: film.id, delay: 0)
            fixture.model.goBackFromDetail()
            try await settle(host.controller.view)
            let restored = try XCTUnwrap(heroInput(in: host.controller.view))
            XCTAssertEqual(restored.convert(restored.bounds, to: host.controller.view).minY, 0, accuracy: 1)
            assertSameColor(try sampleBackgroundColor(host.controller.view), filmColor,
                            "The visible white recommendation must not replace the last opened film's green")
            let sharedHeader = try sampleBackgroundColor(host.controller.view, x: frame.minX + frame.width * 0.78,
                                                        yFraction: 8 / size.height)
            XCTAssertGreaterThan(sharedHeader.greenComponent, sharedHeader.redComponent + 0.16,
                                 "The returned home header must reveal the retained green detail background above the white banner")
            let clearPicture = try sampleBackgroundColor(host.controller.view, x: frame.minX + frame.width * 0.92,
                                                        yFraction: (frame.minY + frame.height * 0.52) / size.height)
            XCTAssertGreaterThan(min(clearPicture.redComponent, clearPicture.greenComponent, clearPicture.blueComponent), 0.9,
                                 "The recommendation keeps its own clear white image below the shared header")
            var preferences = fixture.model.applicationPreferences
            preferences.showHomeRecommendations = false
            XCTAssertTrue(fixture.model.updateApplicationPreferences(preferences))
            try await waitUntil("Hidden recommendations clear their image preference") { artwork == nil }
            preferences.showHomeRecommendations = true
            XCTAssertTrue(fixture.model.updateApplicationPreferences(preferences))
            try await waitUntil("The remounted carousel republishes its own white artwork") {
                guard let artwork, let color = try? self.snapshotColor(artwork) else { return false }
                return min(color.redComponent, color.greenComponent, color.blueComponent) > 0.9
            }
            assertSameColor(try sampleBackgroundColor(host.controller.view), filmColor,
                            "Republishing the same recommendation retains the newer film color")
            XCTAssertEqual(fixture.server.unexpectedPaths, [])
        }
    }

    @MainActor
    func testBrightHeroLongCopyRemainsLegibleAtCompactWidths() async throws {
        _ = NSApplication.shared
        for width in [CGFloat(666), 930, 1000] {
            let fixture = makeAPIFixture(longMovieCopy: true)
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            fixture.server.configureArtwork(try solidArtwork(.white))
            fixture.model.refresh()
            try await waitUntil("Long-copy fixture must have recommendations") { fixture.model.catalogComplete && !fixture.model.loading }
            var artwork: HomeArtworkSnapshot?
            let size = NSSize(width: width, height: 700)
            var measured = [ShelfRefreshRegion]()
            let root: AnyView
            if width == 666 {
                root = AnyView(ScrollView {
                    HomeHeroCarousel(model: fixture.model, items: fixture.model.homeRecommendations,
                                     libraryName: "合成电影库", isVisible: true)
                }.coordinateSpace(name: "home-scroll-viewport")
                    .shelfRefreshViewport(size).preferredColorScheme(.dark)
                    .onPreferenceChange(HomeArtworkPreferenceKey.self) { artwork = $0 })
            } else {
                root = AnyView(SeatSixRootView(model: fixture.model).preferredColorScheme(.dark)
                    .onPreferenceChange(HomeArtworkPreferenceKey.self) { artwork = $0 })
            }
            let controller = NSHostingController(rootView: root.onPreferenceChange(ShelfRefreshRegionsKey.self) { measured = $0 })
            controller.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            controller.view.frame = NSRect(origin: .zero, size: size)
            defer { window.contentViewController = nil; window.close() }
            try await waitUntil("White artwork must be loaded before measuring copy contrast") { artwork != nil }
            try await settle(controller.view)
            try savePreviewIfRequested(controller.view, name: "bright-long-copy-\(Int(width))")
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let hero = try XCTUnwrap(heroInput(in: controller.view))
            let frame = hero.convert(hero.bounds, to: controller.view)
            let isSmallType = frame.width < 760
            let textX = frame.minX + (isSmallType ? 24 : 40)
            let backdrop = try XCTUnwrap(measured.first(where: { $0.isBackdrop })).frame
            // Use the actual title and synopsis frames. This keeps the contrast
            // check tied to glyphs when the text wraps or the poster footer changes.
            let copyFrames = measured.filter { !$0.isBackdrop && backdrop.contains($0.frame) && $0.frame.width > 200 }
                .map { $0.frame.offsetBy(dx: frame.minX - backdrop.minX, dy: frame.minY - backdrop.minY) }
                .sorted { $0.minY < $1.minY }
            XCTAssertEqual(copyFrames.count, 2)
            let title = try XCTUnwrap(copyFrames.first)
            let overview = try XCTUnwrap(copyFrames.last)
            let regions: [(String, NSRect, Double)] = [
                ("eyebrow", NSRect(x: textX, y: title.minY - 27, width: 154, height: 18), 4.5),
                ("title first line", NSRect(x: textX, y: title.minY + 2, width: 220, height: isSmallType ? 42 : 60), 3),
                ("synopsis right edge", NSRect(x: overview.maxX - 112, y: overview.minY, width: 100, height: 18), 4.5)
            ]
            for (name, region, minimum) in regions {
                XCTAssertGreaterThanOrEqual(try renderedContrast(bitmap, in: region, viewSize: size), minimum,
                                            "\(name) must remain legible on white artwork at width \(width)")
            }
            assertVerticalScrollDocumentsFit(controller.view, route: "long-copy bright hero")
            XCTAssertEqual(fixture.server.unexpectedPaths, [])
        }
    }

    @MainActor
    func testPreloadedAndOutgoingArtworkCannotOverrideCurrentTintOrRefetchWhenActivated() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let movies = MediaLibrary(id: "movies", name: "电影")
        fixture.model.libraries = [movies, MediaLibrary(id: "other", name: "其他")]
        fixture.model.selectedLibraryID = movies.id
        let items = try ["current", "neighbor"].map { id in
            try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: [
                "Id": id, "Name": id, "Type": "Movie", "BackdropImageTags": ["synthetic-\(id)"]
            ]))
        }
        fixture.server.configureArtwork(try solidArtwork(.red), itemID: "current", delay: 0.02)
        fixture.server.configureArtwork(try solidArtwork(.blue), itemID: "neighbor", delay: 0.15)
        let selection = BrowseArtworkSelection(currentID: "current")
        var artwork: HomeArtworkSnapshot?
        var reportIDs: [String] = []
        let root = BrowseArtworkPreloadFixture(model: fixture.model, items: items, selection: selection)
            .onPreferenceChange(HomeArtworkPreferenceKey.self) { value in
                artwork = value
                if let id = value?.itemID { reportIDs.append(id) }
            }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        try await waitUntil("The current slide should report before the delayed neighbor") { artwork?.itemID == "current" }
        try await waitUntil("The non-current neighbor should finish preloading") {
            fixture.server.completedHeroArtworkIDs.contains("neighbor")
        }
        try await settle(controller.view)
        XCTAssertEqual(artwork?.itemID, "current", "A late neighbor must not replace the current ambient artwork")
        XCTAssertEqual(Set(reportIDs), ["current"])
        let initialRequests = fixture.server.heroArtworkRequestsByItem
        XCTAssertEqual(initialRequests, ["current": 1, "neighbor": 1])

        let previousAccess = fixture.model.windowArtworkRevision
        fixture.model.libraries = [movies]
        XCTAssertNotEqual(fixture.model.windowArtworkRevision, previousAccess)
        selection.currentID = "neighbor"
        try await waitUntil("The mounted neighbor should contribute its already loaded artwork") { artwork?.itemID == "neighbor" }
        try await settle(controller.view)
        XCTAssertEqual(artwork?.accessRevision, fixture.model.windowArtworkRevision,
                       "Removing an unrelated library must not strand an authorized preloaded color")
        XCTAssertEqual(fixture.server.heroArtworkRequestsByItem, initialRequests,
                       "Changing only contribution must not clear the image or change its request key")
        XCTAssertTrue(try snapshotColor(XCTUnwrap(artwork)).blueComponent > 0.9)

        selection.currentID = "current"
        try await waitUntil("An outgoing mounted slide can become current again without reloading") { artwork?.itemID == "current" }
        try await settle(controller.view)
        XCTAssertEqual(fixture.server.heroArtworkRequestsByItem, initialRequests)
        XCTAssertTrue(try snapshotColor(XCTUnwrap(artwork)).redComponent > 0.9)
        fixture.model.libraries = []
        try await waitUntil("Revoking this library also withdraws its current artwork report") { artwork == nil }
        XCTAssertEqual(fixture.server.heroArtworkRequestsByItem, initialRequests)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    private func sourcePicker(in view: NSView) -> NSPopUpButton? {
        if let picker = view as? NSPopUpButton, picker.accessibilityIdentifier() == "toolbar-source" { return picker }
        return view.subviews.lazy.compactMap { self.sourcePicker(in: $0) }.first
    }

    @MainActor
    func testServerSelectorKeepsArtworkAppearanceWithIncreasedContrast() async throws {
        _ = NSApplication.shared
        let model = try makeFixture()
        for scheme in [ColorScheme.light, .dark] {
            // Inject the read-only system contrast preference into this isolated test host.
            let root = ToolbarSourcePicker(model: model, maxWidth: 180)
                .environment(\.colorScheme, scheme)
                .environment(\._colorSchemeContrast, .increased)
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 200, height: 48)
            try await settle(host)
            let picker = try XCTUnwrap(sourcePicker(in: host))
            XCTAssertEqual(picker.appearance?.bestMatch(from: [.aqua, .darkAqua]),
                           scheme == .light ? .aqua : .darkAqua)
        }
    }

    @MainActor
    func testLightDetailToolbarUsesReadableNativeControlsAcrossTheWindow() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        var preferences = model.applicationPreferences
        preferences.sidebarCollapsed = true
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        let row = detailArtworkMovie(id: "toolbar-light", hasBackdrop: true, hasPoster: false)
        let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
        let activeServer = try XCTUnwrap(model.connection)
        var otherServer = activeServer
        otherServer.id = UUID()
        otherServer.name = "另一个 NAS"
        model.saved.connections.insert(otherServer, at: 0)
        fixture.server.configureArtwork(try solidArtwork(.white), itemID: item.id, delay: 0)
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items/" + item.id { return .init(body: row) }
            return fixture.server.reply(to: request)
        }
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 1120, height: 690), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.navigate(to: "recent")
        model.showDetail(item)
        try await waitUntil("Load the bright art behind the actual title row") {
            !model.detailLoading && fixture.server.artworkRequestCount(.backdrop, itemID: item.id) > 0
        }
        let view = host.controller.view
        try await settle(view)
        let picker = try XCTUnwrap(sourcePicker(in: view))
        XCTAssertEqual(picker.accessibilityLabel(), "切换影视服务器")
        XCTAssertEqual(picker.itemTitles, [otherServer.name, activeServer.name])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, activeServer.id)
        let sourceFrame = try XCTUnwrap(frames["toolbar-source"])
        // AppKit publishes the pop-up's role and hit frame through its cell.
        let accessible = try XCTUnwrap(NSAccessibility.unignoredDescendant(of: picker) as? NSPopUpButtonCell)
        XCTAssertEqual(accessible.accessibilityRole(), .popUpButton)
        let axFrame = accessible.accessibilityFrame()
        XCTAssertGreaterThanOrEqual(axFrame.height, sourceFrame.height - 4)
        XCTAssertGreaterThanOrEqual(axFrame.width, sourceFrame.width - 4)
        let parent = try XCTUnwrap(picker.superview)
        for location in [CGPoint(x: 5, y: picker.bounds.midY), CGPoint(x: picker.bounds.maxX - 5, y: picker.bounds.midY),
                         CGPoint(x: picker.bounds.midX, y: 5), CGPoint(x: picker.bounds.midX, y: picker.bounds.maxY - 5)] {
            XCTAssertTrue(picker.hitTest(picker.convert(location, to: parent)) === picker)
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try savePreviewIfRequested(view, name: "native-detail-toolbar")
        // cacheDisplay omits WindowServer's adaptive glass glyphs. Check the
        // backgrounds against the actual artwork and the independently drawn menu text.
        let reference = try renderedColor(bitmap, at: CGPoint(x: view.bounds.midX, y: 19), viewSize: view.bounds.size)
        for key in ["sidebar-toggle", "toolbar-source", "toolbar-history", "toolbar-refresh", "toolbar-search"] {
            let frame = try XCTUnwrap(frames[key], key)
            XCTAssertGreaterThanOrEqual(min(frame.width, frame.height), 34)
            let fill = try renderedColor(bitmap, at: CGPoint(x: frame.midX, y: frame.minY + 5), viewSize: view.bounds.size)
            XCTAssertGreaterThan(fill.brightnessComponent, reference.brightnessComponent * 0.65,
                                 "\(key) must let the light artwork show through its native surface")
            if key == "toolbar-source" {
                XCTAssertGreaterThan(try renderedContrast(bitmap, in: frame.insetBy(dx: 12, dy: 9),
                                                          viewSize: view.bounds.size, darkGlyphs: true), 4.5)
            }
        }
        var added = otherServer
        added.id = UUID()
        added.name = "新增 NAS"
        model.saved.connections.append(added)
        model.saved.connections[0].name = "改名后的 NAS"
        model.saved.selectedID = otherServer.id
        try await settle(view)
        XCTAssertTrue(sourcePicker(in: view) === picker)
        XCTAssertEqual(picker.itemTitles, ["改名后的 NAS", activeServer.name, added.name])
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, otherServer.id)
        fixture.storage.rejectWrites = true
        picker.selectItem(at: 1)
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        XCTAssertEqual(model.saved.selectedID, otherServer.id)
        XCTAssertEqual(picker.selectedItem?.representedObject as? UUID, otherServer.id,
                       "An unsuccessful switch must restore the menu's actual selected server immediately")
        model.saved.connections.removeLast()
        try await settle(view)
        XCTAssertEqual(picker.itemTitles, ["改名后的 NAS", activeServer.name])
        await model.shutdown()
    }

    @MainActor
    func testCinematicDetailKeepsBackdropLandmarksAndActionsVisibleAcrossWindowSizes() async throws {
        // The film has bright sky at the top and a thin red subject against a blue
        // middle. The low-resolution sampled color field cannot reproduce the subject.
        let width = 640, height = 360
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.08, green: 0.25, blue: 0.94, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor(srgbRed: 0.98, green: 0.17, blue: 0.10, alpha: 1).setFill()
        NSRect(x: 314, y: 0, width: 12, height: height).fill()
        NSColor(srgbRed: 1, green: 0.83, blue: 0.17, alpha: 1).setFill()
        NSRect(x: 0, y: 300, width: width, height: 60).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: 140).fill()
        NSGraphicsContext.restoreGraphicsState()
        let back = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for size in [NSSize(width: 760, height: 640), NSSize(width: 1500, height: 940)] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            let model = fixture.model
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = true
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            model.selectedLibraryID = "movies"
            var row = detailArtworkMovie(id: "cinematic-\(Int(size.width))", hasBackdrop: true, hasPoster: false)
            row["Name"] = String(repeating: "山间奇遇", count: size.width < 800 ? 12 : 2)
            row["Overview"] = String(repeating: "在山间相遇的朋友一起踏上旅程。", count: 15)
            let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
            fixture.server.configureArtwork(back, itemID: item.id, delay: 0.15)
            let detailRow = row
            BrowseLayoutURLProtocol.handler = { request in
                if request.url?.path == "/Users/fixture-user/Items/" + item.id { return .init(body: detailRow) }
                return fixture.server.reply(to: request)
            }
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            model.showDetail(item)
            let view = host.controller.view
            try await waitUntil("Render the red stripe and blue field from the downloaded backdrop") {
                guard let hero = frames["detail-cinematic-hero"], !hero.isEmpty,
                      let snapshot = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
                view.cacheDisplay(in: view.bounds, to: snapshot)
                let y = hero.minY + hero.width * CGFloat(height) / CGFloat(width) * 0.23
                let stripe = CGPoint(x: hero.midX, y: y)
                let field = CGPoint(x: hero.midX + hero.width * 0.055, y: y)
                guard view.bounds.contains(stripe), view.bounds.contains(field),
                      let red = try? self.renderedColor(snapshot, at: stripe, viewSize: view.bounds.size),
                      let blue = try? self.renderedColor(snapshot, at: field, viewSize: view.bounds.size) else { return false }
                return red.redComponent - red.blueComponent > 0.35 && blue.blueComponent - blue.redComponent > 0.35
            }
            try await settle(view)
            let pane = try XCTUnwrap(frames["content"])
            let hero = try XCTUnwrap(frames["detail-cinematic-hero"])
            let title = try XCTUnwrap(frames["detail-hero-title"])
            let play = try XCTUnwrap(frames["detail-primary-play"])
            XCTAssertEqual(hero.minX, pane.minX, accuracy: 1)
            XCTAssertEqual(hero.maxX, pane.maxX, accuracy: 1)
            XCTAssertEqual(hero.minY, pane.minY, accuracy: 1, "The backdrop starts behind the toolbar")
            XCTAssertGreaterThan(hero.height, pane.height * 0.57)
            XCTAssertGreaterThan(title.minY, hero.minY + hero.height * 0.35, "Keep the subject clear of the copy")
            XCTAssertLessThanOrEqual(play.maxY, pane.maxY - 6, "Playback must be reachable on first open")
            XCTAssertTrue(hero.insetBy(dx: -1, dy: -1).contains(play))
            assertVerticalScrollDocumentsFit(view, route: "cinematic detail \(size)")
            let rendered = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rendered)
            func sample(x: CGFloat, y: CGFloat) throws -> NSColor {
                try renderedColor(rendered, at: CGPoint(x: x, y: y), viewSize: view.bounds.size)
            }
            let sky = try sample(x: pane.minX + pane.width * 0.77, y: hero.minY + 12)
            XCTAssertGreaterThan(sky.redComponent - sky.blueComponent, 0.4, "The top of the original image must reach the title bar")
            // The original image's red stripe and blue field extend down past
            // the first third of the header, including with a wrapped title.
            let subjectY = hero.minY + hero.height * 0.32
            let subject = try sample(x: hero.midX, y: subjectY)
            let surrounding = try sample(x: hero.midX + hero.width * 0.055, y: subjectY)
            XCTAssertGreaterThan(subject.redComponent - subject.blueComponent, 0.62, "Preserve the original thin red subject")
            XCTAssertGreaterThan(surrounding.blueComponent - surrounding.redComponent, 0.58, "Preserve the full-color blue field beside it")
            let visibleTitle = title.intersection(view.bounds)
            XCTAssertEqual(visibleTitle, title)
            if !visibleTitle.isEmpty {
                XCTAssertGreaterThanOrEqual(try renderedContrast(rendered, in: visibleTitle, viewSize: view.bounds.size), 4.5,
                                            "Keep the lower title readable even over a white patch of artwork")
            }
            try savePreviewIfRequested(view, name: "cinematic-detail-\(Int(size.width))")
        }
    }

    @MainActor
    func testDetailUsesDeclaredTitleArtworkAndFallsBackToTheFilmName() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        let wideArt = try solidArtwork(.blue)
        let titleImage = NSImage(size: NSSize(width: 300, height: 75), flipped: false) { _ in
            NSColor.green.setFill()
            NSRect(x: 10, y: 12, width: 105, height: 50).fill()
            NSRect(x: 170, y: 12, width: 105, height: 50).fill()
            return true
        }
        let titleArt = try XCTUnwrap(titleImage.tiffRepresentation)
        let available = "title-with-image", unavailable = "title-with-broken-image"
        var rows: [String: [String: Any]] = [:]
        for id in [available, unavailable] {
            var row = detailArtworkMovie(id: id, hasBackdrop: true, hasPoster: false)
            row["ImageTags"] = ["Logo": id]
            row["Name"] = String(repeating: "山间奇遇记", count: 9)
            rows[id] = row
            fixture.server.configureArtwork(wideArt, itemID: id, delay: 0)
        }
        fixture.server.configureArtwork(titleArt, itemID: available, delay: 0, type: .logo)
        let backdropDelivery = DispatchQueue(label: "delayed-detail-backdrop")
        let logoDelivery = DispatchQueue(label: "delayed-detail-title-art")
        backdropDelivery.suspend()
        logoDelivery.suspend()
        var releasedBackdrop = false, releasedLogo = false
        defer {
            if !releasedBackdrop { backdropDelivery.resume() }
            if !releasedLogo { logoDelivery.resume() }
        }
        let detailRows = rows
        BrowseLayoutURLProtocol.handler = { request in
            if let path = request.url?.path, path.hasPrefix("/Users/fixture-user/Items/"),
               let row = detailRows[String(path.split(separator: "/").last ?? "")] { return .init(body: row) }
            var reply = fixture.server.reply(to: request)
            if request.url?.path.hasPrefix("/Items/\(available)/Images/Backdrop") == true { reply.deliveryQueue = backdropDelivery }
            if request.url?.path == "/Items/\(available)/Images/Logo" { reply.deliveryQueue = logoDelivery }
            return reply
        }
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 760, height: 640), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        for id in [available, unavailable] {
            let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(rows[id])))
            model.showDetail(item)
            var pendingHero: CGRect?, pendingPlay: CGRect?
            if id == available {
                try await waitUntil("Open the film while its backdrop is still in flight") {
                    !model.detailLoading && fixture.server.artworkRequestCount(.backdrop, itemID: id) == 1
                }
                try await settle(host.controller.view)
                pendingHero = try XCTUnwrap(frames["detail-cinematic-hero"], "Reserve the film's image area before download")
                pendingPlay = try XCTUnwrap(frames["detail-primary-play"])
                backdropDelivery.resume()
                releasedBackdrop = true
            }
            try await waitUntil("The film with a declared logo requests it once the backdrop is ready") {
                !model.detailLoading && fixture.server.artworkRequestCount(.logo, itemID: id) == 1
            }
            if id == available {
                try await settle(host.controller.view)
                XCTAssertNil(frames["detail-hero-logo"])
                let before = try XCTUnwrap(frames["detail-cinematic-hero"])
                let play = try XCTUnwrap(frames["detail-primary-play"])
                XCTAssertEqual(before.height, try XCTUnwrap(pendingHero).height, accuracy: 1, "Backdrop arrival must not move the following sections")
                XCTAssertEqual(play.minY, try XCTUnwrap(pendingPlay).minY, accuracy: 1, "Keep the playback target stationary when artwork appears")
                XCTAssertNotNil(frames["detail-hero-title"], "Show the long film name while title art is in flight")
                logoDelivery.resume()
                releasedLogo = true
                try await waitUntil("Show the downloaded title artwork") { frames["detail-hero-logo"] != nil }
                try await settle(host.controller.view)
                let after = try XCTUnwrap(frames["detail-cinematic-hero"])
                let updatedPlay = try XCTUnwrap(frames["detail-primary-play"])
                XCTAssertEqual(after.height, before.height, accuracy: 1, "Arrival of an optional image must not move following sections")
                XCTAssertEqual(updatedPlay.minY, play.minY, accuracy: 1, "Keep the playback target stationary while loading title art")
            }
            try await settle(host.controller.view)
            XCTAssertNotNil(frames["detail-cinematic-hero"])
            XCTAssertNotNil(frames["detail-hero-title"], "The heading survives a broken image response")
            XCTAssertEqual(frames["detail-hero-logo"] != nil, id == available)
            XCTAssertNotNil(frames["detail-primary-play"])
            if id == available {
                let logo = try XCTUnwrap(frames["detail-hero-logo"])
                let view = host.controller.view
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let ink = try renderedColor(bitmap, at: CGPoint(x: logo.minX + 30, y: logo.midY), viewSize: view.bounds.size)
                XCTAssertGreaterThan(ink.greenComponent - ink.redComponent, 0.52, "Display the server's actual title artwork")
            }
        }
    }

    @MainActor
    func testDetailArtworkFillsScrollingPaneAndPrefersWideImage() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        let row = detailArtworkMovie(id: "both-images", hasBackdrop: true, hasPoster: true)
        let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
        fixture.server.configureArtwork(try twoToneDetailArtwork(portrait: false), itemID: item.id, delay: 0.04)
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: item.id, delay: 0, type: .primary)
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items/" + item.id { return .init(body: row) }
            return fixture.server.reply(to: request)
        }
        var frames: [String: CGRect] = [:], regions: [ShelfRefreshRegion] = []
        var scrolledDetail: String?
        let host = makeHost(model: model, size: NSSize(width: 1000, height: 600),
                            sidebarReport: { frames = $0 }, shelfReport: { regions = $0 },
                            scrolledDetailReport: { scrolledDetail = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settle(view)
        let existingScrolls = Set(scrollViews(in: view).map(ObjectIdentifier.init))
        model.showDetail(item)
        try await waitUntil("Both declared detail images are requested") {
            !model.detailLoading && fixture.server.artworkRequestCount(.backdrop, itemID: item.id) > 0 &&
                fixture.server.artworkRequestCount(.primary, itemID: item.id) > 0
        }
        try await settle(view)
        let pane = try XCTUnwrap(frames["content"])
        let scroll = try XCTUnwrap(detailScroll(in: view, excluding: existingScrolls))
        XCTAssertNil(scrolledDetail, "The pinned toolbar starts over the artwork")
        let bottom = try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 80, "The sample must let the top poster scroll out of the viewport")
        let upstairs = try detailEdgeColors(view, pane: pane, y: 100)
        let downstairs = try detailEdgeColors(view, pane: pane, y: pane.height - 75)
        assertDetailHasBothHues(upstairs)
        assertDetailHasBothHues(downstairs)
        let title = try XCTUnwrap(frames["toolbar-title"])
        let toolbar = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: toolbar)
        XCTAssertGreaterThanOrEqual(try renderedContrast(toolbar, in: title, viewSize: view.bounds.size, darkGlyphs: true), 4.5,
                                    "The title above light artwork needs dark ink even though the window chrome is dark")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(view)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottom, accuracy: 1)
        XCTAssertEqual(scrolledDetail, item.id, "Only the scrolled film should protect the pinned toolbar")
        let scrolled = try detailEdgeColors(view, pane: pane, y: pane.height - 75)
        assertDetailHasBothHues(scrolled)
        assertSameColor(scrolled.0, downstairs.0, "The left edge belongs to the detail viewport")
        assertSameColor(scrolled.1, downstairs.1, "The right edge belongs to the detail viewport")
        let stream = try XCTUnwrap(regions.first { $0.isBackdrop && $0.frame.width == 250 && $0.visibleFrame == $0.frame })
        let inside = CGPoint(x: pane.minX + stream.frame.minX + 6, y: pane.minY + stream.frame.midY)
        let outside = CGPoint(x: inside.x - 14, y: inside.y)
        let sidebar = CGPoint(x: 4, y: inside.y)
        func panelSamples() throws -> [NSColor] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try [inside, outside, sidebar].map { try renderedColor(bitmap, at: $0, viewSize: view.bounds.size) }
        }
        let before = try panelSamples()
        XCTAssertGreaterThan(before[0].blueComponent - before[0].redComponent, 0.15,
                             "The actual stream panel must already transmit the blue side of the poster")
        let refreshDelivery = DispatchQueue(label: "scrolled-detail-refresh")
        refreshDelivery.suspend()
        var released = false
        defer { if !released { refreshDelivery.resume() } }
        let connectedHandler = try XCTUnwrap(BrowseLayoutURLProtocol.handler)
        BrowseLayoutURLProtocol.handler = { request in
            var reply = connectedHandler(request)
            reply.deliveryQueue = refreshDelivery
            return reply
        }
        model.refreshFromToolbar()
        try await waitUntil("Freeze the scrolled detail card with its current artwork") { frames["toolbar-refresh-skeleton"] != nil }
        try await settle(view)
        let during = try panelSamples()
        assertSameColor(during[0], before[0], "The stream card's interior must keep its translucent light fill while refreshing")
        assertSameColor(during[1], before[1], "Refreshing must preserve the artwork just outside the stream card")
        assertSameColor(during[2], before[2], "Detail refresh must preserve the sidebar's current poster color")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, bottom, accuracy: 1)
        XCTAssertEqual(frames["content"], pane)
        refreshDelivery.resume()
        released = true
        try await waitUntil("The toolbar refresh must finish") { !model.isToolbarRefreshing }
        XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: item.id), 1)
        XCTAssertEqual(fixture.server.artworkRequestCount(.primary, itemID: item.id), 1)
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
        // The refresh bridge restores the recorded scrolled position as data
        // finishes arriving. Settle that restoration before simulating the return.
        try await settleNavigationChange(view)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil("Observe the scroll back to the top") { scrolledDetail == nil }
        XCTAssertNil(scrolledDetail, "Scrolling back restores the edge-to-edge artwork")
    }

    @MainActor
    func testDetailSidebarKeepsPosterAtTheTopAndCanvasAtTheBottomAcrossCollapseAndScroll() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        let row = detailArtworkMovie(id: "sidebar-bands", hasBackdrop: true, hasPoster: true)
        let film = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
        let bands = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { bounds in
            NSColor.red.setFill()
            bounds.fill()
            NSColor.blue.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: bounds.midY).fill()
            return true
        }
        fixture.server.configureArtwork(try XCTUnwrap(bands.tiffRepresentation), itemID: film.id, delay: 0)
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: film.id, delay: 0, type: .primary)
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items/" + film.id { return .init(body: row) }
            return fixture.server.reply(to: request)
        }
        var frames: [String: CGRect] = [:]
        let size = NSSize(width: 1120, height: 740)
        let host = makeHost(model: model, size: size,
                            windowStyle: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        // Attaching the hosting controller can shrink an offscreen NSWindow to
        // its fitting size. Size the window itself to exercise its real top inset.
        host.window.setContentSize(size)
        let view = host.controller.view
        try await settle(view)
        let existingScrolls = Set(scrollViews(in: view).map(ObjectIdentifier.init))
        func paintedBands() throws -> (NSColor, NSColor, NSColor) {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            // Outer edge, clear of text, selection indicators and the fixed toolbar.
            let top = try renderedColor(bitmap, at: CGPoint(x: 4, y: size.height * 0.17), viewSize: size)
            let middle = try renderedColor(bitmap, at: CGPoint(x: 4, y: size.height * 0.57), viewSize: size)
            let bottom = try renderedColor(bitmap, at: CGPoint(x: 4, y: size.height * 0.93), viewSize: size)
            return (top, middle, bottom)
        }
        let neutralBottom = try paintedBands().2
        model.showDetail(film)
        try await waitUntil("The upper red area and the lower blue area of the poster both reach the sidebar") {
            guard let (top, middle, _) = try? paintedBands() else { return false }
            return top.redComponent > top.blueComponent + 0.10 && middle.blueComponent > middle.redComponent + 0.04
        }
        let initial = try paintedBands()
        assertSameColor(initial.2, neutralBottom, "The bottom of the sidebar reaches its original canvas")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let sidebarWidth = try XCTUnwrap(frames["sidebar-pane"]).width
        let titlebarHeight = host.window.frame.height - host.window.contentLayoutRect.maxY
        XCTAssertGreaterThan(titlebarHeight, 16, "Exercise the native title bar's top safe area")
        for y in [titlebarHeight * 0.6, titlebarHeight + 4] {
            // Right of the traffic lights and sidebar toggle, above the first list row.
            let edge = try renderedColor(bitmap, at: CGPoint(x: sidebarWidth - 22, y: y), viewSize: size)
            XCTAssertGreaterThan(edge.redComponent - edge.blueComponent, 0.1,
                                 "The upper artwork must continue across the native safe-area edge at y=\(y), got \(edge)")
        }
        for key in ["navigation-home", "navigation-settings"] {
            let row = try XCTUnwrap(frames[key])
            let label = CGRect(x: row.minX + 40, y: row.midY - 9, width: 44, height: 18)
            XCTAssertGreaterThan(try renderedContrast(bitmap, in: label, viewSize: size), 4.5, key)
        }
        let scroll = try XCTUnwrap(detailScroll(in: view, excluding: existingScrolls))
        let bottom = try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(bottom, 50)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(view)
        let scrolled = try paintedBands()
        assertSameColor(scrolled.0, initial.0, "Artwork at the top of the sidebar is anchored to the window")
        assertSameColor(scrolled.1, initial.1, "The blue area stays at the same window height")
        assertSameColor(scrolled.2, neutralBottom, "Scrolling detail leaves the bottom neutral")
        var preferences = model.applicationPreferences
        preferences.sidebarCollapsed = true
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        try await settleNavigationChange(view)
        XCTAssertEqual(try XCTUnwrap(frames["sidebar-pane"]).width, 0, accuracy: 0.5)
        preferences.sidebarCollapsed = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        try await settleNavigationChange(view)
        let reopened = try paintedBands()
        assertSameColor(reopened.0, initial.0, "Reopening the sidebar restores the upper poster gradient")
        assertSameColor(reopened.1, initial.1, "Reopening the sidebar restores the lower poster gradient")
        assertSameColor(reopened.2, neutralBottom, "The restored gradient ends at the same canvas")
        XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: film.id), 1)
        XCTAssertEqual(fixture.server.artworkRequestCount(.primary, itemID: film.id), 1)
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
    }

    @MainActor
    func testPosterFallbackAndAbandonedBackdropPreserveLastOpenedPalette() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        // Only the portrait's pixels have the blue/pink signature. The delayed
        // green belongs to a separate, abandoned detail request.
        let portraitID = "portrait-only", missingWideID = "missing-wide", slowID = "late-wide", emptyID = "no-images"
        let rows = [
            portraitID: detailArtworkMovie(id: portraitID, hasBackdrop: false, hasPoster: true),
            missingWideID: detailArtworkMovie(id: missingWideID, hasBackdrop: true, hasPoster: true),
            slowID: detailArtworkMovie(id: slowID, hasBackdrop: true, hasPoster: false),
            emptyID: detailArtworkMovie(id: emptyID, hasBackdrop: false, hasPoster: false)
        ]
        func movie(_ id: String) throws -> MediaItem {
            try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(rows[id])))
        }
        let poster = try twoToneDetailArtwork(portrait: true)
        fixture.server.configureArtwork(poster, itemID: portraitID, delay: 0, type: .primary)
        fixture.server.configureArtwork(poster, itemID: missingWideID, delay: 0, type: .primary)
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: slowID, delay: 0)
        let pending = DispatchQueue(label: "pending-detail-backdrop")
        pending.suspend()
        var released = false
        defer { if !released { pending.resume() } }
        BrowseLayoutURLProtocol.handler = { request in
            if let url = request.url, url.path.hasPrefix("/Users/fixture-user/Items/"), let row = rows[url.lastPathComponent] {
                return .init(body: row)
            }
            var reply = fixture.server.reply(to: request)
            if request.url?.path.contains("/Items/" + slowID + "/Images/") == true { reply.deliveryQueue = pending }
            return reply
        }
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 960, height: 620), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.showDetail(try movie(emptyID))
        try await settle(host.controller.view)
        XCTAssertNil(frames["detail-cinematic-hero"])
        let pane = try XCTUnwrap(frames["content"])
        let sidebarEdge = pane.minX - 6
        let neutralSidebar = try sampleBackgroundColor(host.controller.view, x: sidebarEdge)
        model.showDetail(try movie(portraitID))
        try await waitUntil("The declared portrait is requested") { fixture.server.artworkRequestCount(.primary, itemID: portraitID) > 0 }
        try await settle(host.controller.view)
        XCTAssertNil(frames["detail-cinematic-hero"], "Portrait-only art must not be stretched into a landscape")
        XCTAssertNotNil(frames["detail-primary-play"])
        assertDetailHasBothHues(try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75))
        let portraitSidebar = try sampleBackgroundColor(host.controller.view, x: sidebarEdge)
        XCTAssertGreaterThan(portraitSidebar.blueComponent - neutralSidebar.blueComponent, 0.04)
        XCTAssertGreaterThan(portraitSidebar.blueComponent - portraitSidebar.redComponent, 0.08,
                             "The left edge of a portrait should color the sidebar when there is no backdrop")
        XCTAssertEqual(fixture.server.artworkRequestCount(.primary, itemID: portraitID), 1)
        XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: portraitID), 0)
        model.showDetail(try movie(missingWideID))
        try await waitUntil("The server-declared missing wide image and the valid portrait are both requested") {
            fixture.server.artworkRequestCount(.backdrop, itemID: missingWideID) == 1 &&
                fixture.server.artworkRequestCount(.primary, itemID: missingWideID) == 1
        }
        try await settle(host.controller.view)
        XCTAssertNil(frames["detail-cinematic-hero"], "A missing declared backdrop leaves a compact poster header")
        assertDetailHasBothHues(try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75))
        assertSameColor(try sampleBackgroundColor(host.controller.view, x: sidebarEdge), portraitSidebar,
                        "A declared backdrop returning 404 must use the same portrait colors")
        model.showDetail(try movie(slowID))
        try await waitUntil("Start the delayed detail artwork") { fixture.server.artworkRequestCount(.backdrop, itemID: slowID) > 0 }
        try await settle(host.controller.view)
        assertSameColor(try sampleBackgroundColor(host.controller.view, x: sidebarEdge), portraitSidebar,
                        "The previous portrait must stay visible while the next image is pending")
        model.showDetail(try movie(emptyID))
        pending.resume()
        released = true
        try await settle(host.controller.view)
        let restored = try detailEdgeColors(host.controller.view, pane: pane, y: pane.height * 0.33)
        let bottom = try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75)
        assertSameColor(bottom.0, bottom.1, "Both sides return to the shared page canvas below the faded poster")
        XCTAssertNil(frames["detail-cinematic-hero"])
        XCTAssertGreaterThan(restored.0.blueComponent - restored.0.redComponent, 0.05,
                             "An empty film must preserve the prior blue on the left")
        XCTAssertGreaterThan(restored.1.redComponent - restored.1.greenComponent, 0.05,
                             "The abandoned green request must not replace the prior pink on the right")
        assertSameColor(try sampleBackgroundColor(host.controller.view, x: sidebarEdge), portraitSidebar,
                        "The sidebar keeps the opened portrait through an empty film and a late backdrop")
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
    }

    @MainActor
    func testOpenedFilmPaletteFollowsSearchAndLibraryUntilAnotherFilmLoads() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        var preferences = model.applicationPreferences
        preferences.showHomeRecommendations = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        model.refresh()
        try await waitUntil("The movie library is ready") { model.catalogComplete && !model.loading }
        let first = try XCTUnwrap(model.items.first)
        let second = try XCTUnwrap(model.items.dropFirst().first)
        fixture.server.configureArtwork(try solidArtwork(.red), itemID: first.id, delay: 0)
        fixture.server.configureArtwork(try solidArtwork(.blue), itemID: second.id, delay: 0)
        let pending = DispatchQueue(label: "second-opened-film")
        pending.suspend()
        var released = false
        defer { if !released { pending.resume() } }
        let requested = expectation(description: "Second film requests its full detail image")
        BrowseLayoutURLProtocol.handler = { request in
            var reply = fixture.server.reply(to: request)
            if let url = request.url, url.path.hasPrefix("/Items/" + second.id + "/Images/Backdrop"),
               URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                URLQueryItem(name: "MaxWidth", value: String(MediaArtworkRole.detailBackdrop.maximumWidth))) == true {
                reply.deliveryQueue = pending
                requested.fulfill()
            }
            return reply
        }
        model.searchTerm = first.name
        model.navigate(to: "searchServer")
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 1000, height: 640), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settleNavigationChange(view)
        let content = try XCTUnwrap(frames["content"])
        func surfaces() throws -> (sidebar: NSColor, body: NSColor) {
            (try sampleBackgroundColor(view), try sampleBackgroundColor(view, x: content.minX + 3))
        }
        func contentGradient() throws -> [NSColor] {
            // This strip sits inside the detail pane, clear of cards, titles and sidebar chrome.
            try [0.15, 0.45, 0.94].map {
                try sampleBackgroundColor(view, x: content.minX + 3, yFraction: $0)
            }
        }
        func assertPalette(blue: Bool, _ state: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let colors = try surfaces()
            for (area, color) in [("sidebar", colors.sidebar), ("content", colors.body)] {
                let difference = color.redComponent - color.blueComponent
                XCTAssertGreaterThan(blue ? -difference : difference, 0.08, "\(state), \(area): \(color)", file: file, line: line)
            }
        }
        let neutral = try surfaces()
        let originalCanvas = try contentGradient()[2]
        model.showDetail(first)
        try await waitUntil("The first opened film colors the window red") {
            guard let sidebar = try? self.sampleBackgroundColor(view) else { return false }
            return sidebar.redComponent > sidebar.blueComponent + 0.08
        }
        let redSidebar = try sampleBackgroundColor(view)
        model.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.page, "searchServer")
        try assertPalette(blue: false, "Back in search")
        let searchGradient = try contentGradient()
        XCTAssertGreaterThan(searchGradient[0].redComponent, searchGradient[1].redComponent + 0.10)
        XCTAssertGreaterThan(searchGradient[1].redComponent, searchGradient[2].redComponent + 0.10)
        assertSameColor(searchGradient[2], originalCanvas, "Search fades the ambient image into its neutral canvas")
        assertSameColor(try surfaces().sidebar, redSidebar, "Going back to search preserves the exact sidebar field")
        model.navigate(to: "library")
        try await settleNavigationChange(view)
        try assertPalette(blue: false, "Browsing another grid")
        for (library, search) in zip(try contentGradient(), searchGradient) {
            assertSameColor(library, search, "Search and library paint the same background at the same window coordinates")
        }
        let card = detailArtworkMovie(id: "green-thumbnail", hasBackdrop: false, hasPoster: true)
        let thumbnail = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: card))
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: thumbnail.id, delay: 0, type: .primary)
        model.items = [thumbnail, first, second]
        try await waitUntil("A different film's green grid image is requested without opening its detail") {
            fixture.server.artworkRequestCount(.primary, itemID: thumbnail.id) > 0
        }
        try await settle(view)
        try assertPalette(blue: false, "After the library paints an unopened green poster")
        fixture.server.configureResume(count: 0, delay: 0.7)
        model.refreshFromToolbar()
        try await settle(view)
        XCTAssertTrue(model.isToolbarRefreshing)
        try assertPalette(blue: false, "While the library refresh skeleton is visible")
        try await waitUntil("The library refresh is complete") { !model.isToolbarRefreshing }
        model.showDetail(second)
        await fulfillment(of: [requested], timeout: 5)
        try await settle(view)
        try assertPalette(blue: false, "While the second film's only artwork is pending")
        pending.resume()
        released = true
        try await waitUntil("The second film's blue image has reached the sidebar") {
            guard let sidebar = try? self.sampleBackgroundColor(view) else { return false }
            return sidebar.blueComponent > sidebar.redComponent + 0.08
        }
        model.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertEqual(model.page, "library")
        try assertPalette(blue: true, "After the second film replaces red")
        model.navigate(to: "searchServer")
        try await settleNavigationChange(view)
        try assertPalette(blue: true, "Returning to search again")
        let allowed = model.libraries
        XCTAssertFalse(allowed.isEmpty)
        model.navigate(to: "library")
        model.libraries = []
        try await settleNavigationChange(view)
        model.libraries = allowed
        try await settleNavigationChange(view)
        assertSameColor(try surfaces().sidebar, neutral.sidebar, "Restoring library access must not resurrect revoked colors")
        model.showDetail(first)
        try await waitUntil("A fresh authorized visit colors the sidebar again") {
            guard let sidebar = try? self.sampleBackgroundColor(view) else { return false }
            return sidebar.redComponent > sidebar.blueComponent + 0.08
        }
        model.goBackFromDetail()
        try await settle(view)
        model.saved.connections[0].userID = "replacement"
        try await settleNavigationChange(view)
        let afterAccountChange = try surfaces()
        assertSameColor(afterAccountChange.sidebar, neutral.sidebar, "The replacement account starts with a neutral sidebar")
        assertSameColor(afterAccountChange.body, neutral.body, "The replacement account starts with a neutral main pane")
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
    }

    @MainActor
    func testChangingOnlyAnUnusedHomeArtworkCandidateKeepsTheDetailPalette() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.refresh()
        try await waitUntil("The authorized home catalog is ready") { model.homeRecommendations.count >= 2 }
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        var home = model.homeRecommendations[0]
        home.backdropImageTags = ["displayed-backdrop"]
        home.imageTags["Thumb"] = "unused-first-tag"
        func report(_ candidate: MediaItem, color: NSColor) throws -> HomeArtworkSnapshot {
            let key = MediaPoster.requestKey(model: model, item: candidate, role: .landscape,
                                             requestWidth: 1600, libraryID: scope.libraryID)
            return try XCTUnwrap(HomeArtworkSnapshot.make(scope: scope, itemID: candidate.id, requestKey: key,
                loadedKey: key, image: NSImage(data: solidArtwork(color)), accessRevision: model.windowArtworkRevision))
        }
        let original = try report(home, color: .red)
        model.acceptHomeWindowPalette(original)
        let detail = model.homeRecommendations[1]
        model.detail = detail
        let detailColor = try report(detail, color: .blue).blurredBackground
        model.acceptWindowPalette(.init(scope: scope, accessRevision: model.windowArtworkRevision,
                                        itemID: detail.id, field: detailColor))
        model.detail = nil

        home.imageTags["Thumb"] = "unused-second-tag"
        let sameBackdrop = try report(home, color: .red)
        XCTAssertNotEqual(sameBackdrop.requestKey, original.requestKey)
        model.acceptHomeWindowPalette(sameBackdrop)
        XCTAssertTrue(model.windowColorField === detailColor, "Changing the unused Thumb leaves the displayed Backdrop identical")

        let newBackdrop = try report(home, color: .green)
        XCTAssertEqual(newBackdrop.requestKey, sameBackdrop.requestKey)
        model.acceptHomeWindowPalette(newBackdrop)
        XCTAssertTrue(model.windowColorField === newBackdrop.blurredBackground, "A genuinely different decoded Backdrop supersedes the detail color")
        await model.shutdown()
    }

    @MainActor
    func testRefreshingHomeWaitsForTheRecommendationToBecomeVisibleBeforeTakingItsColor() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let red = detailArtworkMovie(id: "before-refresh", hasBackdrop: true, hasPoster: false)
        let blue = detailArtworkMovie(id: "during-refresh", hasBackdrop: true, hasPoster: false)
        let green = detailArtworkMovie(id: "opened-film", hasBackdrop: true, hasPoster: false)
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: "opened-film", delay: 0)
        fixture.server.configureArtwork(try solidArtwork(.red), itemID: "before-refresh", delay: 0)
        fixture.server.configureArtwork(try solidArtwork(.blue), itemID: "during-refresh", delay: 0)
        func catalog(_ item: [String: Any]) -> BrowseLayoutURLProtocol.Reply {
            .init(body: ["Items": [item], "TotalRecordCount": 1])
        }
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items" { return catalog(red) }
            if request.url?.path == "/Users/fixture-user/Items/opened-film" { return .init(body: green) }
            return fixture.server.reply(to: request)
        }
        var banner: HomeArtworkSnapshot?
        let host = makeHost(model: model, size: CGSize(width: 1000, height: 640), artworkReport: { banner = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        model.refresh()
        try await waitUntil("The red banner is visible") { model.homeContentReady && model.windowPalette?.itemID == "before-refresh" }
        let redColor = try sampleBackgroundColor(view)
        model.navigate(to: "searchServer")
        try await settleNavigationChange(view)
        assertSameColor(try sampleBackgroundColor(view), redColor, "Search starts with the visible red recommendation")
        let greenFilm = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: green))
        model.showDetail(greenFilm)
        try await waitUntil("The opened film replaces the home color with green") {
            model.windowPalette?.itemID == greenFilm.id
        }
        let filmField = try XCTUnwrap(model.windowColorField)
        let filmColor = try sampleBackgroundColor(view)
        XCTAssertGreaterThan(filmColor.greenComponent, filmColor.redComponent + 0.08)
        model.navigateBack()
        try await settleNavigationChange(view)
        assertSameColor(try sampleBackgroundColor(view), filmColor, "Returning to search retains the opened film")
        model.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertEqual(model.page, "home")
        XCTAssertEqual(banner?.itemID, "before-refresh")
        assertSameColor(try sampleBackgroundColor(view), filmColor, "Returning to the same banner retains the newer film color")

        let resume = DispatchQueue(label: "hold-home-refresh-cover")
        resume.suspend()
        var released = false
        defer { if !released { resume.resume() } }
        let downloaded = expectation(description: "The replacement artwork arrives behind the refresh cover")
        fixture.server.configureResume(count: 0, delay: 0, deliveryQueue: resume)
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items" { return catalog(blue) }
            var reply = fixture.server.reply(to: request)
            if request.url?.path.hasPrefix("/Items/during-refresh/Images/Backdrop") == true {
                reply.didComplete = { downloaded.fulfill() }
            }
            return reply
        }
        model.refreshFromToolbar()
        await fulfillment(of: [downloaded], timeout: 5)
        try await settle(view)
        XCTAssertTrue(model.isToolbarRefreshing)
        XCTAssertNil(banner, "A covered recommendation must not publish artwork")
        XCTAssertTrue(model.windowColorField === filmField)
        assertSameColor(try sampleBackgroundColor(view), filmColor, "The refresh cover retains the opened film's green")
        resume.resume()
        released = true
        try await waitUntil("Ending the cover exposes the already loaded blue recommendation") {
            !model.isToolbarRefreshing && banner?.itemID == "during-refresh" && model.windowPalette?.itemID == "during-refresh"
        }
        model.navigate(to: "library")
        try await settleNavigationChange(view)
        let carried = try sampleBackgroundColor(view)
        XCTAssertGreaterThan(carried.blueComponent, carried.redComponent + 0.03)
        await model.shutdown()
    }

    @MainActor
    func testHomePaletteAcceptsTheNextVisibleRecommendationAndRejectsStaleAccess() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.refresh()
        try await waitUntil("The home recommendations belong to the current catalog") { model.homeRecommendations.count >= 3 }
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        func snapshot(_ item: MediaItem, _ color: NSColor, tag: String = "original") throws -> HomeArtworkSnapshot {
            let key = "\(item.id)|\(tag)"
            return try XCTUnwrap(HomeArtworkSnapshot.make(scope: scope, itemID: item.id, requestKey: key,
                loadedKey: key, image: NSImage(data: solidArtwork(color)), accessRevision: model.windowArtworkRevision))
        }
        let recommendations = model.homeRecommendations
        let first = try snapshot(recommendations[0], .red)
        let lastVisible = try snapshot(recommendations[1], .green)
        let delayed = try snapshot(recommendations[2], .blue)
        model.acceptHomeWindowPalette(first)
        XCTAssertTrue(model.windowColorField === first.blurredBackground)
        model.acceptHomeWindowPalette(lastVisible)
        XCTAssertTrue(model.windowColorField === lastVisible.blurredBackground)
        model.navigate(to: "searchServer")
        model.acceptHomeWindowPalette(delayed)
        XCTAssertTrue(model.windowColorField === lastVisible.blurredBackground, "An offscreen carousel response cannot recolor search")
        model.navigateBack()
        XCTAssertEqual(model.page, "home")
        let repeated = try snapshot(recommendations[1], .green)
        model.acceptHomeWindowPalette(repeated)
        XCTAssertTrue(model.windowColorField === lastVisible.blurredBackground, "Republishing the same artwork keeps the previous field")
        model.detail = recommendations[0]
        model.acceptWindowPalette(.init(scope: scope, accessRevision: model.windowArtworkRevision,
                                        itemID: recommendations[0].id, field: first.blurredBackground))
        model.detail = nil
        model.acceptHomeWindowPalette(repeated)
        XCTAssertTrue(model.windowColorField === first.blurredBackground, "Returning to the same recommendation preserves the detail color")

        var motion = HomeCarouselMotion()
        motion.reset(to: lastVisible.itemID)
        motion.request(id: delayed.itemID, direction: 1, animated: false)
        XCTAssertTrue(model.windowColorField === first.blurredBackground, "Switching to a recommendation with no ready artwork keeps the detail color")
        motion.request(id: lastVisible.itemID, direction: -1, animated: false)
        var reselected = repeated
        reselected.selectionID = try XCTUnwrap(motion.selectionID)
        model.acceptHomeWindowPalette(reselected)
        XCTAssertTrue(model.windowColorField === reselected.blurredBackground, "Deliberately selecting the cached recommendation again can replace the detail color")
        model.acceptHomeWindowPalette(delayed)
        XCTAssertTrue(model.windowColorField === delayed.blurredBackground, "A newly visible recommendation replaces the carried green color")
        let replacement = try snapshot(recommendations[2], .red, tag: "replacement")
        model.acceptHomeWindowPalette(replacement)
        XCTAssertTrue(model.windowColorField === replacement.blurredBackground, "A new image for the same title can update the color")
        let allowed = model.libraries
        model.libraries = []
        XCTAssertNil(model.windowColorField)
        model.libraries = allowed
        model.acceptHomeWindowPalette(delayed)
        XCTAssertNil(model.windowColorField, "Renewing access cannot revive a recommendation from before revocation")
        let renewed = try snapshot(recommendations[2], .blue)
        model.acceptHomeWindowPalette(renewed)
        XCTAssertTrue(model.windowColorField === renewed.blurredBackground, "A fresh authorized image can seed a new color")
        model.navigate(to: "searchServer")
        for mode in [(true, false), (false, true)] {
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: model, size: NSSize(width: 1000, height: 640),
                                sidebarReport: { frames = $0 }, accessibility: mode)
            defer { host.window.contentViewController = nil; host.window.close() }
            let view = host.controller.view
            try await settleNavigationChange(view)
            let contentX = try XCTUnwrap(frames["content"]).minX + 3
            let sidebar = try sampleBackgroundColor(view)
            let content = try sampleBackgroundColor(view, x: contentX)
            XCTAssertLessThan(abs(sidebar.blueComponent - sidebar.redComponent), 0.08,
                              "The accessible sidebar must stay neutral even with a retained blue home color")
            XCTAssertLessThan(abs(content.blueComponent - content.redComponent), 0.08,
                              "The accessible search background must stay neutral too")
            XCTAssertTrue(model.windowColorField === renewed.blurredBackground)
        }
        await model.shutdown()
    }

    @MainActor
    func testDelayedInitialRecommendationCannotReplaceDetailAfterReturningToSameBanner() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let a = "delayed-first-banner", b = "detail-before-first-banner", c = "replacement-banner"
        let film = detailArtworkMovie(id: b, hasBackdrop: true, hasPoster: false)
        for (id, color) in [(a, NSColor.red), (b, .green), (c, .blue)] {
            fixture.server.configureArtwork(try solidArtwork(color), itemID: id, delay: 0)
        }
        let firstResponse = DispatchQueue(label: "first-banner-image")
        let nextResponse = DispatchQueue(label: "next-banner-image")
        firstResponse.suspend()
        nextResponse.suspend()
        var firstReleased = false, nextReleased = false
        defer {
            if !firstReleased { firstResponse.resume() }
            if !nextReleased { nextResponse.resume() }
        }
        func serveRecommendation(_ id: String, imageQueue: DispatchQueue) {
            let item = detailArtworkMovie(id: id, hasBackdrop: true, hasPoster: false)
            BrowseLayoutURLProtocol.handler = { request in
                let path = request.url?.path
                if path == "/Users/fixture-user/Items" { return .init(body: ["Items": [item], "TotalRecordCount": 1]) }
                if path == "/Users/fixture-user/Items/" + b { return .init(body: film) }
                var reply = fixture.server.reply(to: request)
                if path?.hasPrefix("/Items/" + id + "/Images/Backdrop") == true { reply.deliveryQueue = imageQueue }
                return reply
            }
        }
        serveRecommendation(a, imageQueue: firstResponse)
        let host = makeHost(model: model, size: NSSize(width: 1000, height: 640))
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        model.refresh()
        try await waitUntil("A is presented on home while its image is still loading") {
            model.homeContentReady && model.homeRecommendations.first?.id == a && fixture.server.heroArtworkRequestsByItem[a] == 1
        }
        try await settle(view)
        XCTAssertNil(model.windowPalette)
        model.navigate(to: "searchServer")
        try await settleNavigationChange(view)
        model.showDetail(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: film)))
        try await waitUntil("B provides the first usable window background") { model.windowPalette?.itemID == b }
        firstResponse.resume()
        firstReleased = true
        try await waitUntil("A finishes downloading while the detail for B is open") {
            fixture.server.completedHeroArtworkIDs.contains(a)
        }
        let backdropB = try XCTUnwrap(model.windowColorField)
        model.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertEqual(model.page, "searchServer")
        XCTAssertTrue(model.windowColorField === backdropB)
        model.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertEqual(model.page, "home")
        XCTAssertEqual(model.homeRecommendations.first?.id, a)
        XCTAssertTrue(model.windowColorField === backdropB, "Redisplaying A after its first image arrives must preserve B")

        serveRecommendation(c, imageQueue: nextResponse)
        model.refreshFromToolbar()
        try await waitUntil("Home switches to C before the replacement image is ready") {
            !model.isToolbarRefreshing && model.homeRecommendations.first?.id == c && fixture.server.heroArtworkRequestsByItem[c] == 1
        }
        XCTAssertTrue(model.windowColorField === backdropB, "C is selected but has no prepared background yet")
        nextResponse.resume()
        nextReleased = true
        try await waitUntil("The new recommendation replaces B with its prepared background") {
            model.windowPalette?.itemID == c
        }
        model.navigate(to: "library")
        try await settleNavigationChange(view)
        let color = try sampleBackgroundColor(view)
        XCTAssertGreaterThan(color.blueComponent - color.redComponent, 0.03, "The library now inherits C")
        await model.shutdown()
    }

    @MainActor
    func testColdLaunchUsesNewHomeArtworkInsteadOfTheLastOpenedFilm() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        var preferences = fixture.model.applicationPreferences
        preferences.showHomeRecommendations = false
        XCTAssertTrue(fixture.model.updateApplicationPreferences(preferences))
        fixture.model.refresh()
        try await waitUntil("The first session has the authorized catalog") { fixture.model.catalogComplete }
        let film = try XCTUnwrap(fixture.model.items.first)
        fixture.server.configureArtwork(try solidArtwork(.red), itemID: film.id, delay: 0)
        let size = NSSize(width: 1000, height: 640)
        let expected: NSColor
        do {
            let host = makeHost(model: fixture.model, size: size)
            defer { host.window.contentViewController = nil; host.window.close() }
            fixture.model.showDetail(film)
            try await waitUntil("The opened film colors the first window") {
                guard let color = try? self.sampleBackgroundColor(host.controller.view) else { return false }
                return color.redComponent > color.blueComponent + 0.08
            }
            expected = try sampleBackgroundColor(host.controller.view)
            fixture.model.navigate(to: "library")
            try await settleNavigationChange(host.controller.view)
            assertSameColor(try sampleBackgroundColor(host.controller.view), expected, "The first library retains the film")
        }
        preferences.showHomeRecommendations = true
        XCTAssertTrue(fixture.model.updateApplicationPreferences(preferences))
        await fixture.model.shutdown()

        // Hold the new session's only recommendation response until its window
        // and catalog are both ready, so the first-frame check is deterministic.
        let newID = "new-home-banner"
        let newFilm = detailArtworkMovie(id: newID, hasBackdrop: true, hasPoster: false)
        fixture.server.configureArtwork(try solidArtwork(.blue), itemID: newID, delay: 0)
        let nextID = "new-detail"
        let listing = detailArtworkMovie(id: nextID, hasBackdrop: false, hasPoster: false)
        let nextDetail = detailArtworkMovie(id: nextID, hasBackdrop: true, hasPoster: false)
        fixture.server.configureArtwork(try solidArtwork(.green), itemID: nextID, delay: 0)
        let pending = DispatchQueue(label: "new-home-banner")
        pending.suspend()
        var released = false
        defer { if !released { pending.resume() } }
        let detailResponse = DispatchQueue(label: "new-detail-image")
        detailResponse.suspend()
        var detailReleased = false
        defer { if !detailReleased { detailResponse.resume() } }
        let detailRequested = expectation(description: "The newly opened film requests its green backdrop")
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items" {
                return .init(body: ["Items": [newFilm, listing], "TotalRecordCount": 2])
            }
            if request.url?.path == "/Users/fixture-user/Items/" + nextID { return .init(body: nextDetail) }
            var reply = fixture.server.reply(to: request)
            if request.url?.path.hasPrefix("/Items/" + newID + "/Images/Backdrop") == true {
                reply.deliveryQueue = pending
            } else if request.url?.path.hasPrefix("/Items/" + nextID + "/Images/Backdrop") == true {
                detailRequested.fulfill()
                reply.deliveryQueue = detailResponse
            }
            return reply
        }

        let cold = makeBrowseModel(storage: fixture.storage, session: fixture.session)
        var banner: HomeArtworkSnapshot?
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: cold, size: size, artworkReport: { banner = $0 }, sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settle(view)
        let neutral = try sampleBackgroundColor(view)
        XCTAssertLessThan(abs(neutral.redComponent - neutral.blueComponent), 0.08)
        cold.refresh()
        try await waitUntil("The new home is waiting for its own blue artwork") {
            cold.catalogComplete && fixture.server.heroArtworkRequestsByItem[newID] != nil
        }
        try await settle(view)
        XCTAssertNil(cold.detail)
        XCTAssertEqual(cold.page, "home")
        XCTAssertNil(banner)
        assertSameColor(try sampleBackgroundColor(view), neutral, "The pending banner must not reveal the previous red")
        pending.resume()
        released = true
        try await waitUntil("The new home recommendation supplies its artwork") { banner?.itemID == newID }
        try await settle(view)
        let blue = try sampleBackgroundColor(view)
        XCTAssertGreaterThan(blue.blueComponent - blue.redComponent, 0.03, "The reopened sidebar follows its new blue banner")
        XCTAssertNotNil(cold.windowColorField)
        XCTAssertNil(cold.detail)
        cold.navigate(to: "searchServer")
        try await settleNavigationChange(view)
        let pane = try XCTUnwrap(frames["content"])
        let contentX = pane.minX + 3
        let blueBody = try sampleBackgroundColor(view, x: contentX)
        let bodyY = pane.maxY - 12
        let blueMargin = try detailEdgeColors(view, pane: pane, y: bodyY).0
        XCTAssertGreaterThan(blueBody.blueComponent - blueBody.redComponent, 0.03)
        assertSameColor(try sampleBackgroundColor(view), blue, "The first search inherits the new home banner")
        cold.navigate(to: "library")
        try await settleNavigationChange(view)
        assertSameColor(try sampleBackgroundColor(view), blue, "The library retains the blue sidebar")
        assertSameColor(try sampleBackgroundColor(view, x: contentX), blueBody, "The library retains the blue content")

        cold.showDetail(try XCTUnwrap(cold.items.first { $0.id == nextID }))
        await fulfillment(of: [detailRequested], timeout: 5)
        try await settle(view)
        assertSameColor(try sampleBackgroundColor(view), blue, "Pending detail artwork retains the home sidebar")
        XCTAssertGreaterThan(bodyY, try XCTUnwrap(frames["detail-cinematic-hero"]).maxY)
        assertSameColor(try detailEdgeColors(view, pane: pane, y: bodyY).0, blueMargin,
                        "The exposed background below the detail header keeps the exact home color")
        assertSameColor(try sampleBackgroundColor(view, x: contentX), blueBody,
                        "The header preserves the inherited color until new art needs a text backing")
        detailResponse.resume()
        detailReleased = true
        try await waitUntil("Only the successful new film turns the sidebar green") {
            guard let color = try? self.sampleBackgroundColor(view) else { return false }
            return color.greenComponent > color.blueComponent + 0.08
        }
        let green = try sampleBackgroundColor(view)
        cold.navigateBack()
        try await settleNavigationChange(view)
        XCTAssertEqual(cold.page, "library")
        assertSameColor(try sampleBackgroundColor(view), green, "The replacement persists on return")
        let greenBody = try sampleBackgroundColor(view, x: contentX)
        XCTAssertGreaterThan(greenBody.greenComponent - greenBody.blueComponent, 0.08)
        XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: film.id), 1)
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
        await cold.shutdown()
    }

    @MainActor
    func testAllEpisodesKeepsSeriesArtworkWhileItsHeaderIsUnmounted() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.selectedLibraryID = "movies"
        var row = fixture.server.series
        row["BackdropImageTags"] = ["series-wide"]
        let item = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
        fixture.server.configureArtwork(try twoToneDetailArtwork(portrait: false), itemID: item.id, delay: 0)
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path == "/Users/fixture-user/Items/" + item.id { return .init(body: row) }
            return fixture.server.reply(to: request)
        }
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 960, height: 620), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.showDetail(item)
        try await waitUntil("The normal series preview has ready episodes") { !model.seriesLoading && !model.episodes.isEmpty }
        try await settle(host.controller.view)
        let pane = try XCTUnwrap(frames["content"])
        XCTAssertNotNil(frames["detail-cinematic-hero"])
        assertDetailHasBothHues(try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75))
        model.showAllEpisodes()
        try await settle(host.controller.view)
        XCTAssertTrue(model.seriesPresentation.showsAll)
        XCTAssertNil(frames["detail-cinematic-hero"])
        assertDetailHasBothHues(try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75))
        model.goBackFromDetail()
        try await settle(host.controller.view)
        XCTAssertEqual(model.detail?.id, item.id)
        XCTAssertFalse(model.seriesPresentation.showsAll)
        XCTAssertNotNil(frames["detail-cinematic-hero"])
        assertDetailHasBothHues(try detailEdgeColors(host.controller.view, pane: pane, y: pane.height - 75))
        XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: item.id), 1)
        XCTAssertTrue(fixture.server.unexpectedPaths.isEmpty)
    }

    @MainActor
    func testDetailSidebarUsesNeutralSurfaceForAccessibilityEvenWithLoadedPoster() async throws {
        for (reducedTransparency, increasedContrast) in [(true, false), (false, true)] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            let model = fixture.model
            model.selectedLibraryID = "movies"
            let row = detailArtworkMovie(id: "accessible-poster", hasBackdrop: true, hasPoster: true)
            let film = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: row))
            fixture.server.configureArtwork(try solidArtwork(.red), itemID: film.id, delay: 0, type: .primary)
            BrowseLayoutURLProtocol.handler = { request in
                if request.url?.path == "/Users/fixture-user/Items/" + film.id { return .init(body: row) }
                return fixture.server.reply(to: request)
            }
            let host = makeHost(model: model, size: NSSize(width: 960, height: 620),
                                accessibility: (reducedTransparency, increasedContrast))
            defer { host.window.contentViewController = nil; host.window.close() }
            let view = host.controller.view
            try await settle(view)
            let neutral = try sampleBackgroundColor(view)
            model.showDetail(film)
            try await waitUntil("The poster still loads for the accessible compact detail") {
                !model.detailLoading && fixture.server.artworkRequestCount(.primary, itemID: film.id) == 1
            }
            try await settle(view)
            assertSameColor(try sampleBackgroundColor(view), neutral,
                            "Opaque sidebar for reduced transparency \(reducedTransparency), increased contrast \(increasedContrast)")
            model.goBackFromDetail()
            try await settle(view)
            assertSameColor(try sampleBackgroundColor(view), neutral,
                            "Leaving the film must preserve the opaque accessibility surface")
            XCTAssertEqual(fixture.server.artworkRequestCount(.backdrop, itemID: film.id), 0,
                           "Reduced transparency \(reducedTransparency), increased contrast \(increasedContrast)")
        }
    }

    @MainActor
    func testDetailArtworkLegibilityAndAccessibilityFallbacks() throws {
        let light = try DetailArtworkAppearance.make(from: XCTUnwrap(NSImage(data: twoToneDetailArtwork(portrait: false))))
        let dark = try DetailArtworkAppearance.make(from: XCTUnwrap(NSImage(data: solidArtwork(.blue))))
        let transparent = try DetailArtworkAppearance.make(from: XCTUnwrap(NSImage(data: solidArtwork(.clear))))
        XCTAssertTrue(light.isLight)
        XCTAssertFalse(dark.isLight)
        XCTAssertTrue(dark.hasArtwork)
        XCTAssertFalse(transparent.hasArtwork)
        for appearance in [light, dark] {
            let field = try XCTUnwrap(appearance.colorField?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let pixels = try sRGBPixels(NSBitmapImageRep(cgImage: field))
            let label = try XCTUnwrap(NSColor(appearance.secondaryText).usingColorSpace(.sRGB))
            for index in stride(from: 0, to: pixels.count, by: 4) {
                let point = SeatSixChromeRGB(red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255,
                                             blue: Double(pixels[index + 2]) / 255)
                let a = label.alphaComponent
                let ink = SeatSixChromeRGB(red: label.redComponent * a + point.red * (1 - a),
                                           green: label.greenComponent * a + point.green * (1 - a),
                                           blue: label.blueComponent * a + point.blue * (1 - a))
                let ratio = (max(point.relativeLuminance, ink.relativeLuminance) + 0.05) /
                    (min(point.relativeLuminance, ink.relativeLuminance) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Secondary text must be readable across the whole field")
            }
            let opaque = HomeAtmospherePolicy(reduceTransparency: true, increasedContrast: false, reduceMotion: false)
            let contrast = HomeAtmospherePolicy(reduceTransparency: false, increasedContrast: true, reduceMotion: false)
            let still = HomeAtmospherePolicy(reduceTransparency: false, increasedContrast: false, reduceMotion: true)
            XCTAssertEqual(appearance.applying(opaque), .neutral)
            XCTAssertEqual(appearance.applying(contrast), .neutral)
            XCTAssertEqual(appearance.applying(still), appearance)
        }
    }

    private func detailArtworkMovie(id: String, hasBackdrop: Bool, hasPoster: Bool) -> [String: Any] {
        var row: [String: Any] = [
            "Id": id, "Name": "色彩验收", "Type": "Movie", "ProductionYear": 2026,
            "Overview": "用于详情下半区和滚动的合成样本。",
            "People": [["Name": "一位演员", "Role": "角色", "Type": "Actor"]],
            "MediaStreams": [["Type": "Video", "DisplayTitle": "1080p", "Codec": "H264",
                              "Profile": "Main", "Width": 1920, "Height": 1080, "BitDepth": 8, "Index": 0]]
        ]
        if hasBackdrop { row["BackdropImageTags"] = ["wide"] }
        if hasPoster { row["ImageTags"] = ["Primary": "poster"] }
        return row
    }

    @MainActor
    private func twoToneDetailArtwork(portrait: Bool) throws -> Data {
        let width = portrait ? 160 : 320, height = portrait ? 240 : 180
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(srgbRed: 0.25, green: 0.72, blue: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height).fill()
        NSColor(srgbRed: 1, green: 0.55, blue: 0.70, alpha: 1).setFill()
        NSRect(x: width / 2, y: 0, width: width / 2, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func detailEdgeColors(_ view: NSView, pane: CGRect, y: CGFloat) throws -> (NSColor, NSColor) {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Both points are in the content margin, outside all labels and cards.
        let left = try renderedColor(bitmap, at: CGPoint(x: pane.minX + 18, y: y), viewSize: view.bounds.size)
        let right = try renderedColor(bitmap, at: CGPoint(x: pane.maxX - 23, y: y), viewSize: view.bounds.size)
        return (left, right)
    }

    private func assertDetailHasBothHues(_ colors: (NSColor, NSColor), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(colors.0.blueComponent - colors.0.redComponent, 0.13,
                             "The left edge should retain the blue part of the artwork: \(colors.0)", file: file, line: line)
        XCTAssertGreaterThan(colors.1.redComponent - colors.1.greenComponent, 0.13,
                             "The right edge should retain the pink part of the artwork: \(colors.1)", file: file, line: line)
    }

    @MainActor
    private func solidArtwork(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill(); NSRect(x: 0, y: 0, width: 320, height: 180).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func snapshotColor(_ artwork: HomeArtworkSnapshot) throws -> NSColor {
        let image = try XCTUnwrap(artwork.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try renderedColor(bitmap, at: CGPoint(x: 0.5, y: 0.5), viewSize: NSSize(width: 1, height: 1))
    }

    @MainActor
    private func sampleBackgroundColor(_ view: NSView, x: CGFloat = 4, yFraction: CGFloat = 0.45) throws -> NSColor {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // The outer 4pt strip of the full-height sidebar never contains a row,
        // selection marker, label or separator. Sample the real sidebar surface
        // over the shared atmosphere, without depending on the removed gutter.
        return try renderedColor(bitmap, at: CGPoint(x: x, y: yFraction * view.bounds.height), viewSize: view.bounds.size)
    }

    @MainActor
    func testPrimaryPlaybackLabelStaysLegibleInAnInactiveDarkWindow() async throws {
        _ = NSApplication.shared
        let model = try makeFixture()
        model.detail = model.items[0]
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 1220, height: 820), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        XCTAssertFalse(host.window.isKeyWindow)

        for disabled in [false, true] {
            model.detailLoading = disabled
            try await settle(host.controller.view)
            let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
            host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
            let play = try XCTUnwrap(frames["detail-primary-play"])
            let contrast = try renderedContrast(bitmap, in: play.insetBy(dx: 9, dy: 5), viewSize: host.controller.view.bounds.size)
            XCTAssertGreaterThan(contrast, disabled ? 1.8 : 4.5,
                                 "The native prominent button must retain a distinguishable label when \(disabled ? "disabled" : "enabled") in an inactive dark window")
            try savePreviewIfRequested(host.controller.view, name: "detail-primary-\(disabled ? "disabled" : "enabled")")
        }
    }

    @MainActor
    func testCompactNavigationToolbarKeepsLongSourceSearchAndRefreshSeparate() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820), NSSize(width: 1607, height: 978)] {
            let model = try makeFixture(connectionName: String(repeating: "很长的 NAS 媒体服务器名称", count: 8))
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = true
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            for route in ["home", "favorites", "library", "recent", "detail"] {
                model.detail = route == "detail" ? model.items.first : nil
                model.page = route == "detail" ? "library" : route
                if route == "library" { model.query = "合成" }
                try await settle(host.controller.view)
                let toolbar = try XCTUnwrap(frames["navigation-toolbar"])
                let source = try XCTUnwrap(frames["toolbar-source"])
                let refresh = try XCTUnwrap(frames["toolbar-refresh"])
                XCTAssertLessThanOrEqual(toolbar.height, 54, "Navigation must stay compact instead of returning to a large glass panel")
                XCTAssertGreaterThanOrEqual(toolbar.height, 44)
                XCTAssertGreaterThan(source.width, 80, "A long source must retain readable space")
                XCTAssertGreaterThanOrEqual(refresh.width, 30)
                XCTAssertGreaterThanOrEqual(refresh.height, 30)
                for control in [source, refresh] {
                    XCTAssertTrue(toolbar.insetBy(dx: -1, dy: -1).contains(control), "Toolbar controls must remain within the actual header")
                }
                XCTAssertLessThanOrEqual(toolbar.maxX, size.width + 0.5)
                XCTAssertEqual(toolbar.minX, 0, accuracy: 0.5)
                XCTAssertEqual(toolbar.minY, 0, accuracy: 0.5)
                XCTAssertEqual(toolbar.maxX, size.width, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(source.minX, try XCTUnwrap(frames["sidebar-toggle"]).maxX + 8)
                let search = try XCTUnwrap(frames["toolbar-search"])
                XCTAssertGreaterThanOrEqual(search.minX, refresh.maxX)
                if route == "library" {
                    XCTAssertGreaterThan(search.width, 80, "The mounted search field must leave room to type")
                } else {
                    XCTAssertEqual(search.width, 36, accuracy: 0.5)
                    XCTAssertEqual(search.height, 36, accuracy: 0.5)
                }
                XCTAssertTrue(toolbar.insetBy(dx: -1, dy: -1).contains(search))
                if ["home", "favorites"].contains(route) {
                    XCTAssertNil(frames["toolbar-history"])
                    let tabs = try XCTUnwrap(frames["toolbar-tabs"])
                    XCTAssertLessThanOrEqual(source.maxX, tabs.minX)
                    XCTAssertLessThanOrEqual(tabs.maxX, refresh.minX)
                    XCTAssertEqual(tabs.midX, toolbar.midX, accuracy: 1)
                } else {
                    XCTAssertNil(frames["toolbar-tabs"])
                    let history = try XCTUnwrap(frames["toolbar-history"])
                    XCTAssertGreaterThanOrEqual(history.minX, source.maxX)
                    XCTAssertTrue(toolbar.insetBy(dx: -1, dy: -1).contains(history))
                    let title = try XCTUnwrap(frames["toolbar-title"])
                    XCTAssertGreaterThanOrEqual(title.minX, history.maxX)
                    XCTAssertLessThanOrEqual(title.maxX, refresh.minX)
                }
                let rendered = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
                host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: rendered)
                let title = CGRect(x: source.minX + 14, y: source.midY - 8, width: min(source.width - 28, 100), height: 16)
                XCTAssertGreaterThan(try renderedContrast(rendered, in: title, viewSize: size), 4.5,
                                     "The current source must remain readable without a full-width glass backing")
                assertVerticalScrollDocumentsFit(host.controller.view, route: route)
                try savePreviewIfRequested(host.controller.view, name: "chrome-\(route)-\(Int(size.width))")
            }
            await model.shutdown()
        }
    }

    @MainActor
    func testToolbarShowsOnlyUsableHistoryDirectionsAwayFromTabRoots() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let connection = try XCTUnwrap(model.connection)
        model.saved.applicationPreferences.startupPage = .lastBrowsed
        model.saved.browsingLocations = [BrowsingLocation(connection: connection, page: "library", libraryID: "movies")]
        model.refresh()
        try await waitUntil("Restore the library directly without a previous visit") { model.homeContentReady }
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        try await settle(host.controller.view)
        XCTAssertEqual(model.page, "library")
        XCTAssertFalse(model.canNavigateBack || model.canNavigateForward)
        XCTAssertNil(frames["toolbar-history"])

        model.navigate(to: "home")
        try await settle(host.controller.view)
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertNil(frames["toolbar-history"])
        model.navigate(to: "favorites")
        try await settle(host.controller.view)
        XCTAssertNil(frames["toolbar-history"])

        model.navigate(to: "recent")
        try await settle(host.controller.view)
        let backOnly = try XCTUnwrap(frames["toolbar-history"])
        XCTAssertGreaterThanOrEqual(backOnly.width, 30)
        XCTAssertGreaterThanOrEqual(backOnly.height, 30)
        XCTAssertTrue(model.canNavigateBack)
        XCTAssertFalse(model.canNavigateForward)
        model.showDetail(try XCTUnwrap(model.items.first))
        try await settle(host.controller.view)
        XCTAssertNotNil(model.detail)
        XCTAssertNotNil(frames["toolbar-history"])
        model.navigateBack()
        try await settle(host.controller.view)
        XCTAssertNil(model.detail)
        XCTAssertTrue(model.canNavigateBack && model.canNavigateForward)
        let both = try XCTUnwrap(frames["toolbar-history"])
        XCTAssertGreaterThan(both.width, backOnly.width + 15, "A lone arrow must not reserve a second button's width")
        for tab in ["favorites", "home"] {
            model.navigateBack()
            try await settle(host.controller.view)
            XCTAssertEqual(model.page, tab)
            XCTAssertTrue(model.canNavigateBack && model.canNavigateForward, "History stays available to navigation commands")
            XCTAssertNil(frames["toolbar-history"], "The screenshot's home-with-forward-history must still show only the tabs")
        }
        model.navigateBack()
        try await settle(host.controller.view)
        XCTAssertEqual(model.page, "library")
        XCTAssertTrue(model.canNavigateForward)
        XCTAssertFalse(model.canNavigateBack)
        XCTAssertEqual(try XCTUnwrap(frames["toolbar-history"]).width, backOnly.width, accuracy: 2)
        await model.shutdown()
    }

    @MainActor
    func testSidebarCollapseAndPreferredWidthKeepRootRoutesWithinSupportedWindows() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820), NSSize(width: 1607, height: 978)] {
            let model = try makeFixture(connectionName: String(repeating: "长名称合成媒体服务器", count: 5))
            var preferences = model.applicationPreferences
            preferences.sidebarWidth = 320
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            var anchoredToggle: CGRect?
            for route in ["home", "library", "detail"] {
                model.page = route == "detail" ? "library" : route
                model.detail = route == "detail" ? model.items[0] : nil
                for collapsed in [false, true, false] {
                    preferences = model.applicationPreferences
                    preferences.sidebarCollapsed = collapsed
                    XCTAssertTrue(model.updateApplicationPreferences(preferences))
                    try await settleNavigationChange(host.controller.view)
                    let pane = try XCTUnwrap(frames["sidebar-pane"])
                    let content = try XCTUnwrap(frames["content"])
                    let expectedWidth: CGFloat = collapsed ? 0 : (size.width == 930 ? 192 : 320)
                    XCTAssertEqual(pane.width, expectedWidth, accuracy: 0.5, "\(route) must honor the visible pane width")
                    XCTAssertEqual(content.minX, expectedWidth, accuracy: 0.5)
                    XCTAssertEqual(content.maxX, size.width, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(content.width, 738 - 0.5)
                    XCTAssertEqual(model.applicationPreferences.sidebarWidth, 320,
                                   "Presentation clamping and collapse must not rewrite the stored preference")
                    let toolbar = try XCTUnwrap(frames["navigation-toolbar"])
                    let toggle = try XCTUnwrap(frames["sidebar-toggle"])
                    let refresh = try XCTUnwrap(frames["toolbar-refresh"])
                    XCTAssertEqual(toggle.width, 36, accuracy: 0.5)
                    XCTAssertEqual(toggle.height, 36, accuracy: 0.5)
                    XCTAssertTrue(toolbar.insetBy(dx: -0.5, dy: -0.5).contains(toggle))
                    XCTAssertTrue(toolbar.insetBy(dx: -0.5, dy: -0.5).contains(refresh))
                    if let anchoredToggle {
                        XCTAssertEqual(toggle, anchoredToggle, "The same window point must toggle the sidebar on every route")
                    } else {
                        anchoredToggle = toggle
                    }
                    if collapsed {
                        let source = try XCTUnwrap(frames["toolbar-source"])
                        XCTAssertTrue(toolbar.insetBy(dx: -0.5, dy: -0.5).contains(source))
                        XCTAssertGreaterThanOrEqual(source.minX, toggle.maxX + 8)
                    } else {
                        XCTAssertNil(frames["toolbar-source"], "The expanded sidebar already identifies the current server")
                    }
                    if route == "home" {
                        XCTAssertNil(frames["toolbar-history"])
                        let tabs = try XCTUnwrap(frames["toolbar-tabs"])
                        XCTAssertEqual(tabs.midX, content.midX, accuracy: 1)
                        XCTAssertLessThanOrEqual(tabs.maxX, refresh.minX)
                    } else if !collapsed {
                        XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["toolbar-history"]).minX, content.minX)
                    }
                    assertVerticalScrollDocumentsFit(host.controller.view, route: "\(route), collapsed=\(collapsed)")
                    XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).width, size.width + 1)
                    XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).height, size.height + 1)
                    if collapsed {
                        try savePreviewIfRequested(host.controller.view, name: "stage2-\(route)-collapsed-\(Int(size.width))")
                    }
                }
            }
            await model.shutdown()
        }
    }

    @MainActor
    func testSidebarChangesPreserveMountedLibraryAndScrolledDetailReturnPosition() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820), NSSize(width: 1607, height: 978)] {
            let model = try makeFixture()
            model.page = "library"
            var preferences = model.applicationPreferences
            preferences.sidebarWidth = 320
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            let host = makeHost(model: model, size: size)
            defer { host.window.contentViewController = nil; host.window.close() }
            try await settleNavigationChange(host.controller.view)
            let scroll = try XCTUnwrap(libraryScroll(in: host.controller.view))
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 350))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settleNavigationChange(host.controller.view)
            let position = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(position, 300, "Exercise a real scrolled library before altering its navigation")
            for collapsed in [true, false, true] {
                preferences = model.applicationPreferences
                preferences.sidebarCollapsed = collapsed
                XCTAssertTrue(model.updateApplicationPreferences(preferences))
                try await settleNavigationChange(host.controller.view)
                XCTAssertTrue(libraryScroll(in: host.controller.view) === scroll,
                              "A sidebar layout change must not replace the browsing scroll view")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, position, accuracy: 1)
            }
            model.detail = model.items[9]
            try await settleNavigationChange(host.controller.view)
            preferences = model.applicationPreferences
            preferences.sidebarCollapsed = false
            preferences.sidebarWidth = 192
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            try await settleNavigationChange(host.controller.view)
            model.dismissDetail()
            try await settleNavigationChange(host.controller.view)
            XCTAssertTrue(libraryScroll(in: host.controller.view) === scroll)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, position, accuracy: 1,
                           "Resizing behind a detail must retain the original library position on return")
            assertVerticalScrollDocumentsFit(host.controller.view, route: "library after collapsed detail")
            await model.shutdown()
        }
    }

    @MainActor
    func testCollapsedImmersiveHomeKeepsToolbarClearOfWindowControlsAndReusesArtwork() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820), NSSize(width: 1607, height: 978)] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            fixture.server.configureArtwork(try solidArtwork(.white))
            let model = fixture.model
            var preferences = model.applicationPreferences
            preferences.sidebarWidth = 320
            preferences.sidebarCollapsed = true
            preferences.autoRotateHomeRecommendations = false
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            var artwork: HomeArtworkSnapshot?
            var frames: [String: CGRect] = [:]
            let host = makeHost(model: model, size: size, artworkReport: { artwork = $0 }, sidebarReport: { frames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            model.refresh()
            try await waitUntil("Synthetic hero and catalog must load before testing collapsed chrome") {
                artwork != nil && model.catalogComplete && !model.loading
            }
            try await settleNavigationChange(host.controller.view)
            let input = try XCTUnwrap(heroInput(in: host.controller.view))
            let scroll = try XCTUnwrap(input.enclosingScrollView)
            let inputFrame = input.convert(input.bounds, to: host.controller.view)
            XCTAssertEqual(inputFrame.minX, 0, accuracy: 1)
            XCTAssertEqual(inputFrame.maxX, size.width, accuracy: 1)
            XCTAssertEqual(inputFrame.minY, 0, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(frames["sidebar-pane"]).width, 0, accuracy: 0.5)
            let show = try XCTUnwrap(frames["sidebar-toggle"])
            let source = try XCTUnwrap(frames["toolbar-source"])
            let search = try XCTUnwrap(frames["toolbar-search"])
            let refresh = try XCTUnwrap(frames["toolbar-refresh"])
            for control in [show, source, search, refresh] {
                XCTAssertGreaterThanOrEqual(control.minX, 0)
                XCTAssertLessThanOrEqual(control.maxX, size.width)
                XCTAssertGreaterThanOrEqual(control.minY, 0)
                XCTAssertGreaterThanOrEqual(control.height, 30)
            }
            XCTAssertGreaterThanOrEqual(source.minX, show.maxX + 8)
            XCTAssertGreaterThanOrEqual(refresh.minX, source.maxX)
            XCTAssertGreaterThanOrEqual(search.minX, refresh.maxX)
            let requests = fixture.server.heroArtworkRequestsByItem
            try savePreviewIfRequested(host.controller.view, name: "stage2-hero-collapsed-\(Int(size.width))")
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 160))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settleNavigationChange(host.controller.view)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 70, "Exercise a real scroll beyond the controls")
            XCTAssertEqual(frames["sidebar-toggle"], show)
            XCTAssertEqual(frames["toolbar-source"], source)
            XCTAssertEqual(frames["toolbar-search"], search)
            XCTAssertEqual(frames["toolbar-refresh"], refresh)
            preferences = model.applicationPreferences
            preferences.sidebarCollapsed = false
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            try await settleNavigationChange(host.controller.view)
            XCTAssertTrue(heroInput(in: host.controller.view)?.enclosingScrollView === scroll)
            XCTAssertEqual(frames["sidebar-toggle"], show)
            XCTAssertNil(frames["toolbar-source"])
            let expandedPane = try XCTUnwrap(frames["sidebar-pane"])
            XCTAssertEqual(expandedPane.width, size.width == 930 ? 192 : 320, accuracy: 0.5)
            XCTAssertEqual(fixture.server.heroArtworkRequestsByItem, requests,
                           "Changing chrome geometry must reuse the already loaded current and neighboring artwork")
            XCTAssertEqual(fixture.server.unexpectedPaths, [])
            assertVerticalScrollDocumentsFit(host.controller.view, route: "immersive home after sidebar expansion")
            await model.shutdown()
        }
    }

    @MainActor
    func testSidebarToggleClearsNativeWindowButtonsAtTheSamePointInBothStates() async throws {
        let model = try makeFixture()
        var frames: [String: CGRect] = [:]
        var coordinateAnchor: NSView?
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650),
                            windowStyle: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            sidebarReport: { frames = $0 }, coordinateAnchor: { coordinateAnchor = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        var anchor: CGRect?
        for (collapsed, width) in [(false, 930.0), (true, 1220.0), (false, 930.0)] {
            host.window.setContentSize(NSSize(width: width, height: 650))
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = collapsed
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            try await settleNavigationChange(host.controller.view)
            let reference = try XCTUnwrap(coordinateAnchor)
            let view = host.controller.view
            let nativeRoot = reference.convert(reference.bounds, to: view)
            let toggle = try XCTUnwrap(frames["sidebar-toggle"]).offsetBy(dx: nativeRoot.minX, dy: nativeRoot.minY)
            let windowTop = try XCTUnwrap(frames["sidebar-pane"]).minY
            let column = try XCTUnwrap(frames["content"])
            XCTAssertEqual(column.minY, windowTop, accuracy: 1,
                           "The full-height detail column must begin behind the title bar")
            if !collapsed {
                let firstGroup = try XCTUnwrap(frames["media-header"])
                XCTAssertEqual(firstGroup.midY - windowTop,
                               SeatSixSidebarMetrics.titlebarHeight + SeatSixSidebarMetrics.rowHeight / 2, accuracy: 1,
                               "Reserve title-bar clearance exactly once inside the sidebar column")
            }
            XCTAssertGreaterThanOrEqual(toggle.width, 35, "Measure the native button, including the area that accepts a click")
            XCTAssertEqual(toggle.width, toggle.height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(toggle.minY, -1)
            XCTAssertLessThanOrEqual(toggle.maxY, 54, "Keep the toggle in the window's title-bar row")
            let toolbar = try XCTUnwrap(frames["navigation-toolbar"]).offsetBy(dx: nativeRoot.minX, dy: nativeRoot.minY)
            XCTAssertGreaterThanOrEqual(toggle.minY, toolbar.minY + 1 - 0.5)
            XCTAssertNil(frames["toolbar-history"])
            for key in ["toolbar-tabs", "toolbar-refresh", "toolbar-search"] {
                let control = try XCTUnwrap(frames[key]).offsetBy(dx: nativeRoot.minX, dy: nativeRoot.minY)
                XCTAssertEqual(control.midY, toggle.midY, accuracy: 0.5)
            }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(host.window.standardWindowButton(kind))
                let lights = button.convert(button.bounds, to: view)
                XCTAssertGreaterThan(lights.width, 0)
                let margin = toggle.height / 2 + 1
                let target = min(toolbar.maxY - margin, max(toolbar.minY + margin, lights.midY))
                XCTAssertEqual(toggle.midY, target, accuracy: 0.5,
                               "Align to the system buttons as closely as the full circular hit target allows")
                XCTAssertGreaterThanOrEqual(toggle.minX, lights.maxX + 4)
                XCTAssertFalse(toggle.intersects(lights))
            }
            if let anchor {
                XCTAssertEqual(toggle, anchor)
            } else {
                anchor = toggle
            }
        }
        await model.shutdown()
    }

    @MainActor
    func testNavigationViewportPreferenceIgnoresEmptyAndInvalidSiblingFrames() {
        let measured = CGRect(x: 0, y: -819, width: 1220, height: 819)
        var value = CGRect.zero
        NavigationLayoutKey.reduce(value: &value, nextValue: { measured })
        XCTAssertEqual(value, measured)
        for sibling in [CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 819),
                        CGRect(x: CGFloat.infinity, y: 0, width: 1220, height: 819),
                        CGRect(x: 0, y: 0, width: 1220, height: CGFloat.nan)] {
            NavigationLayoutKey.reduce(value: &value, nextValue: { sibling })
            XCTAssertEqual(value, measured, "A sibling without usable geometry cannot erase the root viewport")
        }
        let resized = CGRect(x: 0, y: -650, width: 930, height: 650)
        NavigationLayoutKey.reduce(value: &value, nextValue: { resized })
        XCTAssertEqual(value, resized, "A genuine subsequent window measurement must still replace the viewport")
    }

    @MainActor
    func testSearchAndDetailRestoreTheNativeToolbarForEachSidebarState() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.refresh()
        try await waitUntil("Home and its searchable library are ready") { model.homeContentReady && !model.items.isEmpty }
        model.navigate(to: "home")
        let movie = try XCTUnwrap(model.items.first)
        let navigation = SeatSixNavigation()
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650), navigation: navigation,
                            sidebarReport: { frames = $0 })
        let view = host.controller.view
        defer { host.window.contentViewController = nil; host.window.close() }

        for collapsed in [true, false] {
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = collapsed
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            try await settleNavigationChange(view)
            XCTAssertNotNil(frames["toolbar-tabs"])
            XCTAssertNotNil(frames["toolbar-search"])
            XCTAssertEqual(frames["toolbar-source"] != nil, collapsed)
            XCTAssertNil(frames["toolbar-history"])

            XCTAssertTrue(navigation.requestSearch(model: model))
            model.searchTerm = movie.name
            try await settleNavigationChange(view)
            XCTAssertEqual(model.page, "searchLibrary")
            let field = try XCTUnwrap(nativeTextFields(in: view).first {
                $0.isEditable && !$0.isHiddenOrHasHiddenAncestor && $0.placeholderString == "搜索"
            })
            XCTAssertEqual(field.stringValue, movie.name)
            let fieldBounds = field.convert(field.bounds, to: view)
            XCTAssertTrue(view.bounds.contains(fieldBounds))
            let back = try XCTUnwrap(frames["toolbar-history"])
            XCTAssertGreaterThan(fieldBounds.minX, back.maxX)
            XCTAssertTrue(model.canNavigateBack)
            XCTAssertFalse(model.canNavigateForward)
            XCTAssertNil(frames["toolbar-source"])
            XCTAssertNil(frames["toolbar-title"])
            XCTAssertNil(frames["toolbar-refresh"])
            XCTAssertNil(frames["toolbar-tabs"])

            model.showDetail(movie)
            try await settleNavigationChange(view)
            XCTAssertEqual(model.detail?.id, movie.id)
            XCTAssertNotNil(frames["toolbar-title"])
            XCTAssertNotNil(frames["toolbar-history"])
            XCTAssertNotNil(frames["toolbar-refresh"])
            XCTAssertEqual(frames["toolbar-source"] != nil, collapsed)

            model.navigateBack()
            try await settleNavigationChange(view)
            XCTAssertNil(model.detail)
            XCTAssertEqual(model.searchTerm, movie.name)
            XCTAssertGreaterThan(try XCTUnwrap(frames["toolbar-history"]).width, back.width + 15)
            XCTAssertNil(frames["toolbar-title"])
            model.cancelSearch()
            try await settleNavigationChange(view)
            XCTAssertEqual(model.page, "home")
            XCTAssertTrue(model.canNavigateForward)
            XCTAssertNil(frames["toolbar-history"])
            XCTAssertNotNil(frames["toolbar-tabs"])
            XCTAssertNotNil(frames["toolbar-refresh"])
            XCTAssertNotNil(frames["toolbar-search"])
            XCTAssertEqual(frames["toolbar-source"] != nil, collapsed)
        }
        await model.shutdown()
    }

    @MainActor
    func testExplicitSearchRequestIsConsumedByMountedFieldWithoutResettingQueryOnCatalogAppend() async throws {
        _ = NSApplication.shared
        let model = try makeFixture()
        model.query = "合成影片"
        let navigation = SeatSixNavigation()
        let host = makeHost(model: model, size: NSSize(width: 1220, height: 820), navigation: navigation)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await settleNavigationChange(host.controller.view)
        XCTAssertFalse(nativeTextFields(in: host.controller.view).contains {
            $0.isEditable && $0.placeholderString == "搜索" && !$0.isHiddenOrHasHiddenAncestor
        })

        XCTAssertTrue(navigation.requestSearch(model: model))
        let requestID = try XCTUnwrap(navigation.searchRequest?.id)
        try await settleNavigationChange(host.controller.view)
        XCTAssertNil(navigation.searchRequest, "The mounted search field must consume the explicit request")
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertEqual(model.query, "合成影片")
        let field = try XCTUnwrap(nativeTextFields(in: host.controller.view).first {
            $0.isEditable && $0.placeholderString == "搜索"
        })
        XCTAssertEqual(field.stringValue, model.searchTerm)
        XCTAssertTrue(field.acceptsFirstResponder)
        XCTAssertFalse(field.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(field.window === host.window)
        XCTAssertTrue(host.controller.view.bounds.intersects(field.convert(field.bounds, to: host.controller.view)),
                      "The requested search field must occupy the actual visible host, not only exist in the view tree")
        XCTAssertEqual(field.stringValue, "", "Home search must not inherit the library filter")
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let textEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        textEditor.insertText("未提交草稿", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settleNavigationChange(host.controller.view)
        XCTAssertEqual(model.searchDraft, "未提交草稿")
        let responder = host.window.firstResponder
        let editor = field.currentEditor()
        let nextItem = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"late-page-item","Name":"合成影片 60","Type":"Movie"}"#.utf8))
        model.items.append(nextItem)
        model.total = model.items.count
        try await settleNavigationChange(host.controller.view)

        let updatedField = try XCTUnwrap(nativeTextFields(in: host.controller.view).first {
            $0.isEditable && $0.placeholderString == "搜索"
        })
        XCTAssertTrue(updatedField === field, "A catalog page must not replace the active native search field")
        XCTAssertEqual(updatedField.stringValue, "未提交草稿")
        XCTAssertTrue(model.searchTerm.isEmpty)
        XCTAssertEqual(model.query, "合成影片")
        XCTAssertNil(navigation.searchRequest, "Catalog progress must not enqueue another focus request")
        XCTAssertFalse(navigation.consumeSearchRequest(model: model, requestID: requestID),
                       "The mounted field's completed request must not be consumable twice")
        XCTAssertTrue(host.window.firstResponder === responder, "Catalog progress must preserve the actual responder")
        // An offscreen window need not own a field editor. When AppKit creates
        // one, assert its identity too; real keyboard focus is checked natively.
        if let editor { XCTAssertTrue(updatedField.currentEditor() === editor) }
        await model.shutdown()
    }

    @MainActor
    func testImmersiveDetailEntryKeepsTransitionGenerationAndReturnSourceAcrossRootLayoutChanges() async throws {
        _ = NSApplication.shared
        for collapsed in [false, true] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            fixture.server.configureArtwork(try solidArtwork(.white))
            let model = fixture.model
            var preferences = model.applicationPreferences
            preferences.sidebarCollapsed = collapsed
            preferences.autoRotateHomeRecommendations = false
            XCTAssertTrue(model.updateApplicationPreferences(preferences))
            let presentation = DetailPresentation()
            var artwork: HomeArtworkSnapshot?
            var rawFrames: [String: CGRect] = [:]
            var sourceFrames: [String: CGRect] = [:]
            var rootFrame = CGRect.zero
            let host = makeHost(model: model, size: NSSize(width: 1220, height: 820),
                detailPresentation: presentation, windowStyle: [.titled, .closable, .resizable, .fullSizeContentView],
                artworkReport: { artwork = $0 },
                rawSidebarReport: { rawFrames = $0 }, layoutReport: { rootFrame = $0 }, sourceReport: { sourceFrames = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            try await settleNavigationChange(host.controller.view)
            model.refresh()
            try await waitUntil("The actual immersive home and its source geometry must be ready") {
                artwork != nil && model.catalogComplete && !model.loading && rootFrame.height > 0
            }
            try await settleNavigationChange(host.controller.view)
            XCTAssertNotNil(artwork, "Titled host must report its loaded current hero; catalogComplete=\(model.catalogComplete), loading=\(model.loading)")
            XCTAssertGreaterThan(rootFrame.height, 0,
                                 "The mounted root must publish its real viewport; frame=\(rootFrame), rawRoot=\(String(describing: rawFrames["test-root"])), rawContent=\(String(describing: rawFrames["content"]))")
            let scroll = try XCTUnwrap(heroInput(in: host.controller.view)?.enclosingScrollView)
            let browseScrollIDs = Set(scrollViews(in: host.controller.view).map(ObjectIdentifier.init))
            let originalPosition = scroll.contentView.bounds.origin
            let item = try XCTUnwrap(model.homeRecommendations.first)
            let sourceID = DetailSourceKey(kind: "hero-detail", itemID: item.id).id
            let sourceFrame = try XCTUnwrap(sourceFrames[sourceID])
            let content = try XCTUnwrap(rawFrames["content"])
            let bounds = CGRect(x: content.minX, y: rootFrame.minY,
                                width: content.width, height: rootFrame.height)
            XCTAssertTrue(DetailTransitionMotion.isVisible(sourceFrame, in: bounds),
                          "The actual hero control must intersect the root viewport; source=\(sourceFrame), bounds=\(bounds), root=\(rootFrame), content=\(content)")
            let scope = try XCTUnwrap(HomeArtworkScope(model: model))
            let browseScope = "\(model.connection?.id.uuidString ?? "")|\(model.selectedLibraryID)"
            let libraryScope = String(reflecting: [browseScope, model.query, model.filterYear.map(String.init) ?? "",
                model.filterGenre ?? "", String(describing: model.watchFilter), String(model.favoritesOnly),
                String(describing: model.sortOrder)])
            let context = String(reflecting: [model.page, libraryScope])
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let openToken = presentation.prepareOpen(itemID: item.id, from: model.detail?.id, sourceID: sourceID,
                scope: scope, context: context, sourceFrame: sourceFrame, bounds: bounds,
                reduceMotion: reduceMotion, restoreFocus: true)
            XCTAssertEqual(presentation.motion.duration, reduceMotion ? 0 : 0.22)
            withAnimation(presentation.motion.animation) { model.showDetail(item) }
            try await settle(host.controller.view)
            XCTAssertEqual(presentation.generation, openToken,
                           "Installing the ordinary detail toolbar must not cancel the entrance generation")
            XCTAssertEqual(presentation.motion.duration, reduceMotion ? 0 : 0.22,
                                 "Root layout changes during normal entry must retain the selected motion")
            try await waitUntil("Synthetic detail metadata must finish") { !model.detailLoading }
            try await settleNavigationChange(host.controller.view)
            XCTAssertEqual(presentation.generation, openToken)
            XCTAssertNotNil(detailScroll(in: host.controller.view, excluding: browseScrollIDs),
                            "Opening detail must mount its native scroll surface")
            XCTAssertTrue(heroInput(in: host.controller.view)?.enclosingScrollView === scroll)
            assertVerticalScrollDocumentsFit(host.controller.view, route: "detail with collapsed=\(collapsed)")

            let detailContent = try XCTUnwrap(rawFrames["content"])
            let returnBounds = CGRect(x: detailContent.minX, y: rootFrame.minY,
                                      width: detailContent.width, height: rootFrame.height)
            let backToken = presentation.prepareBack(from: item.id, to: model.detailBackTargetID,
                scope: scope, context: context, sourceFrames: sourceFrames, bounds: returnBounds, reduceMotion: reduceMotion)
            XCTAssertEqual(presentation.returnFocusRequest?.sourceID, sourceID,
                           "The mounted detail must retain the original hero entrance for keyboard return")
            withAnimation(presentation.motion.animation) { model.goBackFromDetail() }
            try await settleNavigationChange(host.controller.view)
            XCTAssertNil(model.detail)
            XCTAssertEqual(model.page, "home")
            XCTAssertEqual(presentation.generation, backToken,
                           "Restoring immersive chrome must not cancel the return generation")
            XCTAssertTrue(heroInput(in: host.controller.view)?.enclosingScrollView === scroll)
            XCTAssertEqual(scroll.contentView.bounds.origin.x, originalPosition.x, accuracy: 1)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, originalPosition.y, accuracy: 1)
            XCTAssertEqual(fixture.server.unexpectedPaths, [])
            await model.shutdown()
        }
    }

    @MainActor
    func testHomeLibraryAndDetailFitSupportedWindowSizes() async throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820)] {
            let fixture = try makeFixture()
            let host = makeHost(model: fixture, size: size)
            defer { host.window.contentViewController = nil; host.window.close() }
            for route in ["home", "library", "detail"] {
                fixture.detail = route == "detail" ? fixture.items[0] : nil
                fixture.page = route == "home" ? "home" : "library"
                try await settle(host.controller.view)
                let fitting = host.controller.sizeThatFits(in: size)
                XCTAssertGreaterThan(fitting.width, 0)
                XCTAssertLessThanOrEqual(fitting.width, size.width + 1,
                                         "\(route) must not require a wider window at \(size.width) points")
                XCTAssertLessThanOrEqual(fitting.height, size.height + 1,
                                         "\(route) must keep long content inside its scroll view")
                assertVerticalScrollDocumentsFit(host.controller.view, route: route)
                try savePreviewIfRequested(host.controller.view, name: "\(route)-\(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    @MainActor
    func testHomeRecommendationVisibilityChangesLayoutWithoutLosingCatalogOrResumeItems() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        fixture.server.configureResume(count: 3, delay: 0.04)
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650), sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Synthetic home should finish loading") { model.catalogComplete && !model.loading && !model.continuingLoading }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let document = try XCTUnwrap(scroll.documentView)
        let originalHeight = document.bounds.height
        let recommendationIDs = model.homeRecommendations.map(\.id)
        let continuingIDs = model.displayedContinuing.map(\.id)
        XCTAssertEqual(recommendationIDs.count, 10)
        XCTAssertFalse(continuingIDs.isEmpty)
        let initialHero = try XCTUnwrap(heroInput(in: host.controller.view))
        XCTAssertEqual(initialHero.convert(initialHero.bounds, to: host.controller.view).minY, 0, accuracy: 1,
                       "A missing image must retain the full hero layout and its controls")
        try savePreviewIfRequested(host.controller.view, name: "immersive-no-artwork")
        var preferences = model.applicationPreferences
        preferences.autoRotateHomeRecommendations = false
        preferences.showHomeRecommendations = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        try await settle(host.controller.view)
        XCTAssertLessThan(document.bounds.height, originalHeight - 200,
                          "Hiding the banner must remove its layout space and reveal the ordinary home header")
        XCTAssertEqual(model.homeRecommendations.map(\.id), recommendationIDs)
        XCTAssertEqual(model.displayedContinuing.map(\.id), continuingIDs)
        XCTAssertFalse(model.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertFalse(model.libraries.isEmpty)
        XCTAssertNil(heroInput(in: host.controller.view), "The hidden recommendation must not leave an input region behind")
        let toolbar = try XCTUnwrap(frames["navigation-toolbar"])
        XCTAssertGreaterThanOrEqual(scroll.convert(scroll.bounds, to: host.controller.view).minY, toolbar.maxY - 0.5,
                                    "With recommendations hidden, the catalog must start below the persistent toolbar")
        preferences.showHomeRecommendations = true
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        try await settle(host.controller.view)
        XCTAssertEqual(document.bounds.height, originalHeight, accuracy: 2)
        let restoredHero = try XCTUnwrap(heroInput(in: host.controller.view))
        XCTAssertEqual(restoredHero.convert(restoredHero.bounds, to: host.controller.view).minY, 0, accuracy: 1)
        XCTAssertFalse(model.applicationPreferences.autoRotateHomeRecommendations,
                       "Showing recommendations again must preserve the saved rotation choice")
        XCTAssertEqual(model.homeRecommendations.map(\.id), recommendationIDs)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeFirstFrameReservesAllFourSectionsInBothResponseOrders() async throws {
        _ = NSApplication.shared
        for slowCatalog in [false, true] {
            let fixture = makeAPIFixture()
            let server = fixture.server
            server.configureResume(count: 3, delay: 0)
            let pending = DispatchQueue(label: "home-first-frame.delayed-response")
            pending.suspend()
            var released = false
            defer {
                if !released { pending.resume() }
                fixture.session.invalidateAndCancel()
                BrowseLayoutURLProtocol.handler = nil
            }
            BrowseLayoutURLProtocol.handler = { request in
                var reply = server.reply(to: request)
                let suffix = slowCatalog ? "/Items" : "/Items/Resume"
                if request.url?.path.hasSuffix(suffix) == true { reply.deliveryQueue = pending }
                return reply
            }
            let model = fixture.model
            var frames: [String: CGRect] = [:]
            var regions: [ShelfRefreshRegion] = []
            let size = CGSize(width: 1040, height: 1480)
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            let view = host.controller.view
            func snapshot() throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }

            try await settle(view)
            let cold = try snapshot() // First render, before the window's onAppear starts a request.
            let coldRegions = regions
            let coldHero = try XCTUnwrap(coldRegions.first { $0.isBackdrop })
            let lastHeroLine = try XCTUnwrap(coldRegions.filter { !$0.isBackdrop && coldHero.frame.contains($0.frame) }
                .max { $0.frame.maxY < $1.frame.maxY })
            XCTAssertLessThanOrEqual(lastHeroLine.frame.height, 16, "The loading cover ends in a synopsis line")
            XCTAssertGreaterThan(lastHeroLine.frame.width, 250, "A compact fake playback button must not reappear while loading")
            XCTAssertEqual(coldHero.frame.maxY - lastHeroLine.frame.maxY, HomeHeroCarousel.copyBottomInset, accuracy: 1)
            XCTAssertFalse(model.isToolbarRefreshing)
            model.refresh()
            try await waitUntil("The unobstructed response should publish independently") {
                slowCatalog ? (!model.continuingLoading && model.catalogLoading) : (model.catalogComplete && model.continuingLoading)
            }
            try await settle(view)
            let partial = try snapshot()
            pending.resume()
            released = true
            try await waitUntil("Both home requests must settle") { model.homeContentReady }
            try await settle(view)
            let content = try XCTUnwrap(frames["content"])
            let hero = try XCTUnwrap(regions.first { $0.isBackdrop })
            let resume = try XCTUnwrap(regions.first { $0.cornerRadius == 10 && abs($0.frame.width - 254) < 1 })
            let tile = try XCTUnwrap(regions.first { $0.cornerRadius == 12 && $0.frame.height < 90 })
            let poster = try XCTUnwrap(regions.first { $0.cornerRadius == 9 && $0.frame.height > 100 })
            for (placeholder, real) in [
                (coldRegions.first { $0.isBackdrop }, hero),
                (coldRegions.first { $0.cornerRadius == 0 && abs($0.frame.width - 254) < 1 }, resume),
                (coldRegions.first { $0.cornerRadius == 12 && $0.frame.height < 90 }, tile),
                (coldRegions.first { $0.cornerRadius == 9 && $0.frame.height > 100 }, poster)
            ] {
                let reserved = try XCTUnwrap(placeholder)
                XCTAssertEqual(reserved.frame.minY, real.frame.minY, accuracy: 1, "Reserve the final top edge of \(real.frame)")
            }
            func blue(_ bitmap: NSBitmapImageRep, _ region: ShelfRefreshRegion, _ offsetY: CGFloat) throws -> CGFloat {
                let point = CGPoint(x: content.minX + region.frame.midX, y: content.minY + region.frame.minY + offsetY)
                return try renderedColor(bitmap, at: point, viewSize: size).blueComponent
            }
            XCTAssertEqual(try blue(cold, hero, 70), 0.148, accuracy: 0.02, "Hero must start at the final immersive origin")
            for region in [resume, tile, poster] {
                XCTAssertEqual(try blue(cold, region, 7), 0.21, accuracy: 0.03, "The first frame must reserve each real row at \(region.frame)")
                XCTAssertLessThan(try blue(cold, region, -7), 0.14, "The first frame must keep the gap above each real row")
            }
            let pendingCard = slowCatalog ? poster : resume
            XCTAssertEqual(try blue(partial, pendingCard, 7), 0.21, accuracy: 0.03)
            XCTAssertLessThan(try blue(partial, pendingCard, -7), 0.14)
            XCTAssertNil(frames["toolbar-refresh-skeleton"], "An ordinary launch must keep the rest of the window interactive")
            await model.shutdown()
        }
    }

    @MainActor
    func testColdHomeHonorsHiddenSectionsAndRemovesPlaceholdersForAnEmptyAccount() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let server = fixture.server
        BrowseLayoutURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/Views") == true { return .init(body: ["Items": []]) }
            return server.reply(to: request)
        }
        var preferences = model.applicationPreferences
        preferences.showHomeRecommendations = false
        preferences.showRecentlyAdded = false
        XCTAssertTrue(model.updateApplicationPreferences(preferences))
        var regions: [ShelfRefreshRegion] = []
        let host = makeHost(model: model, size: CGSize(width: 1040, height: 1200), shelfReport: { regions = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        try await settle(host.controller.view)
        XCTAssertFalse(regions.contains { $0.isBackdrop || $0.cornerRadius == 9 })
        XCTAssertTrue(regions.contains { $0.cornerRadius == 12 && $0.frame.height < 90 })
        model.refresh()
        try await waitUntil("Empty server view and resume requests must settle") { model.homeContentReady }
        try await settle(host.controller.view)
        XCTAssertTrue(model.libraries.isEmpty && model.displayedContinuing.isEmpty)
        XCTAssertFalse(regions.contains { $0.isBackdrop || $0.cornerRadius == 9 || $0.cornerRadius == 12 ||
            ($0.cornerRadius == 0 && abs($0.frame.width - 254) < 1) })
        await model.shutdown()
    }

    @MainActor
    func testColdHomeKeepsUserScrollAcrossInitialLibraryDiscoveryAndLateResume() async throws {
        let fixture = makeAPIFixture()
        let views = DispatchQueue(label: "initial-home-views"), resume = DispatchQueue(label: "initial-home-progress")
        views.suspend(); resume.suspend()
        var releasedViews = false, releasedResume = false
        defer {
            if !releasedViews { views.resume() }
            if !releasedResume { resume.resume() }
            fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil
        }
        BrowseLayoutURLProtocol.handler = { request in
            var reply = fixture.server.reply(to: request)
            if request.url?.path.hasSuffix("/Views") == true { reply.deliveryQueue = views }
            if request.url?.path.hasSuffix("/Resume") == true { reply.deliveryQueue = resume }
            return reply
        }
        let model = fixture.model, memory = BrowseScrollMemory()
        let host = makeHost(model: model, size: CGSize(width: 930, height: 650), memory: memory)
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await settle(host.controller.view)
        // No carousel input exists yet. Find the vertical page containing the
        // two wide placeholder rails; the library and sidebar do not have them.
        let scroll = try XCTUnwrap(scrollViews(in: host.controller.view).first { scroll in
            guard let document = scroll.documentView, document.bounds.height > scroll.bounds.height else { return false }
            return scrollViews(in: document).filter {
                ($0.documentView?.bounds.width ?? 0) > $0.bounds.width + 10
            }.count >= 2
        })
        let position: CGFloat = 180
        scroll.contentView.scroll(to: CGPoint(x: 0, y: position))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(scroll.contentView.bounds.minY, position, accuracy: 1)
        views.resume(); releasedViews = true
        try await waitUntil("Resolve the library while resume is still pending") { model.catalogComplete && model.continuingLoading }
        try await settle(host.controller.view)
        XCTAssertEqual(scroll.contentView.bounds.minY, position, accuracy: 1)
        resume.resume(); releasedResume = true
        try await waitUntil("All data has replaced the layout placeholders") { model.homeContentReady }
        try await settle(host.controller.view)
        XCTAssertTrue(scroll === homeScroll(in: host.controller.view))
        XCTAssertEqual(scroll.contentView.bounds.minY, position, accuracy: 1)
        await model.shutdown()
    }

    @MainActor
    func testManualRefreshDuringFirstHomeLoadPreservesUnresolvedVisibleCards() async throws {
        let fixture = makeAPIFixture()
        let queue = DispatchQueue(label: "initial-home-resume")
        queue.suspend()
        var released = false
        defer {
            if !released { queue.resume() }
            fixture.session.invalidateAndCancel()
            BrowseLayoutURLProtocol.handler = nil
        }
        fixture.server.configureResume(count: 3, delay: 0, deliveryQueue: queue)
        let model = fixture.model
        let size = CGSize(width: 930, height: 820)
        var regions: [ShelfRefreshRegion] = []
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Only the catalog is ready") { model.catalogComplete && model.continuingLoading }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 280))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 240)
        let resume = try XCTUnwrap(regions.first { $0.cornerRadius == 0 && abs($0.frame.width - 254) < 1 })
        let content = try XCTUnwrap(frames["content"])
        model.refreshFromToolbar()
        try await settle(host.controller.view)
        XCTAssertTrue(model.isToolbarRefreshing)
        let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
        host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
        let point = CGPoint(x: content.minX + resume.visibleFrame.midX, y: content.minY + resume.visibleFrame.midY)
        XCTAssertEqual(try renderedColor(bitmap, at: point, viewSize: size).blueComponent, 0.21, accuracy: 0.03,
                       "The scrolled resume placeholder must still exist in the manual refresh cover")
        queue.resume()
        released = true
        try await waitUntil("Manual refresh finishes after resume arrives") { !model.isToolbarRefreshing && model.homeContentReady }
        await model.shutdown()
    }

    @MainActor
    func testManualRefreshPreservesScrolledLibraryAndServerSearchResults() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let size = CGSize(width: 930, height: 820)
        let model = fixture.model
        var frames: [String: CGRect] = [:]
        var regions: [ShelfRefreshRegion] = []
        let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let root = host.controller.view
        model.refresh()
        try await waitUntil("The library catalog is ready") { model.homeContentReady && model.catalogComplete }
        fixture.server.configureResume(count: 3, delay: 0.9)
        for route in ["searchLibrary", "searchServer"] {
            model.searchTerm = route == "searchLibrary" ? "合成电影" : ""
            model.navigate(to: route)
            if route == "searchServer" {
                try await waitUntil("Server recommendations are ready") { model.serverBrowseComplete }
            }
            try await settleNavigationChange(root)
            func findGrid(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == "search-results-grid" { return view }
                return view.subviews.lazy.compactMap(findGrid).first
            }
            let scroll = try XCTUnwrap(findGrid(root)?.enclosingScrollView)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 421))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(root)
            let offset = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(offset, 400)
            let content = try XCTUnwrap(frames["content"])
            let card = try XCTUnwrap(regions.first { $0.cornerRadius == 9 && $0.frame.height > 80 && $0.frame.minY > 75
                && $0.frame.maxY < content.height })
            let inside = CGPoint(x: content.minX + card.frame.midX, y: content.minY + card.frame.minY + 7)
            let gutter = CGPoint(x: content.minX + card.frame.midX, y: content.minY + card.frame.minY - 4)
            model.refreshFromToolbar()
            try await settle(root)
            XCTAssertTrue(model.isToolbarRefreshing)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            XCTAssertEqual(try renderedColor(bitmap, at: inside, viewSize: size).blueComponent, 0.21, accuracy: 0.03, route)
            XCTAssertLessThan(try renderedColor(bitmap, at: gutter, viewSize: size).blueComponent, 0.13, route)
            try await waitUntil("The search viewport should be released after refresh") { !model.isToolbarRefreshing }
            try await settleNavigationChange(root)
            XCTAssertTrue(findGrid(root)?.enclosingScrollView === scroll)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 2)
        }
        await model.shutdown()
    }

    @MainActor
    func testFirstFrameManualRefreshOfKnownEmptyHomeUsesOnlyVisibleSections() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.saved.connections[0].libraryIDs = []
        // An account with no permitted libraries never issues a resume request.
        // Hold the actual discovery response until the first refresh frame is sampled.
        let viewsDelivery = DispatchQueue(label: "empty-home-first-frame")
        viewsDelivery.suspend()
        var released = false
        defer { if !released { viewsDelivery.resume() } }
        BrowseLayoutURLProtocol.handler = { request in
            var reply = fixture.server.reply(to: request)
            if request.url?.path == "/Users/fixture-user/Views" { reply.deliveryQueue = viewsDelivery }
            return reply
        }
        model.refreshFromToolbar()
        let size = CGSize(width: 930, height: 820)
        var frames: [String: CGRect] = [:]
        let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let root = host.controller.view
        try await settle(root)
        XCTAssertTrue(model.isToolbarRefreshing)
        let content = try XCTUnwrap(frames["content"])
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        // This is a header gutter in the empty home. A fabricated hero
        // would paint it with the much lighter backdrop color.
        let gutter = CGPoint(x: content.maxX - 90, y: content.minY + 70)
        XCTAssertLessThan(try renderedColor(bitmap, at: gutter, viewSize: size).blueComponent, 0.12)
        viewsDelivery.resume()
        released = true
        try await waitUntil("A first-frame empty refresh terminates") { !model.isToolbarRefreshing }
        await model.shutdown()
    }

    @MainActor
    func testColdToolbarRefreshReservesFirstCardBelowHomeAndLibraryHeadings() async throws {
        _ = NSApplication.shared
        for route in ["home", "library"] {
            let fixture = makeAPIFixture()
            defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
            fixture.server.configureResume(count: 3, delay: 1)
            let model = fixture.model
            model.selectedLibraryID = "movies"
            model.page = route
            var frames: [String: CGRect] = [:]
            var regions: [ShelfRefreshRegion] = []
            let size = NSSize(width: 930, height: 820)
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            try await settle(host.controller.view)
            XCTAssertTrue(model.libraries.isEmpty && model.items.isEmpty)
            model.refreshFromToolbar()
            try await waitUntil("Cold manual refresh must present a placeholder in \(route)") {
                frames["toolbar-refresh-skeleton"] != nil
            }
            try await settle(host.controller.view)
            let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
            host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
            let overlay = try XCTUnwrap(frames["toolbar-refresh-skeleton"])
            try await waitUntil("Release the first page after the slow response") {
                model.catalogComplete && model.homeContentReady && !model.isToolbarRefreshing
            }
            try await settleNavigationChange(host.controller.view)
            let card = try XCTUnwrap(regions.first { region in
                if route == "home" { return abs(region.frame.width - 254) < 2 && region.frame.height > 100 }
                return region.cornerRadius == 9 && region.frame.height > 100
            }, "The final real \(route) must have a visible poster")
            // Sample the cached cold frame against the position of the final
            // real card. Both the blank gutter and the poster must align.
            let top = CGPoint(x: overlay.minX + card.frame.midX, y: overlay.minY + card.frame.minY)
            let inside = try renderedColor(bitmap, at: CGPoint(x: top.x, y: top.y + 7), viewSize: size)
            let gutter = try renderedColor(bitmap, at: CGPoint(x: top.x, y: top.y - 7), viewSize: size)
            XCTAssertEqual(inside.blueComponent, 0.21, accuracy: 0.04, "Cold \(route) must reserve the real first poster")
            XCTAssertLessThan(gutter.blueComponent, 0.14, "Cold \(route) must reserve its actual heading and spacing")
            XCTAssertNil(frames["toolbar-refresh-skeleton"])
            await model.shutdown()
        }
    }

    @MainActor
    func testManualRefreshFreezesScrolledHomeRegionsUntilSlowResumeFinishes() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        fixture.server.configureResume(count: 3, delay: 0.02)
        fixture.server.configureArtwork(try solidArtwork(.white))
        let model = fixture.model
        var frames: [String: CGRect] = [:]
        var regions: [ShelfRefreshRegion] = []
        let size = NSSize(width: 930, height: 650)
        let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial catalog and resume rail must be available") {
            model.catalogComplete && model.homeContentReady && model.displayedContinuing.count == 3
        }
        try await settle(host.controller.view)
        XCTAssertNil(frames["toolbar-refresh-skeleton"], "A background load must not masquerade as a manual refresh")
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 270))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        let originalY = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(originalY, 200)
        let content = try XCTUnwrap(frames["content"])
        let railCards = regions.filter { region in
            abs(region.frame.width - 254) < 2 && region.visibleFrame.height >= 50
        }
        XCTAssertGreaterThanOrEqual(railCards.count, 2, "Capture the real visible resume posters before reloading")
        fixture.server.configureResume(count: 3, delay: 0.9)
        model.refreshFromToolbar()
        try await waitUntil("The toolbar action must present a measured skeleton") { frames["toolbar-refresh-skeleton"] != nil }
        try await waitUntil("Exercise the gap between the fast catalog and slow resume response") {
            model.catalogComplete && model.continuingLoading
        }
        try await settle(host.controller.view)
        XCTAssertTrue(model.isToolbarRefreshing)
        let overlay = try XCTUnwrap(frames["toolbar-refresh-skeleton"])
        XCTAssertEqual(overlay.minX, content.minX, accuracy: 1)
        XCTAssertEqual(overlay.maxX, content.maxX, accuracy: 1)
        XCTAssertNil(heroInput(in: host.controller.view),
                     "A horizontal scroll over the skeleton must not reach the hidden carousel's native event monitor")
        let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
        host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
        for card in railCards.prefix(2) {
            let sample = CGPoint(x: overlay.minX + card.visibleFrame.midX, y: overlay.minY + card.visibleFrame.midY)
            let color = try renderedColor(bitmap, at: sample, viewSize: size)
            XCTAssertEqual(color.blueComponent, 0.21, accuracy: 0.04,
                           "The prior resume card must still be a skeleton at its scrolled window position")
        }
        try savePreviewIfRequested(host.controller.view, name: "manual-refresh-scrolled-home")
        try await waitUntil("Remove the skeleton only after the last request has settled") {
            !model.isToolbarRefreshing && frames["toolbar-refresh-skeleton"] == nil
        }
        try await settleNavigationChange(host.controller.view)
        XCTAssertTrue(homeScroll(in: host.controller.view) === scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, originalY, accuracy: 2)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
        await model.shutdown()
    }

    @MainActor
    func testHomeRefreshPreservesOffsetWhileVisibleAndBehindDetail() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Synthetic home catalog should load") { model.catalogComplete && !model.loading }
        XCTAssertEqual(model.homeRecommendations.count, 10, "Return-position coverage must include the large recommendation banner")
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let maximum = try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(maximum, 100, "The home fixture must really overflow the compact window")
        let desired = maximum * 0.8

        for behindDetail in [false, true] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: desired))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(host.controller.view)
            let before = scroll.contentView.bounds.origin.y
            XCTAssertGreaterThan(before, 80)
            if behindDetail {
                model.showDetail(model.items[3])
                try await waitUntil("Synthetic home movie detail should load") { !model.detailLoading }
                try await settle(host.controller.view)
            }

            // Both toolbar refresh and player-close refresh replace the catalog
            // with a shorter placeholder before the same cards come back.
            model.refresh()
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertFalse(model.catalogComplete)
            try await settle(host.controller.view)
            try await waitUntil("Refreshed home content should finish loading") {
                model.catalogComplete && !model.loading && !model.detailLoading
            }
            try await settle(host.controller.view)
            if behindDetail {
                model.goBackFromDetail()
                try await settle(host.controller.view)
            }
            XCTAssertEqual(model.page, "home")
            XCTAssertNil(model.detail)
            XCTAssertEqual(scroll.contentView.bounds.origin.y, before, accuracy: 2,
                           "Home must restore its real offset after \(behindDetail ? "a refresh behind detail" : "a visible refresh")")
        }
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeScrollPositionsAreIsolatedByLibrary() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Synthetic home catalog should load") { model.catalogComplete && !model.loading }
        let other = try JSONDecoder().decode(MediaLibrary.self, from: Data(#"{"Id":"other-movies","Name":"另一合成电影库","CollectionType":"movies"}"#.utf8))
        model.saved.connections[0].libraryIDs.append(other.id)
        model.libraries.append(other)
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let first = (try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height) * 0.8
        scroll.contentView.scroll(to: NSPoint(x: 0, y: first))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 80)

        model.changeLibrary(other.id)
        try await waitUntil("Other synthetic library should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1,
                       "A never-visited home library must not inherit another library's offset")
        let second = first * 0.4
        scroll.contentView.scroll(to: NSPoint(x: 0, y: second))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)

        model.changeLibrary("movies")
        try await waitUntil("Original synthetic library should reload") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, first, accuracy: 2)
        model.changeLibrary(other.id)
        try await waitUntil("Other synthetic library should reload") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, second, accuracy: 2)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeScrollPositionsAreIsolatedByConnection() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let originalConnection = try XCTUnwrap(model.connection)
        var otherConnection = originalConnection
        otherConnection.id = UUID()
        otherConnection.name = "另一合成连接"
        model.saved.connections.append(otherConnection)
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Synthetic home catalog should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let originalScroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let original = (try XCTUnwrap(originalScroll.documentView).bounds.height - originalScroll.contentView.bounds.height) * 0.8
        originalScroll.contentView.scroll(to: NSPoint(x: 0, y: original))
        originalScroll.reflectScrolledClipView(originalScroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(originalScroll.contentView.bounds.origin.y, 80)

        model.switchConnection(otherConnection.id)
        try await waitUntil("Other synthetic connection should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let otherScroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        XCTAssertFalse(otherScroll === originalScroll, "Changing a source really replaces the mounted home view")
        XCTAssertEqual(otherScroll.contentView.bounds.origin.y, 0, accuracy: 1,
                       "A new connection must not inherit a different connection's position, even with the same library ID")
        model.switchConnection(originalConnection.id)
        try await waitUntil("Original synthetic connection should reload") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let restored = try XCTUnwrap(homeScroll(in: host.controller.view))
        XCTAssertEqual(restored.contentView.bounds.origin.y, original, accuracy: 2,
                       "Returning to the original connection must restore its own position")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeRestoresConnectionPositionAfterResumeCardsArriveLaterThanCatalog() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        fixture.server.configureResume(count: 3, delay: 0)
        let model = fixture.model
        let originalConnection = try XCTUnwrap(model.connection)
        var otherConnection = originalConnection
        otherConnection.id = UUID()
        otherConnection.name = "另一合成连接"
        model.saved.connections.append(otherConnection)
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial catalog and resume cards should load") {
            model.catalogComplete && !model.loading && model.continuing.count == 3
        }
        try await settle(host.controller.view)
        let originalScroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let originalMaximum = try XCTUnwrap(originalScroll.documentView).bounds.height - originalScroll.contentView.bounds.height
        let original = originalMaximum * 0.95
        originalScroll.contentView.scroll(to: NSPoint(x: 0, y: original))
        originalScroll.reflectScrolledClipView(originalScroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(originalScroll.contentView.bounds.origin.y, 200,
                             "Start deep enough to detect a reset to the top")

        model.switchConnection(otherConnection.id)
        try await waitUntil("Other connection should load its resume rail") {
            model.catalogComplete && !model.loading && model.continuing.count == 3
        }
        try await settle(host.controller.view)
        XCTAssertEqual(try XCTUnwrap(homeScroll(in: host.controller.view)).contentView.bounds.origin.y, 0, accuracy: 1)

        let resumeDelivery = DispatchQueue(label: "BrowseViewLayoutTests.returningResume")
        let returningScroll: NSScrollView
        resumeDelivery.suspend()
        do {
            defer { resumeDelivery.resume() }
            fixture.server.configureResume(count: 3, delay: 0, deliveryQueue: resumeDelivery)
            model.switchConnection(originalConnection.id)
            try await waitUntil("Catalog should finish before the delayed resume reply") { model.catalogComplete && !model.loading }
            XCTAssertTrue(model.continuingLoading)
            // Keep the resume reply pending beyond the scroll coordinator's
            // retry window so the placeholder geometry can be measured.
            try await Task.sleep(for: .milliseconds(180))
            try await settle(host.controller.view)
            XCTAssertTrue(model.continuing.isEmpty, "The test must exercise a genuinely late resume response")
            returningScroll = try XCTUnwrap(homeScroll(in: host.controller.view))
            let temporaryMaximum = try XCTUnwrap(returningScroll.documentView).bounds.height - returningScroll.contentView.bounds.height
            XCTAssertEqual(temporaryMaximum, originalMaximum, accuracy: 2,
                           "The waiting resume rail must already reserve the final scroll range")
        }
        try await waitUntil("The delayed resume cards should finish loading") { model.continuing.count == 3 }
        try await settle(host.controller.view)
        XCTAssertEqual(returningScroll.contentView.bounds.origin.y, original, accuracy: 2,
                       "Restoration must wait for both catalog and resume geometry after returning to a source")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeReadinessWaitsForCurrentResumeWithoutBlockingCatalogOrTrustingCancelledRequests() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        fixture.server.configureResume(count: 3, delay: 0.5)
        model.refresh()
        try await waitUntil("Catalog should become usable independently of resume") { model.catalogComplete && !model.loading }
        XCTAssertFalse(model.items.isEmpty)
        XCTAssertTrue(model.continuing.isEmpty)
        XCTAssertTrue(model.continuingLoading)
        XCTAssertFalse(model.homeContentReady)

        fixture.server.configureResume(count: 1, delay: 0.5)
        model.refresh()
        try await waitUntil("Replacement catalog should become usable") { model.catalogComplete && !model.loading }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(model.continuingLoading, "Cancellation cleanup from the old request must not release the new request's home readiness")
        XCTAssertFalse(model.homeContentReady)
        try await waitUntil("Only the current resume reply should complete the home") {
            !model.continuingLoading && model.continuing.count == 1
        }
        XCTAssertTrue(model.homeContentReady)

        fixture.server.configureResume(count: 3, delay: 1)
        model.refresh()
        try await waitUntil("Catalog should finish before shutdown") { model.catalogComplete && !model.loading }
        XCTAssertTrue(model.continuingLoading)
        await model.shutdown()
        XCTAssertFalse(model.continuingLoading)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeReadinessSettlesAfterResumeFailureAndEarlyRequestFailures() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        fixture.server.configureResume(count: 0, delay: 0.2, status: 500)
        model.refresh()
        try await waitUntil("A failed resume request should release home readiness") {
            model.homeContentReady && model.errorMessage?.contains("继续观看") == true
        }
        XCTAssertTrue(model.catalogComplete)
        XCTAssertFalse(model.items.isEmpty, "Resume failure must leave the completed catalog usable")
        XCTAssertTrue(model.continuing.isEmpty)

        fixture.server.setCatalogFailure(true)
        fixture.server.configureResume(count: 0, delay: 0.3)
        model.refresh()
        try await waitUntil("Catalog failure should finish before the independent resume request") {
            model.catalogFailed && !model.loading
        }
        XCTAssertTrue(model.continuingLoading)
        XCTAssertFalse(model.homeContentReady)
        try await waitUntil("Independent resume completion should settle the failed home layout") { model.homeContentReady }

        let unavailable = try makeFixture()
        unavailable.saved.selectedID = nil
        unavailable.refresh()
        XCTAssertTrue(unavailable.homeContentReady, "No selected connection must not leave a permanent pending flag")
        unavailable.saved.selectedID = unavailable.saved.connections[0].id
        unavailable.refresh()
        try await waitUntil("Synthetic credential failure should finish the request") { unavailable.catalogFailed && !unavailable.loading }
        XCTAssertTrue(unavailable.homeContentReady, "Failure before starting Resume must also clear its pending state")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHomeFailedRefreshClampsToAvailableContentAndRetryRestoresPosition() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Synthetic home catalog should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(homeScroll(in: host.controller.view))
        let original = (try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height) * 0.8
        scroll.contentView.scroll(to: NSPoint(x: 0, y: original))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 80)

        fixture.server.setCatalogFailure(true)
        model.refresh()
        try await waitUntil("Synthetic catalog failure should be visible") { model.catalogFailed && !model.loading }
        try await settle(host.controller.view)
        let available = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.origin.y, 0)
        XCTAssertLessThanOrEqual(scroll.contentView.bounds.origin.y, available + 1,
                                "Failure must leave a reachable scroll position rather than an empty viewport")
        fixture.server.setCatalogFailure(false)
        model.refresh()
        try await waitUntil("Synthetic retry should finish loading") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, original, accuracy: 2,
                       "A transient short failure page must not replace the remembered browsing position")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testLibraryScrollOffsetSurvivesDetailAndHomeRoundTrips() async throws {
        _ = NSApplication.shared
        let model = try makeFixture()
        model.page = "library"
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(libraryScroll(in: host.controller.view), "The synthetic long library must expose a scrollable document")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height - scroll.contentView.bounds.height, 400)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 350))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        let originalOffset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(originalOffset, 200, "Verify a real scroll happened before checking preservation")

        model.detail = model.items[3]
        try await settle(host.controller.view)
        model.dismissDetail()
        try await settle(host.controller.view)
        XCTAssertTrue(libraryScroll(in: host.controller.view) === scroll,
                      "Opening detail must retain the mounted library NSScrollView")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, originalOffset, accuracy: 1,
                       "Returning from detail must retain the exact browsing position")

        model.page = "home"
        try await settle(host.controller.view)
        model.page = "library"
        try await settle(host.controller.view)
        XCTAssertTrue(libraryScroll(in: host.controller.view) === scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, originalOffset, accuracy: 1,
                       "Switching sidebar routes must not reset the library position")
    }

    @MainActor
    func testLibraryRefreshBehindDetailRestoresThePreviouslyVisibleRow() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.page = "library"
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial synthetic catalog should finish loading") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(libraryScroll(in: host.controller.view))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1600))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        let before = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(before, 1200, "The test must start well below the first poster row")

        model.showDetail(model.items[18])
        try await waitUntil("Synthetic movie detail should load") { !model.detailLoading }
        try await settle(host.controller.view)
        model.refresh()
        XCTAssertTrue(model.items.isEmpty, "Exercise the real empty-catalog phase, not just a mounted detail overlay")
        XCTAssertFalse(model.catalogComplete)
        try await waitUntil("Refreshed synthetic catalog should finish loading") { model.catalogComplete && !model.loading && !model.detailLoading }
        try await settle(host.controller.view)
        model.goBackFromDetail()
        try await settle(host.controller.view)
        let restored = try XCTUnwrap(libraryScroll(in: host.controller.view))
        XCTAssertEqual(model.page, "library")
        XCTAssertNil(model.detail)
        XCTAssertEqual(restored.contentView.bounds.origin.y, before, accuracy: 360,
                       "After catalog replacement the remembered poster row must be within one row, rather than returning to the top")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testRefreshKeepsVisibleColdEpisodeAndMetadataSlotsAtTheirScrolledLocations() async throws {
        for series in [true, false] {
            let fixture = makeAPIFixture()
            let model = fixture.model
            let pending = DispatchQueue(label: "cold-scrolled-detail")
            pending.suspend()
            var released = false
            defer {
                if !released { pending.resume() }
                fixture.session.invalidateAndCancel()
                BrowseLayoutURLProtocol.handler = nil
            }
            model.refresh()
            try await waitUntil("Catalog is available for detail navigation") { model.homeContentReady }
            let item = series
                ? try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
                : try XCTUnwrap(model.items.first)
            let server = fixture.server
            BrowseLayoutURLProtocol.handler = { request in
                var reply = server.reply(to: request)
                if let path = request.url?.path, path.hasSuffix("/" + item.id) || path.hasPrefix("/Shows/") {
                    reply.deliveryQueue = pending
                }
                return reply
            }
            let size = NSSize(width: 930, height: 650)
            var frames: [String: CGRect] = [:], regions: [ShelfRefreshRegion] = []
            let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
            defer { host.window.contentViewController = nil; host.window.close() }
            let view = host.controller.view
            try await settle(view)
            let browseIDs = Set(scrollViews(in: view).map(ObjectIdentifier.init))
            model.showDetail(item)
            if series { model.showAllEpisodes() }
            try await settle(view)
            let scroll = try XCTUnwrap(detailScroll(in: view, excluding: browseIDs))
            let bottom = try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height
            XCTAssertGreaterThan(bottom, 40)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(view)
            XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 40)
            let cards: [ShelfRefreshRegion]
            if series {
                cards = Array(regions.filter { $0.isBackdrop && $0.cornerRadius == 8 && $0.visibleFrame == $0.frame }.prefix(2))
            } else {
                let credit = try XCTUnwrap(regions.first { $0.cornerRadius == 29 && $0.visibleFrame == $0.frame })
                let stream = try XCTUnwrap(regions.first { $0.cornerRadius == 10 && $0.isBackdrop && $0.frame.width == 250 })
                cards = [credit, stream]
            }
            XCTAssertEqual(cards.count, 2, "Two visible cold cards must be measured before refresh")
            XCTAssertTrue(model.isLoadingPresentedDetailMetadata)
            model.refreshFromToolbar()
            try await waitUntil("Cold detail refresh freezes the current viewport") { frames["toolbar-refresh-skeleton"] != nil }
            try await settle(view)
            let overlay = try XCTUnwrap(frames["toolbar-refresh-skeleton"])
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            for card in cards {
                // Sample the side padding of a panel, away from its inset text and artwork.
                let x = card.isBackdrop ? card.visibleFrame.minX + 4 : card.visibleFrame.midX
                let point = CGPoint(x: overlay.minX + x, y: overlay.minY + card.visibleFrame.midY)
                let sample = try renderedColor(bitmap, at: point, viewSize: size)
                XCTAssertEqual(sample.blueComponent, card.isBackdrop ? 0.148 : 0.21, accuracy: 0.025)
            }
            pending.resume()
            released = true
            try await waitUntil("Resolving native jobs releases the cover") { !model.isToolbarRefreshing && !model.detailLoading }
            await model.shutdown()
        }
    }

    @MainActor
    func testManualRefreshHoldsVisibleEpisodeRowsAfterDeepScroll() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let size = NSSize(width: 930, height: 650)
        var frames: [String: CGRect] = [:]
        var regions: [ShelfRefreshRegion] = []
        let host = makeHost(model: model, size: size, sidebarReport: { frames = $0 }, shelfReport: { regions = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial catalog is ready") { model.homeContentReady }
        try await settle(host.controller.view)
        let browseIDs = Set(scrollViews(in: host.controller.view).map(ObjectIdentifier.init))
        let series = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
        model.showDetail(series)
        try await waitUntil("Series rows are ready") { !model.seriesLoading && !model.detailLoading && model.seasons.count == 2 }
        model.selectSeason("season-2")
        model.showAllEpisodes()
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseIDs))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1700))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 1300)
        let rows = regions.filter { $0.isBackdrop && $0.cornerRadius == 8 && $0.visibleFrame.height > 45 }
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        fixture.server.configureResume(count: 0, delay: 1.2)
        model.refreshFromToolbar()
        try await waitUntil("Deep detail viewport has a skeleton") { frames["toolbar-refresh-skeleton"] != nil }
        try await settle(host.controller.view)
        let overlay = try XCTUnwrap(frames["toolbar-refresh-skeleton"])
        let bitmap = try XCTUnwrap(host.controller.view.bitmapImageRepForCachingDisplay(in: host.controller.view.bounds))
        host.controller.view.cacheDisplay(in: host.controller.view.bounds, to: bitmap)
        for row in rows.prefix(2) {
            let point = CGPoint(x: overlay.minX + row.visibleFrame.midX, y: overlay.minY + row.visibleFrame.midY)
            let sample = try renderedColor(bitmap, at: point, viewSize: size)
            XCTAssertEqual(sample.blueComponent, 0.148, accuracy: 0.035, "Each original episode row is drawn in its pre-refresh position")
        }
        try await waitUntil("Series refresh settles") { !model.isToolbarRefreshing }
        try await settleNavigationChange(host.controller.view)
        XCTAssertEqual(model.selectedSeasonID, "season-2")
        XCTAssertTrue(detailScroll(in: host.controller.view, excluding: browseIDs) === scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, offset, accuracy: 2)
        await model.shutdown()
    }

    @MainActor
    func testAllEpisodesReturnsToPreviewAndRemembersSelectedEpisodeAcrossHistory() async throws {
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.refresh()
        try await waitUntil("Fixture catalog") { model.homeContentReady }
        let series = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
        model.showDetail(series)
        try await waitUntil("Series details") { !model.seriesLoading && !model.detailLoading && model.seasons.count == 2 }
        model.selectSeason("season-2")
        let chosen = model.episodes[20]
        model.showAllEpisodes()
        XCTAssertTrue(model.seriesPresentation.showsAll)
        model.preview(chosen)
        XCTAssertFalse(model.seriesPresentation.showsAll)
        XCTAssertEqual(model.seriesPresentation.batch, 2)
        XCTAssertEqual(model.seriesPlaybackCandidate?.id, chosen.id)
        model.showAllEpisodes()
        model.navigateBack()
        try await waitUntil("Return to detail") { !model.seriesLoading && !model.detailLoading }
        XCTAssertFalse(model.seriesPresentation.showsAll)
        XCTAssertEqual(model.previewEpisode?.id, chosen.id)
        model.navigateForward()
        try await waitUntil("Forward to full season") { !model.seriesLoading && !model.detailLoading }
        XCTAssertTrue(model.seriesPresentation.showsAll)
        model.showDetail(chosen)
        try await waitUntil("Episode detail") { !model.detailLoading }
        model.goBackFromDetail()
        try await waitUntil("Return to full season") { !model.seriesLoading && !model.detailLoading }
        XCTAssertTrue(model.seriesPresentation.showsAll)
        XCTAssertEqual(model.selectedSeasonID, "season-2")
        model.goBackFromDetail()
        XCTAssertFalse(model.seriesPresentation.showsAll)
        model.selectSeason("season-1")
        XCTAssertEqual(model.seriesPresentation.batch, 0)
        XCTAssertNil(model.previewEpisode)
        await model.shutdown()
    }

    @MainActor
    func testSeriesEpisodeRoundTripRestoresSeasonAndVisibleEpisodeThenRemembersReturnToTop() async throws {
        _ = NSApplication.shared
        let fixture = makeAPIFixture()
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        model.page = "library"
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650))
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial synthetic catalog should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let browseScrollIDs = Set(scrollViews(in: host.controller.view).map(ObjectIdentifier.init))
        let series = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
        model.showDetail(series)
        try await waitUntil("All synthetic seasons and episodes should load") { !model.seriesLoading && !model.detailLoading && model.seasons.count == 2 }
        model.selectSeason("season-2")
        model.showAllEpisodes()
        try await settle(host.controller.view)
        XCTAssertEqual(model.episodes.count, 60)
        let seriesScroll = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseScrollIDs))
        let documentHeight = try XCTUnwrap(seriesScroll.documentView).bounds.height
        seriesScroll.contentView.scroll(to: NSPoint(x: 0, y: 1700))
        seriesScroll.reflectScrolledClipView(seriesScroll.contentView)
        try await settle(host.controller.view)
        let before = seriesScroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(before, 1300)
        let oneEpisodeRow = ceil(documentHeight / CGFloat(model.episodes.count)) + 20
        let episode = model.episodes[12]
        model.showDetail(episode)
        try await waitUntil("Synthetic episode detail should load") { model.detail?.id == episode.id && !model.detailLoading }
        try await settle(host.controller.view)
        model.goBackFromDetail()
        try await waitUntil("Returning should reload the remembered season") {
            model.detail?.id == series.id && !model.seriesLoading && !model.detailLoading && model.selectedSeasonID == "season-2"
        }
        try await settle(host.controller.view)
        let restored = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseScrollIDs))
        XCTAssertEqual(model.episodes.first?.seasonID, "season-2")
        XCTAssertEqual(restored.contentView.bounds.origin.y, before, accuracy: oneEpisodeRow,
                       "Returning from episode detail must restore the previously visible episode row")

        // Going back to the synopsis is an intentional new position. A stale
        // episode anchor must not pull the next visit down into the season list.
        restored.contentView.scroll(to: .zero)
        restored.reflectScrolledClipView(restored.contentView)
        try await settle(host.controller.view)
        XCTAssertEqual(restored.contentView.bounds.origin.y, 0, accuracy: 1)
        model.showDetail(episode)
        try await waitUntil("Episode should reopen") { model.detail?.id == episode.id && !model.detailLoading }
        try await settle(host.controller.view)
        model.goBackFromDetail()
        try await waitUntil("Series should return after the second episode visit") {
            model.detail?.id == series.id && !model.seriesLoading && !model.detailLoading && model.selectedSeasonID == "season-2"
        }
        try await settle(host.controller.view)
        let top = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseScrollIDs))
        XCTAssertEqual(top.contentView.bounds.origin.y, 0, accuracy: 40,
                       "Returning after scrolling to the synopsis must not restore the stale episode anchor")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testExpandedSeriesOverviewAndEpisodePositionSurviveEpisodeDetailRoundTrip() async throws {
        _ = NSApplication.shared
        let longOverview = (1...18).map { paragraph in
            "第 \(paragraph) 段合成简介。沿海小城的居民踏上漫长旅程，在不同季节里寻找失散的朋友，记录熟悉街道与陌生风景的变化。这些文字仅用于验证展开简介后，返回详情仍保持相同的内容高度与分集浏览位置。"
        }.joined(separator: "\n\n")
        let fixture = makeAPIFixture(seriesOverview: longOverview)
        defer { fixture.session.invalidateAndCancel(); BrowseLayoutURLProtocol.handler = nil }
        let model = fixture.model
        let memory = BrowseScrollMemory()
        model.page = "library"
        let host = makeHost(model: model, size: NSSize(width: 930, height: 650), memory: memory)
        defer { host.window.contentViewController = nil; host.window.close() }
        model.refresh()
        try await waitUntil("Initial synthetic catalog should load") { model.catalogComplete && !model.loading }
        try await settle(host.controller.view)
        let browseScrollIDs = Set(scrollViews(in: host.controller.view).map(ObjectIdentifier.init))
        let series = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: fixture.server.series))
        let detailScope = "\(try XCTUnwrap(model.connection).id.uuidString)|\(series.id)"
        model.showDetail(series)
        try await waitUntil("Long-overview series and its episodes should load") {
            !model.seriesLoading && !model.detailLoading && model.seasons.count == 2
        }
        model.selectSeason("season-2")
        try await settle(host.controller.view)
        let seriesScroll = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseScrollIDs))
        let collapsedHeight = try XCTUnwrap(seriesScroll.documentView).bounds.height
        XCTAssertFalse(memory.overviewExpanded(for: detailScope))

        // This is the same published state changed by the synopsis disclosure
        // button. Measure its visible layout effect before exercising navigation.
        memory.setOverviewExpanded(true, for: detailScope)
        try await settle(host.controller.view)
        let expandedHeight = try XCTUnwrap(seriesScroll.documentView).bounds.height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight + 400,
                             "The synthetic synopsis must add enough height to expose a collapsed-on-return regression")
        seriesScroll.contentView.scroll(to: NSPoint(x: 0, y: expandedHeight - seriesScroll.contentView.bounds.height))
        seriesScroll.reflectScrolledClipView(seriesScroll.contentView)
        try await settle(host.controller.view)
        let beforeOffset = seriesScroll.contentView.bounds.origin.y
        let beforeHeight = try XCTUnwrap(seriesScroll.documentView).bounds.height
        XCTAssertGreaterThan(beforeOffset, 400, "Start at the episode rail below the expanded synopsis")

        let episode = model.episodes[12]
        model.showDetail(episode)
        try await waitUntil("Synthetic episode detail should load") { model.detail?.id == episode.id && !model.detailLoading }
        try await settle(host.controller.view)
        model.goBackFromDetail()
        try await waitUntil("Returning should reload the series and remembered season") {
            model.detail?.id == series.id && !model.seriesLoading && !model.detailLoading && model.selectedSeasonID == "season-2"
        }
        try await settle(host.controller.view)
        let restored = try XCTUnwrap(detailScroll(in: host.controller.view, excluding: browseScrollIDs))
        let restoredHeight = try XCTUnwrap(restored.documentView).bounds.height
        XCTAssertTrue(memory.overviewExpanded(for: detailScope), "The synopsis disclosure must remain expanded after returning")
        XCTAssertGreaterThan(restoredHeight, collapsedHeight + 400,
                             "Stored disclosure state must also restore the actual expanded content geometry")
        XCTAssertEqual(restoredHeight, beforeHeight, accuracy: 2,
                       "The same episode position requires the same expanded synopsis height")
        XCTAssertEqual(restored.contentView.bounds.origin.y, beforeOffset, accuracy: 2,
                       "Returning must preserve the episode position measured with the synopsis expanded")
        XCTAssertEqual(model.episodes.first?.seasonID, "season-2")
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    @MainActor
    func testHiddenBrowseRoutesAreNotExposedToAccessibility() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let model = try makeFixture()
        let host = makeHost(model: model, size: NSSize(width: 1220, height: 820))
        defer { host.window.contentViewController = nil; host.window.close() }
        host.window.orderFront(nil)
        try await settle(host.controller.view)
        let home = accessibilityIdentifiers(in: host.controller.view)
        XCTAssertTrue(home.contains("home-scroll"), "The visible home scroll must be present in the mounted window's accessibility tree")
        XCTAssertFalse(home.contains("library-scroll"))
        XCTAssertFalse(home.contains("library-search"))

        model.page = "library"
        try await settle(host.controller.view)
        let library = accessibilityIdentifiers(in: host.controller.view)
        XCTAssertTrue(library.contains("library-scroll"))
        XCTAssertTrue(library.contains("library-search"))
        XCTAssertFalse(library.contains("home-scroll"))

        model.detail = model.items[0]
        try await settle(host.controller.view)
        let detail = accessibilityIdentifiers(in: host.controller.view)
        XCTAssertTrue(detail.contains("toolbar-back"))
        XCTAssertFalse(detail.contains("home-scroll"))
        XCTAssertFalse(detail.contains("library-scroll"))
        XCTAssertFalse(detail.contains("library-search"))
    }

    @MainActor
    private func makeFixture(connectionName: String = "界面验收 · 合成片库") throws -> ApplicationModel {
        let connection = ServerConnection(kind: .emby, name: connectionName, baseURL: URL(string: "https://never-request.invalid")!,
                                          serverID: "fixture-server", userID: "fixture-user", username: "fixture-only", libraryIDs: ["movies", "series"])
        var saved = SavedApplication()
        saved.connections = [connection]; saved.selectedID = connection.id
        let vault = CredentialAccess(read: { _ in throw BrowseFixtureError.credentialsUnavailable }, save: { _, _ in }, remove: { _ in })
        let model = ApplicationModel(storage: BrowseFixtureStorage(saved), credentials: vault,
                                     subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("seatsix-ui-layout-unused-\(UUID().uuidString)", isDirectory: true)))
        model.libraries = try JSONDecoder().decode([MediaLibrary].self, from: Data(#"[{"Id":"movies","Name":"电影 · 合成样本","CollectionType":"movies"},{"Id":"series","Name":"剧集 · 合成样本","CollectionType":"tvshows"}]"#.utf8))
        model.selectedLibraryID = "movies"
        model.items = try (0..<60).map { index in
            let json: [String: Any] = [
                "Id": "fixture-\(index)", "Name": index == 0 ? "海岸来信：远行与归途" : String(format: "合成影片 %02d", index), "Type": "Movie",
                "Overview": "这是一份仅供界面验收的合成简介。沿海小城的故事从一次旅程开始，人物在熟悉的街道与陌生的风景中寻找新的生活。所有影片、进度和连接均为测试样本。",
                "ProductionYear": 2020 + index % 7, "Genres": ["剧情", "冒险"], "RunTimeTicks": 5_400_000_0000 as Int64,
                "DateCreated": String(format: "2026-10-%02dT12:00:00Z", 1 + index % 24),
                "UserData": ["PlaybackPositionTicks": index < 3 ? 12_000_000_000 as Int64 : 0, "Played": index % 7 == 6, "IsFavorite": index % 4 == 0]
            ]
            return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        }
        model.continuing = Array(model.items.prefix(3))
        model.total = model.items.count
        return model
    }

    @MainActor
    private func makeAPIFixture(seriesOverview: String? = nil, longMovieCopy: Bool = false)
        -> (model: ApplicationModel, session: URLSession, server: BrowseLayoutServer, storage: BrowseFixtureStorage) {
        let server = BrowseLayoutServer(seriesOverview: seriesOverview, longMovieCopy: longMovieCopy)
        BrowseLayoutURLProtocol.handler = { server.reply(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowseLayoutURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = ServerConnection(kind: .emby, name: "合成验收服务器", baseURL: URL(string: "https://never-request.invalid")!,
                                          serverID: "fixture-server", userID: "fixture-user", username: "fixture-only", libraryIDs: ["movies"])
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id
        let storage = BrowseFixtureStorage(saved)
        return (makeBrowseModel(storage: storage, session: session), session, server, storage)
    }

    @MainActor
    private func makeBrowseModel(storage: BrowseFixtureStorage, session: URLSession) -> ApplicationModel {
        let credentials = CredentialAccess(read: { _ in "synthetic-token" }, save: { _, _ in }, remove: { _ in })
        return ApplicationModel(storage: storage, credentials: credentials,
                                clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) },
                                subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("seatsix-ui-layout-unused-\(UUID().uuidString)", isDirectory: true)))
    }

    @MainActor
    private func makeHost(model: ApplicationModel, size: NSSize, memory: BrowseScrollMemory? = nil,
                          navigation: SeatSixNavigation? = nil, detailPresentation: DetailPresentation? = nil,
                          windowStyle: NSWindow.StyleMask = [.borderless],
                          artworkReport: ((HomeArtworkSnapshot?) -> Void)? = nil,
                          sidebarReport: (([String: CGRect]) -> Void)? = nil,
                          rawSidebarReport: (([String: CGRect]) -> Void)? = nil,
                          shelfReport: (([ShelfRefreshRegion]) -> Void)? = nil,
                          scrolledDetailReport: ((String?) -> Void)? = nil,
                          coordinateAnchor: ((NSView) -> Void)? = nil,
                          layoutReport: ((CGRect) -> Void)? = nil,
                          sourceReport: (([String: CGRect]) -> Void)? = nil,
                          accessibility: (reducedTransparency: Bool, increasedContrast: Bool)? = nil) -> (controller: NSHostingController<AnyView>, window: NSWindow) {
        var content = AnyView(SeatSixRootView(model: model, scrollMemory: memory,
                                         navigation: navigation, detailPresentation: detailPresentation))
        if let accessibility {
            content = AnyView(content.environment(\._accessibilityReduceTransparency, accessibility.reducedTransparency)
                .environment(\._colorSchemeContrast, accessibility.increasedContrast ? .increased : .standard))
        }
        let root = AnyView(content
            .preferredColorScheme(.dark).tint(SeatSixStyle.accent)
            .onPreferenceChange(HomeArtworkPreferenceKey.self) { artworkReport?($0) }
            .onPreferenceChange(ShelfRefreshRegionsKey.self) { shelfReport?($0) }
            .onPreferenceChange(ScrolledDetailKey.self) { scrolledDetailReport?($0) }
            .onPreferenceChange(NavigationLayoutKey.self) { layoutReport?($0) }
            .onPreferenceChange(DetailSourceFrameKey.self) { sourceReport?($0) }
            .background {
                SeatSixSidebarGeometry(id: "test-root")
                if let coordinateAnchor { NativeCoordinateAnchor(report: coordinateAnchor) }
            }
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { measured in
                rawSidebarReport?(measured)
                guard let root = measured["test-root"] else { sidebarReport?([:]); return }
                sidebarReport?(measured.mapValues { $0.offsetBy(dx: -root.minX, dy: -root.minY) })
            }
            .transaction { $0.disablesAnimations = true })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: windowStyle, backing: .buffered, defer: false)
        if accessibility?.increasedContrast == true {
            window.appearance = NSAppearance(named: .accessibilityHighContrastDarkAqua)
        }
        if windowStyle.contains(.fullSizeContentView) {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        return (controller, window)
    }

    /// Shares the measured SwiftUI root's bounds so AppKit's title-bar buttons
    /// and the SwiftUI controls can be compared in the same window coordinates.
    private struct NativeCoordinateAnchor: NSViewRepresentable {
        let report: (NSView) -> Void

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            report(view)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor
    private func settle(_ view: NSView) async throws {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func settleNavigationChange(_ view: NSView) async throws {
        try await settle(view)
        // Exercise the settled result even if a nested value-animation creates
        // its own transaction inside the offscreen host's animation override.
        try await Task.sleep(for: .milliseconds(220))
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func waitUntil(_ message: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    @MainActor
    private func nativeTextFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { nativeTextFields(in: $0) }
    }

    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor
    private func heroInput(in view: NSView) -> HomeCarouselScrollInput.Probe? {
        (view as? HomeCarouselScrollInput.Probe) ?? view.subviews.lazy.compactMap { self.heroInput(in: $0) }.first
    }

    @MainActor
    private func homeScroll(in view: NSView) -> NSScrollView? {
        // Anchor this lookup in the actual home banner. The sidebar and hidden
        // library can both overflow at the same window size.
        heroInput(in: view)?.enclosingScrollView
    }

    @MainActor
    private func libraryScroll(in view: NSView) -> NSScrollView? {
        scrollViews(in: view).filter { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 400 }
            .max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    @MainActor
    private func detailScroll(in view: NSView, excluding ids: Set<ObjectIdentifier>) -> NSScrollView? {
        scrollViews(in: view).first { !ids.contains(ObjectIdentifier($0)) }
    }

    @MainActor
    private func assertVerticalScrollDocumentsFit(_ view: NSView, route: String, file: StaticString = #filePath, line: UInt = #line) {
        for scroll in scrollViews(in: view) {
            guard let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 1 else { continue }
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1,
                                     "\(route) vertical content must fit its viewport without horizontal clipping", file: file, line: line)
        }
    }

    @MainActor
    private func menuItems(in element: NSObject) -> [(name: String, frame: CGRect)] {
        func attribute(_ name: String) -> Any? {
            element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
        }
        let children = attribute("accessibilityChildren") as? [NSObject] ?? []
        var items = children.flatMap { menuItems(in: $0) }
        if let role = attribute("accessibilityRole") as? String, ["AXMenuButton", "AXPopUpButton"].contains(role) {
            let name = ["accessibilityLabel", "accessibilityTitle"]
                .compactMap { attribute($0) as? String }.first { !$0.isEmpty }
            if let name, let frame = attribute("accessibilityFrame") as? NSValue {
                items.append((name, frame.rectValue))
            }
        }
        return items
    }

    @MainActor
    private func accessibilityIdentifiers(in view: NSView) -> Set<String> {
        var visited: Set<ObjectIdentifier> = []
        var identifiers: Set<String> = []
        func walk(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            // Hosted SwiftUI nodes can implement the accessibility selectors
            // without declaring NSAccessibilityProtocol conformance.
            if element.responds(to: NSSelectorFromString("accessibilityIdentifier")),
               let identifier = element.value(forKey: "accessibilityIdentifier") as? String {
                identifiers.insert(identifier)
            }
            if element.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = element.value(forKey: "accessibilityChildren") as? [NSObject] {
                children.forEach(walk)
            }
        }
        walk(view)
        return identifiers
    }

    @MainActor
    private func savePreviewIfRequested(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SEATSIX_UI_PREVIEW_DIRECTORY"], !directory.isEmpty else { return }
        guard directory.hasPrefix("/") else { throw BrowseFixtureError.previewDirectoryMustBeAbsolute }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func renderedContrast(_ bitmap: NSBitmapImageRep, in region: NSRect, viewSize: NSSize,
                                  darkGlyphs: Bool = false) throws -> Double {
        let scaleX = Double(bitmap.pixelsWide) / viewSize.width
        let scaleY = Double(bitmap.pixelsHigh) / viewSize.height
        var luminances: [Double] = []
        let pixels = try sRGBPixels(bitmap)
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        for y in Int(region.minY * scaleY)..<Int(region.maxY * scaleY) {
            for x in Int(region.minX * scaleX)..<Int(region.maxX * scaleX) {
                let offset = (y * bitmap.pixelsWide + x) * 4
                luminances.append(0.2126 * linear(Double(pixels[offset]) / 255)
                                  + 0.7152 * linear(Double(pixels[offset + 1]) / 255)
                                  + 0.0722 * linear(Double(pixels[offset + 2]) / 255))
            }
        }
        luminances.sort()
        // Compare the median fill with the bright or dark core of the glyphs.
        let ink = luminances[Int(Double(luminances.count - 1) * (darkGlyphs ? 0.02 : 0.98))]
        let fill = luminances[luminances.count / 2]
        return darkGlyphs ? (fill + 0.05) / (ink + 0.05) : (ink + 0.05) / (fill + 0.05)
    }

    private func renderedColor(_ bitmap: NSBitmapImageRep, at point: CGPoint, viewSize: NSSize) throws -> NSColor {
        let x = Int(point.x * Double(bitmap.pixelsWide) / viewSize.width)
        let y = Int(point.y * Double(bitmap.pixelsHigh) / viewSize.height)
        let pixels = try sRGBPixels(bitmap)
        let offset = (y * bitmap.pixelsWide + x) * 4
        return NSColor(srgbRed: Double(pixels[offset]) / 255, green: Double(pixels[offset + 1]) / 255,
                       blue: Double(pixels[offset + 2]) / 255, alpha: Double(pixels[offset + 3]) / 255)
    }

    /// Read the rendered image through a tagged sRGB buffer. AppKit colorAt can
    /// return calibrated RGB even for a tagged bitmap, changing measured gamma.
    private func sRGBPixels(_ bitmap: NSBitmapImageRep) throws -> [UInt8] {
        let image = try XCTUnwrap(bitmap.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    private func assertSameColor(_ actual: NSColor, _ expected: NSColor, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01, message, file: file, line: line)
    }
}

@MainActor
private final class BrowseArtworkSelection: ObservableObject {
    @Published var currentID: String
    init(currentID: String) { self.currentID = currentID }
}

private struct BrowseArtworkPreloadFixture: View {
    @ObservedObject var model: ApplicationModel
    let items: [MediaItem]
    @ObservedObject var selection: BrowseArtworkSelection
    var body: some View {
        ZStack {
            ForEach(items, id: \.id) { item in
                MediaPoster(model: model, item: item, role: .landscape, requestWidth: 1600,
                            reportsHomeArtwork: true, contributesHomeArtwork: item.id == selection.currentID)
                    .opacity(item.id == selection.currentID ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }.frame(width: 400, height: 240)
    }
}

private final class BrowseFixtureStorage: ApplicationPersisting {
    private var value: SavedApplication
    var rejectWrites = false
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws {
        if rejectWrites { throw CocoaError(.fileWriteNoPermission) }
        value = data
    }
}

private enum BrowseFixtureError: Error {
    case credentialsUnavailable
    case previewDirectoryMustBeAbsolute
}

/// A closed synthetic transport: even an unrecognized request is answered here,
/// never passed to a real HTTP stack or to user-configured connections.
private final class BrowseLayoutURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let body: [String: Any]
        var status = 200
        var delay: TimeInterval = 0.04
        var deliveryQueue: DispatchQueue = .global()
        var imageData: Data?
        var didComplete: (() -> Void)?
    }
    static var handler: ((URLRequest) -> Reply)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        response.deliveryQueue.asyncAfter(deadline: .now() + response.delay) { [self] in
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { return }
            do {
                let data = try response.imageData ?? JSONSerialization.data(withJSONObject: response.body)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                                                  headerFields: ["Content-Type": response.imageData == nil ? "application/json" : "image/png"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                response.didComplete?()
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class BrowseLayoutServer: @unchecked Sendable {
    private let lock = NSLock()
    private var unknown: [String] = []
    private var catalogFailure = false
    private var resumeCount = 0
    private var resumeDelay: TimeInterval = 0.04
    private var resumeStatus = 200
    private var resumeDeliveryQueue: DispatchQueue = .global()
    private var artworkData: Data?
    private var artworkByItem: [String: [MediaArtworkSource.ImageType: (data: Data, delay: TimeInterval)]] = [:]
    private var artworkRequestCounts: [String: [MediaArtworkSource.ImageType: [Int: Int]]] = [:]
    private var completedHeroArtwork: Set<String> = []
    var heroArtworkRequestsByItem: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return artworkRequestCounts.compactMapValues { $0[.backdrop]?[1600] }
    }
    func artworkRequestCount(_ type: MediaArtworkSource.ImageType, itemID: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return artworkRequestCounts[itemID]?[type]?.values.reduce(0, +) ?? 0
    }
    var completedHeroArtworkIDs: Set<String> { lock.lock(); defer { lock.unlock() }; return completedHeroArtwork }
    func setMovieResumePosition(_ ticks: Int64) {
        lock.lock(); defer { lock.unlock() }
        for index in movies.indices {
            movies[index]["UserData"] = ["PlaybackPositionTicks": ticks, "Played": false]
        }
    }
    func configureArtwork(_ data: Data) { lock.lock(); artworkData = data; lock.unlock() }
    func configureArtwork(_ data: Data, itemID: String, delay: TimeInterval, type: MediaArtworkSource.ImageType = .backdrop) {
        lock.lock(); artworkByItem[itemID, default: [:]][type] = (data, delay); lock.unlock()
    }
    var unexpectedPaths: [String] { lock.lock(); defer { lock.unlock() }; return unknown }
    func setCatalogFailure(_ value: Bool) { lock.lock(); catalogFailure = value; lock.unlock() }
    func configureResume(count: Int, delay: TimeInterval, status: Int = 200, deliveryQueue: DispatchQueue = .global()) {
        lock.lock(); defer { lock.unlock() }
        resumeCount = count; resumeDelay = delay; resumeStatus = status; resumeDeliveryQueue = deliveryQueue
    }
    let series: [String: Any]
    init(seriesOverview: String? = nil, longMovieCopy: Bool = false) {
        series = ["Id": "long-series", "Name": "合成长篇剧集", "Type": "Series", "ProductionYear": 2026,
                  "Overview": seriesOverview ?? "此剧集包含两季合成分集，用于验证返回时保留选季和浏览位置。"]
        if longMovieCopy {
            movies = movies.map { item in
                var longItem = item
                longItem["Name"] = "横版推荐长标题，用于检查十部推荐在紧凑窗口中的影片信息排版"
                longItem["Overview"] = String(repeating: "很长的合成简介用于确保标题和故事介绍在紧凑窗口中仍有清晰的阅读空间。", count: 8)
                return longItem
            }
        }
    }
    private var movies: [[String: Any]] = (0..<80).map { index in
        ["Id": "movie-\(index)", "Name": String(format: "合成电影 %03d", index), "Type": "Movie", "ProductionYear": 2026,
         "RunTimeTicks": 54_000_000_000 as Int64, "DateCreated": "2026-10-24T12:00:00Z", "Overview": "用于界面验收的合成电影。",
         "BackdropImageTags": ["synthetic-backdrop-\(index)"]]
    }
    private let seasons: [[String: Any]] = (1...2).map { number in
        ["Id": "season-\(number)", "Name": "第 \(number) 季", "Type": "Season", "IndexNumber": number,
         "SeriesId": "long-series", "ParentId": "long-series"]
    }
    private let episodes: [[String: Any]] = (1...2).flatMap { season in
        (1...60).map { number in
            ["Id": "episode-\(season)-\(number)", "Name": String(format: "合成分集 %02d-%02d", season, number), "Type": "Episode",
             "SeriesId": "long-series", "SeriesName": "合成长篇剧集", "SeasonId": "season-\(season)", "ParentId": "season-\(season)",
             "ParentIndexNumber": season, "IndexNumber": number, "RunTimeTicks": 24_000_000_000 as Int64,
             "Overview": "用于验证选季和分集返回位置的合成单集。"]
        }
    }

    func reply(to request: URLRequest) -> BrowseLayoutURLProtocol.Reply {
        let path = request.url?.path ?? ""
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let components = path.split(separator: "/")
        if components.count >= 4, components[0] == "Items", components[2] == "Images",
           let type = MediaArtworkSource.ImageType(rawValue: String(components[3])) {
            let itemID = String(components[1])
            let width = Int(query["MaxWidth"] ?? "") ?? 0
            lock.lock()
            let artwork = artworkByItem[itemID]?[type]?.data ?? artworkData
            let delay = artworkByItem[itemID]?[type]?.delay ?? 0.04
            artworkRequestCounts[itemID, default: [:]][type, default: [:]][width, default: 0] += 1
            lock.unlock()
            return .init(body: [:], status: artwork == nil ? 404 : 200, delay: delay, imageData: artwork,
                         didComplete: { [weak self] in
                guard type == .backdrop, width == 1600, let self else { return }
                self.lock.lock(); self.completedHeroArtwork.insert(itemID); self.lock.unlock()
            })
        }
        if path == "/Users/fixture-user/Views" {
            return .init(body: ["Items": [["Id": "movies", "Name": "合成电影库", "CollectionType": "movies"]]])
        }
        if path == "/Users/fixture-user/Items/Resume" {
            lock.lock()
            let count = resumeCount, delay = resumeDelay, status = resumeStatus, queue = resumeDeliveryQueue
            lock.unlock()
            let rows = movies.prefix(count).map { item in
                var item = item
                item["UserData"] = ["PlaybackPositionTicks": 12_000_000_000 as Int64, "Played": false]
                return item
            }
            return .init(body: ["Items": rows, "TotalRecordCount": rows.count], status: status, delay: delay, deliveryQueue: queue)
        }
        if path == "/Users/fixture-user/Items" {
            lock.lock(); let failed = catalogFailure; lock.unlock()
            return failed ? .init(body: [:], status: 500) : page(movies, query: query)
        }
        if path == "/Shows/long-series/Seasons" { return page(seasons, query: query) }
        if path == "/Shows/long-series/Episodes" { return page(episodes, query: query) }
        if path == "/Users/fixture-user/Items/long-series" { return .init(body: series) }
        if path.hasPrefix("/Users/fixture-user/Items/"),
           let item = (movies + episodes).first(where: { $0["Id"] as? String == request.url?.lastPathComponent }) {
            return .init(body: item)
        }
        lock.lock(); unknown.append(path); lock.unlock()
        return .init(body: [:], status: 404)
    }

    private func page(_ rows: [[String: Any]], query: [String: String]) -> BrowseLayoutURLProtocol.Reply {
        let offset = max(0, Int(query["StartIndex"] ?? "0") ?? 0)
        let limit = max(1, Int(query["Limit"] ?? "100") ?? 100)
        return .init(body: ["Items": Array(rows.dropFirst(offset).prefix(limit)), "StartIndex": offset, "TotalRecordCount": rows.count])
    }
}
