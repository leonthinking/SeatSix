import AppKit
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class CertificateMemoryStorage: ApplicationPersisting {
    var value: SavedApplication
    var failSave = false
    var writes = 0
    init(_ connection: ServerConnection) {
        value = SavedApplication(); value.connections = [connection]; value.selectedID = connection.id
    }
    func load() throws -> SavedApplication { value }
    func save(_ value: SavedApplication) throws {
        if failSave { throw ApplicationPersistenceError.saveFailed }
        self.value = value; writes += 1
    }
}

@MainActor
final class CertificateConfirmationTests: XCTestCase {
    private static var fixtureDirectory: URL!
    private static var certificateDER: Data!
    private static var clientOnlyDER: Data!

    override class func setUp() {
        super.setUp()
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seatsix-certificate-ui-tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fixtureDirectory = folder
            let config = """
            [req]
            distinguished_name=dn
            x509_extensions=ext
            prompt=no
            [dn]
            CN=fixture.test
            [ext]
            basicConstraints=critical,CA:FALSE
            keyUsage=critical,digitalSignature,keyEncipherment
            extendedKeyUsage=serverAuth
            subjectAltName=DNS:fixture.test
            """
            try config.write(to: folder.appendingPathComponent("cert.cnf"), atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", folder.appendingPathComponent("cert.cnf").path,
                "-keyout", folder.appendingPathComponent("key.pem").path, "-outform", "DER", "-out", folder.appendingPathComponent("cert.der").path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "fixture", code: 1) }
            certificateDER = try Data(contentsOf: folder.appendingPathComponent("cert.der"))
            try config.replacingOccurrences(of: "extendedKeyUsage=serverAuth", with: "extendedKeyUsage=clientAuth")
                .write(to: folder.appendingPathComponent("client.cnf"), atomically: true, encoding: .utf8)
            let clientCertificate = Process(); clientCertificate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            clientCertificate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", folder.appendingPathComponent("client.cnf").path,
                "-keyout", folder.appendingPathComponent("client-key.pem").path, "-outform", "DER", "-out", folder.appendingPathComponent("client.der").path]
            clientCertificate.standardOutput = FileHandle.nullDevice; clientCertificate.standardError = FileHandle.nullDevice
            try clientCertificate.run(); clientCertificate.waitUntilExit()
            guard clientCertificate.terminationStatus == 0 else { throw NSError(domain: "fixture", code: 2) }
            clientOnlyDER = try Data(contentsOf: folder.appendingPathComponent("client.der"))
        } catch { XCTFail("Could not create temporary certificate fixture: \(error)") }
    }
    override class func tearDown() {
        if let fixtureDirectory { try? FileManager.default.removeItem(at: fixtureDirectory) }
        certificateDER = nil; clientOnlyDER = nil; fixtureDirectory = nil
        super.tearDown()
    }
    private func inspection(_ host: String = "fixture.test") throws -> CertificateInspection {
        try CertificateInspector.inspect(certificateDER: Self.certificateDER, url: URL(string: "https://\(host):9443/emby")!)
    }
    private func result(_ attempt: ServerLoginAttempt, _ pin: CertificatePin?) -> AuthenticatedServer {
        AuthenticatedServer(connection: ServerConnection(kind: attempt.kind, name: "Fixture", baseURL: URL(string: attempt.address)!,
            serverID: "fixture-server", userID: "fixture-user", username: attempt.username, certificatePin: pin), token: "fixture-token")
    }
    private func ready(_ services: ServerLoginServices) -> ServerLoginState {
        let state = ServerLoginState(deviceID: "fixture-device", services: services)
        state.address = "https://fixture.test:9443/emby"; state.username = "viewer"
        state[keyPath: \.password] = UUID().uuidString
        return state
    }
    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testUntrustedCertificateNeedsExplicitApprovalBeforeCredentialRetry() async throws {
        let certificate = try inspection()
        var attempts: [CertificatePin?] = []; var inspected: [URL] = []; var libraryCalls = 0
        let state = ready(ServerLoginServices(authenticate: { attempt, pin in
            attempts.append(pin)
            if pin == nil { throw MediaServerError.certificate(.untrusted) }
            return self.result(attempt, pin)
        }, inspect: { url in inspected.append(url); return certificate }, libraries: { _, _ in libraryCalls += 1; return [] }))
        state.login(); try await waitFor { state.challenge != nil }
        XCTAssertEqual(attempts.count, 1); XCTAssertNil(attempts[0]); XCTAssertEqual(libraryCalls, 0)
        XCTAssertEqual(inspected.map(\.absoluteString), ["https://fixture.test:9443/emby"])
        XCTAssertNil(state.authenticated)
        state.approve(try XCTUnwrap(state.challenge).id)
        try await waitFor { state.authenticated != nil }
        XCTAssertEqual(attempts.count, 2); XCTAssertEqual(attempts.last.flatMap { $0 }?.origin, "https://fixture.test:9443")
        XCTAssertEqual(state.authenticated?.connection.certificatePin?.certificateDER, Self.certificateDER)
        XCTAssertEqual(libraryCalls, 1); XCTAssertEqual(state.password, "")
    }

    func testCancelDoesNotRetryAuthenticationOrRetainCandidate() async throws {
        let certificate = try inspection(); var calls = 0
        let state = ready(ServerLoginServices(authenticate: { _, _ in calls += 1; throw MediaServerError.certificate(.untrusted) },
            inspect: { _ in certificate }, libraries: { _, _ in XCTFail("Must not fetch libraries"); return [] }))
        state.login(); try await waitFor { state.challenge != nil }
        let oldID = try XCTUnwrap(state.challenge).id
        state.cancelTrust(); state.approve(oldID)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(calls, 1); XCTAssertNil(state.challenge); XCTAssertNil(state.authenticated)
    }

    func testAddressEditInvalidatesCandidateAndCannotApproveOldOrigin() async throws {
        let certificate = try inspection(); var calls = 0
        let state = ready(ServerLoginServices(authenticate: { _, _ in calls += 1; throw MediaServerError.certificate(.untrusted) },
            inspect: { _ in certificate }, libraries: { _, _ in [] }))
        state.login(); try await waitFor { state.challenge != nil }
        let oldID = try XCTUnwrap(state.challenge).id
        state.address = "https://different.test:9443/emby"; state.approve(oldID)
        XCTAssertNil(state.challenge); XCTAssertNil(state.authenticated); XCTAssertEqual(calls, 1)
    }

    func testTypeEditInvalidatesCandidate() async throws {
        let certificate = try inspection()
        let state = ready(ServerLoginServices(authenticate: { _, _ in throw MediaServerError.certificate(.untrusted) },
            inspect: { _ in certificate }, libraries: { _, _ in [] }))
        state.login(); try await waitFor { state.challenge != nil }
        let oldID = try XCTUnwrap(state.challenge).id
        state.kind = .jellyfin; state.approve(oldID)
        XCTAssertNil(state.challenge); XCTAssertNil(state.authenticated)
    }

    func testLateInspectionCannotResurrectCancelledOrEditedCandidate() async throws {
        let certificate = try inspection(); var continuation: CheckedContinuation<CertificateInspection, Never>?
        let state = ready(ServerLoginServices(authenticate: { _, _ in throw MediaServerError.certificate(.untrusted) },
            inspect: { _ in await withCheckedContinuation { continuation = $0 } }, libraries: { _, _ in [] }))
        state.login(); try await waitFor { continuation != nil }
        state.address = "https://different.test:9443"; continuation?.resume(returning: certificate)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(state.challenge); XCTAssertFalse(state.working); XCTAssertNil(state.authenticated)
    }

    func testNormalAuthenticationFailureNeverTriggersCertificateInspection() async throws {
        var inspectionCalls = 0
        let state = ready(ServerLoginServices(authenticate: { _, _ in throw MediaServerError.httpStatus(401) },
            inspect: { _ in inspectionCalls += 1; return try self.inspection() }, libraries: { _, _ in [] }))
        state.login(); try await waitFor { !state.working }
        XCTAssertEqual(inspectionCalls, 0); XCTAssertNil(state.challenge); XCTAssertNotNil(state.error)
    }

    func testUnapprovableCertificateCannotBeApprovedEvenProgrammatically() async throws {
        let certificate = try CertificateInspector.inspect(certificateDER: Self.clientOnlyDER, url: URL(string: "https://fixture.test:9443/emby")!)
        XCTAssertFalse(certificate.canApprove)
        var authenticationCalls = 0
        let state = ready(ServerLoginServices(authenticate: { _, _ in authenticationCalls += 1; throw MediaServerError.certificate(.untrusted) },
            inspect: { _ in certificate }, libraries: { _, _ in XCTFail("Invalid certificate must not reach library requests"); return [] }))
        state.login(); try await waitFor { state.challenge != nil }
        state.approve(try XCTUnwrap(state.challenge).id)
        XCTAssertEqual(authenticationCalls, 1); XCTAssertNil(state.authenticated); XCTAssertNotNil(state.challenge)
    }

    func testCredentialEditKeepsExistingOriginScopedPin() async throws {
        let pin = try inspection().makePin(); var usedPin: CertificatePin?
        let existing = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "fixture-server", userID: "fixture-user", username: "viewer", certificatePin: pin)
        let state = ServerLoginState(deviceID: "fixture-device", existing: existing, services: ServerLoginServices(authenticate: { attempt, pin in
            usedPin = pin; return self.result(attempt, pin)
        }, inspect: { _ in XCTFail("Approved certificate must not require repeated approval when credentials change"); return try self.inspection() }, libraries: { _, _ in [] }))
        state[keyPath: \.password] = UUID().uuidString; state.login()
        try await waitFor { state.authenticated != nil }
        XCTAssertEqual(usedPin, pin); XCTAssertEqual(state.password, "")
    }

    func testLateAuthenticationCannotCompleteAfterLoginIsCancelled() async throws {
        var continuation: CheckedContinuation<AuthenticatedServer, Never>?
        var submitted: ServerLoginAttempt?
        let state = ready(ServerLoginServices(authenticate: { attempt, _ in
            submitted = attempt
            return await withCheckedContinuation { continuation = $0 }
        }, inspect: { _ in XCTFail("Unexpected inspection"); return try self.inspection() }, libraries: { _, _ in XCTFail("Cancelled login must not load libraries"); return [] }))
        state.login(); try await waitFor { continuation != nil }
        state.cancel()
        continuation?.resume(returning: result(try XCTUnwrap(submitted), nil))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.authenticated); XCTAssertNil(state.challenge); XCTAssertFalse(state.working); XCTAssertEqual(state.password, "")
    }

    func testExistingPinChangeRequiresNewConfirmation() async throws {
        let certificate = try inspection(); let pin = try certificate.makePin(); var pins: [CertificatePin?] = []
        let existing = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "fixture-server", userID: "fixture-user", username: "viewer", certificatePin: pin)
        let state = ServerLoginState(deviceID: "fixture-device", existing: existing, services: ServerLoginServices(authenticate: { _, pin in
            pins.append(pin); throw MediaServerError.certificate(.certificateChanged)
        }, inspect: { _ in certificate }, libraries: { _, _ in [] }))
        state.login(); try await waitFor { state.challenge != nil }
        XCTAssertEqual(pins.count, 1); XCTAssertEqual(pins[0], pin)
        XCTAssertEqual(state.challenge?.previousFingerprint, pin.sha256Fingerprint)
        state.cancel(); XCTAssertEqual(state.password, ""); XCTAssertNil(state.challenge)
    }

    func testRevokePersistsRemovalClearsImagesAndRejectsStaleConnectionPin() async throws {
        let pin = try inspection().makePin()
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "fixture-server", userID: "fixture-user", username: "viewer", certificatePin: pin)
        let storage = CertificateMemoryStorage(connection); var invalidated: [UUID] = []
        let model = ApplicationModel(storage: storage, credentials: CredentialAccess(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
            invalidatePosters: { invalidated.append($0) })
        let movie = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"fixture-movie","Name":"Fixture","Type":"Movie"}"#.utf8))
        let controller = NativePlaybackController(item: movie, connection: connection, client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        XCTAssertTrue(controller.isActive)
        let previousRevision = model.posterRevision
        await model.revokeCertificateTrust(connection.id)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(model.saved.connections.first?.certificatePin); XCTAssertNil(storage.value.connections.first?.certificatePin)
        XCTAssertEqual(invalidated, [connection.id]); XCTAssertNotEqual(model.posterRevision, previousRevision)
        XCTAssertNil(try model.client(for: connection).connection.certificatePin)
        XCTAssertTrue(model.items.isEmpty); XCTAssertNotNil(model.errorMessage)
    }

    func testRevokingInactiveServerTrustKeepsSelectedServersArtworkAndPage() async throws {
        let active = ServerConnection(kind: .emby, name: "Selected", baseURL: URL(string: "https://selected.test")!,
            serverID: "selected-server", userID: "viewer", username: "viewer", libraryIDs: ["movies"])
        let other = ServerConnection(kind: .emby, name: "Other", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "other-server", userID: "viewer", username: "viewer", certificatePin: try inspection().makePin())
        let storage = CertificateMemoryStorage(active)
        storage.value.connections.append(other)
        var invalidated: [UUID] = []
        let model = ApplicationModel(storage: storage, invalidatePosters: { invalidated.append($0) })
        model.libraries = [MediaLibrary(id: "movies", name: "Movies")]
        model.selectedLibraryID = "movies"
        model.page = "searchLibrary"
        let movie = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"film","Name":"Film","Type":"Movie"}"#.utf8))
        model.detail = movie
        let artwork = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { bounds in
            NSColor.systemGreen.setFill(); NSBezierPath(rect: bounds).fill(); return true
        }
        let field = try XCTUnwrap(DetailArtworkAppearance.make(from: artwork).blurredBackground)
        model.acceptWindowPalette(.init(scope: try XCTUnwrap(HomeArtworkScope(model: model)), accessRevision: model.windowArtworkRevision,
                                         itemID: movie.id, field: field))
        let revision = model.posterRevision
        await model.revokeCertificateTrust(other.id)
        XCTAssertEqual(invalidated, [other.id])
        XCTAssertNil(storage.value.connections.first { $0.id == other.id }?.certificatePin)
        XCTAssertEqual(model.posterRevision, revision)
        XCTAssertEqual(model.connection?.id, active.id)
        XCTAssertEqual(model.page, "searchLibrary")
        XCTAssertEqual(model.detail?.id, movie.id)
        XCTAssertTrue(model.windowColorField === field)
    }

    func testPosterQueuedBeforeRevocationDoesNotSendRequestWithOldTrust() async throws {
        let pin = try inspection().makePin()
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "fixture-server", userID: "fixture-user", username: "viewer", certificatePin: pin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PosterCountingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = MediaServerClient(connection: connection, token: "fixture-token", deviceID: "fixture-device", session: session)
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"poster-fixture","Name":"Poster","Type":"Movie","ImageTags":{"Primary":"tag"}}"#.utf8))
        let gate = PosterRequestGate(limit: 1)
        let cache = PosterCache(gate: gate)
        PosterCountingURLProtocol.reset()
        await gate.acquire()
        let load = Task { await cache.load(key: "queued-poster", item: item, client: client) }
        let deadline = Date().addingTimeInterval(2)
        while await gate.waitingCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let queued = await gate.waitingCount
        XCTAssertEqual(queued, 1, "The image request must actually be waiting for a permit")
        cache.remove(connectionID: connection.id)
        await gate.release()
        let image = await load.value
        XCTAssertNil(image)
        XCTAssertEqual(PosterCountingURLProtocol.requestCount, 0, "Revoked certificate trust must never be used by a queued image request")
        // The rejected request must release its permit so unrelated new images can still load.
        let permit = Task { await gate.acquire(); await gate.release() }
        await permit.value
    }

    func testRevokePersistenceFailureKeepsPreviousTrustAndCache() async throws {
        let pin = try inspection().makePin()
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://fixture.test:9443/emby")!,
            serverID: "fixture-server", userID: "fixture-user", username: "viewer", certificatePin: pin)
        let storage = CertificateMemoryStorage(connection); storage.failSave = true; var cleared = false
        let model = ApplicationModel(storage: storage, credentials: CredentialAccess(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
            invalidatePosters: { _ in cleared = true })
        await model.revokeCertificateTrust(connection.id)
        XCTAssertEqual(model.saved.connections.first?.certificatePin, pin); XCTAssertEqual(storage.value.connections.first?.certificatePin, pin)
        XCTAssertFalse(cleared); XCTAssertNotNil(model.errorMessage)
    }
}

private final class PosterCountingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
