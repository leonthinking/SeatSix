import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

/// Exercises the real route, transport and native clip view using only synthetic
/// connections. A model count alone cannot prove that the grid exposes its tail.
@MainActor
final class ServerBrowseViewTests: XCTestCase {
    func testColdLibraryReservesTheGridAndSidebarRowsBeforeDiscovery() async throws {
        let fixture = makeFixture(countPerLibrary: 4)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        model.saved.connections[0].libraryIDs = ["movies", "series"]
        model.page = "library"
        var sidebar: [String: CGRect] = [:]
        let host = makeHost(model, sidebarReport: { sidebar = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settle(view)
        let firstFrame = try gridFrame("library-grid-loading", in: view)
        let sourceOrigin = try XCTUnwrap(sidebar["source-header"]).minY
        XCTAssertGreaterThan(firstFrame.height, 150)
        XCTAssertNotNil(sidebar["libraries-header"])
        XCTAssertNil(sidebar["library-selection-movies"], "Placeholder rows must not be navigation destinations")
        fixture.server.configure(delay: 0.3)
        model.refresh()
        try await waitUntil("Views should finish before the first catalog page") { !model.libraries.isEmpty }
        try await settle(view)
        let afterViews = try gridFrame("library-grid-loading", in: view)
        XCTAssertEqual(try XCTUnwrap(sidebar["source-header"]).minY, sourceOrigin, accuracy: 1)
        XCTAssertEqual(afterViews.minY, firstFrame.minY, accuracy: 2)
        try await waitUntil("The catalog should replace its reserved grid") { model.catalogComplete }
        try await settle(view)
        XCTAssertEqual(try gridFrame("library-results-grid", in: view).minY, firstFrame.minY, accuracy: 2)
        XCTAssertNil(probe(in: view, identifier: "library-grid-loading"))
    }

    func testServerBrowseAndSearchKeepFirstGridOriginThroughPagination() async throws {
        let fixture = makeFixture(countPerLibrary: 18)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        let view = host.controller.view
        fixture.server.configure(delay: 0.26)
        for route in ["movies", "continuing", "searchServer"] {
            model.searchTerm = route == "searchServer" ? "合成内容" : ""
            model.navigate(to: route)
            try await settle(view)
            let loadingID = route == "searchServer" ? "search-grid-loading" : "server-browse-state-\(route)-loading"
            let readyID = route == "searchServer" ? "search-results-grid" : "server-browse-grid-\(route)"
            let skeleton = try gridFrame(loadingID, in: view)
            XCTAssertGreaterThan(skeleton.height, 150)
            try await waitUntil("The first page must leave another request in flight") {
                model.serverBrowseLoading && !(route == "continuing" ? model.serverContinuingItems : model.serverBrowseCatalogItems).isEmpty
            }
            try await settle(view)
            let partial = try gridFrame(readyID, in: view)
            XCTAssertEqual(partial.minY, skeleton.minY, accuracy: 2, route)
            XCTAssertNil(probe(in: view, identifier: loadingID), "Real results stay visible while later pages load")
            try await waitUntil("All pages should finish") { model.serverBrowseComplete }
            try await settle(view)
            XCTAssertEqual(try gridFrame(readyID, in: view).minY, partial.minY, accuracy: 1, route)
        }
    }

    func testLibrarySearchRecommendationsReserveTheirGridBeforeTheFirstRequest() async throws {
        let fixture = makeFixture(countPerLibrary: 4)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        model.navigate(to: "searchLibrary")
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settle(view)
        let skeleton = try gridFrame("search-grid-loading", in: view)
        XCTAssertNil(probe(in: view, identifier: "search-complete-empty"))
        try await loadHome(model)
        try await settle(view)
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertEqual(try gridFrame("search-results-grid", in: view).minY, skeleton.minY, accuracy: 1)
        XCTAssertNil(probe(in: view, identifier: "search-grid-loading"))
    }

    func testKnownEmptyLibrarySelectionImmediatelyShowsTerminalStates() async throws {
        let fixture = makeFixture()
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        model.saved.connections[0].libraryIDs = []
        fixture.server.configure(delay: 0.8)
        model.page = "library"
        var sidebar: [String: CGRect] = [:]
        let host = makeHost(model, sidebarReport: { sidebar = $0 })
        defer { host.window.contentViewController = nil; host.window.close() }
        let view = host.controller.view
        try await settle(view)
        XCTAssertNil(probe(in: view, identifier: "library-grid-loading"))
        XCTAssertNil(sidebar["libraries-header"])
        for route in ["searchLibrary", "searchServer", "continuing"] {
            model.navigate(to: route)
            try await settle(view)
            if route == "continuing" {
                try assertRenderedState("empty", route: route, in: view)
                XCTAssertNil(probe(in: view, identifier: "server-browse-state-continuing-loading"))
            } else {
                XCTAssertNotNil(probe(in: view, identifier: "search-complete-empty"))
                XCTAssertNil(probe(in: view, identifier: "search-grid-loading"))
            }
        }
        await model.shutdown()
    }

    private func gridFrame(_ identifier: String, in root: NSView) throws -> CGRect {
        let anchor = try XCTUnwrap(probe(in: root, identifier: identifier), identifier)
        return anchor.convert(anchor.bounds, to: try XCTUnwrap(anchor.enclosingScrollView?.documentView))
    }

    func testServerBrowseRoutesRenderAllAuthorizedItemsPastHomeRailLimits() async throws {
        let fixture = makeFixture()
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        model.query = "a query matching none of the synthetic titles"
        model.filterYear = 1901
        model.filterGenre = "不存在的类型"
        model.watchFilter = .watched
        model.favoritesOnly = true
        model.sortOrder = .yearDescending
        let selectedLibraryID = model.selectedLibraryID
        XCTAssertTrue(model.displayedItems.isEmpty, "The fixture must have genuinely restrictive library filters")
        XCTAssertFalse(model.applicationPreferences.showRecentlyAdded)

        for route in ["recent", "continuing", "movies", "series", "other", "favorites"] {
            model.page = route
            try await waitUntil("The \(route) server feed should finish") { model.serverBrowseComplete && !model.serverBrowseLoading }
            try await settle(host.controller.view)
            let items = routeItems(model, route: route)
            XCTAssertEqual(Set(items.map(\.id)), fixture.server.expectedIDs(route: route),
                           "Each route must render the selected server's whole authorized collection")
            XCTAssertGreaterThan(items.count, 20, "This must exercise content beyond both original home rails")
            let last = try XCTUnwrap(items.last)
            let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: route))
            try await assertTailVisible(last.id, route: route, scroll: scroll, in: host.controller.view)
            XCTAssertEqual(model.selectedLibraryID, selectedLibraryID)
            XCTAssertEqual(model.query, "a query matching none of the synthetic titles")
            XCTAssertEqual(model.filterYear, 1901)
            XCTAssertEqual(model.filterGenre, "不存在的类型")
            XCTAssertEqual(model.watchFilter, .watched)
            XCTAssertTrue(model.favoritesOnly)
            XCTAssertEqual(model.sortOrder, .yearDescending)
            XCTAssertTrue(model.displayedItems.isEmpty, "A server route must not clear the library's saved filters")
        }
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    func testServerBrowseNativeScrollSurvivesDetailAndRouteRoundTrip() async throws {
        let fixture = makeFixture()
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        model.page = "continuing"
        try await waitUntil("Continue feed should load") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        let continuing = try XCTUnwrap(routeScroll(in: host.controller.view, route: "continuing"))
        let continuingOffset = try await scrollToFraction(0.55, scroll: continuing, in: host.controller.view)
        let movie = try XCTUnwrap(model.serverContinuingItems.first { $0.type == "Movie" })
        model.showDetail(movie)
        try await waitUntil("Synthetic detail should finish") { !model.detailLoading && model.detail?.id == movie.id }
        try await settle(host.controller.view)
        XCTAssertTrue(routeScroll(in: host.controller.view, route: "continuing") === continuing,
                      "Opening detail must keep the actual server clip view mounted")
        model.goBackFromDetail()
        try await settle(host.controller.view)
        XCTAssertEqual(model.page, "continuing")
        XCTAssertNil(model.detail)
        XCTAssertEqual(continuing.contentView.bounds.origin.y, continuingOffset, accuracy: 2)

        model.page = "recent"
        try await waitUntil("Recent feed should load") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        let recent = try XCTUnwrap(routeScroll(in: host.controller.view, route: "recent"))
        XCTAssertEqual(recent.contentView.bounds.origin.y, 0, accuracy: 1,
                       "A first visit to another route must not inherit Continue Watching's offset")
        let recentOffset = try await scrollToFraction(0.35, scroll: recent, in: host.controller.view)
        model.page = "continuing"
        try await waitUntil("Continue feed should reload") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        let returnedContinue = try XCTUnwrap(routeScroll(in: host.controller.view, route: "continuing"))
        XCTAssertEqual(returnedContinue.contentView.bounds.origin.y, continuingOffset, accuracy: 2)
        model.page = "recent"
        try await waitUntil("Recent feed should reload") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        let returnedRecent = try XCTUnwrap(routeScroll(in: host.controller.view, route: "recent"))
        XCTAssertEqual(returnedRecent.contentView.bounds.origin.y, recentOffset, accuracy: 2)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    func testFixedMediaTypeRoutesKeepIndependentNativeScrollPositions() async throws {
        let fixture = makeFixture()
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        var positions: [String: CGFloat] = [:]
        for (index, route) in ["movies", "series", "other"].enumerated() {
            model.page = route
            try await waitUntil("Type collection \(route) should load") { model.serverBrowseComplete }
            try await settle(host.controller.view)
            let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: route))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
            positions[route] = try await scrollToFraction(0.3 + CGFloat(index) * 0.2, scroll: scroll, in: host.controller.view)
        }
        for route in ["movies", "series", "other"] {
            model.page = route
            try await waitUntil("Type collection \(route) should reload") { model.serverBrowseComplete }
            try await settle(host.controller.view)
            let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: route))
            XCTAssertEqual(scroll.contentView.bounds.origin.y, try XCTUnwrap(positions[route]), accuracy: 2,
                           "Each fixed type needs a separate scroll-memory scope")
        }
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    func testServerBrowseRefreshRestoresOffsetWhileVisibleAndBehindDetail() async throws {
        let fixture = makeFixture()
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        model.page = "recent"
        try await waitUntil("Recent feed should load") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: "recent"))
        let original = try await scrollToFraction(0.65, scroll: scroll, in: host.controller.view)
        for behindDetail in [false, true] {
            if behindDetail {
                model.showDetail(try XCTUnwrap(model.serverRecentItems.first { $0.type == "Movie" }))
                try await waitUntil("Synthetic detail should load") { !model.detailLoading }
                try await settle(host.controller.view)
            }
            model.refreshServerBrowse()
            XCTAssertTrue(model.serverBrowseLoading)
            XCTAssertTrue(model.serverRecentItems.isEmpty)
            try await settle(host.controller.view)
            try await waitUntil("The refreshed collection should finish") { model.serverBrowseComplete && !model.serverBrowseLoading }
            try await settle(host.controller.view)
            if behindDetail {
                model.goBackFromDetail()
                try await settle(host.controller.view)
            }
            let returned = try XCTUnwrap(routeScroll(in: host.controller.view, route: "recent"))
            XCTAssertTrue(returned === scroll)
            XCTAssertEqual(returned.contentView.bounds.origin.y, original, accuracy: 2,
                           "A short loading placeholder must not overwrite the saved offset")
        }
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    func testSearchReturnsToItsScrollOffsetAfterPlaybackCloseRefreshBehindDetail() async throws {
        let fixture = makeFixture(countPerLibrary: 66)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        model.searchTerm = "合成内容"
        model.navigate(to: "searchServer")
        try await waitUntil("Both search pages of both authorized libraries should load") { model.serverBrowseComplete }
        XCTAssertEqual(model.serverBrowseCatalogItems.count, 132)
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: "searchServer"))
        let offset = try await scrollToFraction(0.6, scroll: scroll, in: host.controller.view)
        model.showDetail(try XCTUnwrap(model.serverBrowseCatalogItems.first { $0.type == "Movie" }))
        try await waitUntil("Detail should load") { !model.detailLoading }
        fixture.server.configure(delay: 0.1)
        model.refresh(preservingHomeRecommendations: true)
        try await settle(host.controller.view)
        try await waitUntil("Playback-close refresh should finish") { model.catalogComplete && model.serverBrowseComplete && !model.detailLoading }
        model.navigateBack()
        try await settle(host.controller.view)
        XCTAssertEqual(model.page, "searchServer")
        XCTAssertEqual(model.searchTerm, "合成内容")
        let restored = try XCTUnwrap(routeScroll(in: host.controller.view, route: "searchServer"))
        XCTAssertEqual(restored.contentView.bounds.origin.y, offset, accuracy: 2)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    func testDedicatedSearchFieldWaitsForReturnBeforeReplacingRecommendations() async throws {
        let fixture = makeFixture(countPerLibrary: 4)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        model.navigate(to: "searchLibrary")
        let view = host.controller.view
        try await settle(view)
        func searchField(in node: NSView) -> NSTextField? {
            if let field = node as? NSTextField, field.isEditable, field.placeholderString == "搜索" { return field }
            return node.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let field = try XCTUnwrap(searchField(in: view))
        XCTAssertTrue(host.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let unmatched = "UNMATCHED-SEATSIX-MERGE"
        editor.insertText(unmatched, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await settle(view)
        XCTAssertEqual(model.searchDraft, unmatched)
        XCTAssertTrue(model.searchTerm.isEmpty)
        XCTAssertFalse(model.items.isEmpty)
        XCTAssertNil(probe(in: view, identifier: "search-complete-empty"))

        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(view)
        XCTAssertEqual(model.searchTerm, unmatched)
        XCTAssertNotNil(probe(in: view, identifier: "search-complete-empty"))
    }

    func testSearchReportsNoMatchingFilmOnlyAfterServerCatalogSucceeds() async throws {
        let fixture = makeFixture(countPerLibrary: 0)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        fixture.server.configure(status: 500)
        model.searchTerm = "Missing title"
        model.navigate(to: "searchServer")
        try await waitUntil("Search should expose a failed catalog read") { model.serverBrowseError != nil }
        try await settle(host.controller.view)
        XCTAssertNil(probe(in: host.controller.view, identifier: "search-complete-empty"))
        fixture.server.configure(status: 200)
        model.refreshServerBrowse()
        try await waitUntil("Retry should finish reading the empty catalog") { model.serverBrowseComplete }
        try await settle(host.controller.view)
        XCTAssertNotNil(probe(in: host.controller.view, identifier: "search-complete-empty"))
    }

    func testServerBrowseLoadingEmptyFailureAndRetryHaveRenderedStates() async throws {
        try await assertServerBrowseStates(route: "recent", expectedCount: 72)
        try await assertServerBrowseStates(route: "favorites", expectedCount: 36)
    }

    private func assertServerBrowseStates(route: String, expectedCount: Int) async throws {
        let fixture = makeFixture(countPerLibrary: 0)
        defer { fixture.session.invalidateAndCancel(); ServerBrowseViewProtocol.handler = nil }
        let model = fixture.model
        let host = makeHost(model)
        defer { host.window.contentViewController = nil; host.window.close() }
        try await loadHome(model)
        fixture.server.configure(delay: 0.2)
        model.page = route
        XCTAssertTrue(model.serverBrowseLoading)
        try await settle(host.controller.view)
        try assertRenderedState("loading", route: route, in: host.controller.view)
        try await waitUntil("An empty feed should finish without being an error") { model.serverBrowseComplete && !model.serverBrowseLoading }
        try await settle(host.controller.view)
        XCTAssertNil(model.serverBrowseError)
        try assertRenderedState("empty", route: route, in: host.controller.view)

        fixture.server.configure(countPerLibrary: 36, status: 500, delay: 0.04)
        model.refreshServerBrowse()
        try await waitUntil("A failed feed must stop loading and expose its failure") { !model.serverBrowseLoading && model.serverBrowseError != nil }
        try await settle(host.controller.view)
        XCTAssertFalse(model.serverBrowseComplete)
        try assertRenderedState("error", route: route, in: host.controller.view)
        XCTAssertNil(probe(in: host.controller.view, identifier: "server-browse-state-\(route)-empty"),
                     "A network failure must not be presented as an empty media collection")

        fixture.server.configure(status: 200)
        model.refreshServerBrowse()
        try await waitUntil("Retry should recover the complete feed") { model.serverBrowseComplete && !model.serverBrowseLoading }
        try await settle(host.controller.view)
        XCTAssertNil(model.serverBrowseError)
        let items = routeItems(model, route: route)
        XCTAssertEqual(items.count, expectedCount)
        XCTAssertNil(probe(in: host.controller.view, identifier: "server-browse-state-\(route)-error"))
        let scroll = try XCTUnwrap(routeScroll(in: host.controller.view, route: route))
        try await assertTailVisible(try XCTUnwrap(items.last).id, route: route, scroll: scroll, in: host.controller.view)
        XCTAssertEqual(fixture.server.unexpectedPaths, [])
    }

    private func makeFixture(countPerLibrary: Int = 36) -> (model: ApplicationModel, session: URLSession, server: ServerBrowseViewServer) {
        let server = ServerBrowseViewServer(countPerLibrary: countPerLibrary)
        ServerBrowseViewProtocol.handler = { server.reply(to: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerBrowseViewProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = ServerConnection(kind: .emby, name: "独立浏览页 · 合成服务器", baseURL: URL(string: "https://server-browse.invalid")!,
                                          serverID: "fixture-server", userID: "fixture-user", username: "fixture-only",
                                          libraryIDs: ["movies", "series", "removed"])
        var saved = SavedApplication()
        saved.connections = [connection]; saved.selectedID = connection.id
        saved.applicationPreferences.showHomeRecommendations = false
        saved.applicationPreferences.showRecentlyAdded = false
        let credentials = CredentialAccess(read: { _ in "synthetic-token" },
                                           save: { _, _ in XCTFail("Browsing must not write credentials") },
                                           remove: { _ in XCTFail("Browsing must not remove credentials") })
        let model = ApplicationModel(storage: ServerBrowseViewStorage(saved), credentials: credentials,
                                     clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) },
                                     subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("seatsix-server-browse-unused-\(UUID().uuidString)", isDirectory: true)))
        return (model, session, server)
    }

    private func loadHome(_ model: ApplicationModel) async throws {
        model.refresh()
        try await waitUntil("Synthetic home should load through the real client") { model.catalogComplete && model.homeContentReady }
        XCTAssertEqual(Set(model.libraries.map(\.id)), ["movies", "series"])
    }

    private func routeItems(_ model: ApplicationModel, route: String) -> [MediaItem] {
        switch route {
        case "recent": return model.serverRecentItems
        case "continuing": return model.serverContinuingItems
        case "favorites": return model.serverBrowseCatalogItems
        case "movies": return model.serverBrowseCatalogItems.filter { $0.type == "Movie" }
        case "series": return model.serverBrowseCatalogItems.filter { $0.type == "Series" }
        default: return model.serverBrowseCatalogItems.filter { $0.isPlayable && $0.type != "Movie" && $0.type != "Series" }
        }
    }

    private func makeHost(_ model: ApplicationModel, sidebarReport: (([String: CGRect]) -> Void)? = nil)
        -> (controller: NSHostingController<AnyView>, window: NSWindow) {
        _ = NSApplication.shared
        let root = AnyView(SeatSixRootView(model: model)
            .preferredColorScheme(.dark).tint(SeatSixStyle.accent)
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { sidebarReport?($0) }
            .transaction { $0.disablesAnimations = true })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let size = NSSize(width: 930, height: 650)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        return (controller, window)
    }

    private func waitUntil(_ message: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func probe(in view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        return view.subviews.lazy.compactMap { self.probe(in: $0, identifier: identifier) }.first
    }

    private func routeScroll(in view: NSView, route: String) -> NSScrollView? {
        probe(in: view, identifier: "server-browse-scroll-probe-\(route)")?.enclosingScrollView
    }

    private func scrollToFraction(_ fraction: CGFloat, scroll: NSScrollView, in view: NSView) async throws -> CGFloat {
        let maximum = try XCTUnwrap(scroll.documentView).bounds.height - scroll.contentView.bounds.height
        XCTAssertGreaterThan(maximum, 200, "The fixture must genuinely overflow the native clip view")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(view)
        let actual = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(actual, 50)
        return actual
    }

    private func assertTailVisible(_ itemID: String, route: String, scroll: NSScrollView, in view: NSView) async throws {
        let document = try XCTUnwrap(scroll.documentView)
        // Lazy grids refine their height after materializing another screenful.
        // Follow the measured bottom, rather than assuming a fixed row height.
        for _ in 0..<4 {
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(view)
        }
        let tail = try XCTUnwrap(probe(in: view, identifier: "server-browse-last-item-\(route)-\(itemID)"),
                                "The last real card must exist beyond the old home-rail limits")
        let card = tail.convert(tail.bounds, to: document)
        XCTAssertGreaterThan(card.width, 0)
        XCTAssertGreaterThan(card.height, 0)
        XCTAssertGreaterThan(card.intersection(scroll.documentVisibleRect).height, 0,
                             "The last card must actually be reachable in the native viewport")
        XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentView.bounds.width + 1)
        XCTAssertLessThanOrEqual(card.maxX, document.bounds.maxX + 1)
    }

    private func assertRenderedState(_ state: String, route: String, in view: NSView) throws {
        let stateView = try XCTUnwrap(probe(in: view, identifier: "server-browse-state-\(route)-\(state)"))
        let scroll = try XCTUnwrap(stateView.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let frame = stateView.convert(stateView.bounds, to: document)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertGreaterThan(frame.intersection(scroll.documentVisibleRect).height, 0,
                             "The \(state) state must occupy the visible content, not merely exist in model state")
    }
}

private final class ServerBrowseViewStorage: ApplicationPersisting {
    private var saved: SavedApplication
    init(_ saved: SavedApplication) { self.saved = saved }
    func load() throws -> SavedApplication { saved }
    func save(_ data: SavedApplication) throws { saved = data }
}

private final class ServerBrowseViewProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let body: [String: Any]; var status = 200; var delay: TimeInterval = 0.04 }
    static var handler: ((URLRequest) -> Reply)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let reply = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
            lock.lock(); let stopped = cancelled; lock.unlock()
            guard !stopped else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: reply.body)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

