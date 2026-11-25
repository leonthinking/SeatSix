import XCTest
import AVFoundation
import Darwin
@testable import SeatSixCore

final class PlaybackRelayTests: XCTestCase {
    private func authenticatedURL(_ address: String, value: String) -> URL {
        var parts = URLComponents(string: address)!
        parts.queryItems = [URLQueryItem(name: "api_key", value: value)]
        return parts.url!
    }

    func testHTTPParserAcceptsOnlyScopedBodylessRequestsAndOneValidRange() throws {
        let request = try PlaybackRelayRequest.parse(Data("GET /cap/resource.bin HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nRange: bytes=42-99\r\n\r\n".utf8), host: "127.0.0.1:1234")
        XCTAssertEqual(request.range, "bytes=42-99")
        for text in [
            "POST /cap HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n",
            "GET /cap HTTP/1.1\r\nHost: attacker.invalid\r\n\r\n",
            "GET /cap HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nHost: 127.0.0.1:1234\r\n\r\n",
            "GET /cap HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nContent-Length: 1\r\n\r\n",
            "GET /cap HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nTransfer-Encoding: chunked\r\n\r\n",
            "GET /cap HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nRange: bytes=0-5,7-9\r\n\r\n",
            "GET /cap?target=https://example.test HTTP/1.1\r\nHost: 127.0.0.1:1234\r\n\r\n"
        ] { XCTAssertThrowsError(try PlaybackRelayRequest.parse(Data(text.utf8), host: "127.0.0.1:1234")) }
        for valid in ["bytes=0-", "bytes=0-0", "bytes=-100", "bytes=10-20"] { XCTAssertTrue(PlaybackRelayRequest.validRange(valid)) }
        for invalid in ["bytes=-0", "bytes=20-10", "bytes=", "bytes=1.2-5", "bytes=999999999999999999999-", "bytes=0-1,2-3"] { XCTAssertFalse(PlaybackRelayRequest.validRange(invalid)) }
    }

