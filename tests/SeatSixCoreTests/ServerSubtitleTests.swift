import XCTest
@testable import SeatSixCore

final class ServerSubtitleTests: XCTestCase {
    private var session: URLSession!
    private let connectionID = UUID()

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        SubtitleURLProtocol.handler = nil
        super.tearDown()
    }

    func testStandardServerKindsDownloadSelectedSourceWithCurrentAuthentication() async throws {
        for kind in ServerKind.allCases {
            var requestedSubtitle = false
            SubtitleURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("PlaybackInfo") {
                    return .json(["PlaySessionId": "play-1", "MediaSources": [Self.source(id: "source-a", subtitles: [Self.subtitle(index: 2)]), Self.source(id: "source-b", subtitles: [Self.subtitle(index: 9)])]])
                }
                requestedSubtitle = true
                XCTAssertEqual(request.url!.path, "/base/Videos/movie-1/source-b/Subtitles/9/Stream.srt")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "StartPositionTicks" }?.value, "0")
                XCTAssertEqual(query.first { $0.name == "CopyTimestamps" }?.value, "true")
                XCTAssertFalse(query.contains { $0.name == "api_key" })
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "current-fixture-token")
                XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("current-fixture-token"))
                return SubtitleResponse(data: Self.subtitleData)
            }
            let client = makeClient(kind: kind)
            let plan = try await client.playbackPlan(item: movie(), mediaSourceID: "source-b", capability: .localDecoder)
            XCTAssertEqual(plan.externalSubtitles.count, 1)
            let subtitle = try XCTUnwrap(plan.externalSubtitles.first)
            XCTAssertEqual(subtitle.mediaSourceID, plan.mediaSourceID)
            XCTAssertEqual(subtitle.streamIndex, 9)
            let downloaded = try await client.downloadSubtitle(subtitle)
            XCTAssertEqual(downloaded.data, Self.subtitleData)
            XCTAssertEqual(downloaded.fileExtension, "srt")
            XCTAssertTrue(requestedSubtitle)
        }
    }

    func testOnlyExternalWhitelistedTextCodecsBecomeCandidates() async throws {
        let codecs = ["srt", "subrip", "ass", "ssa", "webvtt", "vtt", "pgssub", "dvdsub", "unknown"]
        var streams = codecs.enumerated().map { Self.subtitle(index: $0.offset, codec: $0.element) }
        streams.append(Self.subtitle(index: 20, external: false))
        streams.append(Self.subtitle(index: -1))
        streams.append(Self.subtitle(index: Int.max))
        streams.append(Self.subtitle(index: 0)) // Duplicate server index must not duplicate the menu.
        let source = Self.source(id: "source-a", subtitles: streams)
        SubtitleURLProtocol.handler = { _ in .json(["PlaySessionId": "play-1", "MediaSources": [source]]) }
        let plan = try await makeClient().playbackPlan(item: movie(), capability: .localDecoder)
        XCTAssertEqual(plan.externalSubtitles.map(\.streamIndex), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(plan.externalSubtitles.map(\.fileExtension), ["srt", "srt", "ass", "ssa", "vtt", "vtt"])
        XCTAssertEqual(plan.externalSubtitles.first?.title, "Chinese subtitles")
        XCTAssertEqual(plan.externalSubtitles.first?.language, "zho")
        XCTAssertEqual(plan.externalSubtitles.first?.isForced, true)
        XCTAssertEqual(plan.externalSubtitles.first?.isDefault, true)
    }

    func testCompatibilityRequiresExplicitSafeDeliveryURLAndStripsStaleTokens() async throws {
        var good = Self.subtitle(index: 1)
        var url = URLComponents(string: "/base/subtitle.srt")!
        url.queryItems = [URLQueryItem(name: "api_key", value: "obsolete-fixture-token"), URLQueryItem(name: "StartPositionTicks", value: "999")]
        good["DeliveryUrl"] = url.string!
        var bad = Self.subtitle(index: 2)
        bad["DeliveryUrl"] = "https://other.example/subtitle.srt"
        let source = Self.source(id: "source-a", subtitles: [Self.subtitle(index: 0), good, bad])
        SubtitleURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("PlaybackInfo") { return .json(["PlaySessionId": "play-1", "MediaSources": [source]]) }
            XCTAssertEqual(request.url!.path, "/base/subtitle.srt")
            XCTAssertFalse(request.url!.absoluteString.contains("obsolete-fixture-token"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "current-fixture-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return SubtitleResponse(data: Self.subtitleData)
        }
        let client = makeClient(compatibility: true)
        let plan = try await client.playbackPlan(item: movie(), capability: .localDecoder)
        XCTAssertEqual(plan.externalSubtitles.map(\.streamIndex), [1])
        _ = try await client.downloadSubtitle(XCTUnwrap(plan.externalSubtitles.first))
    }

    func testUnsafeDeliveryURLsAreNotOfferedAndOtherConnectionCannotDownload() async throws {
        let values = ["https://other.example/subtitle.srt", "//other.example/subtitle.srt", "http://media.example:9443/subtitle.srt", "https://name:password@media.example:9443/subtitle.srt", "/sub.srt#fragment", "file:///tmp/subtitle.srt", "\\\\other.example\\sub.srt", ""]
        let streams = values.enumerated().map { index, value -> [String: Any] in var stream = Self.subtitle(index: index); stream["DeliveryUrl"] = value; return stream } + [Self.subtitle(index: 99)]
        SubtitleURLProtocol.handler = { _ in .json(["PlaySessionId": "play-1", "MediaSources": [Self.source(id: "source-a", subtitles: streams)]]) }
        let plan = try await makeClient().playbackPlan(item: movie(), capability: .localDecoder)
        XCTAssertEqual(plan.externalSubtitles.map(\.streamIndex), [99])
        let subtitle = try XCTUnwrap(plan.externalSubtitles.first)
        let other = makeClient(id: UUID())
        do { _ = try await other.downloadSubtitle(subtitle); XCTFail("Cross-connection download allowed") }
        catch { XCTAssertEqual(error as? MediaServerError, .invalidScope) }
    }

    func testRedirectResponsesAreRejectedAndDelegateRefusesRedirect() async throws {
        let client = makeClient()
        let subtitle = try await candidate(client)
        var count = 0
        SubtitleURLProtocol.handler = { _ in count += 1; return SubtitleResponse(status: 302, headers: ["Location": "https://other.example/sub.srt"]) }
        do { _ = try await client.downloadSubtitle(subtitle); XCTFail("Redirect accepted") }
        catch { XCTAssertEqual(error as? MediaServerError, .httpStatus(302)) }
        XCTAssertEqual(count, 1)
        let delegate = CertificateSessionDelegate(pin: nil)
        let source = URL(string: "https://media.example:9443/base/sub.srt")!
        let target = URL(string: "https://other.example/sub.srt")!
        let task = session.dataTask(with: source)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: target)) { XCTAssertNil($0) }
        task.cancel()
    }

    func testOversizeDeclaredAndUndeclaredBodiesAreRejected() async throws {
        let client = makeClient()
        let subtitle = try await candidate(client)
        SubtitleURLProtocol.handler = { _ in SubtitleResponse(headers: ["Content-Length": String(10 * 1024 * 1024 + 1)]) }
        do { _ = try await client.downloadSubtitle(subtitle); XCTFail("Declared oversize accepted") }
        catch { XCTAssertEqual(error as? MediaServerError, .subtitleTooLarge) }
        SubtitleURLProtocol.handler = { _ in SubtitleResponse(data: Data(repeating: 65, count: 10 * 1024 * 1024 + 1)) }
        do { _ = try await client.downloadSubtitle(subtitle); XCTFail("Undeclared oversize accepted") }
        catch { XCTAssertEqual(error as? MediaServerError, .subtitleTooLarge) }
    }

    func testDownloadCancellationAndErrorsDoNotExposeServerContent() async throws {
        let client = makeClient()
        let subtitle = try await candidate(client)
        SubtitleURLProtocol.handler = { _ in SubtitleResponse(data: Self.subtitleData, delay: 2) }
        let download = Task { try await client.downloadSubtitle(subtitle) }
        try await Task.sleep(nanoseconds: 40_000_000)
        download.cancel()
        do { _ = try await download.value; XCTFail("Cancelled download succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        SubtitleURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "sensitive-fixture-server-detail"]) }
        do { _ = try await client.downloadSubtitle(subtitle); XCTFail("Failed request succeeded") }
        catch {
            XCTAssertEqual(error as? MediaServerError, .network)
            XCTAssertFalse(error.localizedDescription.contains("sensitive-fixture"))
        }
    }

    func testTLSFailureRetainsCertificateErrorAndPinOriginCheckedBeforeRequest() async throws {
        let client = makeClient()
        let subtitle = try await candidate(client)
        SubtitleURLProtocol.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do { _ = try await client.downloadSubtitle(subtitle); XCTFail("Untrusted TLS accepted") }
        catch { XCTAssertEqual(error as? MediaServerError, .certificate(.untrusted)) }
        // Exact trust decisions are delegated to the same CertificateSessionDelegate as API calls.
        // Existing CertificateTrustTests exercise its leaf fingerprint and origin policy.
        let pin = try JSONDecoder().decode(CertificatePin.self, from: JSONSerialization.data(withJSONObject: ["origin": "https://other.example:443", "certificateDER": Data([0]).base64EncodedString(), "approvedAt": 0]))
        let pinned = makeClient(pin: pin)
        do { _ = try await pinned.downloadSubtitle(subtitle); XCTFail("Wrong-origin pin accepted") }
        catch { XCTAssertEqual(error as? MediaServerError, .certificate(.originMismatch)) }
    }

    private func candidate(_ client: MediaServerClient) async throws -> ServerSubtitle {
        SubtitleURLProtocol.handler = { _ in .json(["PlaySessionId": "play-1", "MediaSources": [Self.source(id: "source-a", subtitles: [Self.subtitle(index: 2)])]]) }
        let plan = try await client.playbackPlan(item: movie(), capability: .localDecoder)
        return try XCTUnwrap(plan.externalSubtitles.first)
    }
    private func makeClient(kind: ServerKind = .emby, compatibility: Bool = false, id: UUID? = nil, pin: CertificatePin? = nil) -> MediaServerClient {
        let connection = ServerConnection(id: id ?? connectionID, kind: kind, name: "Fixture", baseURL: URL(string: "https://media.example:9443/base")!, serverID: "server-1", userID: "user-1", username: "fixture", compatibilityMode: compatibility, certificatePin: pin)
        return MediaServerClient(connection: connection, token: "current-fixture-token", deviceID: "fixture-device", session: session)
    }
    private func movie() throws -> MediaItem { try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: ["Id": "movie-1", "Name": "Fixture", "Type": "Movie"])) }
    private static func source(id: String, subtitles: [[String: Any]]) -> [String: Any] {
        ["Id": id, "Container": "mkv", "Protocol": "Http", "Path": "/base/video.mkv", "SupportsDirectPlay": true, "MediaStreams": [["Type": "Video", "Codec": "hevc"], ["Type": "Audio", "Codec": "aac"]] + subtitles]
    }
    private static func subtitle(index: Int, codec: String = "subrip", external: Bool = true) -> [String: Any] {
        ["Type": "Subtitle", "Codec": codec, "Index": index, "IsExternal": external, "IsTextSubtitleStream": true, "DisplayTitle": "Chinese subtitles", "Language": "zho", "IsDefault": true, "IsForced": true]
    }
    private static let subtitleData = Data("1\n00:00:01,000 --> 00:00:02,000\nFixture subtitle\n".utf8)
}

private struct SubtitleResponse {
    var status = 200
    var headers: [String: String] = [:]
    var data = Data()
    var delay: TimeInterval = 0
    static func json(_ value: [String: Any]) -> Self { SubtitleResponse(data: try! JSONSerialization.data(withJSONObject: value)) }
}

private final class SubtitleURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> SubtitleResponse)?
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response = try Self.handler!(request)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: response.data)
                self.client?.urlProtocolDidFinishLoading(self)
            }
            pending = work
            DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: work)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { pending?.cancel(); pending = nil }
}
