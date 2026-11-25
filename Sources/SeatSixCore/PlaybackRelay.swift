import Foundation
import Network
import Security

public enum PlaybackRelayError: Error, LocalizedError, Equatable {
    case invalidSource, failedToStart, invalidRequest, unsafeManifest, resourceLimit, stopped

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "播放地址与当前服务器不一致，或连接不符合安全要求。"
        case .failedToStart: return "无法建立本机安全播放连接。"
        case .invalidRequest: return "本机播放请求无效。"
        case .unsafeManifest: return "播放列表包含无法安全代理的地址。"
        case .resourceLimit: return "播放列表或连接数量超出安全限制。"
        case .stopped: return "播放连接已关闭。"
        }
    }
}

/// Media engines only receive a scoped loopback URL. Upstream TLS uses either the
/// explicitly approved leaf pin or the system trust policy; private HTTP is validated.
public actor PinnedPlaybackRelay {
    private let sourceURL: URL
    private let serverURL: URL
    private let certificatePin: CertificatePin?
    private var server: PlaybackRelayServer?
    private var localURL: URL?

    public init(sourceURL: URL, serverURL: URL, certificatePin: CertificatePin? = nil) {
        self.sourceURL = sourceURL
        self.serverURL = serverURL
        self.certificatePin = certificatePin
    }

    public func start() async throws -> URL {
        if let localURL { return localURL }
        guard server == nil else { throw PlaybackRelayError.failedToStart }
        guard PlaybackRelayURL.isSameOrigin(sourceURL, serverURL) else { throw PlaybackRelayError.invalidSource }
        let candidate = try PlaybackRelayServer(sourceURL: sourceURL, serverURL: serverURL, pin: certificatePin)
        server = candidate
        do {
            let url = try await candidate.start()
            guard server === candidate else { throw PlaybackRelayError.stopped }
            localURL = url
            return url
        } catch {
            candidate.stop()
            if server === candidate { server = nil }
            throw error
        }
    }

    public func stop() async {
        localURL = nil
        let previous = server
        server = nil
        await previous?.stopAndWait()
    }

    deinit { server?.stop() }
}

enum PlaybackRelayURL {
    static func isSameSecureOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == "https" && isSameOrigin(a, b)
    }

    static func isSameOrigin(_ a: URL, _ b: URL) -> Bool {
        if a.user != nil || a.password != nil || b.user != nil || b.password != nil { return false }
        guard let scheme = a.scheme?.lowercased(), ["https", "http"].contains(scheme), b.scheme?.lowercased() == scheme,
              a.absoluteString.utf8.count <= 16_384, b.absoluteString.utf8.count <= 16_384,
              a.fragment == nil, b.fragment == nil,
              let host = a.host?.lowercased(), !host.isEmpty, host == b.host?.lowercased(),
              a.port.map({ (1...65535).contains($0) }) ?? true,
              b.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        if scheme == "http" && !ServerEndpoint.isLocalHost(host) { return false }
        let defaultPort = scheme == "https" ? 443 : 80
        return (a.port ?? defaultPort) == (b.port ?? defaultPort)
    }

    static func resolve(_ reference: String, relativeTo base: URL, authenticationSource: URL) throws -> URL {
        guard !reference.isEmpty, !reference.contains("{$"),
              !reference.contains("\\"), !reference.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
              let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              isSameOrigin(url, authenticationSource),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PlaybackRelayError.unsafeManifest }
        let names = Set(["api_key", "apikey", "x-emby-token"])
        var items = components.queryItems ?? []
        let hasAuthentication = items.contains { names.contains($0.name.lowercased()) }
        if !hasAuthentication {
            items += (URLComponents(url: authenticationSource, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .filter { names.contains($0.name.lowercased()) }
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let result = components.url else { throw PlaybackRelayError.unsafeManifest }
        return result
    }
}

struct PlaybackRelayRequest {
    let method: String
    let path: String
    let range: String?

    static func parse(_ bytes: Data, host: String) throws -> Self {
        guard bytes.count <= 16_384, let raw = String(data: bytes, encoding: .ascii),
              raw.hasSuffix("\r\n\r\n") else { throw PlaybackRelayError.invalidRequest }
        // CRLF is one Swift Character; the wire terminator is four bytes.
        let lines = String(decoding: bytes.dropLast(4), as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first else { throw PlaybackRelayError.invalidRequest }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["GET", "HEAD"].contains(parts[0]),
              ["HTTP/1.1", "HTTP/1.0"].contains(parts[2]), parts[1].hasPrefix("/"),
              !parts[1].contains("?"), !parts[1].contains("#") else { throw PlaybackRelayError.invalidRequest }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw PlaybackRelayError.invalidRequest }
            let name = String(line[..<colon]).lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), fields[name] == nil else { throw PlaybackRelayError.invalidRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw PlaybackRelayError.invalidRequest }
            fields[name] = value
        }
        guard fields["host"] == host, fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else { throw PlaybackRelayError.invalidRequest }
        if let range = fields["range"], !validRange(range) { throw PlaybackRelayError.invalidRequest }
        return Self(method: String(parts[0]), path: String(parts[1]), range: fields["range"])
    }

    static func validRange(_ value: String) -> Bool {
        guard value.hasPrefix("bytes=") else { return false }
        let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, !bounds.allSatisfy(\.isEmpty),
              bounds.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return false }
        if bounds[0].isEmpty { return Int64(bounds[1]).map { $0 > 0 } ?? false }
        guard let start = Int64(bounds[0]), start >= 0 else { return false }
        if bounds[1].isEmpty { return true }
        return Int64(bounds[1]).map { $0 >= start } ?? false
    }
}

