import XCTest
@testable import SeatSixCore

final class SeatSixCoreTests: XCTestCase {
    private var session: URLSession!
    private var recorder: RequestRecorder!

    override func setUp() {
        super.setUp()
        recorder = RequestRecorder()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() { session.invalidateAndCancel(); StubURLProtocol.handler = nil; super.tearDown() }

    func testEndpointPreservesPortAndBasePath() throws {
        let endpoint = try ServerEndpoint(address: " https://media.example:9443/jellyfin/ ")
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://media.example:9443/jellyfin")
        XCTAssertEqual(try ServerEndpoint(address: "http://127.0.0.1:8096", allowInsecureHTTP: true).baseURL.host, "127.0.0.1")
        XCTAssertEqual(try ServerEndpoint(address: "http://[::1]:8096", allowInsecureHTTP: true).baseURL.port, 8096)
    }

    func testEndpointRejectsCredentialsQueriesAndPublicCleartext() {
        let queryAddress = Self.fixtureURL("https://media.example", query: ["api_key": "fixture-query-value"])
        for address in ["media.example", "ftp://media.example", "https://user:secret@media.example", queryAddress, "https://media.example#token", "https://media.example:70000"] {
            XCTAssertThrowsError(try ServerEndpoint(address: address), address)
        }
        XCTAssertThrowsError(try ServerEndpoint(address: "http://127.0.0.1:8096"))
        XCTAssertThrowsError(try ServerEndpoint(address: "http://media.example", allowInsecureHTTP: true))
        XCTAssertThrowsError(try ServerEndpoint(address: "http://172.32.1.2", allowInsecureHTTP: true))
    }

    func testBothServerKindsAuthenticateWithPascalCaseAndNoPasswordPersistence() async throws {
        for kind in ServerKind.allCases {
            let recorder = self.recorder!
            StubURLProtocol.handler = { request in
                recorder.append(request)
                if request.url!.path.hasSuffix("/Public") { return .json(["Id": "server-1", "ServerName": "测试服务器"]) }
                return .json(["User": ["Id": "user-1", "Name": "Leon"], "AccessToken": "private-token", "ServerId": "server-1"])
            }
            let authenticated = try await MediaServerClient.authenticate(kind: kind, address: "https://media.example:9443/base", username: "Leon", password: "password-only-in-request", deviceID: "test-device", session: session)
            XCTAssertEqual(authenticated.connection.kind, kind)
            XCTAssertEqual(authenticated.connection.serverID, "server-1")
            XCTAssertEqual(authenticated.connection.userID, "user-1")
            XCTAssertEqual(authenticated.token, "private-token")
            let request = recorder.requests.last!
            XCTAssertEqual(request.url!.path, "/base/Users/AuthenticateByName")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.value(forHTTPHeaderField: "X-Emby-Authorization")!.contains("DeviceId=\"test-device\""))
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.hasPrefix("MediaBrowser Client=\"SeatSix\""), "Modern Jellyfin requires the standard Authorization header")
            let body = try request.jsonBody()
            XCTAssertEqual(body["Username"] as? String, "Leon")
            XCTAssertEqual(body["Pw"] as? String, "password-only-in-request")
            let persisted = String(data: try JSONEncoder().encode(authenticated.connection), encoding: .utf8)!
            XCTAssertFalse(persisted.contains("private-token"))
            XCTAssertFalse(persisted.contains("password-only-in-request"))
        }
    }

    func testWrongProductAndIdentityMismatchAreRejected() async throws {
        StubURLProtocol.handler = { _ in .json(["Id": "server-1", "ProductName": "Jellyfin Server"]) }
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: "https://media.example", username: "u", password: "p", deviceID: "test", session: session)
            XCTFail("Mismatched product accepted")
        } catch { XCTAssertEqual(error as? MediaServerError, .wrongServerKind) }
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Public") { return .json(["Id": "server-1"]) }
            return .json(["User": ["Id": "u"], "AccessToken": "t", "ServerId": "different-server"])
        }
        do {
            _ = try await MediaServerClient.authenticate(kind: .jellyfin, address: "https://media.example", username: "u", password: "p", deviceID: "test", session: session)
            XCTFail("Changed identity accepted")
        } catch { XCTAssertEqual(error as? MediaServerError, .invalidResponse) }
    }

    func testPaginationAndSearchAreScopedToSelectedLibrary() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(["Items": [Self.movieJSON], "TotalRecordCount": 200, "StartIndex": 60]) }
        let client = makeClient()
        let page = try await client.items(libraryID: "library-1", startIndex: 60, search: "星 空&夜")
        XCTAssertEqual(page.totalRecordCount, 200)
        XCTAssertEqual(page.startIndex, 60)
        XCTAssertEqual(page.items.first?.userData.playbackPositionTicks, 321_000_000)
        let query = recorder.requests[0].query
        XCTAssertEqual(query["ParentId"], "library-1")
        XCTAssertEqual(query["SearchTerm"], "星 空&夜")
        XCTAssertEqual(query["StartIndex"], "60")
        XCTAssertEqual(recorder.requests[0].value(forHTTPHeaderField: "X-Emby-Token"), "secret")
        XCTAssertTrue(recorder.requests[0].value(forHTTPHeaderField: "Authorization")!.contains("Token=\"secret\""))
        do { _ = try await client.items(libraryID: "excluded-library"); XCTFail("Scope escape") }
        catch { XCTAssertEqual(error as? MediaServerError, .invalidScope) }
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testResumeRequestsOnlySelectedLibrariesAndDeduplicates() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(["Items": [Self.movieJSON]]) }
        var connection = makeConnection()
        connection.libraryIDs = ["library-1", "library-2"]
        let client = MediaServerClient(connection: connection, token: "secret", deviceID: "test", session: session)
        let items = try await client.resumeItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(recorder.requests.map { $0.query["ParentId"] }, ["library-1", "library-2"])
        connection.libraryIDs = []
        let emptyClient = MediaServerClient(connection: connection, token: "secret", deviceID: "test", session: session)
        let emptyItems = try await emptyClient.resumeItems()
        XCTAssertTrue(emptyItems.isEmpty)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testDirectPlanUsesZeroServerOffsetAndSeparateResumePosition() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(Self.playbackJSON(direct: true)) }
        let client = makeClient()
        let plan = try await client.playbackPlan(item: movie(), startTicks: 321_000_000)
        XCTAssertEqual(plan.method, .directPlay)
        XCTAssertEqual(plan.resumeTicks, 321_000_000)
        XCTAssertEqual(plan.url.path, "/base/Videos/movie-1/stream.mp4")
        XCTAssertEqual(URLRequest(url: plan.url).query["StartTimeTicks"], "0")
        XCTAssertEqual(URLRequest(url: plan.url).query["api_key"], "secret")
        XCTAssertEqual(recorder.requests[0].query["StartTimeTicks"], "0")
        let profile = try XCTUnwrap(try recorder.requests[0].jsonBody()["DeviceProfile"] as? [String: Any])
        XCTAssertEqual(profile["Name"] as? String, "SeatSix AVPlayer")
        XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, 8_000_000)
    }

    func testCompatibilityPlanAcceptsOnlySameOriginAndPreservesBasePath() async throws {
        let returnedURL = Self.fixtureURL("/Videos/movie-1/master.m3u8", query: ["StartTimeTicks": "999", "api_key": "fixture-old-value"])
        StubURLProtocol.handler = { _ in .json(Self.playbackJSON(direct: false, stream: returnedURL)) }
        let plan = try await makeClient().playbackPlan(item: movie(), mode: .compatible, startTicks: 250_000_000)
        XCTAssertTrue(plan.isTranscoding)
        XCTAssertEqual(plan.url.path, "/base/Videos/movie-1/master.m3u8")
        XCTAssertEqual(URLRequest(url: plan.url).query["api_key"], "secret")
        XCTAssertEqual(URLRequest(url: plan.url).query["StartTimeTicks"], "0")
        for malicious in ["https://other.example/movie.m3u8", "http://media.example:9443/base/movie.m3u8", "//other.example/movie.m3u8", "https://name:password@media.example:9443/base/movie.m3u8"] {
            XCTAssertThrowsError(try makeClient().authorizedStreamURL(malicious))
        }
    }

    func testUnsupportedSourceIsNotSilentlyDeclaredDirectPlayable() async throws {
        var response = Self.playbackJSON(direct: true)
        var source = (response["MediaSources"] as! [[String: Any]])[0]
        source["MediaStreams"] = [["Type": "Video", "Codec": "hevc"], ["Type": "Audio", "Codec": "dts"]]
        source["SupportsTranscoding"] = false
        response["MediaSources"] = [source]
        StubURLProtocol.handler = { _ in .json(response) }
        do { _ = try await makeClient().playbackPlan(item: movie()); XCTFail("Unsupported codec passed") }
        catch { XCTAssertEqual(error as? MediaServerError, .unsupportedMedia) }
    }

    func testAutomaticSystemPlaybackNegotiatesHLSForMKVOnEmbyAndJellyfin() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(Self.localPlaybackJSON()) }
        for kind in ServerKind.allCases {
            var connection = makeConnection()
            connection.kind = kind
            let client = MediaServerClient(connection: connection, token: "fixture", deviceID: "test", session: session)
            let plan = try await client.playbackPlan(item: movie(), mode: .automatic, capability: .avFoundation)
            XCTAssertEqual(plan.method, .transcode)
            XCTAssertEqual(plan.url.pathExtension, "m3u8")
            let request = try XCTUnwrap(recorder.requests.last)
            XCTAssertEqual(request.query["EnableDirectPlay"], "true")
            XCTAssertEqual(request.query["EnableTranscoding"], "true")
            let profile = try XCTUnwrap(try request.jsonBody()["DeviceProfile"] as? [String: Any])
            XCTAssertEqual(profile["Name"] as? String, "SeatSix AVPlayer")
        }
    }

    func testReportingSerializesCoalescesAndHonorsStopBarrier() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in
            recorder.append(request)
            return StubResponse(status: 204, data: Data(), delay: request.url!.path.hasSuffix("/Playing") ? 0.3 : 0)
        }
        let reporter = PlaybackReporter(client: makeClient(), plan: plan())
        let start = Task { try await reporter.start(positionTicks: 0) }
        try await waitForRequests(1)
        let first = Task { try await reporter.progress(positionTicks: 100, isPaused: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { try await reporter.progress(positionTicks: 200, isPaused: false) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let third = Task { try await reporter.progress(positionTicks: 50, isPaused: true) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let stop = Task { try await reporter.stop(positionTicks: 50) }
        try await start.value; try await first.value; try await second.value; try await third.value; try await stop.value
        XCTAssertEqual(recorder.requests.map { $0.url!.lastPathComponent }, ["Playing", "Progress", "Stopped"])
        XCTAssertEqual(try recorder.requests[1].jsonBody()["PositionTicks"] as? Int, 50, "A deliberate backward seek must survive coalescing")
        let status = await reporter.status()
        XCTAssertEqual(status, .ended)
    }

    func testFailedWriteStopsAutomaticProgressAndStopReplay() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); throw URLError(.timedOut) }
        let reporter = PlaybackReporter(client: makeClient(), plan: plan())
        do { try await reporter.start(); XCTFail("Failed write succeeded") } catch { XCTAssertEqual(error as? MediaServerError, .network) }
        for action in 0..<2 {
            do {
                if action == 0 { try await reporter.progress(positionTicks: 500, isPaused: false) }
                else { try await reporter.stop(positionTicks: 500) }
                XCTFail("Uncertain report replayed")
            } catch { XCTAssertEqual(error as? MediaServerError, .reportingUncertain) }
        }
        let status = await reporter.status()
        XCTAssertEqual(status, .uncertain)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testServerErrorsNeverExposeResponseBodyOrCredentials() async throws {
        let responseURL = Self.fixtureURL("https://media.example/", query: ["api_key": "fixture-response-value"])
        StubURLProtocol.handler = { _ in StubResponse(status: 401, data: Data(("private-token " + responseURL).utf8)) }
        do { _ = try await makeClient().item(id: "movie-1"); XCTFail("Unauthorized response succeeded") }
        catch {
            XCTAssertEqual(error as? MediaServerError, .httpStatus(401))
            XCTAssertFalse(error.localizedDescription.contains("private-token"))
            XCTAssertFalse(error.localizedDescription.contains("api_key"))
            XCTAssertFalse(error.localizedDescription.contains("media.example"))
        }
    }

    func testImageLoadsThroughAuthenticatedTransportAndIdentityIsScoped() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return StubResponse(status: 200, data: Data([1, 2, 3])) }
        let client = makeClient()
        let imageData = try await client.imageData(item: movie())
        XCTAssertEqual(imageData, Data([1, 2, 3]))
        XCTAssertEqual(recorder.requests[0].value(forHTTPHeaderField: "X-Emby-Token"), "secret")
        XCTAssertNil(recorder.requests[0].query["api_key"])
        XCTAssertEqual(client.identity(for: try movie()), MediaIdentity(serverID: "server-1", userID: "user-1", itemID: "movie-1"))
    }

    func testCompatibilityLoginDoesNotDependOnPublicDiscovery() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in
            recorder.append(request)
            return .json(["User": ["Id": "open-user-1", "Name": "Leon"], "AccessToken": "private-token", "ServerId": "server-1"])
        }
        let result = try await MediaServerClient.authenticate(kind: .emby, address: "https://media.example:9443/emby", username: "Leon", password: "", deviceID: "test", compatibilityMode: true, session: session)
        XCTAssertTrue(result.connection.compatibilityMode)
        XCTAssertEqual(result.connection.serverID, "server-1")
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests[0].url?.path, "/emby/Users/AuthenticateByName")
        XCTAssertNil(recorder.requests[0].value(forHTTPHeaderField: "Authorization"))
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeConnection())) as! [String: Any]
        oldJSON.removeValue(forKey: "compatibilityMode")
        XCTAssertFalse(try JSONDecoder().decode(ServerConnection.self, from: JSONSerialization.data(withJSONObject: oldJSON)).compatibilityMode)
    }

    func testCompatibilityUsesReturnedPathPreservesQueryAndIncludesRuntime() async throws {
        let recorder = self.recorder!
        var response = Self.playbackJSON(direct: true)
        var source = (response["MediaSources"] as! [[String: Any]])[0]
        source["Path"] = "/emby/videos/8226/stream.bin?signature=a%2Bb&source=original"
        source["Protocol"] = "Http"
        source["RunTimeTicks"] = 7_000_000_000 as Int64
        response["MediaSources"] = [source]
        StubURLProtocol.handler = { request in recorder.append(request); return request.url!.path.hasSuffix("PlaybackInfo") ? .json(response) : StubResponse(status: 204, data: Data()) }
        let client = compatibilityClient()
        let plan = try await client.playbackPlan(item: movie(), startTicks: 800_000_000)
        XCTAssertEqual(plan.url.path, "/emby/videos/8226/stream.bin", "Use Path; route suffix does not declare its actual container")
        XCTAssertFalse(plan.url.path.contains("/emby/emby"))
        XCTAssertEqual(URLRequest(url: plan.url).query["signature"], "a+b")
        XCTAssertEqual(URLRequest(url: plan.url).query["source"], "original")
        XCTAssertNil(URLRequest(url: plan.url).query["StartTimeTicks"])
        XCTAssertEqual(plan.runtimeTicks, 7_000_000_000)
        XCTAssertEqual(plan.resumeTicks, 800_000_000)
        let reporter = PlaybackReporter(client: client, plan: plan)
        try await reporter.start(positionTicks: plan.resumeTicks)
        try await reporter.stop(positionTicks: 900_000_000)
        XCTAssertEqual(try recorder.requests.last!.jsonBody()["RunTimeTicks"] as? Int64, 7_000_000_000)
    }

    func testCompatibilityRejectsMKVEvenWhenPathSaysMP4AndNeverOffersTranscode() async throws {
        let recorder = self.recorder!
        var response = Self.playbackJSON(direct: true)
        var source = (response["MediaSources"] as! [[String: Any]])[0]
        source["Path"] = "/emby/videos/8226/stream.mp4"
        source["Protocol"] = "Http"
        source["Container"] = "mkv"
        response["MediaSources"] = [source]
        StubURLProtocol.handler = { request in recorder.append(request); return .json(response) }
        for mode in PlaybackMode.allCases {
            do { _ = try await compatibilityClient().playbackPlan(item: movie(), mode: mode); XCTFail("Unsupported compatibility format accepted") }
            catch { XCTAssertEqual(error as? MediaServerError, .unsupportedCompatibilityMedia) }
        }
        XCTAssertEqual(recorder.requests.count, 1, "Compatibility mode must never ask this server for transcoding")
        XCTAssertEqual(recorder.requests.first?.query["EnableTranscoding"], "false")
    }

    func testCompatibilityDoesNotInvokeUnscopedResumeOrUnsupportedSearch() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(["Items": []]) }
        let client = compatibilityClient()
        let result = try await client.resumeItems()
        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(recorder.requests.isEmpty)
        _ = try await client.items(libraryID: "library-1", search: "宇宙")
        XCTAssertNil(recorder.requests[0].query["SearchTerm"])
        XCTAssertEqual(recorder.requests[0].query["IncludeItemTypes"], "Movie,Series")
    }

    func testLocalDecoderRequestsOnlyOriginalBytesForBothServerKinds() async throws {
        let recorder = self.recorder!
        StubURLProtocol.handler = { request in recorder.append(request); return .json(Self.localPlaybackJSON()) }
        for kind in ServerKind.allCases {
            var connection = makeConnection(); connection.kind = kind
            let client = MediaServerClient(connection: connection, token: "secret", deviceID: "test", session: session)
            let plan = try await client.playbackPlan(item: movie(), startTicks: 987_000_000, capability: .localDecoder)
            XCTAssertEqual(plan.method, .directPlay)
            XCTAssertEqual(plan.url.path, "/base/Videos/movie-1/stream.mkv")
            XCTAssertEqual(plan.resumeTicks, 987_000_000)
            XCTAssertEqual(URLRequest(url: plan.url).query["Static"], "true")
            XCTAssertEqual(URLRequest(url: plan.url).query["StartTimeTicks"], "0")
            let request = try XCTUnwrap(recorder.requests.last)
            XCTAssertEqual(request.query["EnableTranscoding"], "false")
            XCTAssertEqual(request.query["EnableDirectStream"], "false")
            XCTAssertEqual(request.query["EnableDirectPlay"], "true")
            let profile = try XCTUnwrap(try request.jsonBody()["DeviceProfile"] as? [String: Any])
            XCTAssertEqual(profile["Name"] as? String, "SeatSix Local Decoder")
            XCTAssertEqual((profile["TranscodingProfiles"] as? [Any])?.count, 0)
        }
    }

    func testLocalDecoderContainerAndCodecMatrix() async throws {
        let cases = [("matroska", "hevc", "truehd", "mkv"), ("mp4", "h265", "eac3", "mp4"), ("mov", "h264", "pcm_s24le", "mov"), ("avi", "mpeg4", "mp3", "avi"), ("webm", "av1", "opus", "webm"), ("webm", "vp9", "vorbis", "webm"), ("mpegts", "mpeg2video", "ac3", "ts"), ("m2ts", "vc1", "dts", "m2ts"), ("mkv", "hevc", "flac", "mkv"), ("mp4", "h264", "aac", "mp4")]
        for (container, video, audio, suffix) in cases {
            let response = Self.localPlaybackJSON(container: container, video: video, audio: audio)
            StubURLProtocol.handler = { _ in .json(response) }
            let plan = try await makeClient().playbackPlan(item: movie(), capability: .localDecoder)
            XCTAssertEqual(plan.url.path, "/base/Videos/movie-1/stream.\(suffix)")
            XCTAssertFalse(plan.isTranscoding)
        }
    }

    func testLocalDecoderUsesSelectedPlaybackInfoVersionAndCompatibilityPath() async throws {
        let recorder = self.recorder!
        var response = Self.localPlaybackJSON()
        var original = (response["MediaSources"] as! [[String: Any]])[0]
        original["Id"] = "selected-version"
        original["Path"] = "/emby/videos/selected/stream.bin?signature=a%2Bb"
        original["RunTimeTicks"] = 9_000_000_000 as Int64
        var other = original; other["Id"] = "other-version"; other["Path"] = "https://other.example/movie.mkv"
        response["MediaSources"] = [other, original]
        StubURLProtocol.handler = { request in recorder.append(request); return .json(response) }
        let plan = try await compatibilityClient().playbackPlan(item: movie(), mediaSourceID: "selected-version", startTicks: 44_000_000, capability: .localDecoder)
        XCTAssertEqual(plan.mediaSourceID, "selected-version")
        XCTAssertEqual(plan.url.path, "/emby/videos/selected/stream.bin")
        XCTAssertEqual(URLRequest(url: plan.url).query["signature"], "a+b")
        XCTAssertEqual(plan.runtimeTicks, 9_000_000_000)
        XCTAssertEqual(plan.resumeTicks, 44_000_000)
        XCTAssertEqual(try recorder.requests[0].jsonBody().count, 0)
        XCTAssertEqual(recorder.requests[0].query["MediaSourceId"], "selected-version")
        XCTAssertEqual(recorder.requests[0].query["EnableTranscoding"], "false")
    }

    func testLocalDecoderNeverFallsBackToTranscodingOrAnotherRequestedVersion() async throws {
        let recorder = self.recorder!
        var response = Self.localPlaybackJSON()
        var source = (response["MediaSources"] as! [[String: Any]])[0]
        source["SupportsDirectPlay"] = false
        response["MediaSources"] = [source]
        StubURLProtocol.handler = { request in recorder.append(request); return .json(response) }
        do { _ = try await makeClient().playbackPlan(item: movie(), capability: .localDecoder); XCTFail("Unexpected NAS fallback") }
        catch { XCTAssertEqual(error as? MediaServerError, .unsupportedLocalMedia) }
        do { _ = try await makeClient().playbackPlan(item: movie(), mode: .compatible, capability: .localDecoder); XCTFail("Unexpected compatibility request") }
        catch { XCTAssertEqual(error as? MediaServerError, .unsupportedLocalMedia) }
        XCTAssertEqual(recorder.requests.count, 1, "Local compatible mode must fail before any network request")
        StubURLProtocol.handler = { _ in .json(Self.localPlaybackJSON()) }
        do { _ = try await makeClient().playbackPlan(item: movie(), mediaSourceID: "missing-version", capability: .localDecoder); XCTFail("Played wrong version") }
        catch { XCTAssertEqual(error as? MediaServerError, .unsupportedLocalMedia) }
    }

    func testLocalDecoderRejectsUnknownMetadataAndSourcesRequiringOpening() async throws {
        var responses = [Self.localPlaybackJSON(container: "hls"), Self.localPlaybackJSON(container: "unknown"), Self.localPlaybackJSON(video: "unknown"), Self.localPlaybackJSON(audio: "unknown")]
        for change: [String: Any] in [["RequiresOpening": true], ["Id": ""], ["Id": "../other"], ["MediaStreams": []], ["MediaStreams": [["Type": "Audio", "Codec": "aac"]]]] {
            var response = Self.localPlaybackJSON()
            var source = (response["MediaSources"] as! [[String: Any]])[0]
            source.merge(change) { _, new in new }; response["MediaSources"] = [source]
            responses.append(response)
        }
        for sessionID in ["", "../session", "session?other=value", "bad\nsession"] {
            var response = Self.localPlaybackJSON(); response["PlaySessionId"] = sessionID; responses.append(response)
        }
        for response in responses {
            StubURLProtocol.handler = { _ in .json(response) }
            do { _ = try await makeClient().playbackPlan(item: movie(), capability: .localDecoder); XCTFail("Accepted malformed metadata") }
            catch { XCTAssertEqual(error as? MediaServerError, .unsupportedLocalMedia) }
        }
    }

    func testLocalDecoderRejectsExternalOrPlaylistCompatibilityPaths() async throws {
        for path in ["https://other.example/video.mkv", "//other.example/video.mkv", "http://media.example:9443/emby/video.mkv", "https://name:pass@media.example:9443/emby/video.mkv", "/emby/playlist.m3u8", "/emby/playlist.MPD", "/emby/playlist.%6d3u8", "", "/emby/video.mkv#part", "file:///tmp/video.mkv"] {
            var response = Self.localPlaybackJSON()
            var source = (response["MediaSources"] as! [[String: Any]])[0]
            source["Path"] = path; response["MediaSources"] = [source]
            StubURLProtocol.handler = { _ in .json(response) }
            do { _ = try await compatibilityClient().playbackPlan(item: movie(), capability: .localDecoder); XCTFail("Accepted unsafe path: \(path)") }
            catch { XCTAssertTrue([MediaServerError.externalStream, .unsupportedLocalMedia].contains(error as? MediaServerError ?? .invalidResponse)) }
        }
    }

    private static func localPlaybackJSON(container: String = "mkv", video: String = "hevc", audio: String = "ac3") -> [String: Any] {
        ["PlaySessionId": "session-1", "MediaSources": [["Id": "source-1", "Container": container, "SupportsDirectPlay": true, "SupportsTranscoding": true, "TranscodingUrl": "/Videos/movie-1/master.m3u8", "Protocol": "Http", "Path": "/emby/videos/movie-1/stream.mkv", "MediaStreams": [["Type": "Video", "Codec": video, "BitDepth": 10], ["Type": "Audio", "Codec": audio]]]]]
    }

    private func compatibilityClient() -> MediaServerClient {
        var connection = makeConnection()
        connection.kind = .emby; connection.compatibilityMode = true
        connection.baseURL = URL(string: "https://media.example:9443/emby")!
        return MediaServerClient(connection: connection, token: "secret", deviceID: "test", session: session)
    }

    private func waitForRequests(_ count: Int) async throws {
        for _ in 0..<100 { if recorder.requests.count >= count { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("No request arrived")
    }
    private static func fixtureURL(_ path: String, query: [String: String]) -> String {
        var components = URLComponents(string: path)!
        components.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        return components.string!
    }
    private func makeConnection() -> ServerConnection { ServerConnection(kind: .jellyfin, name: "测试", baseURL: URL(string: "https://media.example:9443/base")!, serverID: "server-1", userID: "user-1", username: "u", libraryIDs: ["library-1"]) }
    private func makeClient() -> MediaServerClient { MediaServerClient(connection: makeConnection(), token: "secret", deviceID: "test", session: session) }
    private func movie() throws -> MediaItem { try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: Self.movieJSON)) }
    private func plan() -> PlaybackPlan { PlaybackPlan(itemID: "movie-1", mediaSourceID: "source-1", playSessionID: "session-1", url: URL(string: "https://media.example:9443/base/video.mp4")!, method: .directPlay, resumeTicks: 0) }
    private static var movieJSON: [String: Any] { ["Id": "movie-1", "Name": "测试影片", "Type": "Movie", "Overview": "简介", "ProductionYear": 2026, "RunTimeTicks": 6_000_000_000, "UserData": ["PlaybackPositionTicks": 321_000_000, "Played": false], "ImageTags": ["Primary": "image-1"]] }
    private static func playbackJSON(direct: Bool, stream: String = "Videos/movie-1/master.m3u8") -> [String: Any] {
        ["PlaySessionId": "session-1", "MediaSources": [["Id": "source-1", "Container": "mp4", "SupportsDirectPlay": direct, "SupportsTranscoding": true, "TranscodingUrl": stream, "MediaStreams": [["Type": "Video", "Codec": "h264"], ["Type": "Audio", "Codec": "aac"]]]]]
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; storage.append(request) }
}
private struct StubResponse {
    var status: Int
    var data: Data
    var delay: TimeInterval = 0
    static func json(_ body: [String: Any]) -> StubResponse { StubResponse(status: 200, data: try! JSONSerialization.data(withJSONObject: body)) }
}
private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> StubResponse)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            DispatchQueue.global().asyncAfter(deadline: .now() + result.delay) { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension URLRequest {
    var query: [String: String] { Dictionary((URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last }) }
    func jsonBody() throws -> [String: Any] {
        let data: Data
        if let httpBody { data = httpBody }
        else if let stream = httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(); let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096); defer { buffer.deallocate() }
            while stream.hasBytesAvailable { let count = stream.read(buffer, maxLength: 4096); if count <= 0 { break }; collected.append(buffer, count: count) }
            data = collected
        } else { data = Data() }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
