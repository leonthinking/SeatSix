import Darwin
import Foundation
import SeatSixCore

/// Editable address components. Only `endpoint()` produces the URL used to log in.
struct ServerAddressForm: Equatable {
    var useHTTPS = true
    var host = ""
    var port = ""
    var path = ""

    init() {}

    init(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            host = url.absoluteString
            return
        }
        useHTTPS = parts.scheme?.lowercased() != "http"
        host = parts.host ?? ""
        port = parts.port.map(String.init) ?? ""
        path = parts.percentEncodedPath
        // Never turn a malformed saved URL into a different, apparently valid endpoint.
        if parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil
            || !["https", "http"].contains(parts.scheme?.lowercased() ?? "") {
            host = url.absoluteString
        }
    }

    var validationMessage: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try endpoint(); return nil }
        catch { return error.localizedDescription }
    }

    var preview: String? { try? endpoint().baseURL.absoluteString }

    /// Keep keystrokes in place; split components only for a multi-character paste.
    /// The view also calls `updateHost(host)` on submit or when this field loses focus.
    mutating func editHost(_ input: String) {
        let difference = input.difference(from: host)
        var insertions = 0
        var removals = 0
        for change in difference {
            switch change {
            case .insert: insertions += 1
            case .remove: removals += 1
            }
        }
        if insertions <= 1 && removals <= 1 { host = input }
        else { updateHost(input) }
    }

    func endpoint() throws -> ServerEndpoint {
        let address = try components().string
        guard let address else { throw AddressError.host }
        do { return try ServerEndpoint(address: address, allowInsecureHTTP: !useHTTPS) }
        catch MediaServerError.insecureAddress { throw AddressError.publicHTTP }
    }

    /// Pasting an entire URL replaces every address component, including empty port/path.
    /// A normal hostname edit leaves the separate port and path controls untouched.
    mutating func updateHost(_ input: String) {
        host = input
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = value.contains("://")
        let bracketEnd = value.firstIndex(of: "]")
        let hasPort = value.hasPrefix("[")
            ? bracketEnd.map { value[value.index(after: $0)...].hasPrefix(":") } ?? false
            : value.contains(":")
        guard hasScheme || hasPort || value.contains("/") else { return }
        do {
            let parsed = try Self.parse(value, useHTTPS: useHTTPS)
            _ = try parsed.components()
            self = parsed
        } catch {
            // Keep the original visible input: do not discard credentials, a query or an error.
        }
    }

    private static func parse(_ input: String, useHTTPS: Bool) throws -> Self {
        var result = Self()
        result.useHTTPS = useHTTPS
        var remainder = input[...]
        if let separator = input.range(of: "://") {
            let scheme = input[..<separator.lowerBound].lowercased()
            guard ["http", "https"].contains(scheme) else { throw AddressError.host }
            result.useHTTPS = scheme == "https"
            remainder = input[separator.upperBound...]
        }
        let authority: Substring
        if let slash = remainder.firstIndex(of: "/") {
            authority = remainder[..<slash]
            result.path = String(remainder[slash...])
        } else { authority = remainder }
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { throw AddressError.host }
            result.host = String(authority[...end])
            let suffix = authority[authority.index(after: end)...]
            if !suffix.isEmpty {
                guard suffix.hasPrefix(":"), suffix.count > 1 else { throw AddressError.port }
                result.port = String(suffix.dropFirst())
            }
        } else {
            let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw AddressError.host }
            result.host = String(pieces[0])
            if pieces.count == 2 {
                guard !pieces[1].isEmpty else { throw AddressError.port }
                result.port = String(pieces[1])
            }
        }
        return result
    }

    private func components() throws -> URLComponents {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AddressError.missingHost }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            var address = in6_addr()
            guard String(name.dropFirst().dropLast()).withCString({ inet_pton(AF_INET6, $0, &address) }) == 1
            else { throw AddressError.host }
        } else {
            var allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            allowed.insert(charactersIn: "-._")
            guard name.unicodeScalars.allSatisfy(allowed.contains), !name.hasPrefix("."), !name.contains("..")
            else { throw AddressError.host }
        }
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        var portNumber: Int?
        if !portText.isEmpty {
            guard portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(portText), (1...65535).contains(number) else { throw AddressError.port }
            portNumber = number
        }
        let pathText = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedPath = try Self.encodePath(pathText)
        var parts = URLComponents()
        parts.scheme = useHTTPS ? "https" : "http"
        parts.host = name
        parts.port = portNumber
        parts.percentEncodedPath = escapedPath
        guard parts.url != nil else { throw AddressError.host }
        return parts
    }

    private static func encodePath(_ input: String) throws -> String {
        guard !input.contains("?"), !input.contains("#"), !input.contains("\\"),
              !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AddressError.path }
        let bytes = Array(input.utf8)
        for index in bytes.indices where bytes[index] == 37 {
            guard index + 2 < bytes.count,
                  isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { throw AddressError.path }
        }
        guard let decoded = input.removingPercentEncoding,
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
        else { throw AddressError.path }
        if input.isEmpty { return "" }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: "%")
        allowed.remove(charactersIn: "?#")
        guard var encoded = (input.hasPrefix("/") ? input : "/" + input).addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw AddressError.path }
        // Strip literal separators before ServerEndpoint normalizes its decoded path;
        // otherwise an unrelated encoded slash could silently become a path separator.
        while encoded.hasSuffix("/") { encoded.removeLast() }
        guard encoded.removingPercentEncoding?.hasSuffix("/") != true else { throw AddressError.path }
        return encoded
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private enum AddressError: LocalizedError {
        case missingHost, host, port, path, publicHTTP
        var errorDescription: String? {
            switch self {
            case .missingHost: return "请输入服务器地址。"
            case .host: return "请输入有效的域名或 IP 地址；IPv6 请加方括号。地址不能包含账户、查询参数或锚点。"
            case .port: return "端口号须为 1–65535 的数字，或留空使用协议默认端口。"
            case .path: return "路径不能包含查询参数、锚点、反斜杠、点段或无效的百分号编码。"
            case .publicHTTP: return "HTTP 仅适用于局域网 IP、localhost 或 .local 地址；公网连接请使用 HTTPS。"
            }
        }
    }
}
