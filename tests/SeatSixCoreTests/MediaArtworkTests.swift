import Foundation
import XCTest
@testable import SeatSixCore

final class MediaArtworkTests: XCTestCase {
    func testLandscapeSourcesPreferDeclaredWideArtAndPreserveBackdropIndex() throws {
        let item = try media([
            "ImageTags": ["Primary": "vertical", "Thumb": "thumb"],
            "BackdropImageTags": [NSNull(), 42, "", "backdrop"],
            "PrimaryImageAspectRatio": 0.7,
            "ParentBackdropItemId": "parent", "ParentBackdropImageTags": ["parent-backdrop"],
            "ParentThumbItemId": "parent", "ParentThumbImageTag": "parent-thumb",
            "SeriesId": "series", "SeriesThumbImageTag": "series-thumb"
        ])
        XCTAssertEqual(item.landscapeArtworkSources, [
            .init(itemID: "movie", type: .backdrop, tag: "backdrop", index: 3),
            .init(itemID: "movie", type: .thumb, tag: "thumb"),
            .init(itemID: "parent", type: .backdrop, tag: "parent-backdrop", index: 0),
            .init(itemID: "parent", type: .thumb, tag: "parent-thumb"),
            .init(itemID: "series", type: .thumb, tag: "series-thumb")
        ])
        XCTAssertEqual(item.artworkSources(for: .poster), [.init(itemID: "movie", type: .primary, tag: "vertical")])
    }

    func testPrimaryRequiresExplicitWideRatioAndPrecedesInheritedArt() throws {
        for ratio in [nil, 0.7, 1.0, 1.32] as [Double?] {
            var values: [String: Any] = ["ImageTags": ["Primary": "primary"]]
            if let ratio { values["PrimaryImageAspectRatio"] = ratio }
            XCTAssertTrue(try media(values).landscapeArtworkSources.isEmpty)
        }
        var item = try media(["Type": "Episode", "ImageTags": ["Primary": "still"], "PrimaryImageAspectRatio": 16.0 / 9,
                              "ParentThumbItemId": "series", "ParentThumbImageTag": "inherited"])
        XCTAssertEqual(item.landscapeArtworkSources.map(\.tag), ["still", "inherited"])
        item.primaryImageAspectRatio = .infinity
        XCTAssertEqual(item.landscapeArtworkSources.map(\.tag), ["inherited"])
        item.primaryImageAspectRatio = .nan
        XCTAssertEqual(item.landscapeArtworkSources.map(\.tag), ["inherited"])
    }

    func testBackdropFallbacksAreBoundedPerOwnerWithoutRenumberingImages() throws {
        let item = try media([
            "BackdropImageTags": [NSNull(), "first", "second", "third", "fourth"],
            "ImageTags": ["Thumb": "thumb"],
            "ParentBackdropItemId": "parent",
            "ParentBackdropImageTags": ["", "parent-first", NSNull(), "parent-second", "parent-third", "parent-fourth"]
        ])
        XCTAssertEqual(item.landscapeArtworkSources, [
            .init(itemID: "movie", type: .backdrop, tag: "first", index: 1),
            .init(itemID: "movie", type: .backdrop, tag: "second", index: 2),
            .init(itemID: "movie", type: .backdrop, tag: "third", index: 3),
            .init(itemID: "movie", type: .thumb, tag: "thumb"),
            .init(itemID: "parent", type: .backdrop, tag: "parent-first", index: 1),
            .init(itemID: "parent", type: .backdrop, tag: "parent-second", index: 3),
            .init(itemID: "parent", type: .backdrop, tag: "parent-third", index: 4)
        ])
    }

    func testMalformedOptionalArtworkDoesNotRejectMediaOrInventOwners() throws {
        let item = try media(["ImageTags": ["Primary": 42, "Thumb": "valid-thumb"],
                              "BackdropImageTags": "bad", "PrimaryImageAspectRatio": "bad",
                              "ParentBackdropItemId": ["bad"], "ParentBackdropImageTags": ["orphan"],
                              "ParentThumbItemId": "../other", "ParentThumbImageTag": "unsafe",
                              "SeriesThumbImageTag": "orphan"])
        XCTAssertEqual(item.landscapeArtworkSources, [.init(itemID: "movie", type: .thumb, tag: "valid-thumb")])
        XCTAssertTrue(item.artworkSources(for: .poster).isEmpty)
        let empty = try media(["ImageTags": ["Thumb": "  "], "BackdropImageTags": [NSNull(), "\n"]])
        XCTAssertTrue(empty.landscapeArtworkSources.isEmpty)
    }

