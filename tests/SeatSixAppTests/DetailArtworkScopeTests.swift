import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class DetailArtworkScopeTests: XCTestCase {
    func testRetiringHostDropsArtworkAndMakesNoRequestsAfterLibraryOrAccountChanges() async throws {
        _ = NSApplication.shared
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://detail.test")!,
                                          serverID: "server", userID: "initial", username: "initial", libraryIDs: ["movies"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DetailImageProtocol.self]
        let session = URLSession(configuration: configuration)
        DetailImageProtocol.image = try XCTUnwrap(NSImage(size: NSSize(width: 240, height: 160), flipped: false) { bounds in
            NSColor.blue.setFill()
            bounds.fill()
            return true
        }.tiffRepresentation)
        defer { session.invalidateAndCancel(); DetailImageProtocol.image = nil }
        var requestedBy: [String] = []
        let model = ApplicationModel(storage: DetailScopeStorage(connection),
            credentials: CredentialAccess(read: { _ in "fixture" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { connection, token, device in
                requestedBy.append(connection.userID)
                return MediaServerClient(connection: connection, token: token, deviceID: device, session: session)
            })
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(
            #"{"Id":"shared","Name":"Movie","Type":"Movie","BackdropImageTags":["tag"]}"#.utf8))
        // Keep the exact same host mounted, as happens during a removal transition.
        // A detail entered from server search may start with an empty library ID.
        let layer = DetailArtworkHost(model: model, item: item,
            policyOverride: HomeAtmospherePolicy(reduceTransparency: false, increasedContrast: false, reduceMotion: false)) {
            $0.background
        }
        let underlay = Color(.sRGB, red: 0, green: 1, blue: 0)
        let host = NSHostingController(rootView: ZStack { underlay; layer }.frame(width: 180, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame.size = NSSize(width: 180, height: 120)
        defer { window.contentViewController = nil; window.close() }

        func centerColor() throws -> NSColor {
            let view = host.view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        func waitForColor(_ matches: (NSColor) -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while try !matches(centerColor()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
            XCTAssertTrue(try matches(centerColor()))
        }

        try await waitForColor { $0.blueComponent > $0.greenComponent + 0.4 }
        XCTAssertEqual(requestedBy, ["initial"])
        model.selectedLibraryID = "movies"
        try await waitForColor { $0.greenComponent > $0.blueComponent + 0.4 }
        model.saved.connections[0].userID = "replacement"
        model.selectedLibraryID = ""
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(try centerColor().greenComponent, try centerColor().blueComponent + 0.4)
        XCTAssertEqual(requestedBy, ["initial"], "The retired item must never initiate a request using the replacement account")
    }
}

private final class DetailScopeStorage: ApplicationPersisting {
    private var saved = SavedApplication()
    init(_ connection: ServerConnection) {
        saved.connections = [connection]
        saved.selectedID = connection.id
    }
    func load() throws -> SavedApplication { saved }
    func save(_ value: SavedApplication) throws { saved = value }
}

private final class DetailImageProtocol: URLProtocol {
    static var image: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let image = Self.image, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: image)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