enum PlaybackRelayManifest {
    static let maximumBytes = 2 * 1_024 * 1_024

    static func rewrite(_ data: Data, upstream: URL, authenticationSource: URL, map: (URL) throws -> URL) throws -> Data {
        guard data.count <= maximumBytes, let source = String(data: data, encoding: .utf8),
              source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"),
              !source.contains("{$"), !source.contains("#EXT-X-DEFINE"),
              !source.contains("#EXT-X-CONTENT-STEERING") else { throw PlaybackRelayError.unsafeManifest }
        let attribute = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9-])([A-Za-z0-9-]*URI)\s*=\s*\"([^\"]*)\""#)
        let anyURI = try NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9-])[A-Za-z0-9-]*URI\s*="#)
        var output: [String] = []
        var outputBytes = 0
        for original in source.components(separatedBy: .newlines) {
            var line = original.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !line.hasPrefix("#") {
                line = try map(PlaybackRelayURL.resolve(line, relativeTo: upstream, authenticationSource: authenticationSource)).absoluteString
            } else if line.hasPrefix("#") {
                let matches = attribute.matches(in: line, range: NSRange(line.startIndex..., in: line))
                guard matches.count == anyURI.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line)) else { throw PlaybackRelayError.unsafeManifest }
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 2), in: line) else { throw PlaybackRelayError.unsafeManifest }
                    let url = try PlaybackRelayURL.resolve(String(line[range]), relativeTo: upstream, authenticationSource: authenticationSource)
                    line.replaceSubrange(range, with: try map(url).absoluteString)
                }
                // Unknown absolute network locations must not escape through an unhandled tag.
                let withoutLocal = line.replacingOccurrences(of: #"http://127\.0\.0\.1:[0-9]+/[^\" ,]+"#, with: "", options: .regularExpression)
                guard !withoutLocal.lowercased().contains("https://"), !withoutLocal.lowercased().contains("http://") else { throw PlaybackRelayError.unsafeManifest }
            }
            outputBytes += line.utf8.count + 1
            guard outputBytes <= 4 * 1_024 * 1_024 else { throw PlaybackRelayError.resourceLimit }
            output.append(line)
        }
        return Data(output.joined(separator: "\n").utf8)
    }
}

