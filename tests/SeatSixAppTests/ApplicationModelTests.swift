import AppKit
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class MemoryApplicationStorage: ApplicationPersisting {
    var value: SavedApplication
    var failSaving = false
    init(_ value: SavedApplication = SavedApplication()) { self.value = value }
    func load() throws -> SavedApplication { value }
    func save(_ data: SavedApplication) throws {
        if failSaving { throw ApplicationPersistenceError.saveFailed }
        value = data
    }
}

private final class TestCredentialVault {
    var tokens: [UUID: String] = [:]
    var readCounts: [UUID: Int] = [:]
    var readErrors: [UUID: CredentialStoreError] = [:]
    var saveAttempts: [(UUID, String)] = []
    var removeAttempts: [UUID] = []
    var failingSaveCalls: Set<Int> = []
    var failingRemoveCalls: Set<Int> = []
    var access: CredentialAccess {
        CredentialAccess(read: { [self] id in
            readCounts[id, default: 0] += 1
            if let error = readErrors[id] { throw error }
            guard let token = tokens[id] else { throw CredentialStoreError.notFound }
            return token
        }, save: { [self] token, id in
            saveAttempts.append((id, token))
            if failingSaveCalls.contains(saveAttempts.count) { throw CredentialStoreError.saveFailed }
            tokens[id] = token
        }, remove: { [self] id in
            removeAttempts.append(id)
            if failingRemoveCalls.contains(removeAttempts.count) { throw CredentialStoreError.saveFailed }
            tokens.removeValue(forKey: id)
        })
    }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var body: [String: Any]
        var delay: TimeInterval = 0
    }
    static var handler: ((URLRequest) -> Response)?
    private let lock = NSLock()
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = Self.handler?(request) else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay) { [self] in
            lock.lock(); let isCancelled = cancelled; lock.unlock()
            guard !isCancelled else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.body))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    @discardableResult
    func append(_ value: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        return values.count
    }
    var offsets: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class ApplicationModelTests: XCTestCase {
    private func connection() -> ServerConnection {
        ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://server.test/emby")!, serverID: "server", userID: "user", username: "name", libraryIDs: ["library"])
    }
    private func configured(_ connection: ServerConnection) -> SavedApplication {
        var saved = SavedApplication(); saved.connections = [connection]; saved.selectedID = connection.id; return saved
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func item(_ id: String = "movie", ticks: Int64 = 0) -> [String: Any] {
        ["Id": id, "Name": id, "Type": "Movie", "UserData": ["PlaybackPositionTicks": ticks]]
    }
    private func decodedItem(_ id: String = "movie", ticks: Int64 = 0) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: item(id, ticks: ticks)))
    }
    private func landscapeItem(_ id: String) -> [String: Any] {
        var value = item(id)
        value["BackdropImageTags"] = ["wide-\(id)"]
        return value
    }
    private func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), description)
    }
    private func makeModel(storage: MemoryApplicationStorage, vault: TestCredentialVault, session: URLSession, focus: (() -> Void)? = nil,
                           launch: ((MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void)? = nil) -> ApplicationModel {
        ApplicationModel(storage: storage, credentials: vault.access, clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) }, focusPlayback: focus, playbackLauncher: launch)
    }

    func testPendingPlaybackKeepsDefaultsFromItsNewSession() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session()
        storage.value.applicationPreferences.autoPlayNextEpisode = false
        storage.value.applicationPreferences.subtitleMode = .off
        storage.value.recovery = [.init(serverID: connection.serverID, userID: connection.userID, itemID: "movie", ticks: 90_000_000, updatedAt: Date(), confirmed: false)]
        let movie = item()
        ModelURLProtocol.handler = { _ in .init(body: movie, delay: 0.05) }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.requestPlayback(try decodedItem())
        var updated = model.applicationPreferences
        updated.autoPlayNextEpisode = true; updated.subtitleMode = .mediaDefault
        XCTAssertTrue(model.updateApplicationPreferences(updated))
        try await waitUntil("Recovery prompt should keep launch-time defaults") { model.recoveryPrompt != nil }
        let prompt = try XCTUnwrap(model.recoveryPrompt)
        XCTAssertFalse(prompt.autoPlayNext)
        XCTAssertFalse(prompt.playbackDefaults.autoPlayNextEpisode)
        XCTAssertEqual(prompt.playbackDefaults.subtitleMode, .off)
        XCTAssertEqual(model.applicationPreferences.subtitleMode, .mediaDefault)
    }

    func testColdLaunchOwnsPlaceholdersBeforeAppearanceAndEndsDiscoveryBeforeCatalog() async throws {
        var server = connection()
        server.compatibilityMode = true
        let vault = TestCredentialVault(), transport = session()
        vault.tokens[server.id] = "fixture"
        let storage = MemoryApplicationStorage(configured(server))
        storage.value.applicationPreferences.startupPage = .lastBrowsed
        storage.value.browsingLocations = [.init(connection: server, page: "favorites", libraryID: "library")]
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]])
            }
            return .init(body: ["Items": [], "TotalRecordCount": 0],
                         delay: request.url!.path.hasSuffix("/Resume") ? 0 : 0.25)
        }
        defer { transport.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let model = makeModel(storage: storage, vault: vault, session: transport)
        XCTAssertEqual(model.page, "favorites", "Restore the saved route's first-frame layout")
        XCTAssertEqual(model.selectedLibraryID, "", "Selection still requires a live access check")
        XCTAssertTrue(model.serverBrowseContentPending)
        XCTAssertTrue(model.libraryListPending && model.catalogContentPending && model.continuingContentPending)
        XCTAssertFalse(model.homeContentReady)
        model.refresh()
        XCTAssertTrue(model.libraryListPending)
        try await waitUntil("Views and the independent resume request resolve first") {
            !model.libraryListPending && !model.continuingLoading && model.catalogLoading
        }
        XCTAssertTrue(model.continuingContentPending, "Compatibility servers derive resume cards from the delayed catalog")
        XCTAssertEqual(model.selectedLibraryID, "library")
        try await waitUntil("Empty results release all slots") { model.homeContentReady && !model.serverBrowseContentPending }
        XCTAssertFalse(model.catalogContentPending || model.continuingContentPending || model.libraryListPending)
        XCTAssertFalse(model.canNavigateBack)
        await model.shutdown()
    }

    func testWelcomeAndFailedDiscoveryReleaseColdLoadingSlots() async throws {
        let vault = TestCredentialVault(), transport = session()
        defer { transport.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let welcome = makeModel(storage: MemoryApplicationStorage(), vault: vault, session: transport)
        XCTAssertFalse(welcome.libraryListPending || welcome.catalogContentPending || welcome.continuingContentPending)
        let server = connection(), storage = MemoryApplicationStorage(configured(server))
        let model = makeModel(storage: storage, vault: vault, session: transport)
        XCTAssertTrue(model.libraryListPending)
        model.refresh()
        try await waitUntil("An unreadable credential must end loading") { model.errorMessage != nil && model.homeContentReady }
        XCTAssertFalse(model.libraryListPending || model.catalogContentPending || model.continuingContentPending)
        await model.shutdown()
    }

    func testStartupRestoresOnlyScopedPageAndLibraryAndFallsBackForMissingLibrary() async throws {
        var server = connection(); server.libraryIDs = ["library", "second"]
        let vault = TestCredentialVault(); vault.tokens[server.id] = "test-token"
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"], ["Id": "second", "Name": "Series"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        for (setting, page, library, otherUser, expectedPage, expectedLibrary) in [
            (StartupPage.lastBrowsed, "library", "second", false, "library", "second"),
            (.home, "library", "second", false, "home", "library"),
            (.lastBrowsed, "library", "missing", false, "home", "library"),
            (.lastBrowsed, "servers", "second", false, "home", "library"),
            (.lastBrowsed, "library", "second", true, "home", "library")
        ] {
            let storage = MemoryApplicationStorage(configured(server)), session = session()
            storage.value.applicationPreferences.startupPage = setting
            var scope = server; if otherUser { scope.userID = "different-user" }
            storage.value.browsingLocations = [.init(connection: scope, page: page, libraryID: library)]
            let model = makeModel(storage: storage, vault: vault, session: session)
            model.refresh()
            try await waitUntil("Initial navigation should settle") { model.homeContentReady }
            XCTAssertEqual(model.page, expectedPage); XCTAssertEqual(model.selectedLibraryID, expectedLibrary)
            XCTAssertFalse(model.canNavigateBack, "Resolving the initial page and library is not a user visit")
            XCTAssertFalse(model.canNavigateForward)
            XCTAssertNil(model.detail); XCTAssertNil(model.player); XCTAssertFalse(model.hasActiveFilters)
            await model.shutdown()
        }
    }

    func testNavigationIsPersistedWithoutDetailAndExplicitNavigationWinsPendingRestore() async throws {
        let server = connection(), storage = MemoryApplicationStorage(configured(connection())), vault = TestCredentialVault()
        storage.value = configured(server); vault.tokens[server.id] = "test-token"
        storage.value.applicationPreferences.startupPage = .lastBrowsed
        storage.value.browsingLocations = [.init(connection: server, page: "library", libraryID: "library")]
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]], delay: 0.05) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        let model = makeModel(storage: storage, vault: vault, session: session())
        model.refresh(); model.page = "servers"
        try await waitUntil("Navigation should settle") { model.homeContentReady }
        XCTAssertEqual(model.page, "servers", "A late initial response must not redirect explicit navigation")
        model.page = "library"; model.detail = try decodedItem(); model.query = "search"
        XCTAssertEqual(storage.value.browsingLocations.first?.page, "library")
        let reopened = makeModel(storage: storage, vault: vault, session: session())
        reopened.refresh()
        try await waitUntil("Reload should restore the library only") { reopened.homeContentReady }
        XCTAssertEqual(reopened.page, "library"); XCTAssertNil(reopened.detail); XCTAssertEqual(reopened.query, "")
        await model.shutdown(); await reopened.shutdown()
    }

    func testResumeRewindUsesFinalChoiceOnceAndDoesNotRewriteOriginalRecovery() async throws {
        let server = connection(), vault = TestCredentialVault(); vault.tokens[server.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(server))
        storage.value.applicationPreferences.resumeRewindSeconds = 10
        storage.value.recovery = [.init(serverID: server.serverID, userID: server.userID, itemID: "movie", ticks: 900_000_000, updatedAt: Date(), confirmed: false)]
        let movie = item(ticks: 500_000_000)
        ModelURLProtocol.handler = { _ in .init(body: movie) }
        var launches: [Int64] = []
        let model = makeModel(storage: storage, vault: vault, session: session(), launch: { _, _, _, _, ticks in launches.append(ticks) })
        model.requestPlayback(try decodedItem())
        try await waitUntil("Choice should be shown before rewind") { model.recoveryPrompt != nil }
        XCTAssertEqual(model.recoveryPrompt?.localTicks, 900_000_000)
        var updated = model.applicationPreferences; updated.resumeRewindSeconds = 5
        XCTAssertTrue(model.updateApplicationPreferences(updated))
        model.chooseRecovery(local: true)
        try await waitUntil("Local choice should rewind the captured ten seconds") { launches.count == 1 }
        XCTAssertEqual(launches, [800_000_000])
        XCTAssertEqual(storage.value.recovery.first?.ticks, 900_000_000)
        model.requestPlayback(try decodedItem())
        try await waitUntil("New session should offer unchanged raw progress") { model.recoveryPrompt != nil }
        model.chooseRecovery(local: false)
        try await waitUntil("Server choice should use the new five-second default") { launches.count == 2 }
        XCTAssertEqual(launches, [800_000_000, 450_000_000])
        model.requestPlayback(try decodedItem(), fromBeginning: true)
        try await waitUntil("From beginning should start at zero") { launches.count == 3 }
        XCTAssertEqual(launches.last, 0); XCTAssertNil(model.recoveryPrompt)
    }

    func testSelectingAlreadyVisibleHomeCancelsPendingStartupRestoration() async throws {
        let server = connection(), vault = TestCredentialVault(); vault.tokens[server.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(server))
        storage.value.applicationPreferences.startupPage = .lastBrowsed
        storage.value.browsingLocations = [.init(connection: server, page: "library", libraryID: "library")]
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]], delay: 0.05) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        let model = makeModel(storage: storage, vault: vault, session: session())
        model.refresh(); model.page = "home"
        try await waitUntil("The explicit Home selection should win") { model.homeContentReady }
        XCTAssertEqual(model.page, "home")
        XCTAssertEqual(storage.value.browsingLocations.first?.page, "home")
        await model.shutdown()
    }

    func testHomeResumeUsesDiscoveredLibrariesAndRemovesOnlyRevokedCards() async throws {
        var server = connection()
        server.libraryIDs = ["a", "b"]
        let vault = TestCredentialVault()
        vault.tokens[server.id] = "fixture"
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
        let views = RequestLog(), fetched = RequestLog()
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                views.append(0)
                let call = views.offsets.count
                let ids = call == 1 ? ["a", "b"] : (call <= 3 ? ["a"] : [])
                return .init(body: ["Items": ids.map { ["Id": $0, "Name": $0] }])
            }
            if request.url!.path.hasSuffix("/Resume") {
                let library = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "ParentId" }?.value ?? ""
                fetched.append(library == "a" ? 1 : 2)
                if views.offsets.count >= 2 && library != "a" { return .init(status: 403, body: [:]) }
                return .init(body: ["Items": [library, "shared"].map { ["Id": $0, "Name": $0, "Type": "Movie"] }])
            }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        model.refresh()
        try await waitUntil("Home has read both original libraries") { model.homeContentReady }
        XCTAssertEqual(model.continuing.map(\.id), ["a", "shared", "b"])
        model.navigate(to: "recent")
        try await waitUntil("The aggregate view has seen the first revocation") { model.serverBrowseComplete }
        XCTAssertEqual(model.continuing.map(\.id), ["a", "shared"])
        model.navigate(to: "home")
        model.refresh()
        try await waitUntil("Refresh of the narrower home scope has ended") { model.homeContentReady }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.continuing.map(\.id), ["a", "shared"])
        XCTAssertEqual(fetched.offsets, [1, 2, 1], "The revoked library must not receive another Resume request")
        model.navigate(to: "recent")
        try await waitUntil("The aggregate has discovered that no libraries remain") { model.serverBrowseComplete }
        XCTAssertTrue(model.continuing.isEmpty)
        model.navigate(to: "home")
        model.refresh()
        try await waitUntil("The final empty home has settled") { model.homeContentReady }
        XCTAssertTrue(model.continuing.isEmpty)
        XCTAssertEqual(fetched.offsets, [1, 2, 1])
        await model.shutdown()
    }

    func testEarlierHomeViewsOrResumeResponsesCannotRestoreNewlyRevokedLibraries() async throws {
        for delayViews in [false, true] {
            var server = connection()
            server.libraryIDs = ["a", "b"]
            let vault = TestCredentialVault()
            vault.tokens[server.id] = "fixture"
            let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
            let views = RequestLog(), fetched = RequestLog()
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") {
                    views.append(0)
                    let first = views.offsets.count == 1
                    let ids = first ? ["a", "b"] : []
                    return .init(body: ["Items": ids.map { ["Id": $0, "Name": $0] }], delay: first && delayViews ? 0.3 : 0)
                }
                if request.url!.path.hasSuffix("/Resume") {
                    fetched.append(1)
                    return .init(body: ["Items": [["Id": "old", "Name": "old", "Type": "Movie"]]], delay: 0.3)
                }
                return .init(body: ["Items": [], "TotalRecordCount": 0])
            }
            model.refresh()
            try await waitUntil("An older Home request is in flight") {
                delayViews ? !views.offsets.isEmpty : !fetched.offsets.isEmpty
            }
            model.navigate(to: "recent")
            try await waitUntil("The newer page has confirmed empty access") { model.serverBrowseComplete }
            try await waitUntil("The older Home response has arrived") { model.homeContentReady }
            XCTAssertTrue(model.continuing.isEmpty)
            XCTAssertEqual(fetched.offsets.count, delayViews ? 0 : 1)
            await model.shutdown()
        }
    }

    func testCompatibilityHomeDropsCatalogDerivedResumeWhenItsLibraryIsRevoked() async throws {
        var server = connection()
        server.compatibilityMode = true
        let vault = TestCredentialVault()
        vault.tokens[server.id] = "fixture"
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
        let views = RequestLog()
        let movie = item("playing", ticks: 30_000)
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                views.append(1)
                let rows = views.offsets.count == 1 ? [["Id": "library", "Name": "Movies"]] : []
                return .init(body: ["Items": rows])
            }
            if request.url!.path.hasSuffix("/Resume") { XCTFail("Compatibility mode must not request Resume") }
            return .init(body: ["Items": [movie], "TotalRecordCount": 1])
        }
        model.refresh()
        try await waitUntil("The compatibility catalog has loaded") { model.homeContentReady }
        XCTAssertEqual(model.displayedContinuing.map(\.id), ["playing"])
        model.navigate(to: "recent")
        try await waitUntil("A newer Views response has revoked the selected library") { model.serverBrowseComplete }
        model.navigate(to: "home")
        XCTAssertTrue(model.displayedContinuing.isEmpty)
        await model.shutdown()
    }

    func testRevokedCatalogCannotRepopulateHeroOrRecentAndRecoversRemainingLibrary() async throws {
        var server = connection()
        server.libraryIDs = ["a", "b"]
        let vault = TestCredentialVault()
        vault.tokens[server.id] = "fixture"
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
        let views = RequestLog(), oldCatalog = RequestLog()
        let first = landscapeItem("from-a"), second = landscapeItem("from-b")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                views.append(0)
                let ids: [String]
                switch views.offsets.count {
                case 1, 2: ids = ["a", "b"]
                case 3: ids = ["b"]
                case 4: ids = []
                default: ids = ["a"]
                }
                return .init(body: ["Items": ids.map { ["Id": $0, "Name": $0] }])
            }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let library = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ParentId" }?.value
            let late = library == "a" && views.offsets.count == 2
            if late { oldCatalog.append(1) }
            return .init(body: ["Items": [library == "a" ? first : second], "TotalRecordCount": 1], delay: late ? 0.25 : 0)
        }
        model.refresh()
        try await waitUntil("The initial home catalog is loaded") { model.homeContentReady }
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["from-a"])
        model.refresh(preservingHomeRecommendations: true)
        try await waitUntil("A second Home catalog is in flight") { !oldCatalog.offsets.isEmpty }
        model.searchTerm = "电影"
        model.navigate(to: "searchServer")
        try await waitUntil("The remaining library replaces the revoked catalog") {
            model.homeContentReady && model.serverBrowseComplete && model.selectedLibraryID == "b"
        }
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertEqual(model.items.map(\.id), ["from-b"])
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["from-b"])
        XCTAssertEqual(model.searchTerm, "电影")
        model.refreshServerBrowse()
        try await waitUntil("All catalog content has been withdrawn") { model.serverBrowseComplete && model.homeContentReady }
        XCTAssertTrue(model.libraries.isEmpty && model.items.isEmpty && model.homeRecommendations.isEmpty)
        model.refreshServerBrowse()
        try await waitUntil("A newly accessible library can be browsed again") {
            model.serverBrowseComplete && model.homeContentReady && model.selectedLibraryID == "a"
        }
        XCTAssertEqual(model.items.map(\.id), ["from-a"])
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["from-a"])
        await model.shutdown()
    }

    func testNewerHomeAccessReplacesBothCompletedAndInFlightAggregateScopes() async throws {
        for slowRevokedPage in [false, true] {
            var server = connection()
            server.libraryIDs = ["a", "b"]
            let vault = TestCredentialVault()
            vault.tokens[server.id] = "fixture"
            let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
            let views = RequestLog(), catalogs = RequestLog()
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") {
                    let number = views.append(1)
                    let ids = number == 1 ? ["a"] : ["a", "b"]
                    return .init(body: ["Items": ids.map { ["Id": $0, "Name": $0] }], delay: number == 1 ? 0.3 : 0)
                }
                if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
                let library = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "ParentId" }?.value ?? ""
                catalogs.append(library == "b" ? 2 : 1)
                return .init(body: ["Items": [["Id": library, "Name": library, "Type": "Movie"]], "TotalRecordCount": 1],
                             delay: library == "b" && slowRevokedPage ? 0.45 : 0)
            }
            model.refresh()
            try await waitUntil("Home's independent Views response is pending") { views.offsets == [1] }
            model.navigate(to: "movies")
            try await waitUntil("The original aggregate is actually bound to both libraries") {
                model.serverBrowseLibraryIDs == ["a", "b"] && catalogs.offsets.contains(2)
                    && (slowRevokedPage ? model.serverBrowseLoading : model.serverBrowseComplete)
            }
            if !slowRevokedPage { XCTAssertEqual(model.serverBrowseCatalogItems.map(\.id), ["a", "b"]) }
            try await waitUntil("A fresh aggregate completes using just the newer Home scope") {
                model.serverBrowseLibraryIDs == ["a"] && model.serverBrowseComplete && model.homeContentReady
            }
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(model.page, "movies")
            XCTAssertEqual(model.serverBrowseCatalogItems.map(\.id), ["a"])
            XCTAssertNil(model.serverBrowseError)
            XCTAssertEqual(views.offsets.count, 2, "Rebuilding the feed must use the already-confirmed Views response")
            XCTAssertEqual(catalogs.offsets.filter { $0 == 2 }.count, 1, "The superseded scope cannot request the revoked library again")
            await model.shutdown()
        }
    }

    func testResumeFailureDoesNotBlockLibraryBrowsing() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session()
        let movie = item()
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(status: 404, body: [:]) }
            return .init(body: ["Items": [movie], "TotalRecordCount": 1])
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Resume failure should be visible") { model.errorMessage?.contains("继续观看") == true }
        XCTAssertEqual(model.items.map(\.id), ["movie"])
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.continuing.isEmpty)
        XCTAssertTrue(model.continuingContentFailed, "The empty rail cannot claim that this account has no progress")
    }

    func testHomeResumeDistinguishesTransientFailureDeniedViewsAndConfirmedEmpty() async throws {
        let server = connection(), vault = TestCredentialVault()
        vault.tokens[server.id] = "test-token"
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
        let watched = item("partly-watched", ticks: 12_000_000)
        func refresh(viewsStatus: Int = 200, resumeStatus: Int = 200, watchedRows: [[String: Any]] = []) async throws {
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") {
                    return .init(status: viewsStatus, body: ["Items": [["Id": "library", "Name": "Movies"]]])
                }
                if request.url!.path.hasSuffix("/Resume") { return .init(status: resumeStatus, body: ["Items": watchedRows]) }
                return .init(body: ["Items": [], "TotalRecordCount": 0])
            }
            model.refresh()
            try await waitUntil("Both independently timed requests settled") { model.homeContentReady }
        }
        try await refresh(viewsStatus: 500)
        XCTAssertTrue(model.continuingContentFailed, "Discovery failed before Resume could run")
        try await refresh(watchedRows: [watched])
        XCTAssertEqual(model.displayedContinuing.map(\.id), ["partly-watched"])
        try await refresh(resumeStatus: 503)
        XCTAssertTrue(model.continuingContentFailed)
        XCTAssertEqual(model.displayedContinuing.map(\.id), ["partly-watched"], "Transient failure keeps authorized rows readable")
        try await refresh(resumeStatus: 403)
        XCTAssertTrue(model.continuingContentFailed)
        XCTAssertTrue(model.displayedContinuing.isEmpty, "Denied progress must immediately leave the rail")
        try await refresh()
        XCTAssertFalse(model.continuingContentFailed)
        XCTAssertTrue(model.displayedContinuing.isEmpty, "An authoritative empty response may show the onboarding text")
        await model.shutdown()
    }

    func testCompatibilityHomeResumeReflectsCatalogOutcome() async throws {
        var server = connection()
        server.compatibilityMode = true
        let vault = TestCredentialVault()
        vault.tokens[server.id] = "test-token"
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session())
        for catalogStatus in [500, 200] {
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") {
                    return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]])
                }
                return .init(status: catalogStatus, body: ["Items": [], "TotalRecordCount": 0])
            }
            model.refresh()
            try await waitUntil("Compatibility catalog settled") { model.homeContentReady }
            XCTAssertEqual(model.continuingContentFailed, catalogStatus != 200)
            XCTAssertTrue(model.displayedContinuing.isEmpty)
        }
        await model.shutdown()
    }

    func testCompleteCatalogSearchFindsLaterPageWithoutLoadMore() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), log = RequestLog()
        let first = item("first"), later = item("later")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertNil(fields.first { $0.name == "SearchTerm" })
            let offset = Int(fields.first { $0.name == "StartIndex" }!.value!)!
            log.append(offset)
            return .init(body: ["Items": [offset == 0 ? first : later], "TotalRecordCount": 2], delay: offset == 0 ? 0 : 0.15)
        }
        let model = makeModel(storage: storage, vault: vault, session: session); model.selectedLibraryID = "library"
        model.refresh(); model.query = " later "
        try await waitUntil("First page should be visible as partial") { model.items.count == 1 }
        XCTAssertFalse(model.catalogComplete); XCTAssertTrue(model.catalogLoading)
        XCTAssertTrue(model.displayedItems.isEmpty)
        try await waitUntil("Full catalog should load automatically") { model.catalogComplete && !model.loading }
        XCTAssertEqual(log.offsets, [0, 1]); XCTAssertEqual(model.displayedItems.map(\.id), ["later"])
        XCTAssertEqual(model.total, 2)
        model.query = "first"; model.searchChanged()
        XCTAssertEqual(model.displayedItems.map(\.id), ["first"])
        XCTAssertEqual(log.offsets, [0, 1], "Typing must not depend on ignored server SearchTerm")
    }

    func testRepeatedPageLeavesExplicitIncompleteCatalog() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), log = RequestLog(), movies = [item("a")]
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!)!
            log.append(offset); return .init(body: ["Items": movies, "TotalRecordCount": 100])
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Repeated page must fail with partial results") { model.catalogFailed && !model.loading }
        XCTAssertEqual(log.offsets, [0, 1]); XCTAssertFalse(model.catalogComplete)
        XCTAssertEqual(model.items.map(\.id), ["a"]); XCTAssertEqual(model.total, 100)
        XCTAssertTrue(model.catalogStatus.contains("不完整")); XCTAssertNotNil(model.errorMessage)
    }

    func testHomeRecommendationsWaitForCompleteCatalogAndStayStableDuringBrowsing() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session()
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let first = landscapeItem("first"), later = landscapeItem("later"), noArt = item("no-art")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            if request.url!.path.hasSuffix("/Items/later") { return .init(body: later) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!
            return .init(body: ["Items": offset == "0" ? [first, noArt] : [later], "TotalRecordCount": 3], delay: offset == "0" ? 0 : 0.15)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("The partial catalog must be observable") { model.items.count == 2 }
        XCTAssertTrue(model.homeRecommendations.isEmpty, "A partial page must not become the recommendation pool")
        model.query = "no-art"
        try await waitUntil("The complete catalog should produce recommendations") { model.catalogComplete && !model.catalogLoading }
        let selected = model.homeRecommendations.map(\.id)
        XCTAssertEqual(Set(selected), ["first", "later"], "Search must not filter the recommendation pool; later-page artwork must participate")
        XCTAssertEqual(model.displayedItems.map(\.id), ["no-art"])
        model.query = "first"; model.filterYear = 2000; model.sortOrder = .nameDescending; model.page = "library"
        XCTAssertEqual(model.homeRecommendations.map(\.id), selected)
        model.page = "home"
        model.showDetail(try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: later)))
        try await waitUntil("Detail should load") { !model.detailLoading }
        model.goBackFromDetail()
        XCTAssertEqual(model.page, "home")
        XCTAssertEqual(model.homeRecommendations.map(\.id), selected, "Opening and returning from detail must preserve recommendation order")
        model.refresh()
        XCTAssertTrue(model.homeRecommendations.isEmpty, "Refresh must synchronously invalidate the previous pool")
        try await waitUntil("Refreshed recommendations should finish") { model.catalogComplete && !model.catalogLoading }
        XCTAssertEqual(Set(model.homeRecommendations.map(\.id)), ["first", "later"])
    }

    func testFailedPartialCatalogDoesNotProduceHomeRecommendations() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), first = landscapeItem("first")
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!
            return offset == "0" ? .init(body: ["Items": [first], "TotalRecordCount": 2]) : .init(status: 503, body: [:])
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("A failed next page should end the load") { model.catalogFailed && !model.catalogLoading }
        XCTAssertEqual(model.items.map(\.id), ["first"])
        XCTAssertTrue(model.homeRecommendations.isEmpty)
    }

    func testPlaybackRefreshKeepsRecommendationsMountedAndUpdatesTheirMetadata() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), reads = RequestLog()
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let first = landscapeItem("first"), later = landscapeItem("later")
        var updated = first; updated["Name"] = "Updated after playback"
        updated["UserData"] = ["PlaybackPositionTicks": 123_000_000]
        let refreshed = updated
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                reads.append(1)
                return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]])
            }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!
            if reads.offsets.count == 1 { return .init(body: ["Items": [first, later], "TotalRecordCount": 2]) }
            return .init(body: ["Items": [offset == "0" ? refreshed : later], "TotalRecordCount": 2], delay: offset == "0" ? 0.02 : 0.2)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Initial recommendations should load") { model.catalogComplete && !model.catalogLoading }
        let originalOrder = model.homeRecommendations.map(\.id)
        XCTAssertEqual(Set(originalOrder), ["first", "later"])
        model.refresh(preservingHomeRecommendations: true)
        XCTAssertEqual(model.homeRecommendations.map(\.id), originalOrder, "Closing playback must not unmount the banner while refreshing progress")
        try await waitUntil("Refresh should expose a partial first page") { model.items.count == 1 }
        XCTAssertFalse(model.catalogComplete)
        XCTAssertEqual(model.homeRecommendations.map(\.id), originalOrder)
        try await waitUntil("Updated recommendations should finish") { model.catalogComplete && !model.catalogLoading }
        XCTAssertEqual(model.homeRecommendations.map(\.id), originalOrder)
        let newFirst = try XCTUnwrap(model.homeRecommendations.first { $0.id == "first" })
        XCTAssertEqual(newFirst.name, "Updated after playback")
        XCTAssertEqual(newFirst.userData.playbackPositionTicks, 123_000_000)
        model.refresh()
        XCTAssertTrue(model.homeRecommendations.isEmpty, "An explicit refresh still requests a new selection")
        try await waitUntil("Explicit refresh should finish") { model.catalogComplete && !model.catalogLoading }
    }

    func testToolbarRefreshKeepsArtworkAndWaitsForContinuingAfterCatalogIncludingFailure() async throws {
        let server = connection(), vault = TestCredentialVault(), session = session()
        vault.tokens[server.id] = "test-token"
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let movie = landscapeItem("movie"), resumes = RequestLog()
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") {
                resumes.append(1)
                return resumes.offsets.count == 1 ? .init(body: ["Items": []]) : .init(status: 503, body: [:], delay: 0.25)
            }
            return .init(body: ["Items": [movie], "TotalRecordCount": 1])
        }
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
        model.refresh()
        XCTAssertFalse(model.isToolbarRefreshing)
        try await waitUntil("Background startup loads artwork") { model.homeContentReady }
        model.refreshFromToolbar()
        XCTAssertTrue(model.isToolbarRefreshing)
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["movie"])
        try await waitUntil("The catalog finishes before continuing items") { model.catalogComplete && model.continuingLoading }
        XCTAssertTrue(model.isToolbarRefreshing)
        model.refreshFromToolbar()
        try await waitUntil("A newer request owns the indicator while previous jobs finish") {
            resumes.offsets.count == 3 && model.catalogComplete && model.continuingLoading
        }
        XCTAssertTrue(model.isToolbarRefreshing)
        try await waitUntil("Completing the failed resume request releases the indicator") { !model.isToolbarRefreshing }
        XCTAssertFalse(model.continuingLoading)
        XCTAssertNotNil(model.errorMessage)
        await model.shutdown()
    }

    func testImmediateServerResponseStillPresentsTheManualRefreshSkeleton() async throws {
        let server = connection(), vault = TestCredentialVault(), session = session()
        vault.tokens[server.id] = "test-token"
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
        let clicked = ContinuousClock.now
        model.refreshFromToolbar()
        XCTAssertTrue(model.isToolbarRefreshing)
        try await waitUntil("Fast manual refresh returns to the loaded page") {
            model.homeContentReady && !model.isToolbarRefreshing
        }
        XCTAssertGreaterThanOrEqual(clicked.duration(to: .now), .milliseconds(240))
        await model.shutdown()
    }

    func testToolbarRefreshAdoptsFirstResolvedLibraryAndEndsOnlyForExplicitLibraryChange() async throws {
        var server = connection(); server.libraryIDs.append("other")
        let vault = TestCredentialVault(), session = session()
        vault.tokens[server.id] = "test-token"
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                return .init(body: ["Items": [["Id": "library", "Name": "Movies"], ["Id": "other", "Name": "TV"]]], delay: 0.05)
            }
            return .init(body: ["Items": [], "TotalRecordCount": 0],
                         delay: request.url!.path.hasSuffix("/Resume") ? 0.25 : 0)
        }
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
        model.refreshFromToolbar()
        XCTAssertTrue(model.selectedLibraryID.isEmpty)
        try await waitUntil("Views resolved while the original resume request is pending") {
            model.selectedLibraryID == "library" && model.catalogComplete && model.continuingLoading
        }
        XCTAssertTrue(model.isToolbarRefreshing)
        try await waitUntil("Original session finishes after its children") { !model.isToolbarRefreshing }
        XCTAssertTrue(model.homeContentReady)
        model.refreshFromToolbar()
        model.changeLibrary("other")
        XCTAssertFalse(model.isToolbarRefreshing)
        XCTAssertEqual(model.selectedLibraryID, "other")
        try await waitUntil("The replacement library still completes its independent work") { model.homeContentReady }
        await model.shutdown()
    }

    func testLibraryDenialRetainsOnlyArtworkFromStillAuthorizedLibraries() async throws {
        for (aggregate, status) in [(false, 403), (true, 403), (true, 401)] {
            var server = connection(); server.libraryIDs.append("other")
            let vault = TestCredentialVault(), session = session()
            vault.tokens[server.id] = "test-token"
            defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
            let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
            let movie = item()
            func serve(_ ids: [String], denying library: String? = nil, statusCode: Int = 403) {
                ModelURLProtocol.handler = { request in
                    let url = request.url!
                    if url.path.hasSuffix("/Views") {
                        return .init(body: ["Items": ids.map { ["Id": $0, "Name": $0] }])
                    }
                    if url.path.hasSuffix("/Items/movie") { return .init(body: movie) }
                    if url.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
                    let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                    if let library, parameters?.contains(URLQueryItem(name: "ParentId", value: library)) == true {
                        return .init(status: statusCode, body: [:])
                    }
                    return .init(body: ["Items": [movie], "TotalRecordCount": 1])
                }
            }

            serve(["library"])
            if aggregate {
                model.navigate(to: "movies")
                try await waitUntil("Aggregate confirmed the original library") { model.serverBrowseComplete }
                XCTAssertTrue(model.libraries.isEmpty, "The home catalog has not been opened")
            } else {
                model.refresh()
                try await waitUntil("Home confirmed the original library") { model.homeContentReady }
            }
            let film = try XCTUnwrap((aggregate ? model.serverBrowseCatalogItems : model.items).first)
            model.showDetail(film)
            try await waitUntil("Opened film is ready") { model.detail?.id == film.id && !model.detailLoading }
            let scope = try XCTUnwrap(HomeArtworkScope(model: model, requiresLibrary: false))
            let revision = model.windowArtworkRevision
            let field = NSImage(size: NSSize(width: 1, height: 1))
            model.acceptWindowPalette(.init(scope: scope, accessRevision: revision, itemID: film.id, field: field))
            model.goBackFromDetail()
            XCTAssertTrue(model.windowColorField === field)

            serve(["library", "other"], denying: "other", statusCode: status)
            if aggregate {
                model.refreshServerBrowse()
                try await waitUntil("Added library was denied on the aggregate route") { model.serverBrowseError != nil }
                XCTAssertTrue(model.libraries.isEmpty)
            } else {
                model.refresh()
                try await waitUntil("Home confirms both libraries") { model.homeContentReady && model.libraries.count == 2 }
                model.navigate(to: "library", libraryID: "other")
                try await waitUntil("Added library catalog was denied") { model.catalogFailed }
                XCTAssertEqual(model.libraries.map(\.id), ["library"])
            }
            XCTAssertNotEqual(model.windowArtworkRevision, revision)
            if status == 401 {
                XCTAssertNil(model.windowColorField, "A rejected login invalidates all colors")
            } else {
                XCTAssertTrue(model.windowColorField === field, "B's own denial does not remove A's color")
                serve(["library"])
                if aggregate { model.refreshServerBrowse() } else { model.navigate(to: "library", libraryID: "library") }
                try await waitUntil("The original catalog is available again") {
                    aggregate ? model.serverBrowseComplete : model.homeContentReady
                }
                model.showDetail(film)
                model.acceptWindowPalette(.init(scope: scope, accessRevision: revision, itemID: film.id,
                                                field: NSImage(size: NSSize(width: 1, height: 1))))
                XCTAssertTrue(model.windowColorField === field, "A prior callback cannot publish even for the same film")
                model.goBackFromDetail()
                serve(["library"], denying: "library")
                if aggregate { model.refreshServerBrowse() } else { model.refresh() }
                try await waitUntil("Original library denied") {
                    aggregate ? model.serverBrowseError != nil : model.catalogFailed
                }
                XCTAssertNil(model.windowColorField)
            }
            await model.shutdown()
        }
    }

    func testCatalogPermissionDenialEvictsRetainedArtworkPartialItemsAndLateResumeAndFeedResults() async throws {
        for rejectViews in [true, false] {
            var server = connection(); server.libraryIDs.append("other")
            let vault = TestCredentialVault(), session = session()
            vault.tokens[server.id] = "test-token"
            let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
            let movie = landscapeItem("private"), views = ["Items": [["Id": "library", "Name": "Movies"], ["Id": "other", "Name": "TV"]]]
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") { return .init(body: views) }
                return .init(body: ["Items": [movie], "TotalRecordCount": 1])
            }
            model.refresh()
            try await waitUntil("Initial authorized hero and resume rows load") { model.homeContentReady }
            let old = try XCTUnwrap(model.homeRecommendations.first)
            model.navigate(to: "favorites")
            try await waitUntil("First aggregate feed finishes") { model.serverBrowseComplete }
            ModelURLProtocol.handler = { request in
                if request.url!.path.hasSuffix("/Views") { return rejectViews ? .init(status: 401, body: [:]) : .init(body: views) }
                let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if request.url!.path.hasSuffix("/Resume") || fields.contains(where: { $0.name == "Filters" && $0.value == "IsFavorite" }) {
                    return .init(body: ["Items": [movie], "TotalRecordCount": 1], delay: 0.25)
                }
                if fields.contains(where: { $0.name == "StartIndex" && $0.value == "0" }) {
                    return .init(body: ["Items": [movie], "TotalRecordCount": 2])
                }
                return .init(status: 403, body: [:], delay: 0.05)
            }
            model.refreshFromToolbar()
            XCTAssertEqual(model.homeRecommendations.first?.id, old.id)
            try await waitUntil("A scoped denial clears cached browsing state") { model.catalogFailed && !model.isToolbarRefreshing }
            XCTAssertFalse(model.canBrowseCurrentMedia)
            XCTAssertTrue(model.homeRecommendations.isEmpty)
            XCTAssertTrue(model.items.isEmpty)
            XCTAssertEqual(model.total, 0)
            XCTAssertEqual(model.libraries.map(\.id), rejectViews ? [] : ["other"])
            XCTAssertFalse(SeatSixNavigation().canSearch(model: model))
            model.showDetail(old)
            model.resumeWatching(old)
            XCTAssertNil(model.detail)
            XCTAssertNil(model.resumeLoadingID)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(model.continuing.isEmpty)
            XCTAssertTrue(model.serverBrowseCatalogItems.isEmpty)
            XCTAssertTrue(model.homeRecommendations.isEmpty)
            await model.shutdown()
            session.invalidateAndCancel()
            ModelURLProtocol.handler = nil
        }
    }

    func testToolbarRefreshWaitsForServerFeedAndLeavingAllowsNextPagesOwnRefresh() async throws {
        let server = connection(), vault = TestCredentialVault(), session = session()
        vault.tokens[server.id] = "test-token"
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let movie = landscapeItem("movie")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let isFavorites = fields?.contains { $0.name == "Filters" && $0.value == "IsFavorite" } == true
            return .init(body: ["Items": [movie], "TotalRecordCount": 1], delay: isFavorites ? 0.25 : 0)
        }
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
        model.refresh()
        try await waitUntil("Initial catalog loads") { model.homeContentReady }
        model.navigate(to: "favorites")
        model.refreshFromToolbar()
        try await waitUntil("Server favorites still loading after ordinary catalog settles") {
            model.homeContentReady && model.serverBrowseLoading
        }
        XCTAssertTrue(model.isToolbarRefreshing)
        try await waitUntil("Favorites completion releases the indicator") { !model.isToolbarRefreshing }
        XCTAssertTrue(model.serverBrowseComplete)
        model.refreshFromToolbar()
        model.navigate(to: "movies")
        XCTAssertFalse(model.isToolbarRefreshing)
        try await waitUntil("New route must complete its own server request") { model.serverBrowseComplete }
        XCTAssertEqual(model.serverBrowseCatalogItems.map(\.id), ["movie"])
        await model.shutdown()
    }

    func testToolbarRefreshAwaitsBothDetailMetadataAndSeriesEpisodes() async throws {
        let server = connection(), vault = TestCredentialVault(), session = session()
        vault.tokens[server.id] = "test-token"
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let model = makeModel(storage: MemoryApplicationStorage(configured(server)), vault: vault, session: session)
        model.selectedLibraryID = "library"
        let show: [String: Any] = ["Id": "show", "Name": "Show", "Type": "Series"]
        model.detail = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: show))
        for slowDetail in [true, false] {
            ModelURLProtocol.handler = { request in
                let path = request.url!.path
                if path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
                if path.hasSuffix("/Items/show") { return .init(body: show, delay: slowDetail ? 0.25 : 0) }
                return .init(body: ["Items": [], "TotalRecordCount": 0],
                             delay: !slowDetail && path.hasSuffix("/Episodes") ? 0.25 : 0)
            }
            model.refreshFromToolbar()
            try await waitUntil("Only the deliberately slow detail or series request remains") {
                model.homeContentReady && model.detailLoading == slowDetail && model.seriesLoading != slowDetail
            }
            XCTAssertTrue(model.isToolbarRefreshing)
            try await waitUntil("Both detail requests finish") { !model.isToolbarRefreshing }
            XCTAssertFalse(model.detailLoading)
            XCTAssertFalse(model.seriesLoading)
        }
        await model.shutdown()
    }

    func testPreservedRecommendationsAreClearedWhenLibraryResolutionFallsBack() async throws {
        var connection = connection(); connection.libraryIDs = ["library", "other"]
        let vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), reads = RequestLog()
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let old = landscapeItem("old"), replacement = landscapeItem("replacement")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") {
                reads.append(1)
                let libraries = reads.offsets.count == 1
                    ? [["Id": "library", "Name": "Movies"], ["Id": "other", "Name": "Other"]]
                    : [["Id": "other", "Name": "Other"]]
                return .init(body: ["Items": libraries])
            }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let library = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "ParentId" }!.value!
            return .init(body: ["Items": [library == "library" ? old : replacement], "TotalRecordCount": 1], delay: library == "library" ? 0 : 0.2)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Initial library should load") { model.catalogComplete && !model.catalogLoading }
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["old"])
        model.refresh(preservingHomeRecommendations: true)
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["old"])
        try await waitUntil("Removed library should resolve to the fallback") { model.selectedLibraryID == "other" }
        XCTAssertTrue(model.homeRecommendations.isEmpty, "A preserved banner must be discarded before showing another library's catalog")
        try await waitUntil("Fallback library should complete") { model.catalogComplete && !model.catalogLoading }
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["replacement"])
    }

    func testPreservedRecommendationsCannotReappearAfterConnectionChange() async throws {
        let oldConnection = connection(); var newConnection = connection(); newConnection.userID = "new-user"
        let vault = TestCredentialVault(); vault.tokens[oldConnection.id] = "old-token"; vault.tokens[newConnection.id] = "new-token"
        var saved = configured(oldConnection); saved.connections.append(newConnection)
        let storage = MemoryApplicationStorage(saved), session = session(), oldReads = RequestLog(), requests = RequestLog()
        defer { session.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        let old = landscapeItem("old"), stale = landscapeItem("stale"), fresh = landscapeItem("new")
        ModelURLProtocol.handler = { request in
            let isNew = request.url!.path.contains("/new-user/")
            if request.url!.path.hasSuffix("/Views") {
                if !isNew { oldReads.append(1) }
                return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]])
            }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            if isNew { return .init(body: ["Items": [fresh], "TotalRecordCount": 1]) }
            let refreshing = oldReads.offsets.count > 1
            if refreshing { requests.append(1) }
            return .init(body: ["Items": [refreshing ? stale : old], "TotalRecordCount": 1], delay: refreshing ? 0.25 : 0)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Original account should load") { model.catalogComplete && !model.catalogLoading }
        model.refresh(preservingHomeRecommendations: true)
        try await waitUntil("Old account refresh should be in flight") { !requests.offsets.isEmpty }
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["old"])
        model.switchConnection(newConnection.id)
        XCTAssertTrue(model.homeRecommendations.isEmpty)
        try await waitUntil("New account should load") { model.catalogComplete && !model.catalogLoading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["new"])
        XCTAssertEqual(model.connection?.userID, "new-user")
    }

    func testRefreshCancelsOldCatalogAndIgnoresStalePage() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), reads = RequestLog()
        let first = landscapeItem("fresh"), stale = landscapeItem("stale")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { reads.append(1); return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!
            return .init(body: ["Items": [offset == "0" ? first : stale], "TotalRecordCount": reads.offsets.count == 1 ? 2 : 1], delay: offset == "0" ? 0 : 0.25)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Old first page should arrive") { model.items.count == 1 }
        model.refresh()
        XCTAssertTrue(model.items.isEmpty); XCTAssertFalse(model.catalogComplete)
        try await waitUntil("Refresh should complete") { model.catalogComplete && !model.loading }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.items.map(\.id), ["fresh"]); XCTAssertEqual(model.total, 1)
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["fresh"])
        XCTAssertFalse(model.catalogLoading); XCTAssertFalse(model.catalogFailed)
    }

    func testLibraryChangeClearsFiltersAndCannotReceiveOldPages() async throws {
        var connection = connection(); connection.libraryIDs = ["library", "other"]
        let vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session()
        let old = landscapeItem("old"), stale = landscapeItem("stale"), other = landscapeItem("other-movie")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"], ["Id": "other", "Name": "Other"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": [other]]) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let library = query.first { $0.name == "ParentId" }!.value!
            let offset = query.first { $0.name == "StartIndex" }!.value!
            if library == "other" { return .init(body: ["Items": [other], "TotalRecordCount": 1]) }
            return .init(body: ["Items": [offset == "0" ? old : stale], "TotalRecordCount": 2], delay: offset == "0" ? 0 : 0.25)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Old library's first page should arrive") { model.items.count == 1 }
        model.query = "old"; model.filterYear = 2000; model.filterGenre = "Drama"; model.watchFilter = .watched
        model.changeLibrary("other")
        XCTAssertFalse(model.hasActiveFilters); XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.homeRecommendations.isEmpty)
        try await waitUntil("Other library should complete") { model.catalogComplete }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.displayedItems.map(\.id), ["other-movie"]); XCTAssertFalse(model.catalogFailed)
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["other-movie"])
        try await waitUntil("Switching during first load must still load Continue Watching") { model.continuing.map(\.id) == ["other-movie"] }
    }

    func testRefreshPreservesWatchFilterAndReadsUpdatedPlayedState() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), reads = RequestLog()
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { reads.append(1); return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            return .init(body: ["Items": [["Id":"a", "Name":"Alpha", "Type":"Movie", "UserData":["Played": reads.offsets.count > 1]]], "TotalRecordCount":1])
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("Initial catalog complete") { model.catalogComplete }
        model.watchFilter = .watched
        XCTAssertTrue(model.displayedItems.isEmpty)
        model.refresh()
        try await waitUntil("Updated watched state should arrive") { model.catalogComplete && !model.displayedItems.isEmpty }
        XCTAssertEqual(model.watchFilter, .watched); XCTAssertEqual(model.displayedItems.map(\.id), ["a"])
    }

    func testConnectionChangeRejectsOldPagesWithIdenticalLibraryID() async throws {
        let oldConnection = connection(); var newConnection = connection(); newConnection.userID = "new-user"
        let vault = TestCredentialVault(); vault.tokens[oldConnection.id] = "old-token"; vault.tokens[newConnection.id] = "new-token"
        var saved = configured(oldConnection); saved.connections.append(newConnection)
        let storage = MemoryApplicationStorage(saved), session = session(), old = landscapeItem("old"), stale = landscapeItem("stale"), fresh = landscapeItem("new")
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            if request.url!.path.hasSuffix("/Resume") { return .init(body: ["Items": []]) }
            if request.url!.path.contains("/new-user/") { return .init(body: ["Items": [fresh], "TotalRecordCount":1]) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "StartIndex" }!.value!
            return .init(body: ["Items": [offset == "0" ? old : stale], "TotalRecordCount":2], delay: offset == "0" ? 0 : 0.25)
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.refresh()
        try await waitUntil("First account partial page") { model.items.count == 1 }
        model.switchConnection(newConnection.id)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.homeRecommendations.isEmpty)
        try await waitUntil("Second account completes") { model.catalogComplete }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.items.map(\.id), ["new"]); XCTAssertEqual(model.connection?.userID, "new-user")
        XCTAssertEqual(model.homeRecommendations.map(\.id), ["new"])
    }

    func testCombinedFiltersSortAndClearUseCompleteCatalog() throws {
        let model = makeModel(storage: MemoryApplicationStorage(), vault: TestCredentialVault(), session: session())
        let data: [[String: Any]] = [
            ["Id":"a", "Name":"Alpha", "Type":"Movie", "ProductionYear":2020, "Genres":["Drama"], "UserData":["Played":true]],
            ["Id":"b", "Name":"Beta", "Type":"Movie", "ProductionYear":2020, "Genres":["Drama"], "UserData":["Played":false]],
            ["Id":"c", "Name":"Gamma", "Type":"Movie", "ProductionYear":2023, "Genres":["Comedy"], "UserData":["Played":true]]]
        model.items = try JSONDecoder().decode([MediaItem].self, from: JSONSerialization.data(withJSONObject: data))
        model.filterYear = 2020; model.filterGenre = "Drama"; model.watchFilter = .watched; model.query = "ALPHA"
        XCTAssertEqual(model.displayedItems.map(\.id), ["a"])
        XCTAssertEqual(model.catalogFacets.years, [2023, 2020])
        model.sortOrder = .yearDescending; model.clearLibraryFilters()
        XCTAssertFalse(model.hasActiveFilters); XCTAssertEqual(model.sortOrder, .yearDescending)
        XCTAssertEqual(model.displayedItems.map(\.id), ["c", "a", "b"])
    }

    func testRefreshReplacesSlowDetailRequestAndReleasesLoading() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), details = RequestLog()
        var oldMovie = item(ticks: 10_000_000); oldMovie["Name"] = "Old detail"
        var freshMovie = item(ticks: 900_000_000); freshMovie["Name"] = "Updated detail"
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Items/movie") {
                details.append(1)
                let first = details.offsets.count == 1
                return .init(body: first ? oldMovie : freshMovie, delay: first ? 0.2 : 0.01)
            }
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        let model = makeModel(storage: storage, vault: vault, session: session)
        model.showDetail(try decodedItem())
        try await waitUntil("Initial detail request should begin") { details.offsets.count == 1 }
        XCTAssertTrue(model.detailLoading)
        model.refresh()
        try await waitUntil("Refresh should replace the detail request and enable playback") {
            !model.detailLoading && model.detail?.name == "Updated detail"
        }
        XCTAssertEqual(model.detail?.userData.playbackPositionTicks, 900_000_000)
        XCTAssertEqual(details.offsets.count, 2)
        // Wait beyond the deliberately slow first response to prove it cannot restore stale metadata.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.detail?.name, "Updated detail")
        XCTAssertEqual(model.detail?.userData.playbackPositionTicks, 900_000_000)
        XCTAssertFalse(model.detailLoading)
    }

    func testConnectionSaveFailureKeepsLoginOpenAndRestoresCredential() throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "old-token"
        let storage = MemoryApplicationStorage(configured(connection)); storage.failSaving = true
        let model = makeModel(storage: storage, vault: vault, session: session()); model.showLogin = true
        let authenticated = AuthenticatedServer(connection: connection, token: "new-token")
        XCTAssertThrowsError(try model.add(authenticated, libraryIDs: ["different"], name: "Changed"))
        XCTAssertTrue(model.showLogin)
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertEqual(vault.tokens[connection.id], "old-token")
        XCTAssertEqual(storage.value.connections, [connection])
        XCTAssertNotNil(model.errorMessage)
    }

    func testFailedNewConnectionCanBeRetriedWithoutFalseSuccess() async throws {
        let connection = connection(), vault = TestCredentialVault(), storage = MemoryApplicationStorage(), session = session()
        storage.failSaving = true
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        let model = makeModel(storage: storage, vault: vault, session: session); model.showLogin = true
        let authenticated = AuthenticatedServer(connection: connection, token: "new-token")
        XCTAssertThrowsError(try model.add(authenticated, libraryIDs: ["library"], name: "New"))
        XCTAssertTrue(model.saved.connections.isEmpty)
        XCTAssertNil(vault.tokens[connection.id])
        XCTAssertTrue(model.showLogin)
        storage.failSaving = false
        try model.add(authenticated, libraryIDs: ["library"], name: "New")
        XCTAssertFalse(model.showLogin)
        XCTAssertEqual(model.saved.connections.first?.name, "New")
        XCTAssertEqual(vault.tokens[connection.id], "new-token")
        XCTAssertEqual(storage.value.connections.first?.id, connection.id)
        try await waitUntil("Saved connection should load") { !model.loading }
    }

    func testCredentialReadErrorsCannotOverwriteOrDeletePersistentTokenEvenWhenCached() async throws {
        for failure in [CredentialStoreError.invalidData, .unsafeLocation, .unavailable] {
            let connection = connection(), vault = TestCredentialVault()
            vault.tokens[connection.id] = "old-token"
            let storage = MemoryApplicationStorage(configured(connection))
            let model = makeModel(storage: storage, vault: vault, session: session())
            _ = try model.client(for: connection)
            vault.readErrors[connection.id] = failure
            XCTAssertThrowsError(try model.add(AuthenticatedServer(connection: connection, token: "new-token"),
                                               libraryIDs: ["different"], name: "Changed")) {
                XCTAssertEqual($0 as? CredentialStoreError, failure)
            }
            await model.removeConnection(connection.id)
            XCTAssertEqual(vault.tokens[connection.id], "old-token")
            XCTAssertTrue(vault.saveAttempts.isEmpty)
            XCTAssertTrue(vault.removeAttempts.isEmpty)
            XCTAssertEqual(storage.value.connections, [connection])
            XCTAssertEqual(model.saved.connections, [connection])
            XCTAssertTrue(model.errorMessage?.contains(failure.localizedDescription) == true)
        }
    }

    func testConnectionRemovalConfigurationFailureRestoresCredentialAndCanRetry() async throws {
        let connection = connection(), vault = TestCredentialVault()
        vault.tokens[connection.id] = "old-token"
        let storage = MemoryApplicationStorage(configured(connection))
        let model = makeModel(storage: storage, vault: vault, session: session())
        _ = try model.client(for: connection)
        storage.failSaving = true
        await model.removeConnection(connection.id)
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertEqual(storage.value.connections, [connection])
        XCTAssertEqual(vault.tokens[connection.id], "old-token")
        XCTAssertEqual(vault.removeAttempts, [connection.id])
        XCTAssertEqual(vault.saveAttempts.map(\.1), ["old-token"])
        XCTAssertNoThrow(try model.client(for: connection))

        storage.failSaving = false
        await model.removeConnection(connection.id)
        XCTAssertTrue(model.saved.connections.isEmpty)
        XCTAssertTrue(storage.value.connections.isEmpty)
        XCTAssertNil(vault.tokens[connection.id])
    }

    func testLocalCredentialFilesRollBackWhenConnectionConfigurationCannotBeSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixLocalRollback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let credentials = CredentialAccess.local(directory: directory.appendingPathComponent("Credentials", isDirectory: true))
        let connection = connection(), apiSession = session()
        try credentials.save("old-local-token", connection.id)
        let storage = MemoryApplicationStorage(configured(connection))
        storage.failSaving = true
        let model = ApplicationModel(storage: storage, credentials: credentials, clientFactory: {
            MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        })
        XCTAssertThrowsError(try model.add(AuthenticatedServer(connection: connection, token: "new-local-token"),
                                           libraryIDs: ["different"], name: "Changed"))
        XCTAssertEqual(try credentials.read(connection.id), "old-local-token")
        XCTAssertEqual(model.saved.connections, [connection])
        await model.removeConnection(connection.id)
        XCTAssertEqual(try credentials.read(connection.id), "old-local-token")
        XCTAssertEqual(model.saved.connections, [connection])
        storage.failSaving = false
        await model.removeConnection(connection.id)
        XCTAssertThrowsError(try credentials.read(connection.id)) {
            XCTAssertEqual($0 as? CredentialStoreError, .notFound)
        }
        XCTAssertTrue(model.saved.connections.isEmpty)
    }

    func testConnectionWithMissingLocalTokenCanBeRemovedWithoutReadingLegacyCredentials() async {
        let connection = connection(), vault = TestCredentialVault()
        let storage = MemoryApplicationStorage(configured(connection))
        let model = makeModel(storage: storage, vault: vault, session: session())
        await model.removeConnection(connection.id)
        XCTAssertTrue(model.saved.connections.isEmpty)
        XCTAssertTrue(storage.value.connections.isEmpty)
        XCTAssertEqual(vault.readCounts[connection.id], 1)
        XCTAssertEqual(vault.removeAttempts, [connection.id])
        XCTAssertTrue(vault.saveAttempts.isEmpty)
    }

    func testLoginRollbackFailureBlocksStaleCacheUntilRestorationCanRetry() async throws {
        let connection = connection(), vault = TestCredentialVault()
        vault.tokens[connection.id] = "old-token"
        vault.failingSaveCalls = [2, 3]
        let storage = MemoryApplicationStorage(configured(connection)), apiSession = session()
        var suppliedTokens: [String] = []
        let model = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: {
            suppliedTokens.append($1)
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        })
        _ = try model.client(for: connection)
        storage.failSaving = true
        let authenticated = AuthenticatedServer(connection: connection, token: "new-token")
        XCTAssertThrowsError(try model.add(authenticated, libraryIDs: ["library"], name: "Changed")) {
            XCTAssertTrue($0.localizedDescription.contains("恢复失败"))
        }
        XCTAssertEqual(vault.tokens[connection.id], "new-token", "The failed rollback is a real persistent mismatch")
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertThrowsError(try model.client(for: connection))
        XCTAssertEqual(suppliedTokens, ["old-token"], "Neither a stale cached token nor the uncommitted new token may be used")

        storage.failSaving = false
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        try model.add(authenticated, libraryIDs: ["library"], name: "Changed")
        XCTAssertEqual(vault.saveAttempts.map(\.1), ["new-token", "old-token", "old-token", "old-token", "new-token"])
        XCTAssertEqual(vault.tokens[connection.id], "new-token")
        XCTAssertEqual(model.connection?.id, connection.id)
        XCTAssertEqual(model.connection?.name, "Changed")
        _ = try model.client(for: connection)
        XCTAssertEqual(suppliedTokens.last, "new-token")
        try await waitUntil("Successful retry should load the connection") { !model.loading }
    }

    func testRemovalRollbackFailureDoesNotUseCachedCredentialAndCanRecoverBeforeRetry() async throws {
        let connection = connection(), vault = TestCredentialVault()
        vault.tokens[connection.id] = "old-token"
        vault.failingSaveCalls = [1, 2]
        let storage = MemoryApplicationStorage(configured(connection))
        let model = makeModel(storage: storage, vault: vault, session: session())
        _ = try model.client(for: connection)
        storage.failSaving = true
        await model.removeConnection(connection.id)
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertEqual(storage.value.connections, [connection])
        XCTAssertNil(vault.tokens[connection.id])
        XCTAssertTrue(model.errorMessage?.contains("恢复失败") == true)
        XCTAssertThrowsError(try model.client(for: connection), "A cached token cannot hide failed persistent restoration")

        storage.failSaving = false
        await model.removeConnection(connection.id)
        XCTAssertEqual(vault.saveAttempts.map(\.1), ["old-token", "old-token", "old-token"])
        XCTAssertEqual(vault.removeAttempts, [connection.id, connection.id])
        XCTAssertTrue(model.saved.connections.isEmpty)
        XCTAssertTrue(storage.value.connections.isEmpty)
        XCTAssertNil(vault.tokens[connection.id])
    }

    func testNewConnectionRollbackRemovalFailureRetriesCleanupBeforeSavingAgain() async throws {
        let connection = connection(), vault = TestCredentialVault()
        vault.failingRemoveCalls = [1, 2]
        let storage = MemoryApplicationStorage(), apiSession = session()
        let model = makeModel(storage: storage, vault: vault, session: apiSession)
        storage.failSaving = true
        let authenticated = AuthenticatedServer(connection: connection, token: "new-token")
        XCTAssertThrowsError(try model.add(authenticated, libraryIDs: ["library"], name: "New")) {
            XCTAssertTrue($0.localizedDescription.contains("恢复失败"))
        }
        XCTAssertTrue(model.saved.connections.isEmpty)
        XCTAssertEqual(vault.tokens[connection.id], "new-token")
        XCTAssertThrowsError(try model.client(for: connection))

        storage.failSaving = false
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        try model.add(authenticated, libraryIDs: ["library"], name: "New")
        XCTAssertEqual(vault.removeAttempts, [connection.id, connection.id, connection.id])
        XCTAssertEqual(vault.saveAttempts.map(\.1), ["new-token", "new-token"])
        XCTAssertEqual(model.connection?.id, connection.id)
        try await waitUntil("The new connection should work after cleanup and retry") { !model.loading }
    }

    func testRestartAfterLoginRollbackFailureUsesPublishedTokenOnlyForOriginalSavedIdentity() throws {
        let connection = connection(), vault = TestCredentialVault(), apiSession = session()
        defer { apiSession.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { _ in
            XCTFail("This transaction boundary test must not send a network request")
            return .init(status: 500, body: [:])
        }
        vault.tokens[connection.id] = "old-token"
        vault.failingSaveCalls = [2, 3]
        let storage = MemoryApplicationStorage(configured(connection))
        var suppliedClients: [(ServerConnection, String)] = []
        let factory: (ServerConnection, String, String) -> MediaServerClient = {
            suppliedClients.append(($0, $1))
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        }
        let original = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        _ = try original.client(for: connection)
        storage.failSaving = true
        var authenticatedConnection = connection
        authenticatedConnection.id = UUID()
        authenticatedConnection.username = "Updated display name"
        XCTAssertThrowsError(try original.add(AuthenticatedServer(connection: authenticatedConnection, token: "new-token"),
                                              libraryIDs: ["different"], name: "Changed"))
        XCTAssertThrowsError(try original.client(for: connection), "The original process still owns its pending restoration")
        XCTAssertEqual(suppliedClients.map(\.1), ["old-token"])
        XCTAssertEqual(storage.value.connections, [connection])
        XCTAssertEqual(vault.tokens[connection.id], "new-token")
        XCTAssertNil(vault.tokens[authenticatedConnection.id])

        // A fresh model has no in-memory restoration journal. It reads the
        // published token while retaining the previously committed connection.
        let reopened = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        let savedConnection = try XCTUnwrap(reopened.connection)
        XCTAssertEqual(savedConnection, connection)
        _ = try reopened.client(for: savedConnection)
        XCTAssertEqual(suppliedClients.map(\.1), ["old-token", "new-token"])
        let reopenedIdentity = try XCTUnwrap(suppliedClients.last?.0)
        XCTAssertEqual(reopenedIdentity.id, connection.id)
        XCTAssertEqual(reopenedIdentity.serverID, connection.serverID)
        XCTAssertEqual(reopenedIdentity.userID, connection.userID)
        XCTAssertEqual(reopenedIdentity.baseURL, connection.baseURL)
        XCTAssertEqual(vault.saveAttempts.count, 3, "Reopening must not invent or persist a restoration journal")
    }

    func testRestartAfterRemovalRollbackFailurePreservesConnectionButRequiresLoginForMissingToken() async throws {
        let connection = connection(), vault = TestCredentialVault(), apiSession = session()
        defer { apiSession.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { _ in
            XCTFail("Missing local credentials must prevent all network requests")
            return .init(status: 500, body: [:])
        }
        vault.tokens[connection.id] = "old-token"
        vault.failingSaveCalls = [1, 2]
        let storage = MemoryApplicationStorage(configured(connection))
        var clientCreations = 0
        let factory: (ServerConnection, String, String) -> MediaServerClient = {
            clientCreations += 1
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        }
        let original = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        _ = try original.client(for: connection)
        storage.failSaving = true
        await original.removeConnection(connection.id)
        XCTAssertThrowsError(try original.client(for: connection))
        XCTAssertEqual(storage.value.connections, [connection])
        XCTAssertNil(vault.tokens[connection.id])

        let reopened = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        XCTAssertEqual(reopened.connection, connection)
        XCTAssertThrowsError(try reopened.client(for: connection)) {
            XCTAssertEqual($0 as? CredentialStoreError, .notFound)
        }
        reopened.refresh()
        try await waitUntil("A missing credential after restart should show the application login error") { reopened.homeContentReady }
        XCTAssertEqual(reopened.saved.connections, [connection])
        XCTAssertTrue(reopened.errorMessage?.contains(CredentialStoreError.notFound.localizedDescription) == true)
        XCTAssertEqual(clientCreations, 1, "Only the original pre-failure client was created; restart cannot use its cached token")
        XCTAssertEqual(vault.saveAttempts.count, 2)
    }

    func testRestartAfterFailedNewConnectionDoesNotReadOrUseOrphanedToken() throws {
        let connection = connection(), vault = TestCredentialVault(), apiSession = session()
        defer { apiSession.invalidateAndCancel(); ModelURLProtocol.handler = nil }
        ModelURLProtocol.handler = { _ in
            XCTFail("An uncommitted connection must never initiate a network request after restart")
            return .init(status: 500, body: [:])
        }
        vault.failingRemoveCalls = [1]
        let storage = MemoryApplicationStorage()
        storage.failSaving = true
        var clientCreations = 0
        let factory: (ServerConnection, String, String) -> MediaServerClient = {
            clientCreations += 1
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        }
        let original = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        XCTAssertThrowsError(try original.add(AuthenticatedServer(connection: connection, token: "orphaned-token"),
                                              libraryIDs: ["library"], name: "New"))
        XCTAssertTrue(storage.value.connections.isEmpty)
        XCTAssertEqual(vault.tokens[connection.id], "orphaned-token")
        let readsBeforeRestart = vault.readCounts

        let reopened = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: factory)
        reopened.refresh()
        XCTAssertNil(reopened.connection)
        XCTAssertTrue(reopened.saved.connections.isEmpty)
        XCTAssertTrue(reopened.homeContentReady)
        XCTAssertEqual(vault.readCounts, readsBeforeRestart, "No saved connection means no automatic credential lookup")
        XCTAssertEqual(clientCreations, 0)
        XCTAssertEqual(vault.tokens[connection.id], "orphaned-token", "Restart neither imports nor silently cleans up an orphan")
    }

    func testCredentialsAreReadOncePerConnectionAcrossRefreshAndSwitchingBack() async throws {
        let first = connection()
        var second = connection(); second.serverID = "second-server"
        let vault = TestCredentialVault()
        vault.tokens[first.id] = "first-token"; vault.tokens[second.id] = "second-token"
        var saved = configured(first); saved.connections.append(second)
        let model = makeModel(storage: MemoryApplicationStorage(saved), vault: vault, session: session())
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        for _ in 0..<2 {
            model.refresh()
            try await waitUntil("Refreshing should finish") { model.homeContentReady }
            _ = try model.client(for: first)
        }
        model.switchConnection(second.id)
        try await waitUntil("The second connection should finish loading") { model.homeContentReady }
        model.switchConnection(first.id)
        try await waitUntil("Returning to the first connection should finish loading") { model.homeContentReady }
        XCTAssertEqual(vault.readCounts, [first.id: 1, second.id: 1])
        XCTAssertTrue(vault.saveAttempts.isEmpty)
        XCTAssertTrue(vault.removeAttempts.isEmpty)
    }

    func testDefaultLocalCredentialsUseStorageDirectoryAndReloadAcrossModelInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixLocalModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory), connection = connection()
        try storage.save(configured(connection))
        let credentials = CredentialAccess.local(directory: directory.appendingPathComponent("Credentials", isDirectory: true))
        try credentials.save("first-local-token", connection.id)
        let apiSession = session()
        var suppliedTokens: [String] = []
        let clientFactory: (ServerConnection, String, String) -> MediaServerClient = {
            suppliedTokens.append($1)
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        }
        let firstModel = ApplicationModel(storage: storage, clientFactory: clientFactory)
        _ = try firstModel.client(for: connection)
        try credentials.save("second-local-token", connection.id)
        _ = try firstModel.client(for: connection)
        let reopened = ApplicationModel(storage: try ApplicationStorage(directory: directory), clientFactory: clientFactory)
        _ = try reopened.client(for: connection)
        XCTAssertEqual(suppliedTokens, ["first-local-token", "first-local-token", "second-local-token"])
    }

    func testCustomStorageWithoutCredentialInjectionNeverFallsBackToUserCredentials() throws {
        let connection = connection()
        let model = ApplicationModel(storage: MemoryApplicationStorage(configured(connection)))
        XCTAssertThrowsError(try model.client(for: connection)) {
            XCTAssertEqual($0 as? CredentialStoreError, .unavailable)
        }
        XCTAssertThrowsError(try model.add(AuthenticatedServer(connection: connection, token: "fixture-token"),
                                           libraryIDs: ["library"], name: "Changed")) {
            XCTAssertEqual($0 as? CredentialStoreError, .unavailable)
        }
        XCTAssertEqual(model.connection, connection)
    }

    func testExplicitCredentialInjectionOverridesLocalDefaultWithoutCreatingCredentialFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixInjectedModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory), connection = connection()
        try storage.save(configured(connection))
        let vault = TestCredentialVault(); vault.tokens[connection.id] = "injected-token"
        let apiSession = session()
        var suppliedToken: String?
        let model = ApplicationModel(storage: storage, credentials: vault.access, clientFactory: {
            suppliedToken = $1
            return MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        })
        _ = try model.client(for: connection)
        XCTAssertEqual(suppliedToken, "injected-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Credentials").path))
    }

    func testMissingLocalTokenKeepsSavedConnectionAndReloginPreservesIdentityAndPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SeatSixReloginModel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try ApplicationStorage(directory: directory), connection = connection(), apiSession = session()
        var saved = configured(connection)
        saved.applicationPreferences.autoRotateHomeRecommendations = false
        saved.recovery = [.init(serverID: connection.serverID, userID: connection.userID, itemID: "movie", ticks: 123, updatedAt: Date(), confirmed: true)]
        try storage.save(saved)
        let model = ApplicationModel(storage: storage, clientFactory: {
            MediaServerClient(connection: $0, token: $1, deviceID: $2, session: apiSession)
        })
        model.refresh()
        try await waitUntil("Missing local login should settle with an actionable error") { model.homeContentReady }
        XCTAssertEqual(model.saved.connections, [connection])
        XCTAssertTrue(model.errorMessage?.contains(CredentialStoreError.notFound.localizedDescription) == true)
        var authenticatedConnection = connection
        authenticatedConnection.id = UUID()
        ModelURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/Views") { return .init(body: ["Items": [["Id": "library", "Name": "Movies"]]]) }
            return .init(body: ["Items": [], "TotalRecordCount": 0])
        }
        try model.add(AuthenticatedServer(connection: authenticatedConnection, token: "new-local-token"),
                      libraryIDs: connection.libraryIDs, name: connection.name)
        XCTAssertEqual(model.connection?.id, connection.id)
        XCTAssertEqual(model.connection?.libraryIDs, connection.libraryIDs)
        XCTAssertFalse(model.applicationPreferences.autoRotateHomeRecommendations)
        XCTAssertEqual(model.saved.recovery.first?.ticks, 123)
        XCTAssertEqual(try CredentialAccess.local(directory: directory.appendingPathComponent("Credentials")).read(connection.id), "new-local-token")
        try await waitUntil("Application re-login should load normally") { model.homeContentReady }
    }

    func testRecoverySaveFailureRemainsVolatileAndUnconfirmed() throws {
        let connection = connection(), vault = TestCredentialVault(), storage = MemoryApplicationStorage(); storage.failSaving = true
        let model = makeModel(storage: storage, vault: vault, session: session())
        XCTAssertFalse(model.saveRecovery(item: "movie", connection: connection, ticks: 70_000_000, confirmed: true))
        XCTAssertTrue(storage.value.recovery.isEmpty)
        XCTAssertEqual(model.recovery(for: "movie", connection: connection)?.ticks, 70_000_000)
        XCTAssertFalse(try XCTUnwrap(model.recovery(for: "movie", connection: connection)).confirmed)
        model.refresh()
        XCTAssertNotNil(model.errorMessage)
        storage.failSaving = false
        XCTAssertTrue(model.saveRecovery(item: "movie", connection: connection, ticks: 80_000_000, confirmed: true))
        XCTAssertEqual(storage.value.recovery.first?.ticks, 80_000_000)
    }

    func testReopeningSamePlaybackOnlyFocusesExistingWindow() throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), movie = try decodedItem(), requests = RequestLog()
        ModelURLProtocol.handler = { _ in requests.append(1); return .init(status: 500, body: [:]) }
        var focused = 0
        let model = makeModel(storage: storage, vault: vault, session: session, focus: { focused += 1 })
        let controller = NativePlaybackController(item: movie, connection: connection, client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        model.requestPlayback(movie)
        XCTAssertEqual(focused, 1)
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(model.launchingPlayback)
        XCTAssertTrue(requests.offsets.isEmpty)
    }

    func testReplayStopsCurrentPlaybackBeforeReadingAndStartsAtZero() async throws {
        let connection = connection(), vault = TestCredentialVault(); vault.tokens[connection.id] = "test-token"
        let storage = MemoryApplicationStorage(configured(connection)), session = session(), movie = try decodedItem(), remoteMovie = item(ticks: 600_000_000)
        var launchedTicks: Int64?
        let model = makeModel(storage: storage, vault: vault, session: session, launch: { _, _, _, _, ticks in launchedTicks = ticks })
        let controller = NativePlaybackController(item: movie, connection: connection, client: try model.client(for: connection)) { _, _ in true }
        model.player = controller
        let readAfterStop = expectation(description: "Item read occurs after current playback stops")
        ModelURLProtocol.handler = { _ in
            Task { @MainActor in XCTAssertFalse(controller.isActive); readAfterStop.fulfill() }
            return .init(body: remoteMovie)
        }
        model.requestPlayback(movie, fromBeginning: true)
        await fulfillment(of: [readAfterStop], timeout: 2)
        try await waitUntil("Replay launches") { launchedTicks != nil }
        XCTAssertEqual(launchedTicks, 0)
    }
}
