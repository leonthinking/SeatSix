import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class ServerLoginFormStateTests: XCTestCase {
    private func result(_ attempt: ServerLoginAttempt) -> AuthenticatedServer {
        AuthenticatedServer(connection: ServerConnection(kind: attempt.kind, name: "Fixture NAS",
            baseURL: URL(string: attempt.address)!, serverID: "fixture-server", userID: "fixture-user",
            username: attempt.username, compatibilityMode: attempt.compatibilityMode), token: "fixture-token")
    }

    private func services(authenticate: @escaping (ServerLoginAttempt, CertificatePin?) async throws -> AuthenticatedServer,
                          libraries: @escaping (AuthenticatedServer, String) async throws -> [MediaLibrary] = { _, _ in [] }) -> ServerLoginServices {
        ServerLoginServices(authenticate: authenticate, inspect: { _ in
            XCTFail("Unexpected certificate inspection"); throw MediaServerError.invalidResponse
        }, libraries: libraries)
    }

    private func waitFor(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testExistingConnectionRestoresSeparateFieldsAndCompatibility() {
        let connection = ServerConnection(kind: .emby, name: "Fixture", baseURL: URL(string: "https://nas.test:9443/media/emby")!,
            serverID: "server", userID: "user", username: "viewer", compatibilityMode: true)
        let state = ServerLoginState(deviceID: "test", existing: connection)
        XCTAssertTrue(state.addressForm.useHTTPS)
        XCTAssertEqual(state.addressForm.host, "nas.test")
        XCTAssertEqual(state.addressForm.port, "9443")
        XCTAssertEqual(state.addressForm.path, "/media/emby")
        XCTAssertEqual(state.source, .compatible)
        XCTAssertEqual(state.address, connection.baseURL.absoluteString)
        XCTAssertEqual(state.username, "viewer")
        XCTAssertTrue(state.canSubmit, "An account with an empty password may log in")
    }

    func testUGREENPresetPreservesHostAndCredentialsAndUsesEmbySubset() {
        let state = ServerLoginState(deviceID: "test")
        state.address = "http://192.168.1.42:8096/custom"
        state.username = "viewer"; state.password = "password with spaces "
        state.source = .jellyfin
        state.applyUGREENPreset()
        XCTAssertEqual(state.source, .compatible)
        XCTAssertEqual(state.kind, .emby)
        XCTAssertTrue(state.compatibilityMode)
        XCTAssertEqual(state.address, "https://192.168.1.42:9443/emby")
        XCTAssertEqual(state.username, "viewer")
        XCTAssertEqual(state.password, "password with spaces ")
        XCTAssertFalse(state.allowHTTP)
        state.source = .jellyfin
        XCTAssertFalse(state.compatibilityMode)
        XCTAssertEqual(state.address, "https://192.168.1.42:9443/emby", "Changing a service must not rewrite its endpoint")
        state.source = .emby
        XCTAssertFalse(state.compatibilityMode)
    }

    func testPresetOverridesPendingTypedURLBeforeFocusLeavesHost() {
        let state = ServerLoginState(deviceID: "fixture")
        var input = ""
        for character in "http://nas.local:8096/jellyfin" {
            input.append(character)
            state.addressForm.editHost(input)
        }
        state.applyUGREENPreset()
        state.addressForm.updateHost(state.addressForm.host)
        XCTAssertEqual(state.addressForm.host, "nas.local")
        XCTAssertEqual(state.addressForm.preview, "https://nas.local:9443/emby")
        XCTAssertEqual(state.source, .compatible)
    }

    func testLoginUsesNormalizedAddressAndUsernameAndPreservesPassword() async throws {
        var submissions: [ServerLoginAttempt] = []
        let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
            submissions.append(attempt); return self.result(attempt)
        }))
        state.addressForm.host = "192.168.1.42"
        state.addressForm.port = "9443"
        state.addressForm.path = "media/emby/"
        state.username = "  viewer\n"
        state.password = " secret with spaces "
        state.source = .compatible
        XCTAssertTrue(state.canSubmit)
        state.login(); try await waitFor { state.authenticated != nil }
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.address, "https://192.168.1.42:9443/media/emby")
        XCTAssertEqual(submissions.first?.username, "viewer")
        XCTAssertEqual(submissions.first?.password, " secret with spaces ")
        XCTAssertEqual(submissions.first?.compatibilityMode, true)
        XCTAssertEqual(state.password, "", "Successful login must release the password")
        XCTAssertEqual(state.authenticated?.connection.name, "Fixture NAS", "Preserve server-provided naming")
    }

    func testEmptyPasswordIsSubmittedAndWhitespaceUsernameIsRejected() async throws {
        var submissions: [ServerLoginAttempt] = []
        let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
            submissions.append(attempt); return self.result(attempt)
        }))
        state.address = "https://nas.test"
        state.username = " \n "
        XCTAssertFalse(state.canSubmit)
        state.login()
        XCTAssertNotNil(state.error)
        XCTAssertTrue(submissions.isEmpty)
        state.username = "viewer"
        XCTAssertTrue(state.canSubmit)
        XCTAssertNil(state.error)
        state.login(); try await waitFor { state.authenticated != nil }
        XCTAssertEqual(submissions.first?.password, "")
    }

    func testInvalidAddressCannotReachAuthenticationOrInspection() async throws {
        var calls = 0
        let state = ServerLoginState(deviceID: "test", services: services(authenticate: { _, _ in
            calls += 1; throw MediaServerError.invalidResponse
        }))
        state.username = "viewer"
        XCTAssertFalse(state.canSubmit)
        for invalid in ["https://user:secret@nas.test", "https://nas.test?token=secret", "http://public.example", "https://nas.test:99999"] {
            state.address = invalid
            XCTAssertFalse(state.canSubmit, invalid)
            state.login()
            XCTAssertFalse(state.working)
            XCTAssertNotNil(state.error)
        }
        state.address = "https://nas.test"
        state.addressForm.port = "abc"
        XCTAssertFalse(state.canSubmit)
        state.login()
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(state.authenticated)
    }

    func testEachAddressFieldEditInvalidatesPendingAuthentication() async throws {
        let edits: [(inout ServerAddressForm) -> Void] = [
            { $0.host = "192.168.1.43" }, { $0.port = "9444" },
            { $0.path = "/other" }, { $0.useHTTPS = false }
        ]
        for edit in edits {
            var pending: CheckedContinuation<AuthenticatedServer, Never>?
            var submitted: ServerLoginAttempt?
            var libraryCalls = 0
            let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
                submitted = attempt
                return await withCheckedContinuation { pending = $0 }
            }, libraries: { _, _ in libraryCalls += 1; return [] }))
            state.address = "https://192.168.1.42:9443/emby"; state.username = "viewer"
            state.login(); try await waitFor { pending != nil }
            XCTAssertTrue(state.working)
            edit(&state.addressForm)
            XCTAssertFalse(state.working)
            XCTAssertNil(state.challenge)
            pending?.resume(returning: result(try XCTUnwrap(submitted)))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(state.authenticated)
            XCTAssertEqual(libraryCalls, 0, "A changed endpoint must never advance an older login")
        }
    }

    func testPathEditDuringLibraryLoadingRejectsLateResult() async throws {
        var pending: CheckedContinuation<[MediaLibrary], Never>?
        let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
            self.result(attempt)
        }, libraries: { _, _ in await withCheckedContinuation { pending = $0 } }))
        state.address = "https://nas.test:9443/emby"; state.username = "viewer"
        state.login(); try await waitFor { pending != nil }
        state.addressForm.path = "/other"
        pending?.resume(returning: [MediaLibrary(id: "old", name: "Old source")])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(state.authenticated)
        XCTAssertTrue(state.libraries.isEmpty)
        XCTAssertFalse(state.working)
    }

    func testAddressEditsAfterAuthenticationInvalidateLibrarySelection() async throws {
        let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
            self.result(attempt)
        }, libraries: { _, _ in [MediaLibrary(id: "movies", name: "Movies")] }))
        state.address = "https://nas.test:9443/emby"; state.username = "viewer"
        state.login(); try await waitFor { state.authenticated != nil }
        XCTAssertEqual(state.libraries.count, 1)
        state.addressForm.port = "8443"
        XCTAssertNil(state.authenticated)
        XCTAssertTrue(state.libraries.isEmpty)
    }

    func testCompatibilityFallbackNameUsesHostAndPreservesRealNames() async throws {
        let cases: [(address: String, source: ServerLoginSource, returnedName: String, expected: String)] = [
            ("https://nas.test:9443/emby", .compatible, "Emby", "nas.test"),
            ("https://[fd12::1]:9443/emby", .compatible, "Emby", "[fd12::1]"),
            ("https://nas.test:9443/emby", .compatible, "客厅 NAS", "客厅 NAS"),
            ("https://nas.test:9443", .emby, "Emby", "Emby"),
            ("https://nas.test:9443", .emby, "家庭影院", "家庭影院"),
            ("https://nas.test:9443", .jellyfin, "Jellyfin", "Jellyfin")
        ]
        for item in cases {
            let state = ServerLoginState(deviceID: "test", services: services(authenticate: { attempt, _ in
                var authenticated = self.result(attempt)
                authenticated.connection.name = item.returnedName
                return authenticated
            }))
            state.address = item.address; state.username = "viewer"; state.source = item.source
            state.login(); try await waitFor { state.authenticated != nil }
            XCTAssertEqual(state.authenticated?.connection.name, item.expected)
        }
    }

    func testEachConnectionComponentEditInvalidatesCertificateChallenge() async throws {
        let inspection = try certificateInspection()
        XCTAssertTrue(inspection.canApprove)
        let edits: [(inout ServerAddressForm) -> Void] = [
            { $0.port = "9444" }, { $0.path = "/other" }, { $0.useHTTPS = false }
        ]
        for edit in edits {
            var authenticationCalls = 0
            let state = ServerLoginState(deviceID: "test", services: ServerLoginServices(authenticate: { _, _ in
                authenticationCalls += 1
                throw MediaServerError.certificate(.untrusted)
            }, inspect: { _ in inspection }, libraries: { _, _ in
                XCTFail("A rejected challenge must not load libraries"); return []
            }))
            state.address = "https://192.168.1.42:9443/emby"; state.username = "viewer"
            state.login(); try await waitFor { state.challenge != nil }
            let oldID = try XCTUnwrap(state.challenge).id
            edit(&state.addressForm)
            XCTAssertNil(state.challenge)
            state.approve(oldID)
            await Task.yield()
            XCTAssertEqual(authenticationCalls, 1, "Changed components must reject approval of the old endpoint")
            XCTAssertNil(state.authenticated)
            XCTAssertFalse(state.working)
        }
    }

    private func certificateInspection() throws -> CertificateInspection {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seatsix-login-form-cert-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
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
        subjectAltName=IP:192.168.1.42
        """
        try config.write(to: folder.appendingPathComponent("cert.cnf"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-config", folder.appendingPathComponent("cert.cnf").path,
            "-keyout", folder.appendingPathComponent("key.pem").path, "-outform", "DER", "-out", folder.appendingPathComponent("cert.der").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "CertificateFixture", code: Int(process.terminationStatus)) }
        let certificate = try Data(contentsOf: folder.appendingPathComponent("cert.der"))
        return try CertificateInspector.inspect(certificateDER: certificate, url: URL(string: "https://192.168.1.42:9443/emby")!)
    }
}
