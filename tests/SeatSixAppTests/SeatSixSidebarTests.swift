import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

/// These hosts use only in-memory connections and synthetic backgrounds. They
/// never open the user's saved connections, credentials or a media server.
final class SeatSixSidebarTests: XCTestCase {
    @MainActor
    func testRequestedWidthsReserveTitlebarAndKeepFooterInsideTheSidebar() async throws {
        for width in [CGFloat(192), 256, 320] {
            let model = fixture(connectionCount: 3, libraryCount: 3, longNames: true)
            let host = makeHost(SeatSixSidebar(model: model, width: width),
                                size: NSSize(width: width, height: 650))
            defer { host.close() }
            try await settle(host.controller.view)
            let sidebar = try XCTUnwrap(host.frames.values["sidebar"])
            let heading = try XCTUnwrap(host.frames.values["media-header"])
            XCTAssertEqual(sidebar.width, width, accuracy: 0.5)
            XCTAssertEqual(heading.minY - sidebar.minY, 52, accuracy: 0.5)
            XCTAssertNil(host.frames.values["brand"])
            XCTAssertNil(host.frames.values["sidebar-toggle"])
            try assertVisibleRow("navigation-home", in: host)
            try assertVisibleRow("navigation-servers", in: host)
            try assertVisibleRow("navigation-settings", in: host)
            XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: host.controller.view.bounds.size).width, width + 0.5)
        }
    }

    @MainActor
    func testSidebarAndContentMeetWithoutGuttersAtCompactAndPreferredSizes() async throws {
        for size in [NSSize(width: 930, height: 650), NSSize(width: 1220, height: 820), NSSize(width: 1607, height: 978)] {
            let model = fixture(connectionCount: 1)
            let host = makeHost(SeatSixRootView(model: model), size: size)
            defer { host.close() }
            try await settle(host.controller.view)
            let sidebar = try XCTUnwrap(host.frames.values["sidebar"])
            let surface = try XCTUnwrap(host.frames.values["sidebar-surface"])
            let content = try XCTUnwrap(host.frames.values["content"])
            let dividerWidth = try XCTUnwrap(host.controller.view.testSidebarSplit).dividerThickness
            XCTAssertEqual(sidebar.minX, 0, accuracy: 0.5)
            XCTAssertEqual(sidebar.minY, 0, accuracy: 0.5)
            XCTAssertEqual(sidebar.width + dividerWidth, 192, accuracy: 0.5)
            XCTAssertEqual(sidebar.maxY, size.height, accuracy: 0.5)
            XCTAssertEqual(surface.minX, 0, accuracy: 0.5)
            XCTAssertEqual(surface.minY, 0, accuracy: 0.5)
            XCTAssertEqual(surface.maxY, size.height, accuracy: 0.5)
            XCTAssertEqual(surface.maxX, sidebar.maxX, accuracy: 0.5)
            XCTAssertEqual(content.minX - sidebar.maxX, dividerWidth, accuracy: 0.5,
                           "Only the native divider may separate the sidebar from the content")
            XCTAssertEqual(content.maxX, size.width, accuracy: 0.5)
            XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).width, size.width + 1)
            XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).height, size.height + 1)
            try assertVisibleRow("navigation-home", in: host)
            try assertVisibleRow("navigation-continuing", in: host)
            try assertVisibleRow("navigation-recent", in: host)
            try assertVisibleRow("navigation-movies", in: host)
            try assertVisibleRow("navigation-series", in: host)
            try assertVisibleRow("navigation-other", in: host)
            try assertVisibleRow("navigation-library", in: host)
            try assertVisibleRow("navigation-settings", in: host)
            try savePreview(host.controller.view, name: "sidebar-root-\(Int(size.width))x\(Int(size.height))")
        }
    }

    @MainActor
    func testLongServerNamesStayWithinSidebarAndLastServerScrollsAboveFixedFooter() async throws {
        let model = fixture(connectionCount: 30, libraryCount: 30, longNames: true)
        let size = NSSize(width: 930, height: 650)
        let host = makeHost(HStack(spacing: 0) {
            SeatSixSidebar(model: model)
            Color.clear
        }, size: size, backdrop: Color.black)
        defer { host.close() }
        try await settle(host.controller.view)
        let sidebar = try XCTUnwrap(host.frames.values["sidebar"])
        let viewport = try XCTUnwrap(host.frames.values["server-scroll"])
        let footer = try XCTUnwrap(host.frames.values["footer"])
        let add = try XCTUnwrap(host.frames.values["add-server"])
        let scroll = try XCTUnwrap(scrollViews(in: host.controller.view).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scrollViews(in: host.controller.view).count, 1,
                       "Libraries, navigation and servers must share one scroll viewport, not nested scrolling lists")
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height + 200)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1)
        XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).width, size.width + 1)
        XCTAssertLessThanOrEqual(host.controller.sizeThatFits(in: size).height, size.height + 1)
        XCTAssertEqual(sidebar.width, 192, accuracy: 0.5)
        XCTAssertGreaterThan(viewport.height, 100)
        XCTAssertLessThanOrEqual(viewport.maxY, add.minY)
        XCTAssertLessThanOrEqual(add.maxY, footer.minY + 1)
        for connection in model.saved.connections {
            let row = try XCTUnwrap(host.frames.values["server-\(connection.id.uuidString)"])
            XCTAssertEqual(row.height, 36, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(row.minX, sidebar.minX)
            XCTAssertLessThanOrEqual(row.maxX, sidebar.maxX)
            XCTAssertEqual(row.width, 176, accuracy: 0.5,
                           "Long Chinese/English labels must truncate rather than widen a server row")
        }

        for library in model.libraries {
            let row = try XCTUnwrap(host.frames.values["library-\(library.id)"])
            XCTAssertEqual(row.height, 36, accuracy: 0.5)
            XCTAssertEqual(row.width, 176, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(row.minX, sidebar.minX)
            XCTAssertLessThanOrEqual(row.maxX, sidebar.maxX)
        }
        let lastLibrary = try XCTUnwrap(model.libraries.last)
        let lastLibraryRow = try XCTUnwrap(host.frames.values["library-\(lastLibrary.id)"])
        scroll.contentView.scroll(to: NSPoint(x: 0, y: lastLibraryRow.minY - viewport.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        model.selectedLibraryID = lastLibrary.id
        model.page = "library"
        try await settle(host.controller.view)
        let visibleLibrary = try XCTUnwrap(host.frames.values["library-\(lastLibrary.id)"])
        XCTAssertGreaterThanOrEqual(visibleLibrary.intersection(viewport).height, 35,
                                    "The final real library must be reachable before the server section")
        try assertMarker("library-selection-\(lastLibrary.id)", inside: "library-\(lastLibrary.id)", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-library"], "The parent must not duplicate its selected child's highlight")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        let last = try XCTUnwrap(model.saved.connections.last)
        let lastRow = try XCTUnwrap(host.frames.values["server-\(last.id.uuidString)"])
        let scrolledViewport = try XCTUnwrap(host.frames.values["server-scroll"])
        XCTAssertGreaterThanOrEqual(lastRow.intersection(scrolledViewport).height, 35,
                                    "The final connection must be fully reachable in the scroll viewport")
        XCTAssertEqual(host.frames.values["footer"], footer, "Scrolling servers must not move the footer")
        XCTAssertEqual(host.frames.values["add-server"], add, "Adding a server must stay outside the scrolling list")
        try assertVisibleRow("navigation-servers", in: host)
        try assertVisibleRow("navigation-settings", in: host)

        // Changing the selected account must retain its leading context
        // marker even when the label is truncated; this is a rendering check,
        // not a request to connect to the synthetic server.
        model.saved.selectedID = last.id
        try await settle(host.controller.view)
        try assertContextMarker("selected-indicator-\(last.id.uuidString)",
                                inside: "server-\(last.id.uuidString)", in: host)
        try savePreview(host.controller.view, name: "sidebar-many-libraries-and-servers")

        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        for key in ["navigation-home", "navigation-continuing", "navigation-recent", "navigation-movies", "navigation-series", "navigation-other", "navigation-library"] {
            let row = try XCTUnwrap(host.frames.values[key])
            XCTAssertGreaterThanOrEqual(row.intersection(viewport).height, 35,
                                        "Scrolling back must make every top-level navigation entry reachable")
        }
    }

    @MainActor
    func testEmptyConnectionsKeepAddManagementAndSettingsReachable() async throws {
        let model = fixture(connectionCount: 0)
        let host = makeHost(SeatSixSidebar(model: model), size: NSSize(width: 192, height: 650))
        defer { host.close() }
        try await settle(host.controller.view)
        for key in ["navigation-home", "navigation-continuing", "navigation-recent", "navigation-movies", "navigation-series", "navigation-other", "navigation-library", "add-server", "navigation-servers", "navigation-settings"] {
            try assertVisibleRow(key, in: host)
        }
        XCTAssertFalse(host.frames.values.keys.contains { $0.hasPrefix("server-") && $0 != "server-scroll" })
        let source = try XCTUnwrap(host.frames.values["source-header"])
        let add = try XCTUnwrap(host.frames.values["add-server"])
        XCTAssertLessThan(add.minY - source.maxY, 20,
                          "An empty source list should not leave a tall vacant panel before Add Server")
        try savePreview(host.controller.view, name: "sidebar-empty")
    }

    @MainActor
    func testDisclosingGroupsPreservesRouteLibraryAndServerSelection() async throws {
        let model = fixture(connectionCount: 2, libraryCount: 2)
        let selectedServer = try XCTUnwrap(model.connection?.id)
        model.page = "library"
        model.selectedLibraryID = "library-1"
        let disclosure = SidebarDisclosure()
        let host = makeHost(SeatSixSidebar(model: model, disclosure: disclosure), size: NSSize(width: 192, height: 920))
        defer { host.close() }
        try await settle(host.controller.view)
        let media = try XCTUnwrap(host.frames.values["media-header"])
        let firstChild = try XCTUnwrap(host.frames.values["navigation-home"])
        XCTAssertEqual(firstChild.midY - media.midY, 40, accuracy: 0.5)
        disclosure.toggle(.libraries)
        try await settle(host.controller.view)
        XCTAssertNil(host.frames.values["library-library-1"])
        XCTAssertNotNil(host.frames.values["navigation-home"])
        disclosure.toggle(.servers)
        try await settle(host.controller.view)
        XCTAssertNil(host.frames.values["server-\(selectedServer.uuidString)"])
        disclosure.toggle(.media)
        try await settle(host.controller.view)
        XCTAssertNil(host.frames.values["navigation-home"])
        for row in ["media-header", "libraries-header", "source-header", "add-server", "navigation-settings"] {
            try assertVisibleRow(row, in: host)
        }

        disclosure.toggle(.libraries)
        try await settle(host.controller.view)
        try assertMarker("library-selection-library-1", inside: "library-library-1", in: host)
        XCTAssertNil(host.frames.values["navigation-home"])
        disclosure.toggle(.servers)
        try await settle(host.controller.view)
        try assertContextMarker("selected-indicator-\(selectedServer.uuidString)",
                                inside: "server-\(selectedServer.uuidString)", in: host)
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.selectedLibraryID, "library-1")
        XCTAssertEqual(model.connection?.id, selectedServer)
    }

    @MainActor
    func testSelectionHasPositionalMarkersAndTracksRouteAndConnection() async throws {
        let model = fixture(connectionCount: 2, libraryCount: 2)
        let first = model.saved.connections[0], second = model.saved.connections[1]
        let host = makeHost(SeatSixSidebar(model: model), size: NSSize(width: 192, height: 650))
        defer { host.close() }
        try await settle(host.controller.view)
        try assertMarker("navigation-selection-home", inside: "navigation-home", in: host)
        try assertContextMarker("selected-indicator-\(first.id.uuidString)", inside: "server-\(first.id.uuidString)", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-library"])

        model.page = "library"
        model.saved.selectedID = second.id
        try await settle(host.controller.view)
        try assertMarker("library-selection-library-0", inside: "library-library-0", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-library"])
        try assertContextMarker("selected-indicator-\(second.id.uuidString)", inside: "server-\(second.id.uuidString)", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-home"])
        XCTAssertNil(host.frames.values["selected-indicator-\(first.id.uuidString)"])

        for route in ["continuing", "recent", "movies", "series", "other", "servers"] {
            model.page = route
            try await settle(host.controller.view)
            try assertMarker("navigation-selection-\(route)", inside: "navigation-\(route)", in: host)
            XCTAssertNil(host.frames.values["library-selection-library-0"])
            XCTAssertNil(host.frames.values["navigation-selection-library"])
            for other in ["home", "continuing", "recent", "movies", "series", "other", "servers"] where other != route {
                XCTAssertNil(host.frames.values["navigation-selection-\(other)"])
            }
        }

        model.libraries = []
        model.page = "library"
        try await settle(host.controller.view)
        try assertMarker("navigation-selection-library", inside: "navigation-library", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-servers"])
    }

    @MainActor
    func testRealLibrariesKeepServerNamesTypesAndOneSelectedDestination() async throws {
        let model = fixture(connectionCount: 1)
        model.libraries = [
            .init(id: "personal-movies", name: "私人电影 · 原盘", collectionType: "movies"),
            .init(id: "family-shows", name: "家人追剧", collectionType: "tvshows"),
            .init(id: "animation", name: "动画长片", collectionType: "movies"),
            .init(id: "travel", name: "旅行纪录", collectionType: "homevideos")
        ]
        model.selectedLibraryID = "family-shows"
        let destinations = SeatSixSidebar(model: model).libraryDestinations
        XCTAssertEqual(destinations.map(\.id), ["personal-movies", "family-shows", "animation", "travel"])
        XCTAssertEqual(destinations.map(\.title), ["私人电影 · 原盘", "家人追剧", "动画长片", "旅行纪录"])
        XCTAssertEqual(destinations.map(\.icon), ["film", "tv", "film", "folder"])
        XCTAssertEqual(destinations.filter { $0.isSelected(page: "library", libraryID: model.selectedLibraryID) }.map(\.id), ["family-shows"])
        XCTAssertFalse(destinations.contains { $0.isSelected(page: "recent", libraryID: model.selectedLibraryID) })

        model.page = "library"
        let host = makeHost(SeatSixSidebar(model: model), size: NSSize(width: 192, height: 650))
        defer { host.close() }
        try await settle(host.controller.view)
        for destination in destinations { try assertVisibleRow("library-\(destination.id)", in: host) }
        XCTAssertEqual(host.frames.values.keys.filter { $0.hasPrefix("library-") && !$0.hasPrefix("library-selection-") }.count, 4,
                       "Only actual server libraries may be rendered, including separate libraries of the same media type")
        try assertMarker("library-selection-family-shows", inside: "library-family-shows", in: host)
        XCTAssertNil(host.frames.values["navigation-selection-library"])
        for other in ["personal-movies", "animation", "travel"] {
            XCTAssertNil(host.frames.values["library-selection-\(other)"])
        }
        model.selectedLibraryID = "animation"
        try await settle(host.controller.view)
        try assertMarker("library-selection-animation", inside: "library-animation", in: host)
        XCTAssertNil(host.frames.values["library-selection-family-shows"])
        try savePreview(host.controller.view, name: "sidebar-real-library-destinations")
    }

    @MainActor
    func testOpaqueAccessibilityFallbackBlocksBackdropAndKeepsTextLegible() async throws {
        for (name, reduceTransparency, contrast) in [
            ("reduce-transparency", true, ColorSchemeContrast.standard),
            ("increased-contrast", false, ColorSchemeContrast.increased)
        ] {
            var samples: [NSColor] = []
            for backdrop in [Color.red, Color.blue] {
                let model = fixture(connectionCount: 1)
                let root = SeatSixSidebar(model: model, appearanceOverride: .init(
                    reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                    reduceMotion: true))
                let host = makeHost(root, size: NSSize(width: 192, height: 650), backdrop: backdrop)
                defer { host.close() }
                try await settle(host.controller.view)
                let bitmap = try render(host.controller.view)
                samples.append(try pixel(bitmap, at: CGPoint(x: 4, y: 325), viewSize: host.controller.view.bounds.size))
                let row = try XCTUnwrap(host.frames.values["navigation-library"])
                let textRegion = CGRect(x: row.minX + 34, y: row.minY, width: 100, height: row.height)
                XCTAssertGreaterThan(try contrastRatio(bitmap, in: textRegion, viewSize: host.controller.view.bounds.size), 4.5,
                                     "\(name) must keep inactive navigation text readable")
                try savePreview(host.controller.view, name: "sidebar-\(name)")
            }
            XCTAssertEqual(samples[0].redComponent, samples[1].redComponent, accuracy: 0.01)
            XCTAssertEqual(samples[0].greenComponent, samples[1].greenComponent, accuracy: 0.01)
            XCTAssertEqual(samples[0].blueComponent, samples[1].blueComponent, accuracy: 0.01,
                           "The actual sidebar surface must be opaque, not merely advertise an opaque policy")
        }
    }

    @MainActor
    func testOrdinarySidebarRetainsBackdropColorAndReducedMotionDisablesTransitions() async throws {
        var samples: [NSColor] = []
        var sourceSamples: [NSColor] = []
        for color in [NSColor.red, .blue] {
            let backdrop = try artworkBackdrop(color)
            let host = makeHost(SeatSixSidebar(model: fixture(connectionCount: 1))
                .environment(\.controlActiveState, .active),
                size: NSSize(width: 192, height: 650), backdrop: backdrop)
            let sourceHost = makeHost(Color.clear, size: NSSize(width: 192, height: 650), backdrop: backdrop)
            defer { host.close(); sourceHost.close() }
            try await settle(host.controller.view)
            try await settle(sourceHost.controller.view)
            samples.append(try pixel(render(host.controller.view), at: CGPoint(x: 4, y: 325),
                                     viewSize: host.controller.view.bounds.size))
            sourceSamples.append(try pixel(render(sourceHost.controller.view), at: CGPoint(x: 4, y: 325),
                                           viewSize: sourceHost.controller.view.bounds.size))
        }
        // Compare two actual renders in the same colour space. The surface
        // darkens the poster locally under the navigation labels while the
        // adjacent content still shows the original blurred image.
        let redContribution = samples[0].redComponent - samples[0].blueComponent
        let blueContribution = samples[1].blueComponent - samples[1].redComponent
        let sourceRed = sourceSamples[0].redComponent - sourceSamples[0].blueComponent
        let sourceBlue = sourceSamples[1].blueComponent - sourceSamples[1].redComponent
        XCTAssertGreaterThan(redContribution, 0.015)
        XCTAssertGreaterThan(blueContribution, 0.015)
        XCTAssertLessThan(redContribution, sourceRed * 0.95,
                          "Navigation must visibly temper the blurred poster behind the labels")
        XCTAssertLessThan(blueContribution, sourceBlue * 0.95)
        for reduceTransparency in [false, true] {
            for increasedContrast in [false, true] {
                let reduced = SeatSixSidebarAppearancePolicy(reduceTransparency: reduceTransparency,
                    increasedContrast: increasedContrast, reduceMotion: true)
                XCTAssertFalse(reduced.allowsAnimation)
                XCTAssertEqual(reduced.isOpaque, reduceTransparency || increasedContrast)
            }
        }
    }

    func testRowPresentationSeparatesDestinationContextHoverPressAndFocus() {
        for isActive in [true, false] {
            for increasedContrast in [false, true] {
                for reduceMotion in [false, true] {
                    let policy = SeatSixSidebarAppearancePolicy(reduceTransparency: false,
                        increasedContrast: increasedContrast, reduceMotion: reduceMotion)
                    func state(_ role: SeatSixSidebarRowRole = .destination, selected: Bool = false,
                               hovered: Bool = false, pressed: Bool = false, focused: Bool = false)
                        -> SeatSixSidebarRowPresentation {
                        .init(role: role, selected: selected, hovered: hovered, pressed: pressed,
                              focused: focused, isActive: isActive, policy: policy)
                    }
                    let idle = state(), hover = state(hovered: true), press = state(pressed: true)
                    let destination = state(selected: true), context = state(.connection, selected: true)
                    let focused = state(selected: true, focused: true)
                    XCTAssertGreaterThan(context.fillOpacity, idle.fillOpacity)
                    XCTAssertGreaterThan(destination.fillOpacity, context.fillOpacity * 3,
                                         "The current NAS is context, not a second active destination")
                    XCTAssertGreaterThan(hover.fillOpacity, idle.fillOpacity)
                    XCTAssertGreaterThan(press.fillOpacity, hover.fillOpacity)
                    XCTAssertEqual(focused.fillOpacity, destination.fillOpacity,
                                   "Focus must not masquerade as another selected or hovered row")
                    XCTAssertEqual(destination.focusOpacity, 0)
                    XCTAssertGreaterThan(focused.focusOpacity, 0.65)
                    XCTAssertEqual(destination.boundaryOpacity > 0, increasedContrast)
                    XCTAssertEqual(destination.allowsAnimation, !reduceMotion)
                    XCTAssertGreaterThanOrEqual(destination.textOpacity, 0.88,
                                                "Inactive windows may soften chrome, never fade labels away")
                }
            }
        }
    }

    @MainActor
    func testDestinationIsStrongerThanServerContextAndAllLabelsRemainLegible() async throws {
        for color in [NSColor.black, .white, .red, .blue] {
            let backdrop = try artworkBackdrop(color)
            for (name, transparency, contrast) in [("standard", false, false),
                                                   ("opaque", true, false), ("contrast", false, true)] {
                for activeState in [ControlActiveState.active, .inactive] {
                    let model = fixture(connectionCount: 1)
                    let policy = SeatSixSidebarAppearancePolicy(reduceTransparency: transparency,
                        increasedContrast: contrast, reduceMotion: true)
                    let host = makeHost(SeatSixSidebar(model: model, appearanceOverride: policy)
                        .environment(\.controlActiveState, activeState),
                        size: NSSize(width: 192, height: 650), backdrop: backdrop)
                    defer { host.close() }
                    try await settle(host.controller.view)
                    let bitmap = try render(host.controller.view)
                    let viewSize = host.controller.view.bounds.size
                    let home = try XCTUnwrap(host.frames.values["navigation-home"])
                    let server = try XCTUnwrap(host.frames.values["server-\(model.saved.connections[0].id.uuidString)"])
                    func rowHighlight(_ row: CGRect) throws -> Double {
                        let y = row.minY + 5
                        let fill = try pixel(bitmap, at: CGPoint(x: row.maxX - 24, y: y), viewSize: viewSize)
                        let surrounding = try pixel(bitmap, at: CGPoint(x: 4, y: y), viewSize: viewSize)
                        return luminance(fill) - luminance(surrounding)
                    }
                    XCTAssertGreaterThan(try rowHighlight(home), try rowHighlight(server) + 0.012,
                                         "\(name) must distinguish the destination from the NAS against each row's local backdrop")
                    for key in ["navigation-home", "navigation-library", "source-header",
                                "server-\(model.saved.connections[0].id.uuidString)"] {
                        let row = try XCTUnwrap(host.frames.values[key])
                        let inset: CGFloat = 39
                        let text = CGRect(x: row.minX + inset, y: row.minY,
                                          width: 100, height: row.height)
                        XCTAssertGreaterThan(try contrastRatio(bitmap, in: text, viewSize: viewSize), 4.5,
                                             "\(name) \(activeState): \(key) must retain ordinary text contrast")
                    }
                    try assertContextMarker("selected-indicator-\(model.saved.connections[0].id.uuidString)",
                                            inside: "server-\(model.saved.connections[0].id.uuidString)", in: host)
                }
            }
        }
    }

    @MainActor
    func testRenderedHoverPressAndFocusAreDistinctWithoutChangingRowGeometry() async throws {
        let policy = SeatSixSidebarAppearancePolicy(reduceTransparency: false,
            increasedContrast: false, reduceMotion: true)
        for isActive in [true, false] {
            var centerSamples: [NSColor] = []
            var edgeSamples: [NSColor] = []
            for (name, hovered, pressed, focused) in [("idle", false, false, false),
                                                      ("hover", true, false, false),
                                                      ("press", true, true, false),
                                                      ("focus", false, false, true)] {
                let presentation = SeatSixSidebarRowPresentation(role: .destination, selected: true,
                    hovered: hovered, pressed: pressed, focused: focused, isActive: isActive, policy: policy)
                let surfacePolicy = SeatSixSurfacePolicy(reduceTransparency: false, increasedContrast: false,
                                                         reduceMotion: true, isActive: isActive)
                let row = Text("当前页面")
                    .font(.system(size: 13)).foregroundStyle(Color.white.opacity(presentation.textOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 34)
                    .background(SeatSixSidebarRowBackground(presentation: presentation))
                    .seatSixSurface(role: .navigation, cornerRadius: 0, policyOverride: surfacePolicy)
                let host = makeHost(row, size: NSSize(width: 176, height: 34),
                                    backdrop: try artworkBackdrop(.white))
                defer { host.close() }
                try await settle(host.controller.view)
                let bitmap = try render(host.controller.view)
                let size = host.controller.view.bounds.size
                XCTAssertEqual(size.width, 176, accuracy: 0.5)
                XCTAssertEqual(size.height, 34, accuracy: 0.5)
                centerSamples.append(try pixel(bitmap, at: CGPoint(x: 150, y: 17), viewSize: size))
                edgeSamples.append(try pixel(bitmap, at: CGPoint(x: 1, y: 17), viewSize: size))
                XCTAssertGreaterThan(try contrastRatio(bitmap, in: CGRect(x: 34, y: 0, width: 100, height: 34), viewSize: size), 4.5,
                                     "\(name), active \(isActive) must not lighten the row beyond readable contrast")
            }
            XCTAssertGreaterThan(luminance(centerSamples[1]), luminance(centerSamples[0]) + 0.005)
            XCTAssertGreaterThan(luminance(centerSamples[2]), luminance(centerSamples[1]) + 0.005)
            XCTAssertEqual(luminance(centerSamples[3]), luminance(centerSamples[0]), accuracy: 0.005,
                           "Focus adds an outline without changing selection fill")
            XCTAssertGreaterThan(luminance(edgeSamples[3]), luminance(edgeSamples[0]) + 0.10,
                                 "Keyboard focus must have a visible outline on a selected row")
        }
    }

    @MainActor
    private func fixture(connectionCount: Int, libraryCount: Int = 0, longNames: Bool = false) -> ApplicationModel {
        var saved = SavedApplication()
        saved.connections = (0..<connectionCount).map { index in
            let name = longNames
                ? (index.isMultiple(of: 2) ? String(repeating: "很长的服务器名称", count: 8) : String(repeating: "LongUnbrokenServerName", count: 6))
                : "合成服务器 \(index + 1)"
            return ServerConnection(kind: index.isMultiple(of: 2) ? .emby : .jellyfin, name: name,
                                    baseURL: URL(string: "https://never-request.invalid")!,
                                    serverID: "fixture-\(index)", userID: "fixture-user", username: "fixture", libraryIDs: (0..<libraryCount).map { "library-\($0)" })
        }
        saved.selectedID = saved.connections.first?.id
        let model = ApplicationModel(storage: SidebarFixtureStorage(saved),
                                credentials: CredentialAccess(read: { _ in throw CredentialStoreError.notFound },
                                                              save: { _, _ in XCTFail("Layout tests must not save credentials") },
                                                              remove: { _ in XCTFail("Layout tests must not remove credentials") }),
                                subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                                    .appendingPathComponent("seatsix-sidebar-unused-\(UUID().uuidString)")))
        model.libraries = (0..<libraryCount).map { index in
            let name = longNames
                ? (index.isMultiple(of: 2) ? String(repeating: "真实片库的长名称", count: 8) : String(repeating: "LongServerLibraryName", count: 6))
                : "合成片库 \(index + 1)"
            return MediaLibrary(id: "library-\(index)", name: name, collectionType: index.isMultiple(of: 2) ? "movies" : "tvshows")
        }
        model.selectedLibraryID = model.libraries.first?.id ?? ""
        return model
    }

    @MainActor
    private func makeHost<Content: View, Backdrop: View>(_ content: Content, size: NSSize,
                                        backdrop: Backdrop = SeatSixStyle.background) -> SidebarHost {
        _ = NSApplication.shared
        let frames = SidebarFrames()
        let root = AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(backdrop).preferredColorScheme(.dark).tint(SeatSixStyle.accent)
            .background(SeatSixSidebarGeometry(id: "test-root"))
            .onPreferenceChange(SeatSixSidebarFrameKey.self) { measured in
                // AppKit offscreen hosts can place SwiftUI's global origin
                // outside the content bitmap. Compare local layout and pixels
                // relative to a separately measured root, never a fixed offset.
                guard let root = measured["test-root"] else { frames.values = [:]; return }
                frames.values = measured.mapValues { $0.offsetBy(dx: -root.minX, dy: -root.minY) }
            }
            .transaction { $0.disablesAnimations = true })
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        return SidebarHost(controller: controller, window: window, frames: frames)
    }

    @MainActor
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func assertVisibleRow(_ key: String, in host: SidebarHost, file: StaticString = #filePath, line: UInt = #line) throws {
        let row = try XCTUnwrap(host.frames.values[key], file: file, line: line)
        let sidebar = try XCTUnwrap(host.frames.values["sidebar"], file: file, line: line)
        XCTAssertEqual(row.height, 36, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.minX, sidebar.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(row.minY, sidebar.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxX, sidebar.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(row.maxY, sidebar.maxY, file: file, line: line)
    }

    @MainActor
    private func assertMarker(_ markerKey: String, inside rowKey: String, in host: SidebarHost,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(host.frames.values[markerKey], file: file, line: line)
        let row = try XCTUnwrap(host.frames.values[rowKey], file: file, line: line)
        XCTAssertEqual(marker.width, 2, accuracy: 0.5, file: file, line: line)
        XCTAssertGreaterThan(marker.height, 10, file: file, line: line)
        XCTAssertEqual(marker.intersection(row), marker, file: file, line: line)
    }

    @MainActor
    private func assertContextMarker(_ markerKey: String, inside rowKey: String, in host: SidebarHost,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let marker = try XCTUnwrap(host.frames.values[markerKey], file: file, line: line)
        let row = try XCTUnwrap(host.frames.values[rowKey], file: file, line: line)
        XCTAssertEqual(marker.width, 3, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(marker.height, 16, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(marker.intersection(row), marker, file: file, line: line)
        XCTAssertEqual(marker.minX, row.minX + 2, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(marker.midY, row.midY, accuracy: 0.5, file: file, line: line)
    }

    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    @MainActor
    private func render(_ view: NSView) throws -> SidebarRenderedBitmap {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let source = try XCTUnwrap(bitmap.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let data = try XCTUnwrap(context.data)
        let image = try XCTUnwrap(context.makeImage())
        return SidebarRenderedBitmap(representation: NSBitmapImageRep(cgImage: image),
            pixelsWide: source.width, pixelsHigh: source.height,
            rgba: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                           count: source.width * source.height * 4)))
    }

    private func pixel(_ bitmap: SidebarRenderedBitmap, at point: CGPoint, viewSize: CGSize) throws -> NSColor {
        let x = Int(point.x * Double(bitmap.pixelsWide) / viewSize.width)
        let y = Int(point.y * Double(bitmap.pixelsHigh) / viewSize.height)
        guard (0..<bitmap.pixelsWide).contains(x), (0..<bitmap.pixelsHigh).contains(y) else {
            XCTFail("Pixel sample must lie inside the rendered sidebar")
            throw NSError(domain: "SidebarPixelSample", code: 1)
        }
        // colorAt() can return calibrated RGB even for an sRGB bitmap. Reading
        // explicit sRGB bytes avoids accidentally applying its gamma twice.
        let offset = (y * bitmap.pixelsWide + x) * 4
        let alpha = Double(bitmap.rgba[offset + 3]) / 255
        let denominator = alpha > 0 ? 255 * alpha : 255
        return NSColor(srgbRed: Double(bitmap.rgba[offset]) / denominator,
                       green: Double(bitmap.rgba[offset + 1]) / denominator,
                       blue: Double(bitmap.rgba[offset + 2]) / denominator, alpha: alpha)
    }

    @MainActor
    private func artworkBackdrop(_ color: NSColor) throws -> HomeAtmosphereBackground {
        let source = NSImage(size: NSSize(width: 16, height: 9), flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            return true
        }
        let thumbnail = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: source))
        let blurred = try XCTUnwrap(HomeAtmosphereArtwork.blurredBackground(from: thumbnail))
        return HomeAtmosphereBackground(blurredBackground: blurred)
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func contrastRatio(_ bitmap: SidebarRenderedBitmap, in region: CGRect, viewSize: CGSize) throws -> Double {
        var luminances: [Double] = []
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) {
                let color = try pixel(bitmap, at: CGPoint(x: CGFloat(x), y: CGFloat(y)), viewSize: viewSize)
                luminances.append(luminance(color))
            }
        }
        luminances.sort()
        guard !luminances.isEmpty else { XCTFail("A contrast region must contain rendered pixels"); return 0 }
        return (luminances[Int(Double(luminances.count - 1) * 0.98)] + 0.05)
            / (luminances[luminances.count / 2] + 0.05)
    }

    @MainActor
    private func savePreview(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SEATSIX_UI_PREVIEW_DIRECTORY"], directory.hasPrefix("/") else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render(view).representation.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

private struct SidebarRenderedBitmap {
    let representation: NSBitmapImageRep
    let pixelsWide: Int
    let pixelsHigh: Int
    let rgba: [UInt8]
}

@MainActor
private final class SidebarFrames {
    var values: [String: CGRect] = [:]
}

@MainActor
private struct SidebarHost {
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    let frames: SidebarFrames

    func close() {
        window.contentViewController = nil
        window.close()
    }
}

private final class SidebarFixtureStorage: ApplicationPersisting {
    private var value: SavedApplication
    init(_ value: SavedApplication) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ value: SavedApplication) throws { self.value = value }
}
