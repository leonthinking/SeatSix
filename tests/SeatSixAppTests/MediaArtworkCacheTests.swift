import AppKit
import SwiftUI
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class MediaArtworkCacheTests: XCTestCase {
    func testPosterKeepsItsSlotAndOnlyShowsMissingArtworkAfterTheRequestFinishes() async throws {
        let fixture = makeClient(), connection = fixture.client.connection
        let model = ApplicationModel(storage: CreditFixtureStorage(connection),
            credentials: CredentialAccess(read: { _ in "fixture" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { _, _, _ in fixture.client })
        let gate = DispatchSemaphore(value: 0), requests = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            requests.append(request)
            _ = gate.wait(timeout: .now() + 5)
            return (404, Data())
        }
        defer {
            gate.signal()
            fixture.session.invalidateAndCancel()
            ArtworkCacheURLProtocol.handler = nil
        }
        let poster = MediaPoster(model: model, item: try media(["ImageTags": ["Primary": "pending"]]))
        let size = NSSize(width: 288, height: 205)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: HStack(spacing: 0) { poster; ShelfRefreshSkeleton.fill }
            .frame(width: size.width, height: size.height))
        window.contentViewController = host
        host.view.frame.size = size
        defer { window.contentViewController = nil; window.close() }
        func hasSolidPlaceholder() throws -> Bool {
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            func blue(_ x: Int, _ y: Int) throws -> CGFloat {
                try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).blueComponent
            }
            let mid = bitmap.pixelsWide / 2
            let reference = try blue(mid + 10, bitmap.pixelsHigh / 2)
            for x in [12, mid - 12] {
                for y in [12, bitmap.pixelsHigh - 12] {
                    if try abs(blue(x, y) - reference) > 0.006 { return false }
                }
            }
            return true
        }
        let started = ContinuousClock.now + .seconds(3)
        while requests.values.isEmpty, ContinuousClock.now < started { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests.values.count, 1)
        XCTAssertTrue(try hasSolidPlaceholder())
        gate.signal()
        let finished = ContinuousClock.now + .seconds(3)
        while try hasSolidPlaceholder(), ContinuousClock.now < finished { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(try hasSolidPlaceholder(), "A confirmed 404 must release the loading placeholder")
        XCTAssertEqual(host.view.bounds.size, size)
    }

    func testRealCreditPortraitsRejectMissingIdentitiesAndReplaceSameNameAndStaleImages() async throws {
        let fixture = makeClient()
        let connection = fixture.client.connection
        // Count requests across remounts in an empty cache, independently of
        // unrelated fixture images and connection revocations in the suite.
        let portraitCache = PosterCache()
        let model = ApplicationModel(storage: CreditFixtureStorage(connection),
            credentials: CredentialAccess(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { _, _, _ in fixture.client })
        let recorder = CacheRequests()
        let images = try (0..<3).map { channel in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 32))
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            for offset in stride(from: 0, to: bitmap.bytesPerRow * bitmap.pixelsHigh, by: 4) {
                for index in 0..<3 { pixels[offset + index] = index == channel ? 255 : 0 }
                pixels[offset + 3] = 255
            }
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func requestKey(_ request: URLRequest) -> String {
            let url = request.url!
            let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Tag" }?.value ?? ""
            return url.path + "@" + tag
        }
        let firstKey = "/emby/Items/person-A/Images/Primary@v1"
        let otherKey = "/emby/Items/person-B/Images/Primary@v1"
        let updatedKey = "/emby/Items/person-A/Images/Primary@v2"
        let payloads = [firstKey: images[0], otherKey: images[1], updatedKey: images[2]]
        ArtworkCacheURLProtocol.handler = { request in
            recorder.append(request)
            guard let data = payloads[requestKey(request)] else { return (404, Data()) }
            return (200, data)
        }
        defer {
            fixture.session.invalidateAndCancel()
            ArtworkCacheURLProtocol.handler = nil
        }
        func credit(_ id: String?, _ tag: String?) -> [String: String] {
            var entry = ["Name": "同名演员", "Type": "Actor"]
            entry["Id"] = id
            entry["PrimaryImageTag"] = tag
            return entry
        }
        let invalid = [credit("../wrong", "v1"), credit(nil, "v1"), credit("person-X", nil),
                       credit("person-X", "  "), credit("person-X", String(repeating: "x", count: 4097))]
        func view(_ entries: [[String: String]]) throws -> some View {
            let item = try media(["People": entries])
            return MediaDetailInformationView(model: model, people: item.people, streams: [], portraitCache: portraitCache)
                .padding(12).frame(width: 800, height: 176).preferredColorScheme(.dark)
        }
        let first = credit("person-A", "v1")
        let second = credit("person-B", "v1")
        let updated = credit("person-A", "v2")
        let host = NSHostingController(rootView: try view([first, second] + invalid))
        let size = NSSize(width: 800, height: 176)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame = NSRect(origin: .zero, size: size)
        defer { window.contentViewController = nil; window.close() }

        // Read actual portrait pixels in order. Reusing a view by row position or
        // display name would leave the wrong color after the two people swap.
        func visibleColors() throws -> [Int] {
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            var colors: [Int] = []
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let components = [color.redComponent, color.greenComponent, color.blueComponent]
                    // ColorSync converts the device-RGB fixture to the window's
                    // display profile. Match the dominant hue, including wide gamut.
                    let sorted = components.sorted(by: >)
                    if sorted[0] > 0.65, sorted[0] - sorted[1] > 0.3,
                       let band = components.firstIndex(of: sorted[0]) {
                        if colors.last != band { colors.append(band) }
                        break
                    }
                }
            }
            return colors
        }
        func expect(_ expected: [Int]) async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            while try visibleColors() != expected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(35))
            }
            XCTAssertEqual(try visibleColors(), expected)
        }
        try await expect([0, 1])
        host.rootView = try view([second, updated] + invalid)
        try await expect([1, 2])
        host.rootView = try view([first, second] + invalid)
        try await expect([0, 1])
        XCTAssertEqual(recorder.values.map(requestKey).sorted(), [firstKey, otherKey, updatedKey].sorted())
        await model.shutdown()
    }

    func testPortraitLandscapeAndHeroSizesNeverShareCachedImage() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let portrait = try png(width: 200, height: 300)
        let landscape = try png(width: 2880, height: 1620)
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            recorder.append(request)
            return (200, request.url!.path.hasSuffix("Primary") ? portrait : landscape)
        }
        let item = try media(["ImageTags": ["Primary": "poster"], "BackdropImageTags": ["wide"]])
        let cache = PosterCache()
        let first = await cache.load(key: "same", item: item, client: fixture.client)
        let second = await cache.load(key: "same", item: item, client: fixture.client, role: .landscape)
        let hero = await cache.load(key: "same", item: item, client: fixture.client, role: .landscape, requestWidth: 1600)
        let cached = await cache.load(key: "same", item: item, client: fixture.client, role: .landscape, requestWidth: 1600)
        let detail = await cache.load(key: "same", item: item, client: fixture.client, role: .detailBackdrop, requestWidth: 6000)
        let detailCached = await cache.load(key: "same", item: item, client: fixture.client, role: .detailBackdrop, requestWidth: 2560)
        XCTAssertEqual(try XCTUnwrap(first).size, NSSize(width: 200, height: 300))
        XCTAssertEqual(try XCTUnwrap(second).size.width, 600)
        XCTAssertEqual(try XCTUnwrap(hero).size, NSSize(width: 1600, height: 900))
        XCTAssertTrue(hero === cached)
        XCTAssertEqual(try XCTUnwrap(detail).size, NSSize(width: 2560, height: 1440))
        XCTAssertTrue(detail === detailCached)
        XCTAssertEqual(recorder.values.map { $0.url!.path }, ["/emby/Items/movie/Images/Primary"] + Array(repeating: "/emby/Items/movie/Images/Backdrop/0", count: 3))
    }

    func testDarkEmptySolidAndMalformedTitleArtLeaveTheRealTitleAvailable() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let size = NSSize(width: 240, height: 80)
        func art(_ ink: NSColor, withMargin: Bool) throws -> Data {
            try XCTUnwrap(NSImage(size: size, flipped: false) { bounds in
                ink.setFill()
                (withMargin ? bounds.insetBy(dx: 20, dy: 20) : bounds).fill()
                return true
            }.tiffRepresentation)
        }
        let payloads = try ["title": art(.white, withMargin: true), "dark": art(.black, withMargin: true),
                            "blank": art(.clear, withMargin: false), "solid": art(.white, withMargin: false),
                            "malformed": Data([0])]
        ArtworkCacheURLProtocol.handler = { request in
            let tag = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "Tag" }?.value
            return (200, tag.flatMap { payloads[$0] } ?? Data())
        }
        let cache = PosterCache()
        for tag in payloads.keys.sorted() {
            let item = try media(["ImageTags": ["Logo": tag]])
            let result = await cache.load(key: "wordmark", item: item, client: fixture.client, role: .logo)
            XCTAssertEqual(result != nil, tag == "title", tag)
        }
    }

    func testDetailRequestsALogoOnlyWhenItsUsableBackdropIsShown() async throws {
        let fixture = makeClient()
        let model = ApplicationModel(storage: CreditFixtureStorage(fixture.client.connection),
            credentials: CredentialAccess(read: { _ in "fixture" }, save: { _, _ in }, remove: { _ in }),
            clientFactory: { _, _, _ in fixture.client })
        let scene = try XCTUnwrap(NSImage(size: NSSize(width: 180, height: 100), flipped: false) { rect in
            NSColor.green.setFill(); rect.fill(); return true
        }.tiffRepresentation)
        let title = try XCTUnwrap(NSImage(size: NSSize(width: 180, height: 60), flipped: false) { rect in
            NSColor.white.setFill(); rect.insetBy(dx: 16, dy: 9).fill(); return true
        }.tiffRepresentation)
        let requests = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            requests.append(request)
            let path = request.url!.path
            if path.contains("/unusable/") { return (404, Data()) }
            return (200, path.hasSuffix("/Logo") ? title : scene)
        }
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let size = NSSize(width: 240, height: 140)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }

        for id in ["no-backdrop", "unusable", "no-logo", "reduced", "displayed"] {
            let item = try media(["Id": id, "ImageTags": id == "no-logo" ? [:] : ["Logo": "logo-tag"],
                                  "BackdropImageTags": id == "no-backdrop" ? [] : ["scene-tag"]])
            var resolved = false
            let root = DetailArtworkHost(model: model, item: item,
                policyOverride: HomeAtmospherePolicy(reduceTransparency: id == "reduced", increasedContrast: false, reduceMotion: false)) { art in
                let ready = !art.landscapePending && (art.logo != nil) == (id == "displayed")
                return Color.clear.onChange(of: ready, initial: true) { _, value in resolved = value }
            }
            let host = NSHostingController(rootView: root)
            host.sizingOptions = []
            window.contentViewController = host
            host.view.frame.size = size
            let deadline = ContinuousClock.now + .seconds(3)
            while !resolved, ContinuousClock.now < deadline {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTAssertTrue(resolved, id)
        }
        let paths = requests.values.map { $0.url!.path }
        XCTAssertEqual(paths.filter { $0.hasSuffix("/Logo") }, ["/emby/Items/displayed/Images/Logo"])
        XCTAssertEqual(paths.filter { $0.contains("/displayed/") }, [
            "/emby/Items/displayed/Images/Backdrop/0", "/emby/Items/displayed/Images/Logo"])
        XCTAssertFalse(paths.contains { $0.contains("/reduced/") || $0.contains("/no-backdrop/") })
        await model.shutdown()
    }

    func testMissingAndMalformedLandscapeImagesFallBackToDeclaredWidePrimary() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let wide = try png(width: 400, height: 225)
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            recorder.append(request)
            if request.url!.path.contains("Backdrop") { return (404, Data()) }
            return (200, request.url!.path.hasSuffix("Thumb") ? Data("invalid image".utf8) : wide)
        }
        let item = try media(["ImageTags": ["Primary": "still", "Thumb": "thumb"], "BackdropImageTags": ["missing"], "PrimaryImageAspectRatio": 16.0 / 9])
        let image = await PosterCache().load(key: "fallback", item: item, client: fixture.client, role: .landscape)
        XCTAssertEqual(try XCTUnwrap(image).size, NSSize(width: 400, height: 225))
        XCTAssertEqual(recorder.values.map { $0.url!.path.components(separatedBy: "/Images/").last! }, ["Backdrop/0", "Thumb", "Primary"])
    }

    func testOversizedDetailBackdropFallsBackToTheNextDeclaredImage() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let wide = try png(width: 400, height: 225)
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            recorder.append(request)
            return (200, request.url!.path.hasSuffix("/Backdrop/0") ? Data(count: 15 * 1024 * 1024 + 1) : wide)
        }
        let item = try media(["BackdropImageTags": ["oversized", "usable"], "ImageTags": ["Thumb": "unused"]])
        let image = await PosterCache().load(key: "oversized", item: item, client: fixture.client,
            role: .detailBackdrop, requestWidth: 2560)
        XCTAssertEqual(try XCTUnwrap(image).size, NSSize(width: 400, height: 225))
        XCTAssertEqual(recorder.values.map { $0.url!.path }, ["/emby/Items/movie/Images/Backdrop/0", "/emby/Items/movie/Images/Backdrop/1"])
    }

    func testPhysicallyPortraitBackdropIsRejectedAndNoUnknownPrimaryFallbackOccurs() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let portrait = try png(width: 200, height: 300)
        let wide = try png(width: 400, height: 225)
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in
            recorder.append(request)
            return (200, request.url!.path.hasSuffix("Thumb") ? wide : portrait)
        }
        let cache = PosterCache()
        let fallback = try media(["ImageTags": ["Primary": "poster", "Thumb": "thumb"], "BackdropImageTags": ["bad"]])
        let image = await cache.load(key: "physical", item: fallback, client: fixture.client, role: .landscape)
        XCTAssertEqual(try XCTUnwrap(image).size, NSSize(width: 400, height: 225))
        let missing = try media(["ImageTags": ["Primary": "poster"], "BackdropImageTags": ["bad"]])
        let noImage = await cache.load(key: "physical", item: missing, client: fixture.client, role: .landscape)
        XCTAssertNil(noImage)
        XCTAssertFalse(recorder.values.contains { $0.url!.path.hasSuffix("Primary") })
    }

    func testLaterOwnAndInheritedBackdropsRecoverFromMissingCorruptAndPortraitFirstImages() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let wide = try png(width: 400, height: 225)
        let portrait = try png(width: 200, height: 300)
        for owner in ["movie", "parent"] {
            for failure in ["missing", "corrupt", "portrait"] {
                let recorder = CacheRequests()
                ArtworkCacheURLProtocol.handler = { request in
                    recorder.append(request)
                    if request.url!.path.hasSuffix("/Backdrop/1") {
                        switch failure {
                        case "missing": return (404, Data())
                        case "corrupt": return (200, Data("invalid image".utf8))
                        default: return (200, portrait)
                        }
                    }
                    return (200, wide)
                }
                let values: [String: Any] = owner == "movie"
                    ? ["BackdropImageTags": ["", "broken", "good", "unused"], "ImageTags": ["Thumb": "unused-thumb"]]
                    : ["ParentBackdropItemId": "parent", "ParentBackdropImageTags": ["", "broken", "good", "unused"],
                       "ParentThumbItemId": "parent", "ParentThumbImageTag": "unused-thumb"]
                let image = await PosterCache().load(key: "later-backdrop", item: try media(values), client: fixture.client, role: .landscape)
                XCTAssertEqual(try XCTUnwrap(image).size, NSSize(width: 400, height: 225), "\(owner) / \(failure)")
                XCTAssertEqual(recorder.values.map { $0.url!.path }, [
                    "/emby/Items/\(owner)/Images/Backdrop/1", "/emby/Items/\(owner)/Images/Backdrop/2"
                ], "The next declared backdrop must be tried before changing image type; stop after success")
            }
        }
    }

    func testAuthorizationFailureStopsFallbackAndIdentitySeparatesCachedImages() async throws {
        let fixture = makeClient()
        let other = makeClient(userID: "other", connectionID: fixture.client.connection.id)
        defer {
            fixture.session.invalidateAndCancel(); other.session.invalidateAndCancel()
            ArtworkCacheURLProtocol.handler = nil
        }
        let wide = try png(width: 400, height: 225)
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in recorder.append(request); return (401, Data()) }
        let item = try media(["ImageTags": ["Thumb": "thumb"], "BackdropImageTags": ["wide"]])
        let cache = PosterCache()
        let rejected = await cache.load(key: "same", item: item, client: fixture.client, role: .landscape)
        XCTAssertNil(rejected)
        XCTAssertEqual(recorder.values.count, 1)
        ArtworkCacheURLProtocol.handler = { request in recorder.append(request); return (200, wide) }
        let first = await cache.load(key: "same", item: item, client: fixture.client, role: .landscape)
        let second = await cache.load(key: "same", item: item, client: other.client, role: .landscape)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertFalse(first === second)
        XCTAssertEqual(recorder.values.count, 3, "Even reused connection IDs must not share another account's image")
    }

    func testRevokedQueuedLandscapeRequestDoesNotSendOrPoisonCache() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkCacheURLProtocol.handler = nil }
        let gate = PosterRequestGate(limit: 1)
        let cache = PosterCache(gate: gate)
        let item = try media(["BackdropImageTags": ["wide"], "ImageTags": ["Thumb": "thumb"]])
        let recorder = CacheRequests()
        ArtworkCacheURLProtocol.handler = { request in recorder.append(request); return (404, Data()) }
        await gate.acquire()
        let load = Task { await cache.load(key: "queued", item: item, client: fixture.client, role: .landscape) }
        let deadline = Date().addingTimeInterval(2)
        while await gate.waitingCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let waiting = await gate.waitingCount
        XCTAssertEqual(waiting, 1)
        cache.remove(connectionID: fixture.client.connection.id)
        await gate.release()
        let image = await load.value
        XCTAssertNil(image)
        XCTAssertTrue(recorder.values.isEmpty)
        let wide = try png(width: 400, height: 225)
        ArtworkCacheURLProtocol.handler = { request in recorder.append(request); return (200, wide) }
        let fresh = await cache.load(key: "queued", item: item, client: fixture.client, role: .landscape)
        XCTAssertNotNil(fresh)
        XCTAssertEqual(recorder.values.count, 1)
    }

    private func png(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func media(_ extra: [String: Any]) throws -> MediaItem {
        var json: [String: Any] = ["Id": "movie", "Name": "Fixture", "Type": "Movie"]
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makeClient(userID: String = "viewer", connectionID: UUID = UUID()) -> (client: MediaServerClient, session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkCacheURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test/emby")!,
                                          serverID: "server", userID: userID, username: userID, libraryIDs: ["library"])
        connection.id = connectionID
        return (MediaServerClient(connection: connection, token: "fixture-token", deviceID: "device", session: session), session)
    }
}

private final class CacheRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class ArtworkCacheURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class CreditFixtureStorage: ApplicationPersisting {
    var saved = SavedApplication()
    init(_ connection: ServerConnection) {
        saved.connections = [connection]
        saved.selectedID = connection.id
    }
    func load() throws -> SavedApplication { saved }
    func save(_ value: SavedApplication) throws { saved = value }
}