/// No fixture request can escape to a network. Unselected and deleted libraries
/// deliberately contain rows, so accidental broad requests cannot look correct.
private final class ServerBrowseViewServer: @unchecked Sendable {
    private let lock = NSLock()
    private var countPerLibrary: Int
    private var status = 200
    private var delay: TimeInterval = 0.04
    private var unknown: [String] = []
    init(countPerLibrary: Int) { self.countPerLibrary = countPerLibrary }
    var unexpectedPaths: [String] { lock.lock(); defer { lock.unlock() }; return unknown }
    func configure(countPerLibrary: Int? = nil, status: Int? = nil, delay: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let countPerLibrary { self.countPerLibrary = countPerLibrary }
        if let status { self.status = status }
        if let delay { self.delay = delay }
    }
    func expectedIDs(route: String) -> Set<String> {
        lock.lock(); let count = countPerLibrary; lock.unlock()
        let expectedType: String? = ["movies": "Movie", "series": "Series", "other": "Video"][route]
        return Set(["movies", "series"].flatMap { library in
            (0..<count).filter { (expectedType == nil || Self.types[$0 % 3] == expectedType) && (route != "favorites" || $0.isMultiple(of: 2)) }
                .map { "\(library)-\($0)" }
        })
    }
    private static let types = ["Movie", "Series", "Video"]
    private func rows(library: String, count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            ["Id": "\(library)-\(index)", "Name": String(format: "合成内容 %@ %03d", library, index),
             "Type": Self.types[index % 3], "ParentId": library, "ProductionYear": 2026,
             "DateCreated": String(format: "2026-11-%02dT12:%02d:00Z", index % 28 + 1, index),
             "Overview": "独立服务器浏览页验收使用的合成内容。", "Genres": ["剧情"],
             "RunTimeTicks": 54_000_000_000 as Int64,
             "UserData": ["Played": false, "PlaybackPositionTicks": 12_000_000_000 as Int64, "IsFavorite": index.isMultiple(of: 2)]]
        }
    }
    func reply(to request: URLRequest) -> ServerBrowseViewProtocol.Reply {
        let path = request.url?.path ?? ""
        let query = Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        lock.lock(); let count = countPerLibrary, status = self.status, delay = self.delay; lock.unlock()
        if path == "/Users/fixture-user/Views" {
            return .init(body: ["Items": [
                ["Id": "movies", "Name": "合成电影库", "CollectionType": "movies"],
                ["Id": "series", "Name": "合成综合库", "CollectionType": "mixed"],
                ["Id": "private", "Name": "未选择库", "CollectionType": "movies"]
            ]], delay: delay)
        }
        if path == "/Users/fixture-user/Items" || path == "/Users/fixture-user/Items/Resume" {
            let items = query["ParentId"].map { rows(library: $0, count: count) }
                ?? ["movies", "series", "private", "removed"].flatMap { rows(library: $0, count: count) }
            let offset = max(0, Int(query["StartIndex"] ?? "0") ?? 0)
            // A server may return fewer rows than requested. Fifteen forces the
            // new complete feeds to visit real subsequent pages for each library.
            let limit = min(15, max(1, Int(query["Limit"] ?? "60") ?? 60))
            return .init(body: ["Items": Array(items.dropFirst(offset).prefix(limit)), "StartIndex": offset,
                                "TotalRecordCount": items.count], status: status, delay: delay)
        }
        if path.hasPrefix("/Users/fixture-user/Items/"),
           let item = ["movies", "series"].flatMap({ rows(library: $0, count: count) })
                .first(where: { $0["Id"] as? String == request.url?.lastPathComponent }) {
            return .init(body: item, delay: delay)
        }
        lock.lock(); unknown.append(path); lock.unlock()
        return .init(body: [:], status: 404, delay: delay)
    }
}
