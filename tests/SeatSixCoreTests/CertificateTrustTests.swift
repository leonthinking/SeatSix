import XCTest
import Security
@testable import SeatSixCore

final class CertificateTrustTests: XCTestCase {
    private static let fixture = try! TestCertificate(commonName: "SeatSix Self Signed Test", usage: "serverAuth")
    private static let otherFixture = try! TestCertificate(commonName: "SeatSix Different Certificate", usage: "serverAuth")
    private static let clientFixture = try! TestCertificate(commonName: "SeatSix Client Only", usage: "clientAuth")
    private static let legacyFixture = try! TestCertificate(commonName: "SeatSix Legacy No Extensions", usage: nil)
    private static let alteredLegacyFixture = try! TestCertificate(commonName: "SeatSix Legacy Altered Signature", usage: nil, corruptSignature: true)
    private static let weakLegacyKey = try! TestCertificate(commonName: "SeatSix Legacy Weak Key", usage: nil, keyBits: 1024)
    private static let weakLegacyHash = try! TestCertificate(commonName: "SeatSix Legacy Weak Hash", usage: nil, hash: "sha1")
    private static let v3MissingUsage = try! TestCertificate(commonName: "SeatSix V3 No EKU", usage: "", extraExtension: "subjectAltName=DNS:fixture.test")
    private let url = URL(string: "https://127.0.0.1:9443/emby")!

    func testOriginIncludesEffectivePortAndNormalizesCase() throws {
        XCTAssertEqual(try CertificatePin.origin(for: URL(string: "HTTPS://MEDIA.EXAMPLE/path?q=value")!), "https://media.example:443")
        XCTAssertEqual(try CertificatePin.origin(for: URL(string: "https://[::1]:9443/path")!), "https://[::1]:9443")
        XCTAssertThrowsError(try CertificatePin.origin(for: URL(string: "http://127.0.0.1:9443")!))
        XCTAssertThrowsError(try CertificatePin.origin(for: URL(string: "https://name:password@media.example")!))
    }

