import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class ServerLoginViewTests: XCTestCase {
    private let size = NSSize(width: 560, height: 630)

    // Offscreen SwiftUI hosts expose their AppKit controls, but do not expose
    // their SwiftUI AX tree on this macOS runtime. These tests assert actual
    // rendering and native controls; button actions/focus require window acceptance.
    func testNewConnectionRendersEveryInputAndHTTPSWithinFixedWindow() async throws {
        let host = makeHost(existing: nil)
        defer { close(host) }
        try await settle(host.controller.view)
        let fields = textFields(in: host.controller.view)
        XCTAssertEqual(fields.count, 6)
        XCTAssertTrue(fields.allSatisfy { $0.stringValue.isEmpty })
        XCTAssertEqual(fields.filter { $0 is NSSecureTextField }.count, 1)
        let placeholders = Set(fields.compactMap(\.placeholderString))
        XCTAssertTrue(placeholders.contains("留空自动获取服务器名称"))
        XCTAssertTrue(placeholders.contains("IP、域名或完整服务器地址"))
        XCTAssertTrue(placeholders.contains("例如 /emby 或 /jellyfin"))
        XCTAssertTrue(placeholders.contains("443"))
        XCTAssertTrue(placeholders.contains("服务器账户"))
        let source = try XCTUnwrap(nativeViews(in: host.controller.view).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual((0..<source.segmentCount).compactMap(source.label(forSegment:)), ["Emby", "Jellyfin", "Emby 兼容"])
        XCTAssertEqual(source.selectedSegment, 0)
        XCTAssertEqual(nativeViews(in: host.controller.view).compactMap { $0 as? NSSwitch }.first?.state, .on)
        assertFits(host)
        try savePreviewIfRequested(host.controller.view, name: "server-login-new")
    }

    func testExistingConnectionRendersSplitAddressAndNameWithoutRestoringPassword() async throws {
        let connection = fixtureConnection()
        let host = makeHost(existing: connection)
        defer { close(host) }
        try await settle(host.controller.view)
        let fields = textFields(in: host.controller.view)
        XCTAssertEqual(fields.count, 6)
        XCTAssertEqual(Set(fields.map(\.stringValue)), [connection.name, "media.example.invalid", "9443", "/jellyfin", connection.username, ""])
        XCTAssertEqual(fields.compactMap { $0 as? NSSecureTextField }.first?.stringValue, "")
        XCTAssertEqual(nativeViews(in: host.controller.view).compactMap { $0 as? NSSwitch }.first?.state, .on)
        XCTAssertEqual(nativeViews(in: host.controller.view).compactMap { $0 as? NSSegmentedControl }.first?.selectedSegment, 1)
        assertFits(host)
        try savePreviewIfRequested(host.controller.view, name: "server-login-existing")
    }

    func testAddressUpdatesAndLongErrorsRemainEditableWithoutHorizontalClipping() async throws {
        let state = makeState()
        state.address = "https://media.example.invalid:9443/emby"
        state.username = "fixture-viewer"
        let host = makeHost(existing: nil, state: state)
        defer { close(host) }
        try await settle(host.controller.view)
        let scroll = try XCTUnwrap(scrollViews(in: host.controller.view).first)
        let initialFormFrame = host.controller.view.convert(scroll.bounds, from: scroll)
        let footerControls = host.controller.view.subviews.filter {
            let frame = host.controller.view.convert($0.bounds, from: $0)
            return frame.minY >= initialFormFrame.maxY && frame.width >= 40 && frame.height >= 20
        }
        XCTAssertGreaterThanOrEqual(footerControls.count, 2, "Require rendered native targets for both footer actions")
        state.addressForm.useHTTPS = false
        state.addressForm.host = "192.168.10.20"
        state.addressForm.port = "8096"
        state.addressForm.path = "/media"
        try await settle(host.controller.view)
        let formHeightBeforeError = try XCTUnwrap(scroll.documentView).frame.height
        state.error = String(repeating: "无法连接服务器。请检查网络、地址、端口和服务器证书后重试。", count: 8)
        try await settle(host.controller.view)
        let fields = textFields(in: host.controller.view)
        for value in ["192.168.10.20", "8096", "/media", "fixture-viewer"] {
            XCTAssertTrue(fields.contains { $0.stringValue == value }, value)
        }
        XCTAssertTrue(fields.allSatisfy(\.isEditable))
        XCTAssertEqual(nativeViews(in: host.controller.view).compactMap { $0 as? NSSwitch }.first?.state, .off)
        let scrolls = scrollViews(in: host.controller.view)
        XCTAssertEqual(scrolls.count, 2, "Error text needs an independent scrolling region")
        let errorScroll = try XCTUnwrap(scrolls.first { $0 !== scroll })
        let errorDocument = try XCTUnwrap(errorScroll.documentView)
        XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.height, formHeightBeforeError, accuracy: 1,
                       "The error must not be appended below the main form")
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
        XCTAssertGreaterThan(errorDocument.bounds.height, errorScroll.contentView.bounds.height,
                             "Long errors must scroll within their own visible region")
        let errorFrame = host.controller.view.convert(errorScroll.bounds, from: errorScroll)
        XCTAssertTrue(host.controller.view.bounds.contains(errorFrame))
        XCTAssertFalse(errorFrame.intersects(host.controller.view.convert(scroll.bounds, from: scroll)))
        for control in footerControls {
            let frame = host.controller.view.convert(control.bounds, from: control)
            XCTAssertTrue(host.controller.view.bounds.contains(frame))
            XCTAssertFalse(errorFrame.intersects(frame), "Error text must not cover either footer action")
        }
        let formDocument = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: formDocument.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(host.controller.view.convert(errorScroll.bounds, from: errorScroll), errorFrame,
                       "Scrolling the form must never move its error message offscreen")
        let formOffset = scroll.contentView.bounds.origin
        errorScroll.contentView.scroll(to: NSPoint(x: 0, y: errorDocument.bounds.height - errorScroll.contentView.bounds.height))
        errorScroll.reflectScrolledClipView(errorScroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(errorScroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(scroll.contentView.bounds.origin, formOffset, "Error scrolling must not move the form")
        XCTAssertEqual(host.controller.view.convert(errorScroll.bounds, from: errorScroll), errorFrame)
        assertFits(host)
        state.error = "连接失败，请检查网络、服务器地址及 HTTPS 证书。"
        try await settle(host.controller.view)
        try savePreviewIfRequested(host.controller.view, name: "server-login-error")
    }

    func testAuthenticationReplacesLoginControlsAndLongLibraryListScrolls() async throws {
        let connection = fixtureConnection()
        let libraries = (1...24).map { MediaLibrary(id: "library-\($0)", name: "合成媒体库 \($0)", collectionType: "movies") }
        let state = makeState(connection: connection, libraries: libraries)
        state.address = connection.baseURL.absoluteString
        state.username = connection.username
        let host = makeHost(existing: nil, state: state)
        defer { close(host) }
        try await settle(host.controller.view)
        XCTAssertEqual(textFields(in: host.controller.view).count, 6)
        state.login()
        try await waitFor { state.authenticated != nil }
        try await settle(host.controller.view)
        XCTAssertTrue(textFields(in: host.controller.view).isEmpty,
                      "The rendered login form must be removed after authentication")
        XCTAssertTrue(nativeViews(in: host.controller.view).compactMap { $0 as? NSSegmentedControl }.isEmpty)
        let scroll = try XCTUnwrap(scrollViews(in: host.controller.view).first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height * 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        assertFits(host)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host.controller.view)
        try savePreviewIfRequested(host.controller.view, name: "server-login-libraries")
        state.back()
        try await settle(host.controller.view)
        XCTAssertEqual(textFields(in: host.controller.view).count, 6,
                       "Returning must restore actual editable controls")
        XCTAssertTrue(textFields(in: host.controller.view).contains { $0.stringValue == "9443" })
    }

    private func fixtureConnection() -> ServerConnection {
        ServerConnection(kind: .jellyfin, name: "家庭影音", baseURL: URL(string: "https://media.example.invalid:9443/jellyfin")!,
                         serverID: "fixture-server", userID: "fixture-user", username: "fixture-viewer", libraryIDs: ["movies"])
    }

    private func makeState(connection: ServerConnection? = nil, libraries: [MediaLibrary] = []) -> ServerLoginState {
        let result = AuthenticatedServer(connection: connection ?? fixtureConnection(), token: "fixture-token")
        return ServerLoginState(deviceID: "fixture-device", services: ServerLoginServices(
            authenticate: { _, _ in result },
            inspect: { _ in XCTFail("Synthetic login must never inspect a real server"); throw MediaServerError.network },
            libraries: { _, _ in libraries }))
    }

    private typealias Host = (controller: NSHostingController<AnyView>, window: NSWindow)

    private func makeHost(existing: ServerConnection?, state: ServerLoginState? = nil) -> Host {
        _ = NSApplication.shared
        let model = ApplicationModel(storage: ServerLoginViewStorage(),
            credentials: CredentialAccess(read: { _ in throw ApplicationPersistenceError.unavailable }, save: { _, _ in }, remove: { _ in }),
            subtitleArchive: SubtitleArchive(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("seatsix-login-unused-\(UUID().uuidString)", isDirectory: true)))
        let view = ServerLoginView(model: model, existing: existing, state: state)
        let controller = NSHostingController(rootView: AnyView(view.transaction { $0.disablesAnimations = true }))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(origin: .zero, size: size)
        return (controller, window)
    }

    private func close(_ host: Host) {
        host.window.contentViewController = nil
        host.window.close()
    }

    private func assertFits(_ host: Host, file: StaticString = #filePath, line: UInt = #line) {
        let fitting = host.controller.sizeThatFits(in: size)
        XCTAssertLessThanOrEqual(fitting.width, size.width + 1, file: file, line: line)
        XCTAssertLessThanOrEqual(fitting.height, size.height + 1, file: file, line: line)
        let scrolls = scrollViews(in: host.controller.view)
        XCTAssertFalse(scrolls.isEmpty, "The form must remain scrollable at the fixed window height", file: file, line: line)
        for scroll in scrolls {
            guard let document = scroll.documentView else { continue }
            XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1, file: file, line: line)
        }

    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Synthetic authentication did not finish")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func nativeViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { nativeViews(in: $0) }
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        nativeViews(in: view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    }

    private func savePreviewIfRequested(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SEATSIX_UI_PREVIEW_DIRECTORY"], directory.hasPrefix("/") else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}

private final class ServerLoginViewStorage: ApplicationPersisting {
    private var value = SavedApplication()
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws { value = data }
}
