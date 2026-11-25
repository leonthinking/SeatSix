import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class EpisodeOverviewTests: XCTestCase {
    private let spoiler = "这个单集的关键结局不应提前显示。"

    func testOnlyUnwatchedEpisodesWithAnOverviewAreHidden() throws {
        var item = try fixtureItem()
        XCTAssertEqual(content(item), .hidden)
        XCTAssertEqual(content(item, enabled: false), .overview(spoiler))
        XCTAssertEqual(content(item, revealed: true), .overview(spoiler))
        // Having a resume point does not mean this episode has been watched.
        item.userData.playbackPositionTicks = 60 * 10_000_000
        XCTAssertEqual(content(item), .hidden)
        item.userData.played = true
        XCTAssertEqual(content(item), .overview(spoiler))
        item.userData.played = false
        for type in ["Movie", "Series", "Video", "Season"] {
            item.type = type
            XCTAssertEqual(content(item), .overview(spoiler), type)
        }
        item.type = "Episode"
        let missingOverviews: [String?] = [nil, "", " \n "]
        for overview in missingOverviews {
            item.overview = overview
            XCTAssertEqual(content(item), .unavailable)
        }
    }

    func testRevealScopeSeparatesAccountsSourcesItemsAndProtectionChanges() throws {
        let item = try fixtureItem()
        let connection = fixtureConnection()
        let initial = EpisodeOverviewScope(connection: connection, item: item, hideUnwatched: true)
        var changedConnection = connection
        changedConnection.userID = "another-account"
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: changedConnection, item: item, hideUnwatched: true))
        changedConnection = connection
        changedConnection.serverID = "another-server"
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: changedConnection, item: item, hideUnwatched: true))
        changedConnection = connection
        changedConnection.id = UUID()
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: changedConnection, item: item, hideUnwatched: true))
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: nil, item: item, hideUnwatched: true))
        var changedItem = item
        changedItem.id = "another-episode"
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: connection, item: changedItem, hideUnwatched: true))
        changedItem = item
        changedItem.userData.played = true
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: connection, item: changedItem, hideUnwatched: true))
        XCTAssertNotEqual(initial, EpisodeOverviewScope(connection: connection, item: item, hideUnwatched: false))
        changedItem = item
        changedItem.overview = "刷新后的简介"
        changedItem.userData.playbackPositionTicks = 10_000_000
        XCTAssertEqual(initial, EpisodeOverviewScope(connection: connection, item: changedItem, hideUnwatched: true),
                       "Refreshing metadata during this detail visit must not revoke an explicit reveal")
    }

    func testHostedOverviewConcealsAccessibleTextAndLimitsRevealToCurrentVisit() async throws {
        let app = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = app.accessibilityAttributeValue(attribute) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: attribute)
        defer { app.accessibilitySetValue(previous, forAttribute: attribute) }
        let fixture = OverviewFixture(item: try fixtureItem(), connection: fixtureConnection())
        let controller = NSHostingController(rootView: OverviewHarness(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
        defer { window.contentViewController = nil; window.close() }
        window.orderFront(nil)
        try await settle(controller.view)
        // Establish that the same hosted AX tree exposes the unprotected text.
        XCTAssertTrue(labels(in: controller.view).contains(where: { $0.contains(spoiler) }))

        fixture.enabled = true
        try await settle(controller.view)
        assertConcealed(controller.view)
        try await reveal(controller.view)
        XCTAssertTrue(labels(in: controller.view).contains(where: { $0.contains(spoiler) }))
        let expansion = try XCTUnwrap(element("episode-overview-expansion", in: controller.view))
        XCTAssertTrue((expansion as AnyObject).accessibilityPerformPress?() == true)
        try await settle(controller.view)
        XCTAssertTrue(fixture.expanded, "The existing expand/collapse binding must keep working after reveal")

        fixture.item.runTimeTicks = 100 * 10_000_000
        try await settle(controller.view)
        XCTAssertNotNil(element("media-overview-text", in: controller.view), "Ordinary detail refresh preserves this visit's reveal")
        fixture.connection.userID = "another-account"
        try await settle(controller.view)
        assertConcealed(controller.view)

        try await reveal(controller.view)
        fixture.enabled = false
        try await settle(controller.view)
        fixture.enabled = true
        try await settle(controller.view)
        assertConcealed(controller.view)

        try await reveal(controller.view)
        fixture.item.userData.played = true
        try await settle(controller.view)
        fixture.item.userData.played = false
        try await settle(controller.view)
        assertConcealed(controller.view)

        try await reveal(controller.view)
        fixture.visible = false
        try await settle(controller.view)
        fixture.visible = true
        try await settle(controller.view)
        assertConcealed(controller.view)
        XCTAssertTrue(fixture.expanded, "Only reveal permission resets on return; normal overview expansion is retained")
    }

    private func content(_ item: MediaItem, enabled: Bool = true, revealed: Bool = false) -> EpisodeOverviewContent {
        .resolve(item: item, hideUnwatched: enabled, revealed: revealed)
    }

    private func fixtureItem() throws -> MediaItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "Id": "episode", "Name": "测试单集", "Type": "Episode", "Overview": spoiler,
            "UserData": ["Played": false]
        ])
        return try JSONDecoder().decode(MediaItem.self, from: data)
    }

    private func fixtureConnection() -> ServerConnection {
        ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://example.invalid")!,
                         serverID: "server", userID: "user", username: "fixture")
    }

    private func assertConcealed(_ view: NSView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(element("episode-overview-hidden", in: view), file: file, line: line)
        XCTAssertNotNil(element("episode-overview-reveal", in: view), file: file, line: line)
        XCTAssertNil(element("media-overview-text", in: view), file: file, line: line)
        XCTAssertFalse(labels(in: view).contains(where: { $0.contains(spoiler) }), file: file, line: line)
    }

    private func reveal(_ view: NSView) async throws {
        let button = try XCTUnwrap(element("episode-overview-reveal", in: view))
        XCTAssertTrue((button as AnyObject).accessibilityPerformPress?() == true)
        try await settle(view)
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func attribute(_ key: String, of element: NSObject) -> Any? {
        guard element.responds(to: NSSelectorFromString(key)) else { return nil }
        return element.value(forKey: key)
    }

    private func elements(in view: NSView) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        var result: [NSObject] = []
        func walk(_ element: NSObject) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            // Hosted SwiftUI nodes can implement AX selectors without declaring
            // NSAccessibilityProtocol conformance.
            let children = attribute("accessibilityChildren", of: element) as? [NSObject] ?? []
            children.forEach(walk)
        }
        walk(view)
        return result
    }

    private func element(_ identifier: String, in view: NSView) -> NSObject? {
        elements(in: view).first { attribute("accessibilityIdentifier", of: $0) as? String == identifier }
    }

    private func labels(in view: NSView) -> [String] {
        elements(in: view).flatMap { element in
            ["accessibilityLabel", "accessibilityValue"].compactMap { key in
                let value = attribute(key, of: element)
                return value as? String ?? (value as? NSAttributedString)?.string
            }
        }
    }
}

@MainActor
private final class OverviewFixture: ObservableObject {
    @Published var item: MediaItem
    @Published var connection: ServerConnection
    @Published var enabled = false
    @Published var visible = true
    @Published var expanded = false

    init(item: MediaItem, connection: ServerConnection) {
        self.item = item
        self.connection = connection
    }
}

private struct OverviewHarness: View {
    @ObservedObject var fixture: OverviewFixture

    var body: some View {
        if fixture.visible {
            MediaOverviewView(connection: fixture.connection, item: fixture.item, hideUnwatched: fixture.enabled,
                              expanded: $fixture.expanded)
                .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