    func testDefaultTrustRejectsSelfSignedAndPinAllowsOnlyExactLeaf() throws {
        let fixture = Self.fixture
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: nil).validate(serverTrust: fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443)) { XCTAssertEqual($0 as? CertificateTrustError, .untrusted) }
        let pin = try CertificatePin(url: url, certificateDER: fixture.der)
        XCTAssertNoThrow(try CertificateTrustPolicy(pin: pin).validate(serverTrust: fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443))
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: pin).validate(serverTrust: Self.otherFixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443)) { XCTAssertEqual($0 as? CertificateTrustError, .certificateChanged) }
    }

    func testPinNeverOverridesAnOriginMismatch() throws {
        let pin = try CertificatePin(url: url, certificateDER: Self.fixture.der)
        for (host, port) in [("127.0.0.1", 443), ("localhost", 9443), ("media.example", 9443)] {
            XCTAssertThrowsError(try CertificateTrustPolicy(pin: pin).validate(serverTrust: Self.fixture.trust(host: host), host: host, port: port)) { XCTAssertEqual($0 as? CertificateTrustError, .originMismatch) }
        }
    }

    func testExpiredNotYetValidAndWrongTLSUsageAreNeverApproved() throws {
        let inspection = try CertificateInspector.inspect(certificateDER: Self.fixture.der, url: url)
        let pin = try inspection.makePin()
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: pin).validate(serverTrust: Self.fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443, now: inspection.validFrom!.addingTimeInterval(-1))) { XCTAssertEqual($0 as? CertificateTrustError, .certificateExpired) }
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: pin).validate(serverTrust: Self.fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443, now: inspection.validUntil!.addingTimeInterval(1))) { XCTAssertEqual($0 as? CertificateTrustError, .certificateExpired) }
        let clientInspection = try CertificateInspector.inspect(certificateDER: Self.clientFixture.der, url: url)
        XCTAssertFalse(clientInspection.canApprove)
        XCTAssertThrowsError(try clientInspection.makePin()) { XCTAssertEqual($0 as? CertificateTrustError, .invalidUsage) }
    }

    func testLegacyV1RequiresStrongAlgorithmsAndExplicitPin() throws {
        let inspection = try CertificateInspector.inspect(certificateDER: Self.legacyFixture.der, url: url)
        XCTAssertFalse(inspection.systemTrusted)
        XCTAssertTrue(inspection.canApprove)
        XCTAssertTrue(inspection.trustFailureDescription?.contains("旧式 v1") == true)
        XCTAssertNoThrow(try inspection.makePin())
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: nil).validate(serverTrust: Self.legacyFixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443))
        for fixture in [Self.weakLegacyKey, Self.weakLegacyHash, Self.v3MissingUsage, Self.clientFixture] {
            let denied = try CertificateInspector.inspect(certificateDER: fixture.der, url: url)
            XCTAssertFalse(denied.canApprove)
            XCTAssertThrowsError(try denied.makePin())
        }
        var badSignature = Self.legacyFixture.der
        badSignature[badSignature.count - 1] ^= 1
        // An exact, user-approved leaf is a trust anchor; its self-signature is
        // not the authentication proof. TLS proves possession of its private key.
        let altered = try CertificateInspector.inspect(certificateDER: badSignature, url: url)
        XCTAssertTrue(altered.canApprove)
        let alteredPin = try altered.makePin()
        let alteredCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, badSignature as CFData))
        var alteredTrust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(alteredCertificate, SecPolicyCreateSSL(true, nil), &alteredTrust), errSecSuccess)
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: nil).validate(serverTrust: XCTUnwrap(alteredTrust), host: "127.0.0.1", port: 9443))
        XCTAssertNoThrow(try CertificateTrustPolicy(pin: alteredPin).validate(serverTrust: XCTUnwrap(alteredTrust), host: "127.0.0.1", port: 9443))
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: inspection.makePin()).validate(serverTrust: XCTUnwrap(alteredTrust), host: "127.0.0.1", port: 9443)) { XCTAssertEqual($0 as? CertificateTrustError, .certificateChanged) }
    }

    func testModernWeakKeyAndUnknownCriticalExtensionAreNotApproved() throws {
        let fixtures = [
            try TestCertificate(commonName: "Weak Key Modern", usage: "serverAuth", keyBits: 1024),
            try TestCertificate(commonName: "Unknown Critical Modern", usage: "serverAuth", extraExtension: "1.2.3.4=critical,DER:01:01:FF")
        ]
        for fixture in fixtures {
            let inspection = try CertificateInspector.inspect(certificateDER: fixture.der, url: url)
            XCTAssertFalse(inspection.canApprove, inspection.subject)
            XCTAssertThrowsError(try inspection.makePin(), inspection.subject)
        }
    }

    func testKnownCriticalAndUnknownNoncriticalExtensionsRemainApprovable() throws {
        for extra in ["subjectAltName=critical,DNS:fixture.test", "1.2.3.4=DER:01:01:FF"] {
            let fixture = try TestCertificate(commonName: "Modern Extension Fixture", usage: "serverAuth", extraExtension: extra)
            let inspection = try CertificateInspector.inspect(certificateDER: fixture.der, url: url)
            XCTAssertTrue(inspection.canApprove)
            XCTAssertNoThrow(try inspection.makePin())
        }
    }

    func testInspectionContainsVerifiableIdentityWithoutGrantingSystemTrust() throws {
        let inspection = try CertificateInspector.inspect(certificateDER: Self.fixture.der, url: url)
        XCTAssertFalse(inspection.systemTrusted)
        XCTAssertTrue(inspection.canApprove)
        XCTAssertEqual(inspection.subject, "SeatSix Self Signed Test")
        XCTAssertTrue(inspection.issuer.contains("SeatSix Self Signed Test"))
        XCTAssertEqual(inspection.sha256Fingerprint.split(separator: ":").count, 32)
        XCTAssertLessThanOrEqual(try XCTUnwrap(inspection.validFrom), Date())
        XCTAssertGreaterThan(try XCTUnwrap(inspection.validUntil), Date())
        XCTAssertThrowsError(try CertificateInspector.inspect(certificateDER: Data("invalid".utf8), url: url))
        // Inspection changes only its temporary SecTrust, never the system trust store.
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: nil).validate(serverTrust: Self.fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443))
    }

    func testOldConnectionsDecodeWithoutPinAndPinRoundTrips() throws {
        let old = Data(#"{"id":"3AB73A82-A993-437E-89CC-3B78DB204097","kind":"emby","name":"Test","baseURL":"https://media.example","serverID":"s","userID":"u","username":"name"}"#.utf8)
        var connection = try JSONDecoder().decode(ServerConnection.self, from: old)
        XCTAssertNil(connection.certificatePin)
        connection.certificatePin = try CertificatePin(url: url, certificateDER: Self.fixture.der)
        XCTAssertEqual(try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(connection)), connection)
    }

    func testMalformedDecodedPinsCannotBypassValidation() throws {
        let pin = try CertificatePin(url: url, certificateDER: Self.fixture.der)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pin)) as! [String: Any]
        object["origin"] = "https://127.0.0.1"
        var invalid = try JSONDecoder().decode(CertificatePin.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: invalid).validate(serverTrust: Self.fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443)) { XCTAssertEqual($0 as? CertificateTrustError, .originMismatch) }
        object["origin"] = pin.origin
        object["certificateDER"] = Data("invalid certificate".utf8).base64EncodedString()
        invalid = try JSONDecoder().decode(CertificatePin.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try CertificateTrustPolicy(pin: invalid).validate(serverTrust: Self.fixture.trust(host: "127.0.0.1"), host: "127.0.0.1", port: 9443)) { XCTAssertEqual($0 as? CertificateTrustError, .certificateChanged) }
    }

    func testPinnedAuthenticationRejectsCleartextBeforeSendingCredentials() async throws {
        let pin = try CertificatePin(url: url, certificateDER: Self.fixture.der)
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: "http://127.0.0.1:1", username: "fixture", password: "", allowInsecureHTTP: true, deviceID: "fixture", certificatePin: pin)
            XCTFail("Pinned connection was downgraded to HTTP")
        } catch { XCTAssertEqual(error as? MediaServerError, .certificate(.originMismatch)) }
    }

    func testRealHandshakeInspectionDoesNotSendHTTPOrCredentials() async throws {
        let server = try TestTLSServer(certificate: Self.fixture)
        defer { server.stop() }
        let candidate = try await CertificateInspector.inspect(url: server.url.appendingPathComponent("emby/Users/AuthenticateByName"))
        XCTAssertEqual(candidate.certificateDER, Self.fixture.der)
        XCTAssertTrue(candidate.canApprove)
        XCTAssertFalse(candidate.systemTrusted)
        XCTAssertEqual(server.requestCount, 0, "Inspection must cancel the handshake before sending any HTTP request")
    }

    func testLegacyTLSWithAlteredIssuerSignatureStillRequiresExplicitExactPin() async throws {
        // The issuer signature is altered while the server retains the matching
        // leaf private key. Only explicit pin approval may authenticate this TLS peer.
        let server = try TestTLSServer(certificate: Self.alteredLegacyFixture)
        defer { server.stop() }
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true)
            XCTFail("Legacy TLS accepted before approval")
        } catch { XCTAssertEqual(error as? MediaServerError, .certificate(.untrusted)) }
        XCTAssertEqual(server.requestCount, 0)
        let inspection = try await CertificateInspector.inspect(url: server.url)
        XCTAssertEqual(inspection.certificateDER, Self.alteredLegacyFixture.der)
        XCTAssertFalse(inspection.systemTrusted)
        XCTAssertTrue(inspection.canApprove)
        XCTAssertEqual(server.requestCount, 0)
        let pin = try inspection.makePin()
        let authenticated = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true, certificatePin: pin)
        XCTAssertEqual(authenticated.connection.certificatePin, pin)
        XCTAssertEqual(server.requestCount, 1)
        let wrongPin = try CertificatePin(url: server.url, certificateDER: Self.legacyFixture.der)
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true, certificatePin: wrongPin)
            XCTFail("Legacy TLS accepted a different leaf pin")
        } catch { XCTAssertEqual(error as? MediaServerError, .certificate(.certificateChanged)) }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealHTTPSAuthenticationRequiresApprovedPinAndClassifiesChanges() async throws {
        let server = try TestTLSServer(certificate: Self.fixture)
        defer { server.stop() }
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true)
            XCTFail("Self-signed certificate accepted without user approval")
        } catch { XCTAssertEqual(error as? MediaServerError, .certificate(.untrusted)) }
        XCTAssertEqual(server.requestCount, 0)
        let pin = try CertificatePin(url: server.url, certificateDER: Self.fixture.der)
        let result = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true, certificatePin: pin)
        XCTAssertEqual(result.connection.certificatePin, pin)
        XCTAssertEqual(result.connection.userID, "fixture-user")
        let changedPin = try CertificatePin(url: server.url, certificateDER: Self.otherFixture.der)
        do {
            _ = try await MediaServerClient.authenticate(kind: .emby, address: server.url.absoluteString, username: "fixture-user", password: "", deviceID: "fixture", compatibilityMode: true, certificatePin: changedPin)
            XCTFail("Changed certificate accepted")
        } catch { XCTAssertEqual(error as? MediaServerError, .certificate(.certificateChanged)) }
        XCTAssertEqual(server.requestCount, 1, "Rejected TLS must not transmit authentication")
    }
}

