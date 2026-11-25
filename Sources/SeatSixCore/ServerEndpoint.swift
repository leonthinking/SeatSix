import Foundation

public struct ServerEndpoint: Sendable {
    public let baseURL: URL
    public init(address: String, allowInsecureHTTP: Bool = false) throws {
        guard var parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.query == nil, parts.fragment == nil, parts.port.map({ (1...65535).contains($0) }) ?? true
        else { throw MediaServerError.invalidAddress }
        if parts.user != nil || parts.password != nil { throw MediaServerError.invalidAddress }
        if scheme == "http", !(allowInsecureHTTP && Self.isLocalHost(host)) { throw MediaServerError.insecureAddress }
        parts.scheme = scheme
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw MediaServerError.invalidAddress }
        baseURL = url
    }

    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        if host.contains(":"), host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:") { return true }
        let components = host.split(separator: ".")
        guard components.count == 4 else { return false }
        let values = components.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        return values[0] == 127 || values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1])) || (values[0] == 192 && values[1] == 168) || (values[0] == 169 && values[1] == 254)
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased() && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
}

// Refuse redirects rather than forwarding authentication to an unverified endpoint.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