    func testLandscapeRequestRetainsAuthenticationAndImageOwnerIndexAndWidth() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkURLProtocol.handler = nil }
        let recorder = ArtworkRequests()
        ArtworkURLProtocol.handler = { request in recorder.append(request); return (200, Data([1, 2, 3])) }
        let source = MediaArtworkSource(itemID: "parent", type: .backdrop, tag: "tag+with/value", index: 2)
        let data = try await fixture.client.imageData(source: source, width: 1600)
        XCTAssertEqual(data, Data([1, 2, 3]))
        let request = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(request.url?.path, "/emby/Items/parent/Images/Backdrop/2")
        XCTAssertEqual(query(request)["Tag"], "tag+with/value")
        XCTAssertEqual(query(request)["MaxWidth"], "1600")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
        XCTAssertNil(query(request)["api_key"])
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(fixture.client.imageURL(source: source, width: 9000)), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "MaxWidth" })?.value, "1600")
    }

    func testInvalidSourcesAndMissingPosterDoNotSendRequests() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkURLProtocol.handler = nil }
        let recorder = ArtworkRequests()
        ArtworkURLProtocol.handler = { request in recorder.append(request); return (200, Data()) }
        for source in [MediaArtworkSource(itemID: "../outside", type: .thumb, tag: "tag"),
                       .init(itemID: "valid", type: .backdrop, tag: "tag", index: -1),
                       .init(itemID: "valid", type: .backdrop, tag: "tag"),
                       .init(itemID: "valid", type: .primary, tag: "tag", index: 0),
                       .init(itemID: "valid", type: .thumb, tag: "")] {
            XCTAssertNil(fixture.client.imageURL(source: source))
            let data = try await fixture.client.imageData(source: source)
            XCTAssertNil(data)
        }
        let data = try await fixture.client.imageData(item: media([:]))
        XCTAssertNil(data)
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testDetailBackdropSizeLimitAndOwnTitleLogoRequests() async throws {
        let fixture = makeClient()
        defer { fixture.session.invalidateAndCancel(); ArtworkURLProtocol.handler = nil }
        let item = try media(["Id": "episode", "Type": "Episode", "SeriesId": "parent",
                              "ImageTags": ["Primary": "portrait", "Logo": "title"],
                              "BackdropImageTags": ["scene"], "ParentLogoItemId": "parent", "ParentLogoImageTag": "series-title"])
        let backdrop = try XCTUnwrap(item.artworkSources(for: .detailBackdrop).first)
        XCTAssertEqual(item.artworkSources(for: .detailBackdrop), item.landscapeArtworkSources)
        XCTAssertFalse(item.artworkSources(for: .detailBackdrop).contains { $0.type == .primary })
        let logo = try XCTUnwrap(item.artworkSources(for: .logo).first)
        XCTAssertEqual(logo, .init(itemID: "episode", type: .logo, tag: "title"))
        XCTAssertTrue(try media(["Type": "Episode", "SeriesId": "parent", "ParentLogoItemId": "parent",
                                 "ParentLogoImageTag": "series-title"]).artworkSources(for: .logo).isEmpty)
        let url = try XCTUnwrap(fixture.client.imageURL(source: logo, width: 20_000, role: .logo))
        XCTAssertEqual(url.path, "/emby/Items/episode/Images/Logo")
        XCTAssertEqual(query(URLRequest(url: url))["MaxWidth"], "600")
        XCTAssertEqual(query(URLRequest(url: url))["Format"], "Png")

        let recorder = ArtworkRequests()
        ArtworkURLProtocol.handler = { request in recorder.append(request); return (200, Data(count: 15 * 1024 * 1024 + 1)) }
        let oversized = try await fixture.client.imageData(source: backdrop, width: 20_000, role: .detailBackdrop)
        XCTAssertNil(oversized, "An oversized response must be discarded before decoding")
        XCTAssertEqual(query(try XCTUnwrap(recorder.values.first))["MaxWidth"], "2560")
    }

    func testCompatibleFirstBackdropUsesUnindexedAuthenticatedEndpoint() async throws {
        let fixture = makeClient(compatibility: true)
        defer { fixture.session.invalidateAndCancel(); ArtworkURLProtocol.handler = nil }
        let recorder = ArtworkRequests()
        let imageBytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        ArtworkURLProtocol.handler = { request in
            recorder.append(request)
            // This interface serves the default backdrop but rejects /Backdrop/0.
            guard request.url?.path == "/emby/Items/movie/Images/Backdrop" else {
                return (404, Data())
            }
            return (200, imageBytes)
        }
        let source = MediaArtworkSource(itemID: "movie", type: .backdrop, tag: "wide+tag/value", index: 0)
        let received = try await fixture.client.imageData(source: source, width: 1600)
        XCTAssertEqual(received, imageBytes)
        let request = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(request.url?.path, "/emby/Items/movie/Images/Backdrop")
        XCTAssertEqual(query(request)["Tag"], "wide+tag/value")
        XCTAssertEqual(query(request)["MaxWidth"], "1600")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "fixture-token")
        XCTAssertNil(query(request)["api_key"])
    }

    func testBackdropIndexPathsRemainDistinctAcrossServerModes() throws {
        for kind in [ServerKind.emby, .jellyfin] {
            for compatibility in [false, true] {
                let fixture = makeClient(kind: kind, compatibility: compatibility)
                defer { fixture.session.invalidateAndCancel() }
                let first = MediaArtworkSource(itemID: "parent", type: .backdrop, tag: "first", index: 0)
                let later = MediaArtworkSource(itemID: "parent", type: .backdrop, tag: "later", index: 2)
                XCTAssertEqual(fixture.client.imageURL(source: first)?.path,
                               compatibility ? "/emby/Items/parent/Images/Backdrop" : "/emby/Items/parent/Images/Backdrop/0")
                XCTAssertEqual(fixture.client.imageURL(source: later)?.path, "/emby/Items/parent/Images/Backdrop/2")
                let primary = MediaArtworkSource(itemID: "parent", type: .primary, tag: "poster")
                XCTAssertEqual(fixture.client.imageURL(source: primary)?.path, "/emby/Items/parent/Images/Primary")
            }
        }
    }

    func testCatalogAndResumeRequestImageMetadataForBothServerModes() async throws {
        for compatibility in [false, true] {
            let fixture = makeClient(compatibility: compatibility)
            defer { fixture.session.invalidateAndCancel(); ArtworkURLProtocol.handler = nil }
            let recorder = ArtworkRequests()
            ArtworkURLProtocol.handler = { request in
                recorder.append(request)
                return (200, Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8))
            }
            _ = try await fixture.client.libraryCatalog(libraryID: "library")
            _ = try await fixture.client.resumeItems()
            XCTAssertEqual(recorder.values.count, compatibility ? 1 : 2)
            for request in recorder.values {
                XCTAssertEqual(query(request)["EnableImages"], "true")
                XCTAssertTrue(query(request)["Fields"]?.split(separator: ",").contains("PrimaryImageAspectRatio") == true)
                XCTAssertEqual(query(request)["ParentId"], "library")
            }
        }
    }

    private func media(_ extra: [String: Any]) throws -> MediaItem {
        var json: [String: Any] = ["Id": "movie", "Name": "Fixture", "Type": "Movie"]
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makeClient(kind: ServerKind = .emby, compatibility: Bool = false) -> (client: MediaServerClient, session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let connection = ServerConnection(kind: kind, name: "Fixture", baseURL: URL(string: "https://fixture.test/emby")!,
                                          serverID: "server", userID: "viewer", username: "viewer", libraryIDs: ["library"], compatibilityMode: compatibility)
        return (MediaServerClient(connection: connection, token: "fixture-token", deviceID: "device", session: session), session)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}

private final class ArtworkRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var values: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
}

private final class ArtworkURLProtocol: URLProtocol {
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
