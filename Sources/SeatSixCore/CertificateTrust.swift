import Foundation
import Security
import CryptoKit

/// A user-approved leaf certificate, scoped to one HTTPS host and effective port.
/// This never changes the system keychain or trust settings.
public struct CertificatePin: Codable, Equatable, Sendable {
    public let origin: String
    public let certificateDER: Data
    public let approvedAt: Date

    public init(url: URL, certificateDER: Data, approvedAt: Date = Date()) throws {
        origin = try Self.origin(for: url)
        guard SecCertificateCreateWithData(nil, certificateDER as CFData) != nil else { throw CertificateTrustError.invalidCertificate }
        self.certificateDER = certificateDER
        self.approvedAt = approvedAt
    }

    public var sha256Fingerprint: String { Self.fingerprint(certificateDER) }

    public static func origin(for url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              (1...65535).contains(parts.port ?? 443) else { throw CertificateTrustError.invalidOrigin }
        if parts.user != nil || parts.password != nil { throw CertificateTrustError.invalidOrigin }
        let normalizedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "https://\(normalizedHost):\(parts.port ?? 443)"
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

public enum CertificateTrustError: Error, LocalizedError, Equatable, Sendable {
    case untrusted, certificateChanged, originMismatch, invalidCertificate, certificateExpired, invalidUsage, invalidOrigin

    public var errorDescription: String? {
        switch self {
        case .untrusted: return "服务器的 HTTPS 证书未获系统信任。请核对证书后决定是否仅对此服务器信任。"
        case .certificateChanged: return "服务器证书已改变，连接已停止。请重新核对证书，确认后才能继续。"
        case .originMismatch: return "保存的证书信任不适用于此服务器地址或端口。"
        case .invalidCertificate: return "无法验证服务器证书及其有效期，连接已停止。"
        case .certificateExpired: return "服务器证书已过期或尚未生效，请先更新服务器证书。"
        case .invalidUsage: return "此证书未通过 TLS 服务器用途验证，不能用于此连接。"
        case .invalidOrigin: return "证书信任仅适用于有效的 HTTPS 服务器地址。"
        }
    }
}

public struct CertificateInspection: Sendable {
    public let origin: String
    public let certificateDER: Data
    public let sha256Fingerprint: String
    public let subject: String
    public let issuer: String
    public let validFrom: Date?
    public let validUntil: Date?
    public let systemTrusted: Bool
    public let trustFailureDescription: String?
    public let canApprove: Bool
    private let approvalError: CertificateTrustError?

    init(url: URL, trust: SecTrust) throws {
        origin = try CertificatePin.origin(for: url)
        guard let certificate = CertificateTrustPolicy.leaf(in: trust) else { throw CertificateTrustError.invalidCertificate }
        certificateDER = SecCertificateCopyData(certificate) as Data
        sha256Fingerprint = CertificatePin.fingerprint(certificateDER)
        let details = CertificateDetails(certificate)
        subject = details.subject
        issuer = details.issuer
        validFrom = details.validFrom
        validUntil = details.validUntil
        var systemError: CFError?
        SecTrustSetNetworkFetchAllowed(trust, false)
        systemTrusted = SecTrustEvaluateWithError(trust, &systemError)
        // Do not display raw network errors, which can include request URLs.
        let systemFailure = systemTrusted ? nil : Self.systemFailureDescription(systemError)
        let pin = try CertificatePin(url: url, certificateDER: certificateDER)
        do {
            try CertificateTrustPolicy(pin: pin).validate(serverTrust: trust, host: url.host ?? "", port: url.port ?? 443)
            approvalError = nil
            canApprove = true
            trustFailureDescription = PinnedCertificateStructure.isLegacyV1Eligible(certificate, der: certificateDER)
                ? "这是未声明 TLS 用途的旧式 v1 证书，系统无法核实签发者。请核对完整指纹；确认后仅信任当前地址和此证书。"
                : systemFailure
        } catch {
            let refusal = error as? CertificateTrustError ?? .invalidCertificate
            approvalError = refusal
            canApprove = false
            trustFailureDescription = refusal.localizedDescription
        }
    }

    private static func systemFailureDescription(_ error: CFError?) -> String {
        guard let error else { return CertificateTrustError.untrusted.localizedDescription }
        switch OSStatus(CFErrorGetCode(error)) {
        case errSecHostNameMismatch: return "系统验证失败：证书中的服务器名称与当前地址不匹配。"
        case errSecCertificateExpired: return "系统验证失败：证书已过期。"
        case errSecCertificateNotValidYet: return "系统验证失败：证书尚未生效。"
        case errSecNotTrusted, errSecInvalidRoot: return "系统验证失败：证书签发链未获信任，或根证书无效。"
        default: return "系统无法确认此服务器的证书身份，可能存在自签名、签发链或名称不匹配问题。"
        }
    }

    public func makePin() throws -> CertificatePin {
        if let approvalError { throw approvalError }
        guard let validFrom, let validUntil, validFrom <= Date(), Date() <= validUntil,
              let url = URL(string: origin) else { throw CertificateTrustError.certificateExpired }
        return try CertificatePin(url: url, certificateDER: certificateDER)
    }
}

/// The shared policy used by JSON/image requests and the streaming relay.
public struct CertificateTrustPolicy: Sendable {
    public let pin: CertificatePin?
    public init(pin: CertificatePin?) { self.pin = pin }

    public func validate(serverTrust: SecTrust, host: String, port: Int) throws {
        try validate(serverTrust: serverTrust, host: host, port: port, now: Date())
    }

    func validate(serverTrust: SecTrust, host: String, port: Int, now: Date) throws {
        guard let certificate = Self.leaf(in: serverTrust) else { throw CertificateTrustError.invalidCertificate }
        SecTrustSetNetworkFetchAllowed(serverTrust, false)
        guard let pin else {
            var error: CFError?
            guard SecTrustEvaluateWithError(serverTrust, &error) else { throw CertificateTrustError.untrusted }
            return
        }
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = host; origin.port = port
        guard let url = origin.url, try CertificatePin.origin(for: url) == pin.origin else { throw CertificateTrustError.originMismatch }
        guard SecCertificateCopyData(certificate) as Data == pin.certificateDER else { throw CertificateTrustError.certificateChanged }
        let details = CertificateDetails(certificate)
        guard let validFrom = details.validFrom, let validUntil = details.validUntil, validFrom <= validUntil else { throw CertificateTrustError.invalidCertificate }
        guard validFrom <= now, now <= validUntil else { throw CertificateTrustError.certificateExpired }
        // Leaf-anchor evaluation can skip unknown critical extensions. Refuse
        // those explicitly rather than approving semantics this client cannot read.
        guard PinnedCertificateStructure.hasSupportedCriticalExtensions(pin.certificateDER) else { throw CertificateTrustError.invalidUsage }
        // Explicit approval permits this exact leaf's hostname mismatch and unknown issuer,
        // but preserves TLS server-purpose, signature, key and date validation.
        let policy = SecPolicyCreateSSL(true, nil)
        guard SecTrustSetPolicies(serverTrust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(serverTrust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess,
              SecTrustSetVerifyDate(serverTrust, now as CFDate) == errSecSuccess else { throw CertificateTrustError.invalidCertificate }
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) { return }
        // RFC 5280 permits an absent EKU; Apple's SSL policy additionally requires
        // serverAuth after July 2019. A narrow, explicitly pinned legacy-v1 path
        // handles extension-free NAS certificates without ignoring an explicit EKU.
        let code = error.map { OSStatus(CFErrorGetCode($0)) }
        guard code == errSecInvalidExtendedKeyUsage || code == errSecSSLBadExtendedKeyUsage,
              PinnedCertificateStructure.isLegacyV1Eligible(certificate, der: pin.certificateDER),
              validUntil.timeIntervalSince(validFrom) <= 825 * 24 * 60 * 60,
              SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustEvaluateWithError(serverTrust, &error) else { throw CertificateTrustError.invalidUsage }

    }

    /// Returns the refusal reason for the delegate's error reporting; calls completion once.
    @discardableResult
    public func evaluate(challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> CertificateTrustError? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return nil
        }
        guard challenge.protectionSpace.protocol?.lowercased() == "https", let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return .invalidCertificate
        }
        do {
            try validate(serverTrust: trust, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port)
            completionHandler(.useCredential, URLCredential(trust: trust))
            return nil
        } catch {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return error as? CertificateTrustError ?? .invalidCertificate
        }
    }

    static func leaf(in trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
}

/// Use a dedicated instance per request when reading lastTrustError.
public final class CertificateSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: CertificateTrustPolicy
    private let lock = NSLock()
    private var storedError: CertificateTrustError?
    public var lastTrustError: CertificateTrustError? { lock.lock(); defer { lock.unlock() }; return storedError }
    public init(pin: CertificatePin?) { policy = CertificateTrustPolicy(pin: pin) }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Store failure before cancellation resumes the request continuation.
        var disposition: URLSession.AuthChallengeDisposition = .cancelAuthenticationChallenge
        var credential: URLCredential?
        let error = policy.evaluate(challenge: challenge) { disposition = $0; credential = $1 }
        lock.lock(); storedError = error; lock.unlock()
        completionHandler(disposition, credential)
    }
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        var disposition: URLSession.AuthChallengeDisposition = .cancelAuthenticationChallenge
        var credential: URLCredential?
        let error = policy.evaluate(challenge: challenge) { disposition = $0; credential = $1 }
        lock.lock(); storedError = error; lock.unlock()
        completionHandler(disposition, credential)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum CertificateSessionFactory {
    public static func makeSession(pin: CertificatePin?, configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: CertificateSessionDelegate(pin: pin), delegateQueue: nil)
    }
}