private final class TestCertificate {
    let directory: URL
    let der: Data
    var pemURL: URL { directory.appendingPathComponent("cert.pem") }
    var keyURL: URL { directory.appendingPathComponent("key.pem") }
    init(commonName: String, usage: String?, keyBits: Int = 2048, hash: String = "sha256", extraExtension: String? = nil, corruptSignature: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("seatsix-cert-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let certificate = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")
        if let usage {
            var arguments = ["req", "-x509", "-newkey", "rsa:\(keyBits)", "-nodes", "-days", "2", "-\(hash)", "-subj", "/CN=\(commonName)", "-addext", "keyUsage=digitalSignature,keyEncipherment", "-keyout", key.path, "-out", certificate.path]
            if !usage.isEmpty { arguments += ["-addext", "extendedKeyUsage=\(usage)"] }
            if let extraExtension { arguments += ["-addext", extraExtension] }
            try Self.run(arguments)
        } else {
            let request = directory.appendingPathComponent("request.csr")
            try Self.run(["req", "-new", "-newkey", "rsa:\(keyBits)", "-nodes", "-subj", "/CN=\(commonName)", "-keyout", key.path, "-out", request.path])
            try Self.run(["x509", "-req", "-in", request.path, "-signkey", key.path, "-days", "2", "-\(hash)", "-out", certificate.path])
        }
        let derURL = directory.appendingPathComponent("cert.der")
        try Self.run(["x509", "-in", certificate.path, "-outform", "DER", "-out", derURL.path])
        var certificateDER = try Data(contentsOf: derURL)
        if corruptSignature {
            certificateDER[certificateDER.count - 1] ^= 1
            try certificateDER.write(to: derURL)
            try Self.run(["x509", "-inform", "DER", "-in", derURL.path, "-outform", "PEM", "-out", certificate.path])
        }
        der = certificateDER
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func trust(host: String) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }
    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "CertificateFixture", code: Int(process.terminationStatus)) }
    }
}