private final class PlaybackRelayServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.seatsix.playback-relay")
    let sourceURL: URL
    let serverURL: URL
    let policy: CertificateTrustPolicy
    private let capability: String
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var connections: [UUID: PlaybackRelayConnection] = [:]
    private var resources: [String: URL] = [:]
    private var resourcePaths: [URL: String] = [:]
    private var resourceBytes = 0
    private var port: UInt16?
    private var stopped = false

    init(sourceURL: URL, serverURL: URL, pin: CertificatePin?) throws {
        guard (try? ServerEndpoint(address: serverURL.absoluteString, allowInsecureHTTP: pin == nil)) != nil,
              PlaybackRelayURL.isSameOrigin(sourceURL, serverURL) else { throw PlaybackRelayError.invalidSource }
        if let pin {
            guard PlaybackRelayURL.isSameSecureOrigin(sourceURL, serverURL),
                  pin.origin == (try CertificatePin.origin(for: serverURL)) else { throw PlaybackRelayError.invalidSource }
        }
        self.sourceURL = sourceURL
        self.serverURL = serverURL
        self.policy = CertificateTrustPolicy(pin: pin)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PlaybackRelayError.failedToStart }
        capability = bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.stopped else { continuation.resume(throwing: PlaybackRelayError.stopped); return }
                self.startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.newConnectionHandler = { [weak self] incoming in self?.accept(incoming) }
                    listener.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            do {
                                guard let port = listener.port?.rawValue else { throw PlaybackRelayError.failedToStart }
                                self.port = port
                                let url = try self.map(self.sourceURL)
                                self.startContinuation?.resume(returning: url)
                                self.startContinuation = nil
                            } catch { self.failStart() }
                        case .failed: self.failStart()
                        default: break
                        }
                    }
                    listener.start(queue: self.queue)
                } catch { self.failStart() }
            }
        }
    }

    private func failStart() {
        startContinuation?.resume(throwing: PlaybackRelayError.failedToStart)
        startContinuation = nil
        close()
    }

    func stop() { queue.async { self.close() } }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in queue.async { self.close(); continuation.resume() } }
    }

    private func close() {
        guard !stopped else { return }
        stopped = true
        startContinuation?.resume(throwing: PlaybackRelayError.stopped)
        startContinuation = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.close() }
        resources.removeAll()
        resourcePaths.removeAll()
        resourceBytes = 0
        port = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8, let port else { connection.cancel(); return }
        let client = PlaybackRelayConnection(server: self, connection: connection, host: "127.0.0.1:\(port)")
        connections[client.id] = client
        client.start()
    }

    func remove(_ id: UUID) { connections.removeValue(forKey: id) }
    func resource(path: String) -> URL? { resources[path] }

    func map(_ url: URL) throws -> URL {
        guard !stopped, let port, PlaybackRelayURL.isSameOrigin(url, serverURL) else { throw PlaybackRelayError.invalidSource }
        if let path = resourcePaths[url] { return URL(string: "http://127.0.0.1:\(port)\(path)")! }
        let cost = url.absoluteString.utf8.count
        guard resources.count < 8_192, resourceBytes + cost <= 8 * 1_024 * 1_024 else { throw PlaybackRelayError.resourceLimit }
        let suffix = url.pathExtension.lowercased() == "m3u8" ? ".m3u8" : ".bin"
        let path = "/\(capability)/\(UUID().uuidString.lowercased())\(suffix)"
        resources[path] = url
        resourcePaths[url] = path
        resourceBytes += cost
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}