public enum CertificateInspector {
    /// Builds the same inspection from captured DER without opening a connection.
    public static func inspect(certificateDER: Data, url: URL) throws -> CertificateInspection {
        _ = try CertificatePin.origin(for: url)
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else { throw CertificateTrustError.invalidCertificate }
        let policy = SecPolicyCreateSSL(true, url.host as CFString?)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess, let trust else { throw CertificateTrustError.invalidCertificate }
        return try CertificateInspection(url: url, trust: trust)
    }

    /// Makes a credential-free handshake to the origin. No authentication or redirect is sent.
    public static func inspect(url: URL) async throws -> CertificateInspection {
        let origin = try CertificatePin.origin(for: url)
        guard let probeURL = URL(string: origin + "/") else { throw CertificateTrustError.invalidOrigin }
        let delegate = CertificateInspectionDelegate(url: probeURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: probeURL)
        request.httpMethod = "HEAD"
        do { _ = try await session.data(for: request, delegate: delegate) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if let result = delegate.result { return try result.get() }
            throw MediaServerError.network
        }
        if let result = delegate.result { return try result.get() }
        throw CertificateTrustError.invalidCertificate
    }
}

private final class CertificateInspectionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var storedResult: Result<CertificateInspection, Error>?
    var result: Result<CertificateInspection, Error>? { lock.lock(); defer { lock.unlock() }; return storedResult }
    init(url: URL) { self.url = url }
    func capture(_ challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let result = Result { try CertificateInspection(url: url, trust: trust) }
        lock.lock(); storedResult = result; lock.unlock()
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { capture(challenge, completionHandler: completionHandler) }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { capture(challenge, completionHandler: completionHandler) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct CertificateDetails {
    let subject: String
    let issuer: String
    let validFrom: Date?
    let validUntil: Date?
    init(_ certificate: SecCertificate) {
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any] ?? [:]
        subject = Self.clean(SecCertificateCopySubjectSummary(certificate) as String? ?? "未知")
        let issuerField = values[kSecOIDX509V1IssuerName as String] as? [String: Any]
        issuer = Self.clean(Self.strings(issuerField?[kSecPropertyKeyValue as String]).joined(separator: ", "))
        func date(_ key: CFString) -> Date? {
            let field = values[key as String] as? [String: Any]
            guard let number = field?[kSecPropertyKeyValue as String] as? NSNumber, number.doubleValue.isFinite else { return nil }
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        validFrom = date(kSecOIDX509V1ValidityNotBefore)
        validUntil = date(kSecOIDX509V1ValidityNotAfter)
    }
    private static func strings(_ value: Any?) -> [String] {
        if let string = value as? String { return [string] }
        if let values = value as? [Any] { return values.flatMap { strings($0) } }
        if let value = value as? [String: Any] { return strings(value[kSecPropertyKeyValue as String]) }
        return []
    }
    private static func clean(_ value: String) -> String {
        let filtered = String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(512))
        return filtered.isEmpty ? "未知" : filtered
    }
}

/// Accepts only an extension-free, strongly keyed, self-issued X.509 v1 leaf.
/// This parser is an allowlist for the legacy exception, not a general X.509 parser.
private enum PinnedCertificateStructure {
    static func isLegacyV1Eligible(_ certificate: SecCertificate, der: Data) -> Bool {
        guard der.count <= 65_536, let outer = DERNode.only(der), outer.tag == 0x30,
              let certificateFields = outer.children(), certificateFields.count == 3,
              certificateFields[0].tag == 0x30, certificateFields[1].tag == 0x30,
              certificateFields[2].tag == 0x03,
              let fields = certificateFields[0].children(),
              // Omitted default version means v1; any [0] version or trailing
              // unique-ID/extension field is rejected, including v3 without EKU.
              fields.count == 6, fields.map(\.tag) == [0x02, 0x30, 0x30, 0x30, 0x30, 0x30],
              fields[2].encoded == fields[4].encoded,
              fields[1].encoded == certificateFields[1].encoded,
              let algorithm = signatureAlgorithm(fields[1]),
              let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let bits = attributes[kSecAttrKeySizeInBits as String] as? Int, bits >= 2048,
              certificateFields[2].value.first == 0 else { return false }
        let signature = Data(certificateFields[2].value.dropFirst())
        guard signature.count == (bits + 7) / 8, SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        // This exact leaf is the user-approved trust anchor. Its issuer signature
        // does not establish identity; the out-of-band fingerprint approval does.
        // TLS still proves possession of its private key. As with modern leaf pins,
        // do not require an anchor's self-signature to authenticate that anchor.
        return true
    }

    static func hasSupportedCriticalExtensions(_ der: Data) -> Bool {
        guard der.count <= 65_536, let outer = DERNode.only(der), outer.tag == 0x30,
              let fields = outer.children(), fields.count == 3, fields[0].tag == 0x30,
              let tbs = fields[0].children() else { return false }
        let extensionFields = tbs.filter { $0.tag == 0xa3 }
        guard extensionFields.count <= 1 else { return false }
        guard let field = extensionFields.first else { return true }
        guard let sequence = DERNode.only(field.value), sequence.tag == 0x30,
              let extensions = sequence.children() else { return false }
        let supported: Set<Data> = [Data([0x55, 0x1d, 0x13]), // basicConstraints
                                    Data([0x55, 0x1d, 0x0f]), // keyUsage
                                    Data([0x55, 0x1d, 0x25]), // extendedKeyUsage
                                    Data([0x55, 0x1d, 0x11])] // subjectAltName
        var seen: Set<Data> = []
        for item in extensions {
            guard item.tag == 0x30, let parts = item.children(), (2...3).contains(parts.count),
                  parts[0].tag == 0x06, seen.insert(parts[0].value).inserted,
                  parts.last?.tag == 0x04 else { return false }
            if parts.count == 3 {
                guard parts[1].tag == 0x01, parts[1].value == Data([0]) || parts[1].value == Data([0xff]) else { return false }
                if parts[1].value == Data([0xff]), !supported.contains(parts[0].value) { return false }
            }
        }
        return true
    }

    private static func signatureAlgorithm(_ node: DERNode) -> SecKeyAlgorithm? {
        guard let fields = node.children(), fields.count == 1 || fields.count == 2,
              fields[0].tag == 0x06,
              fields.count == 1 || (fields[1].tag == 0x05 && fields[1].value.isEmpty) else { return nil }
        // 1.2.840.113549.1.1.{11,12,13}: SHA-256/384/512 with RSA PKCS#1 v1.5.
        switch Array(fields[0].value) {
        case [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b]: return .rsaSignatureMessagePKCS1v15SHA256
        case [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0c]: return .rsaSignatureMessagePKCS1v15SHA384
        case [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0d]: return .rsaSignatureMessagePKCS1v15SHA512
        default: return nil
        }
    }

    private struct DERNode {
        let tag: UInt8
        let value: Data
        let encoded: Data
        static func only(_ data: Data) -> DERNode? {
            var index = 0
            let bytes = Array(data)
            guard let node = read(bytes, index: &index), index == bytes.count else { return nil }
            return node
        }
        func children() -> [DERNode]? {
            var result: [DERNode] = []
            let bytes = Array(value)
            var index = 0
            while index < bytes.count {
                guard result.count < 16, let node = Self.read(bytes, index: &index) else { return nil }
                result.append(node)
            }
            return result
        }
        static func read(_ bytes: [UInt8], index: inout Int) -> DERNode? {
            let start = index
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]; index += 1
            let lengthByte = bytes[index]; index += 1
            var length = Int(lengthByte)
            if lengthByte & 0x80 != 0 {
                let count = Int(lengthByte & 0x7f)
                guard (1...4).contains(count), index + count <= bytes.count,
                      bytes[index] != 0 else { return nil }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
                guard length >= 128 else { return nil }
            }
            guard length <= bytes.count - index else { return nil }
            let value = Data(bytes[index..<(index + length)])
            index += length
            return DERNode(tag: tag, value: value, encoded: Data(bytes[start..<index]))
        }
    }
}