private final class TestTLSServer {
    let process: Process
    let url: URL
    private let counter: URL
    private var stopped = false
    var requestCount: Int { (try? String(contentsOf: counter)).flatMap { Int($0) } ?? 0 }
    init(certificate: TestCertificate) throws {
        counter = certificate.directory.appendingPathComponent(UUID().uuidString + ".count")
        let source = #"""
import http.server, ssl, sys, json
counter=sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            with open(counter) as f: count=int(f.read())
        except FileNotFoundError: count=0
        with open(counter,'w') as f: f.write(str(count+1))
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        body=json.dumps({'User':{'Id':'fixture-user','Name':'Fixture'},'AccessToken':'synthetic-fixture-token','ServerId':'fixture-server'}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_HEAD(self):
        with open(counter,'w') as f: f.write('999')
        self.send_response(200); self.end_headers()
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1],sys.argv[2])
server.socket=context.wrap_socket(server.socket,server_side=True)
print(server.server_address[1],flush=True)
server.serve_forever()
"""#
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", source, certificate.pemURL.path, certificate.keyURL.path, counter.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([10]) { break }
            bytes.append(byte)
        }
        guard let line = String(data: bytes, encoding: .utf8), let port = Int(line), let parsed = URL(string: "https://127.0.0.1:\(port)") else {
            process.terminate()
            throw NSError(domain: "TLSFixture", code: 1)
        }
        url = parsed
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        // Foundation can miss Process.waitUntilExit completion on a cooperative
        // executor after the child has already gone away. Termination is enough
        // for this disposable localhost fixture; never block test teardown on it.
        if process.isRunning { process.terminate() }
    }
    deinit { stop(); try? FileManager.default.removeItem(at: counter) }
}