private final class PlaybackRelayConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let id = UUID()
    private weak var server: PlaybackRelayServer?
    private let connection: NWConnection
    private let host: String
    private var header = Data()
    private var request: PlaybackRelayRequest?
    private var upstreamURL: URL?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timeout: DispatchWorkItem?
    private var closed = false
    private var failing = false
    private var responseStarted = false
    private var upstreamComplete = false
    private var sending = false
    private var isManifest = false
    private var manifest = Data()
    private var chunks: [Data] = []
    private var bufferedBytes = 0
    private var suspended = false
    private var receivedBytes: Int64 = 0
    private var expectedBytes: Int64?

    init(server: PlaybackRelayServer, connection: NWConnection, host: String) {
        self.server = server
        self.connection = connection
        self.host = host
    }

    func start() {
        guard let server else { return }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.close() }
            if case .cancelled = state { self.close() }
        }
        connection.start(queue: server.queue)
        resetTimeout()
        readHeader()
    }

    private func resetTimeout() {
        guard let server, !closed else { return }
        timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        server.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.header.append(data) }
            guard self.header.count <= 16_384 else { self.fail(status: 431); return }
            if let end = self.header.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound == self.header.endIndex else { self.fail(status: 400); return }
                do {
                    let request = try PlaybackRelayRequest.parse(self.header, host: self.host)
                    guard let url = self.server?.resource(path: request.path) else { self.fail(status: 404); return }
                    self.request = request
                    self.header.removeAll()
                    self.fetch(url)
                } catch { self.fail(status: 400) }
            } else if complete || error != nil { self.close() }
            else { self.readHeader() }
        }
    }

    private func fetch(_ url: URL, asManifest: Bool = false) {
        guard let server, let request else { close(); return }
        upstreamURL = url
        isManifest = asManifest || url.pathExtension.lowercased() == "m3u8"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = server.queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        var upstream = URLRequest(url: url)
        upstream.httpMethod = isManifest ? "GET" : request.method
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if !isManifest, let range = request.range { upstream.setValue(range, forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: upstream)
        self.task = task
        task.resume()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let server, !closed else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        _ = server.policy.evaluate(challenge: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard self.task === dataTask else { completionHandler(.cancel); return }
        guard !closed, !failing, let response = response as? HTTPURLResponse, let request,
              let url = response.url, let server, PlaybackRelayURL.isSameOrigin(url, server.serverURL) else {
            completionHandler(.cancel); fail(status: 502); return
        }
        resetTimeout()
        let status = response.statusCode
        guard [200, 206, 416].contains(status) else {
            completionHandler(.cancel)
            fail(status: [401, 403, 404].contains(status) ? status : 502)
            return
        }
        if response.mimeType?.lowercased().contains("mpegurl") == true { isManifest = true }
        if isManifest {
            guard status == 200, response.expectedContentLength <= Int64(PlaybackRelayManifest.maximumBytes),
                  response.expectedContentLength >= -1 else { completionHandler(.cancel); fail(status: 502); return }
            if dataTask.originalRequest?.httpMethod == "HEAD" {
                // Extensionless playlists are discovered from MIME. Their rewritten length
                // can only be calculated from a bounded GET of this same pinned resource.
                self.task = nil
                self.session = nil
                completionHandler(.cancel)
                session.invalidateAndCancel()
                fetch(url, asManifest: true)
                return
            }
            completionHandler(.allow)
            return
        }
        var fields: [String: String] = [:]
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"), Self.safeField(contentType) { fields["Content-Type"] = contentType }
        if let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges"), acceptRanges.lowercased() == "bytes" { fields["Accept-Ranges"] = "bytes" }
        if status == 206 || status == 416 {
            guard let range = response.value(forHTTPHeaderField: "Content-Range"), Self.validContentRange(range, unsatisfied: status == 416) else {
                completionHandler(.cancel); fail(status: 502); return
            }
            if status == 206, response.expectedContentLength >= 0, Self.contentRangeLength(range) != response.expectedContentLength {
                completionHandler(.cancel); fail(status: 502); return
            }
            fields["Content-Range"] = range
        }
        if status == 416 { fields["Content-Length"] = "0" }
        else if response.expectedContentLength >= 0 {
            fields["Content-Length"] = String(response.expectedContentLength)
            expectedBytes = request.method == "HEAD" ? nil : response.expectedContentLength
        }
        responseStarted = true
        sendHeaders(status: status, fields: fields) { [weak self] success in
            guard let self else { completionHandler(.cancel); return }
            if success && status != 416 { completionHandler(.allow) }
            else { completionHandler(.cancel); self.close() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.task === dataTask, !closed, !failing else { return }
        resetTimeout()
        receivedBytes += Int64(data.count)
        if let expectedBytes, receivedBytes > expectedBytes { close(); return }
        if isManifest {
            guard manifest.count + data.count <= PlaybackRelayManifest.maximumBytes else { fail(status: 502); return }
            manifest.append(data)
        } else {
            guard request?.method != "HEAD", bufferedBytes + data.count <= 1_024 * 1_024 else { close(); return }
            if !suspended { dataTask.suspend(); suspended = true }
            chunks.append(data)
            bufferedBytes += data.count
            drain()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard self.task === task, !closed, !failing else { return }
        guard error == nil, expectedBytes == nil || expectedBytes == receivedBytes else { fail(status: 502); return }
        upstreamComplete = true
        self.task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        if isManifest {
            do {
                guard let server, let upstreamURL else { throw PlaybackRelayError.stopped }
                let rewritten = try PlaybackRelayManifest.rewrite(manifest, upstream: upstreamURL, authenticationSource: server.sourceURL, map: server.map)
                manifest.removeAll()
                responseStarted = true
                sendHeaders(status: 200, fields: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(rewritten.count)]) { [weak self] success in
                    guard let self else { return }
                    guard success else { self.close(); return }
                    if self.request?.method != "HEAD" { self.chunks = [rewritten]; self.bufferedBytes = rewritten.count }
                    self.drain()
                }
            } catch { fail(status: 502) }
        } else { drain() }
    }

    private func drain() {
        guard !closed, !sending else { return }
        if chunks.isEmpty {
            if upstreamComplete { close() }
            else if suspended { suspended = false; task?.resume() }
            return
        }
        sending = true
        let data = chunks.removeFirst()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.sending = false
            self.bufferedBytes -= data.count
            guard error == nil else { self.close(); return }
            self.resetTimeout()
            self.drain()
        })
    }

    private func sendHeaders(status: Int, fields: [String: String], completion: @escaping (Bool) -> Void) {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 416: "Range Not Satisfiable", 431: "Request Header Fields Too Large", 502: "Bad Gateway"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { error in completion(error == nil) })
    }

    private func fail(status: Int) {
        guard !closed, !failing else { return }
        guard !responseStarted else { close(); return }
        failing = true
        responseStarted = true
        task?.cancel()
        sendHeaders(status: status, fields: ["Content-Length": "0"]) { [weak self] _ in self?.close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        chunks.removeAll()
        manifest.removeAll()
        header.removeAll()
        connection.stateUpdateHandler = nil
        connection.cancel()
        server?.remove(id)
    }

    private static func safeField(_ field: String) -> Bool {
        field.utf8.allSatisfy { (32...126).contains($0) } && field.utf8.count <= 512
    }

    static func validContentRange(_ value: String, unsatisfied: Bool) -> Bool {
        guard value.hasPrefix("bytes ") else { return false }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        if unsatisfied { return parts[0] == "*" && Int64(parts[1]).map { $0 >= 0 } == true }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start,
              contentRangeLength(value) != nil else { return false }
        return parts[1] == "*" || Int64(parts[1]).map { $0 > end } == true
    }

    private static func contentRangeLength(_ value: String) -> Int64? {
        let range = value.dropFirst(6).split(separator: "/").first?.split(separator: "-") ?? []
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]), start >= 0, end >= start else { return nil }
        let (count, overflow) = (end - start).addingReportingOverflow(1)
        return overflow ? nil : count
    }
}