    func testManifestRewritesVariantsKeysMapsAndMediaWhileKeepingAuthenticationUpstream() throws {
        let upstream = authenticatedURL("https://media.test:9443/emby/videos/master.m3u8", value: "private-fixture")
        let source = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",URI="audio/list.m3u8"
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="/emby/init.mp4"
        #EXTINF:6,
        segment.ts?Index=2
        """
        var mapped: [URL] = []
        let result = try PlaybackRelayManifest.rewrite(Data(source.utf8), upstream: upstream, authenticationSource: upstream) { url in
            mapped.append(url)
            return URL(string: "http://127.0.0.1:1234/cap/\(mapped.count).bin")!
        }
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertEqual(mapped.count, 4)
        XCTAssertFalse(text.contains("private-fixture"))
        XCTAssertFalse(text.contains("media.test"))
        XCTAssertTrue(text.contains("URI=\"http://127.0.0.1:1234/cap/1.bin\""))
        XCTAssertEqual(mapped[0].path, "/emby/videos/audio/list.m3u8")
        XCTAssertEqual(mapped[2].path, "/emby/init.mp4")
        XCTAssertTrue(mapped.allSatisfy { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "api_key", value: "private-fixture")) == true })
    }

    func testManifestRejectsUnapprovedOriginsVariablesAndUnquotedURI() throws {
        let base = URL(string: "https://media.test:9443/master.m3u8")!
        for line in ["https://elsewhere.test/a.ts", "http://media.test:9443/a.ts", "https://media.test:443/a.ts", "file:///tmp/a.ts", "//elsewhere.test/a.ts", "{$variable}/a.ts", "#EXT-X-KEY:METHOD=AES-128,URI=key.bin", "#EXT-X-CONTENT-STEERING:SERVER-URI=\"/steering.json\""] {
            XCTAssertThrowsError(try PlaybackRelayManifest.rewrite(Data(("#EXTM3U\n" + line + "\n").utf8), upstream: base, authenticationSource: base) { $0 }, line)
        }
        XCTAssertThrowsError(try PlaybackRelayManifest.rewrite(Data(repeating: 65, count: PlaybackRelayManifest.maximumBytes + 1), upstream: base, authenticationSource: base) { $0 })
    }

    func testOriginValidationAndExistingChildAuthentication() throws {
        let base = authenticatedURL("https://media.test:9443/base/master.m3u8", value: "root")
        var reference = URLComponents(string: "segment.ts")!
        reference.queryItems = [URLQueryItem(name: "api_key", value: "child"), URLQueryItem(name: "Index", value: "1")]
        let child = try PlaybackRelayURL.resolve(reference.string!, relativeTo: base, authenticationSource: base)
        XCTAssertEqual(URLComponents(url: child, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "api_key" }.map(\.value), ["child"])
        XCTAssertFalse(PlaybackRelayURL.isSameSecureOrigin(URL(string: "https://user:password@media.test:9443/a")!, base))
        XCTAssertFalse(PlaybackRelayURL.isSameSecureOrigin(URL(string: "https://media.test:9443/a#fragment")!, base))
    }

    func testPinnedTLSRelayStreamsRangesHeadPlaylistsAndRejectsChangedCertificate() async throws {
        let fixture = try await RelayTLSFixture.start()
        defer { fixture.stop() }
        let source = fixture.url("bytes.bin")
        let relay = PinnedPlaybackRelay(sourceURL: source, serverURL: fixture.origin, certificatePin: try fixture.pin())
        let local = try await relay.start()
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertFalse(local.absoluteString.contains("fixture-only-token"))
        var ranged = URLRequest(url: local)
        ranged.setValue("bytes=100000-299999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: ranged)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 100000-299999/2097152")
        XCTAssertEqual(data, Data((100000...299999).map { UInt8($0 % 251) }))
        let (entireData, entireResponse) = try await URLSession.shared.data(from: local)
        XCTAssertEqual((entireResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(entireData.count, 2 * 1024 * 1024, "Larger media must stream without being collected by the relay")
        var head = URLRequest(url: local)
        head.httpMethod = "HEAD"
        let (headData, headResponse) = try await URLSession.shared.data(for: head)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual(headResponse.expectedContentLength, 2 * 1024 * 1024)
        ranged.setValue("bytes=3000000-", forHTTPHeaderField: "Range")
        let (empty, unsatisfied) = try await URLSession.shared.data(for: ranged)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual((unsatisfied as? HTTPURLResponse)?.statusCode, 416)
        await relay.stop()

        let playlistRelay = PinnedPlaybackRelay(sourceURL: fixture.url("master.m3u8"), serverURL: fixture.origin, certificatePin: try fixture.pin())
        let playlist = try await playlistRelay.start()
        let (master, _) = try await URLSession.shared.data(from: playlist)
        let variant = try XCTUnwrap(String(decoding: master, as: UTF8.self).split(separator: "\n").first(where: { !$0.hasPrefix("#") }).flatMap { URL(string: String($0)) })
        let (child, childResponse) = try await URLSession.shared.data(from: variant)
        XCTAssertEqual((childResponse as? HTTPURLResponse)?.statusCode, 200)
        let text = String(decoding: child, as: UTF8.self)
        XCTAssertFalse(text.contains("fixture-only-token"))
        XCTAssertTrue(text.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"http://127.0.0.1:"))
        await playlistRelay.stop()

        for path in ["unsafe.m3u8", "redirect.mp4"] {
            let unsafeRelay = PinnedPlaybackRelay(sourceURL: fixture.url(path), serverURL: fixture.origin, certificatePin: try fixture.pin())
            let unsafeURL = try await unsafeRelay.start()
            let (body, refused) = try await URLSession.shared.data(from: unsafeURL)
            XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertTrue(body.isEmpty)
            await unsafeRelay.stop()
        }

        let other = try await RelayTLSFixture.start()
        defer { other.stop() }
        let wrongPin = try CertificatePin(url: fixture.origin, certificateDER: Data(contentsOf: other.der))
        let changedRelay = PinnedPlaybackRelay(sourceURL: source, serverURL: fixture.origin, certificatePin: wrongPin)
        let changed = try await changedRelay.start()
        let (_, refused) = try await URLSession.shared.data(from: changed)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 502)
        await changedRelay.stop()
    }

    func testNilPinUsesSystemTLSAndRejectsSelfSignedCertificate() async throws {
        let fixture = try await RelayTLSFixture.start()
        defer { fixture.stop() }
        let relay = PinnedPlaybackRelay(sourceURL: fixture.url("bytes.bin"), serverURL: fixture.origin)
        let url = try await relay.start()
        let (body, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502, "No pin must never grant trust to a self-signed leaf")
        XCTAssertTrue(body.isEmpty)
        await relay.stop()
    }

    func testNilPinPrivateHTTPRelaysRangesAndRejectsRedirectsAndExternalManifests() async throws {
        let fixture = try await RelayTLSFixture.start(insecureHTTP: true)
        defer { fixture.stop() }
        let relay = PinnedPlaybackRelay(sourceURL: fixture.url("bytes.bin"), serverURL: fixture.origin, certificatePin: nil)
        let local = try await relay.start()
        XCTAssertFalse(local.absoluteString.contains("fixture-only-token"))
        var request = URLRequest(url: local)
        request.setValue("bytes=42-99", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 42-99/2097152")
        XCTAssertEqual(data, Data((42...99).map { UInt8($0 % 251) }))
        await relay.stop()
        for path in ["redirect.mp4", "unsafe.m3u8"] {
            let refusedRelay = PinnedPlaybackRelay(sourceURL: fixture.url(path), serverURL: fixture.origin)
            let local = try await refusedRelay.start()
            let (body, response) = try await URLSession.shared.data(from: local)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertTrue(body.isEmpty)
            await refusedRelay.stop()
        }
        let manifestRelay = PinnedPlaybackRelay(sourceURL: fixture.url("master.m3u8"), serverURL: fixture.origin)
        let manifest = try await manifestRelay.start()
        let (master, masterResponse) = try await URLSession.shared.data(from: manifest)
        XCTAssertEqual((masterResponse as? HTTPURLResponse)?.statusCode, 200)
        let variant = try XCTUnwrap(String(decoding: master, as: UTF8.self).split(separator: "\n").first(where: { !$0.hasPrefix("#") }).flatMap { URL(string: String($0)) })
        let (child, childResponse) = try await URLSession.shared.data(from: variant)
        XCTAssertEqual((childResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: child, as: UTF8.self).contains("fixture-only-token"))
        await manifestRelay.stop()
    }

    func testRelayRejectsPinnedHTTPPublicHTTPAndCrossOriginBeforeStarting() async throws {
        let fixture = try await RelayTLSFixture.start(insecureHTTP: true)
        defer { fixture.stop() }
        var secureOrigin = URLComponents(url: fixture.origin, resolvingAgainstBaseURL: false)!
        secureOrigin.scheme = "https"
        let pin = try CertificatePin(url: secureOrigin.url!, certificateDER: Data(contentsOf: fixture.der))
        let cases: [(URL, URL, CertificatePin?)] = [
            (fixture.url("bytes.bin"), fixture.origin, pin),
            (URL(string: "http://public.example/video.mkv")!, URL(string: "http://public.example")!, nil),
            (URL(string: "https://elsewhere.example/video.mkv")!, fixture.origin, nil),
            (URL(string: "http://127.0.0.1:1/video.mkv")!, fixture.origin, nil)
        ]
        for (source, server, pin) in cases {
            let relay = PinnedPlaybackRelay(sourceURL: source, serverURL: server, certificatePin: pin)
            do { _ = try await relay.start(); XCTFail("Unsafe relay origin accepted") }
            catch { XCTAssertEqual(error as? PlaybackRelayError, .invalidSource) }
            await relay.stop()
        }
    }

    func testSameOriginRequiresSchemeAndEffectivePortForEveryResource() throws {
        let base = URL(string: "http://127.0.0.1/master.m3u8")!
        XCTAssertTrue(PlaybackRelayURL.isSameOrigin(URL(string: "http://127.0.0.1:80/video.ts")!, base))
        XCTAssertFalse(PlaybackRelayURL.isSameSecureOrigin(base, base))
        for address in ["https://127.0.0.1/video.ts", "http://127.0.0.1:443/video.ts", "http://127.0.0.2/video.ts", "http://user:pass@127.0.0.1/video.ts", "http://127.0.0.1/video.ts#fragment"] {
            XCTAssertFalse(PlaybackRelayURL.isSameOrigin(URL(string: address)!, base))
            XCTAssertThrowsError(try PlaybackRelayURL.resolve(address, relativeTo: base, authenticationSource: base))
        }
        XCTAssertEqual(try PlaybackRelayURL.resolve("segment.ts", relativeTo: base, authenticationSource: base).absoluteString, "http://127.0.0.1/segment.ts")
    }

    func testExtensionlessHLSHeadHasRewrittenGetLengthAndNoBody() async throws {
        let fixture = try await RelayTLSFixture.start()
        defer { fixture.stop() }
        let relay = PinnedPlaybackRelay(sourceURL: fixture.url("hls/playlist"), serverURL: fixture.origin, certificatePin: try fixture.pin())
        let local = try await relay.start()
        var head = URLRequest(url: local)
        head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await URLSession.shared.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(headResponse.mimeType, "application/vnd.apple.mpegurl")
        XCTAssertTrue(headBody.isEmpty)
        let (getBody, getResponse) = try await URLSession.shared.data(from: local)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertGreaterThan(getBody.count, 0)
        XCTAssertEqual(headResponse.expectedContentLength, Int64(getBody.count))
        XCTAssertEqual(getResponse.expectedContentLength, Int64(getBody.count))
        XCTAssertFalse(String(decoding: getBody, as: UTF8.self).contains("fixture-only-token"))
        await relay.stop()
    }

    @MainActor
    func testAVPlayerDecodesAndSeeksSyntheticMP4ThroughPinnedRelay() async throws {
        let fixture = try await RelayTLSFixture.start(makePlayableMedia: true)
        defer { fixture.stop() }
        for path in ["video.mp4", "hls/index.m3u8"] {
            let relay = PinnedPlaybackRelay(sourceURL: fixture.url(path), serverURL: fixture.origin, certificatePin: try fixture.pin())
            let url = try await relay.start()
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.play()
            var decoded = false
            for _ in 0..<200 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { decoded = true; break }
                if item.status == .failed { break }
            }
            XCTAssertTrue(decoded, "AVPlayer must decode a synthetic \(path) frame through the pin-protected relay")
            if decoded {
                await player.seek(to: CMTime(seconds: 75, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                try await Task.sleep(nanoseconds: 500_000_000)
                XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 74)
                XCTAssertLessThan(player.currentTime().seconds, 80)
            }
            player.pause()
            player.replaceCurrentItem(with: nil)
            await relay.stop()
        }
    }
}

private final class RelayTLSFixture: @unchecked Sendable {
    let folder: URL
    let der: URL
    let process: Process
    let origin: URL

    private init(folder: URL, der: URL, process: Process, origin: URL) {
        self.folder = folder; self.der = der; self.process = process; self.origin = origin
    }

    static func start(makePlayableMedia: Bool = false, insecureHTTP: Bool = false) async throws -> RelayTLSFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seatsix-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var spawnedProcess: Process?
        var keepResources = false
        defer {
            if !keepResources {
                if let spawnedProcess { stopProcess(spawnedProcess) }
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let config = folder.appendingPathComponent("certificate.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = extensions
        prompt = no
        [dn]
        CN = SeatSix Relay Test
        [extensions]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = IP:127.0.0.1
        """.write(to: config, atomically: true, encoding: .utf8)
        let pem = folder.appendingPathComponent("certificate.pem")
        let key = folder.appendingPathComponent("key.pem")
        let der = folder.appendingPathComponent("certificate.der")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", config.path, "-keyout", key.path, "-out", pem.path])
        try run("/usr/bin/openssl", ["x509", "-in", pem.path, "-outform", "DER", "-out", der.path])
        let hlsFolder = folder.appendingPathComponent("hls")
        let media = folder.appendingPathComponent("video.mp4")
        if makePlayableMedia {
            // Give the 75-second seek a real target even in a fresh source checkout.
            try run("/usr/bin/env", ["ffmpeg", "-hide_banner", "-loglevel", "error",
                                     "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=12",
                                     "-f", "lavfi", "-i", "sine=frequency=440",
                                     "-t", "96", "-c:v", "libx264", "-g", "24", "-preset", "ultrafast",
                                     "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", media.path])
            try FileManager.default.createDirectory(at: hlsFolder, withIntermediateDirectories: true)
            try run("/usr/bin/env", ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", media.path, "-t", "120", "-c", "copy", "-hls_time", "6", "-hls_playlist_type", "vod", "-hls_segment_filename", hlsFolder.appendingPathComponent("segment%03d.ts").path, hlsFolder.appendingPathComponent("index.m3u8").path])
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ready = folder.appendingPathComponent("ready.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [root.appendingPathComponent("scripts/integration/tls_fixture.py").path, "--certificate", pem.path, "--key", key.path, "--ready", ready.path]
        if makePlayableMedia { process.arguments! += ["--media", media.path, "--hls", hlsFolder.path] }
        if insecureHTTP {
            // Reuse the fixture handler without TLS; never patch or bypass its TLS mode.
            let driver = """
            import importlib.util, json, pathlib, sys
            from http.server import ThreadingHTTPServer
            spec = importlib.util.spec_from_file_location("relay_fixture", sys.argv[1])
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            server = ThreadingHTTPServer(("127.0.0.1", 0), module.Fixture)
            server.daemon_threads = True
            server.media = None
            server.hls = None
            pathlib.Path(sys.argv[2]).write_text(json.dumps({"port": server.server_port}))
            server.serve_forever()
            """
            process.arguments = ["-c", driver, root.appendingPathComponent("scripts/integration/tls_fixture.py").path, ready.path]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        spawnedProcess = process
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: ready), let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Int], let port = dictionary["port"] {
                keepResources = true
                return RelayTLSFixture(folder: folder, der: der, process: process, origin: URL(string: "\(insecureHTTP ? "http" : "https")://127.0.0.1:\(port)")!)
            }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw PlaybackRelayError.failedToStart
    }

    func pin() throws -> CertificatePin { try CertificatePin(url: origin, certificateDER: Data(contentsOf: der)) }
    func url(_ path: String) -> URL { origin.appendingPathComponent(path).appending(queryItems: [URLQueryItem(name: "api_key", value: "fixture-only-token")]) }
    func stop() {
        Self.stopProcess(process)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    private static func waitForDisappearance(_ pid: pid_t, seconds: Double) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        repeat {
            if !processExists(pid) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return !processExists(pid)
    }

    private static func stopProcess(_ process: Process) {
        // Foundation can retain isRunning after the child has already disappeared.
        // Consult the kernel and never wait indefinitely for Foundation's exit observer.
        let pid = process.processIdentifier
        guard pid > 0, processExists(pid) else { return }
        if kill(pid, SIGTERM) != 0 && errno != ESRCH {
            XCTFail("Could not terminate owned relay fixture child: errno \(errno)")
        }
        if waitForDisappearance(pid, seconds: 2) { return }
        XCTFail("Relay fixture child exceeded its 2-second graceful cleanup deadline; sending SIGKILL")
        if kill(pid, SIGKILL) != 0 && errno != ESRCH {
            XCTFail("Could not kill owned relay fixture child: errno \(errno)")
        }
        if !waitForDisappearance(pid, seconds: 2) {
            XCTFail("Relay fixture child still exists after forced cleanup deadline")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        guard completion.wait(timeout: .now() + 60) == .success else {
            stopProcess(process)
            XCTFail("Relay fixture preparation exceeded its 60-second completion deadline")
            throw PlaybackRelayError.failedToStart
        }
        guard process.terminationStatus == 0 else { throw PlaybackRelayError.failedToStart }
    }
}
