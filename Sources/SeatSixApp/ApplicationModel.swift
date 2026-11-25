import SwiftUI
import SeatSixCore

@MainActor
final class ApplicationModel: ObservableObject {
    @Published var saved = SavedApplication() {
        didSet {
            if let session = toolbarRefreshSession, session.connection != connection { endToolbarRefresh() }
        }
    }
    @Published var libraries: [MediaLibrary] = [] {
        didSet { observeBrowserAccess(libraries.map(\.id)) }
    }
    @Published var items: [MediaItem] = [] { didSet { catalogFacets = LibraryCatalogFacets(items: items); updateLibraryResults() } }
    @Published var continuing: [MediaItem] = []
    @Published private(set) var homeRecommendations: [MediaItem] = []
    private struct HomeRecommendationScope: Equatable {
        let connectionID: UUID
        let serverID: String
        let userID: String
        let libraryID: String
    }
    private var homeRecommendationScope: HomeRecommendationScope?
    private var currentHomeRecommendationScope: HomeRecommendationScope? {
        guard let connection, !selectedLibraryID.isEmpty else { return nil }
        return HomeRecommendationScope(connectionID: connection.id, serverID: connection.serverID,
                                       userID: connection.userID, libraryID: selectedLibraryID)
    }
    @Published var selectedLibraryID = "" {
        didSet {
            if selectedLibraryID != oldValue {
                if oldValue.isEmpty, resolvingBrowsingLocation, toolbarRefreshSession?.generation == generation {
                    toolbarRefreshSession?.libraryID = selectedLibraryID
                } else { endToolbarRefresh() }
                restoreLibrarySort()
                browsingLocationChanged()
            }
        }
    }
    @Published var searchTerm = "" {
        didSet { searchDraft = searchTerm }
    }
    @Published private(set) var searchDraft = ""
    @Published var query = "" { didSet { updateLibraryResults() } }
    @Published var filterYear: Int? { didSet { updateLibraryResults() } }
    @Published var filterGenre: String? { didSet { updateLibraryResults() } }
    @Published var watchFilter: LibraryWatchFilter = .all { didSet { updateLibraryResults() } }
    @Published var favoritesOnly = false { didSet { updateLibraryResults() } }
    @Published private(set) var userStateBusy = false
    @Published private(set) var userStateError: String?
    private var userStateTask: Task<Void, Never>?
    private var userStateConnectionID: UUID?
    private var changingPlayedAccount: (serverID: String, userID: String)?
    @Published var sortOrder: LibrarySortOrder = .nameAscending {
        didSet { if sortOrder != oldValue { rememberLibrarySort(previous: oldValue) }; updateLibraryResults() }
    }
    private var restoringLibrarySort = false
    private var restoringVisitQuery = false
    @Published private(set) var preferencesError: String?
    var applicationPreferences: ApplicationPreferences { saved.applicationPreferences }
    @Published private(set) var displayedItems: [MediaItem] = []
    @Published private(set) var catalogFacets = LibraryCatalogFacets(items: [])
    @Published private(set) var catalogComplete = false
    @Published private(set) var catalogLoading = false
    @Published private(set) var continuingLoading = false
    @Published private var resumeReadFailed = false
    private enum LibraryDiscovery { case awaitingLaunch, fetching, idle }
    @Published private var libraryDiscovery = LibraryDiscovery.idle

    var isAwaitingInitialCatalogRequest: Bool { libraryDiscovery == .awaitingLaunch }
    private var hasConfiguredLibraries: Bool { connection?.libraryIDs.isEmpty == false }
    var libraryListPending: Bool { hasConfiguredLibraries && libraryDiscovery != .idle }
    var catalogContentPending: Bool { hasConfiguredLibraries && (isAwaitingInitialCatalogRequest || catalogLoading) }
    var continuingContentPending: Bool {
        hasConfiguredLibraries && (isAwaitingInitialCatalogRequest || (connection?.compatibilityMode == true ? catalogLoading : continuingLoading))
    }
    var continuingContentFailed: Bool {
        connection?.compatibilityMode == true ? catalogFailed : resumeReadFailed
    }
    @Published private(set) var catalogFailed = false
    @Published private(set) var serverRecentItems: [MediaItem] = []
    @Published private(set) var serverContinuingItems: [MediaItem] = []
    @Published private(set) var serverBrowseCatalogItems: [MediaItem] = []
    @Published private(set) var serverBrowseLibraryIDs: [String] = []
    @Published private(set) var serverBrowseLoading = false
    var serverBrowseContentPending: Bool {
        hasConfiguredLibraries && (serverBrowseLoading || (isAwaitingInitialCatalogRequest && ServerBrowseFeed.isPage(page)))
    }
    @Published private(set) var serverBrowseComplete = false
    @Published private(set) var serverBrowseError: String?
    @Published private(set) var serverBrowseMissingDateCount = 0
    private var serverBrowseTask: Task<Void, Never>?
    private var serverBrowseGeneration = UUID()
    @Published var page = "home" {
        willSet { if newValue != page { recordBrowserDeparture() } }
        didSet {
            if page != oldValue { cancelResumeWatching() }
            // Selecting the already-visible Home is still an explicit request
            // and must cancel a pending restoration to a different page.
            browsingLocationChanged()
            if page != oldValue {
                invalidateServerBrowse()
                if ServerBrowseFeed.isPage(page) { refreshServerBrowse() }
            } else if ServerBrowseFeed.isPage(page), !serverBrowseLoading, !serverBrowseComplete {
                refreshServerBrowse()
            }
        }
    }
    @Published var loading = false
    @Published var total = 0
    @Published var errorMessage: String?
    @Published var detail: MediaItem? {
        didSet { if detail?.id != oldValue?.id { endToolbarRefresh() } }
    }
    @Published var detailLoading = false
    private var detailMetadataID: String?
    var isLoadingPresentedDetailMetadata: Bool {
        detailLoading && detailMetadataID != nil && detailMetadataID == detail?.id
    }
    @Published private(set) var seasons: [MediaItem] = []
    @Published private(set) var episodes: [MediaItem] = []
    @Published private(set) var selectedSeasonID = ""
    @Published private(set) var seriesPresentation = SeriesPresentation()
    @Published private(set) var seriesLoading = false
    @Published private(set) var seriesError: String?
    private var displayedSequence: EpisodeSequence?
    private var detailEpisodeSequence: EpisodeSequence?
    private var detailHistory: [DetailLocation] = []
    private var detailOriginPage = "home"
    @Published private var browseHistory = BrowseHistory()
    private var applyingBrowserNavigation = false
    private var accessibleHistoryLibraries: Set<String> = []
    private var continuingLibrariesByItem: [String: Set<String>] = [:]
    private var libraryResponseRevision = 0
    private var latestLibraryResponse: [MediaLibrary]?
    private var homeAccessRevision = 0
    private enum CatalogScope: Hashable { case views, library(String) }
    private var deniedCatalogScopes: Set<CatalogScope> = []
    var canBrowseCurrentMedia: Bool {
        !deniedCatalogScopes.contains(.views) && !deniedCatalogScopes.contains(.library(selectedLibraryID))
    }
    private var seriesGeneration = UUID()
    private var seriesTask: Task<Void, Never>?
    private var terminating = false
    @Published var showLogin = false
    @Published var reauthenticate: ServerConnection?
    @Published var player: NativePlaybackController?
    @Published var launchingPlayback = false
    @Published private(set) var resumeLoadingID: String?
    private var resumeTask: Task<Void, Never>?
    private var resumeGeneration = UUID()
    /// Only pending direct-resume work belongs to browser navigation. An already
    /// playing window keeps its own playback intent when the user browses elsewhere.
    private var resumePlaybackIntent: UUID?
    @Published var recoveryPrompt: RecoveryPrompt?
    @Published private(set) var posterRevision = UUID()
    /// Reject artwork from a request that lost access before the background was ready.
    @Published private(set) var windowArtworkRevision = UUID()
    @Published private var retainedWindowPalette: WindowArtworkPalette?
    // Returning to the same banner republishes its loaded image. Only a new
    // picture or a new carousel selection should supersede a detail.
    private var lastHomeArtwork: (id: HomeArtworkSnapshot.ImageID, selectionID: UUID?)?
    private var visibleHomeBanner: HomeBannerSelection?
    private var supersededPendingBanner: HomeBannerSelection?
    private var paletteLibraryIDs: Set<String> = []
    var windowPalette: WindowArtworkPalette? {
        guard let palette = retainedWindowPalette,
              palette.scope.sharesArtworkAccess(with: HomeArtworkScope(model: self, requiresLibrary: false)) else { return nil }
        return palette
    }
    var windowColorField: NSImage? { windowPalette?.field }
    private var storage: (any ApplicationPersisting)?
    private let subtitleArchive: SubtitleArchive
    private let credentials: CredentialAccess
    private let clientFactory: (ServerConnection, String, String) -> MediaServerClient
    private let focusPlayback: (() -> Void)?
    private let playbackLauncher: ((MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void)?
    private var storageErrorMessage: String?
    private var generation = UUID()
    private var detailGeneration = UUID()
    private var detailTask: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var playbackOpeningScreen: NSRect?
    private var browseTask: Task<Void, Never>?
    private struct ToolbarRefreshSession: Equatable {
        let generation: UUID
        let connection: ServerConnection
        let page: String
        var libraryID: String
        let detailID: String?
    }
    @Published private var toolbarRefreshSession: ToolbarRefreshSession?
    var isToolbarRefreshing: Bool {
        guard let session = toolbarRefreshSession else { return false }
        return session.generation == generation && session.connection == connection
            && session.page == page && session.libraryID == selectedLibraryID && session.detailID == detail?.id
    }
    private var tokens: [UUID: String] = [:]
    private enum CredentialSnapshot {
        case missing
        case token(String)
    }
    private struct PendingCredentialRestore {
        let snapshot: CredentialSnapshot
        let operationError: Error
    }
    private struct CredentialRestoreError: LocalizedError {
        let operationError: Error
        let restoreError: Error
        var errorDescription: String? {
            "\(operationError.localizedDescription)\n登录凭据恢复失败：\(restoreError.localizedDescription) 请重试；本次运行中恢复完成前不会继续使用此连接。重启后若凭据缺失，需要重新登录。"
        }
    }
    private var pendingCredentialRestores: [UUID: PendingCredentialRestore] = [:]
    private var playerWindow: PlaybackWindowController?
    private var resolvingBrowsingLocation = false
    private var startupResolutionPending = true
    private var volumeSaveTask: Task<Void, Never>?
    private var pendingPlaybackVolume: PlaybackVolumeState?
    private var revokingConnections: Set<UUID> = []
    private let invalidatePosters: @MainActor (UUID) -> Void
    var connection: ServerConnection? { saved.connections.first { $0.id == saved.selectedID } }
    var deviceID: String { saved.deviceID }
    var selectedLibrary: MediaLibrary? { libraries.first { $0.id == selectedLibraryID } }
    var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filterYear != nil || filterGenre != nil || watchFilter != .all || favoritesOnly
    }
    var catalogStatus: String {
        if catalogComplete { return "完整媒体库 · 共 \(items.count) 项 · 匹配 \(displayedItems.count) 项" }
        if catalogFailed { return "目录未读完 · 已读取 \(items.count) / \(total) 项，当前结果不完整" }
        if catalogLoading { return total > 0 ? "正在读取完整媒体库 · \(items.count) / \(total) 项" : "正在读取完整媒体库…" }
        return "尚未读取媒体库"
    }
    private var currentLibraryQuery: LibraryQuery {
        LibraryQuery(text: query, year: filterYear, genre: filterGenre, watched: watchFilter,
                     sort: sortOrder, favoritesOnly: favoritesOnly)
    }
    private func updateLibraryResults() {
        if !restoringVisitQuery { displayedItems = currentLibraryQuery.apply(to: items) }
    }
    func clearLibraryFilters(resetSearch: Bool = true) {
        if resetSearch { searchTerm = "" }
        query = ""; filterYear = nil; filterGenre = nil; watchFilter = .all; favoritesOnly = false
    }
    var displayedContinuing: [MediaItem] {
        guard connection?.compatibilityMode == true else { return continuing }
        return items.filter { ($0.isPlayable || $0.type == "Series") && !$0.userData.played && $0.userData.playbackPositionTicks > 0 }
    }
    // The home page's height depends on both independent requests. Library
    // browsing still becomes ready as soon as the catalog itself is loaded.
    var homeContentReady: Bool { !isAwaitingInitialCatalogRequest && !catalogLoading && !continuingLoading }

    init(storage: (any ApplicationPersisting)? = nil,
         credentials: CredentialAccess? = nil,
         clientFactory: @escaping (ServerConnection, String, String) -> MediaServerClient = { MediaServerClient(connection: $0, token: $1, deviceID: $2) },
         focusPlayback: (() -> Void)? = nil,
         playbackLauncher: ((MediaItem, ServerConnection, PlaybackMode, String?, Int64) async -> Void)? = nil,
         subtitleArchive: SubtitleArchive? = nil,
         invalidatePosters: @escaping @MainActor (UUID) -> Void = { PosterCache.shared.remove(connectionID: $0) }) {
        self.clientFactory = clientFactory
        self.focusPlayback = focusPlayback
        self.playbackLauncher = playbackLauncher
        self.invalidatePosters = invalidatePosters
        let resolvedStorage: (any ApplicationPersisting)?
        do { resolvedStorage = try storage ?? ApplicationStorage() }
        catch { resolvedStorage = nil }
        let supportDirectory = (resolvedStorage as? ApplicationStorage)?.directory ?? ApplicationStorage.defaultDirectory()
        // An injected in-memory/custom store must never silently access the
        // user's real credentials. Tests and custom stores inject their vault.
        self.credentials = credentials ?? (resolvedStorage as? ApplicationStorage).map {
            CredentialAccess.local(directory: $0.directory.appendingPathComponent("Credentials", isDirectory: true))
        } ?? CredentialAccess(read: { _ in throw CredentialStoreError.unavailable },
                              save: { _, _ in throw CredentialStoreError.unavailable },
                              remove: { _ in throw CredentialStoreError.unavailable })
        self.subtitleArchive = subtitleArchive ?? SubtitleArchive(directory: supportDirectory.appendingPathComponent("SubtitleArchive", isDirectory: true))
        do {
            guard let resolvedStorage else { throw ApplicationPersistenceError.unavailable }
            self.storage = resolvedStorage
            saved = try resolvedStorage.load()
            saved.applicationPreferences = saved.applicationPreferences.normalized
            sortOrder = saved.applicationPreferences.defaultLibrarySort
            if let connection {
                libraryDiscovery = .awaitingLaunch
                // Lay out the saved destination on the first frame. Its data
                // and library selection still require the live access check.
                if saved.applicationPreferences.startupPage == .lastBrowsed,
                   let location = saved.browsingLocations.first(where: { $0.belongs(to: connection) }),
                   let destination = BrowseDestination(rawValue: location.page), destination.isRestorable,
                   destination.isServerBrowse || location.libraryID.map(connection.libraryIDs.contains) == true {
                    _page = Published(initialValue: location.page)
                }
            }
        } catch {
            storageErrorMessage = "无法读取本地连接配置。为保护已有数据，未覆盖原配置。"
            errorMessage = storageErrorMessage; self.storage = nil
        }
    }
    func persist() throws { try write(saved) }

    func recordVisibleHomeBanner(_ banner: HomeBannerSelection) {
        guard page == "home", detail == nil, banner.scope == HomeArtworkScope(model: self) else { return }
        visibleHomeBanner = banner
    }

    func acceptHomeWindowPalette(_ snapshot: HomeArtworkSnapshot) {
        guard page == "home", detail == nil, !isToolbarRefreshing, applicationPreferences.showHomeRecommendations,
              snapshot.accessRevision == windowArtworkRevision, snapshot.matches(scope: HomeArtworkScope(model: self)),
              accessibleHistoryLibraries.contains(snapshot.scope.libraryID), canBrowseCurrentMedia,
              homeRecommendationScope == currentHomeRecommendationScope,
              homeRecommendations.contains(where: { $0.id == snapshot.itemID }) else { return }
        if supersededPendingBanner?.matches(scope: snapshot.scope, itemID: snapshot.itemID,
                                            selectionID: snapshot.selectionID) == true { return }
        if let previous = lastHomeArtwork, previous.id == snapshot.imageID,
           snapshot.selectionID == nil || previous.selectionID == snapshot.selectionID { return }
        lastHomeArtwork = (snapshot.imageID, snapshot.selectionID)
        supersededPendingBanner = nil
        let palette = WindowArtworkPalette(scope: snapshot.scope, accessRevision: snapshot.accessRevision,
            itemID: snapshot.itemID, field: snapshot.blurredBackground, source: .recommendation)
        guard retainedWindowPalette != palette else { return }
        paletteLibraryIDs = [snapshot.scope.libraryID]
        retainedWindowPalette = palette
    }

    func acceptWindowPalette(_ palette: WindowArtworkPalette) {
        guard palette.source == .detail, palette.belongsToOpenDetail(in: self), retainedWindowPalette != palette else { return }
        // A banner that was visible but still loading has no pixel identity to
        // remember. Its late first image must not take the window back from B.
        if let banner = visibleHomeBanner {
            let wasReady = lastHomeArtwork.map {
                $0.id.scope == banner.scope && $0.id.itemID == banner.itemID &&
                    (banner.selectionID == nil || banner.selectionID == $0.selectionID)
            } ?? false
            supersededPendingBanner = wasReady ? nil : banner
        }
        paletteLibraryIDs = accessibleHistoryLibraries
        retainedWindowPalette = palette
    }

    private func invalidateWindowPalette(remainingAccess: Set<String> = []) {
        windowArtworkRevision = UUID()
        if !paletteLibraryIDs.isEmpty && paletteLibraryIDs.isSubset(of: remainingAccess) { return }
        paletteLibraryIDs = []
        lastHomeArtwork = nil
        visibleHomeBanner = nil
        supersededPendingBanner = nil
        retainedWindowPalette = nil
    }
    @discardableResult
    func updateApplicationPreferences(_ preferences: ApplicationPreferences) -> Bool {
        var candidate = saved
        candidate.applicationPreferences = preferences.normalized
        do {
            try write(candidate)
            saved = candidate; preferencesError = nil
            player?.updateInterfacePreferences(candidate.applicationPreferences)
            if !candidate.applicationPreferences.rememberVolume {
                volumeSaveTask?.cancel(); volumeSaveTask = nil; pendingPlaybackVolume = nil
            } else if let player { rememberPlaybackVolume(player.volumeState, from: player) }
            return true
        } catch {
            preferencesError = error.localizedDescription
            return false
        }
    }
    func resetPlaybackWindow() {
        playerWindow?.resetGeometry()
    }

    func rememberPlaybackVolume(_ state: PlaybackVolumeState, from controller: NativePlaybackController) {
        guard player === controller, applicationPreferences.rememberVolume else { return }
        pendingPlaybackVolume = state.normalized
        volumeSaveTask?.cancel()
        volumeSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flushPlaybackVolume()
        }
    }
    func flushPlaybackVolume() {
        volumeSaveTask?.cancel(); volumeSaveTask = nil
        guard let volume = pendingPlaybackVolume, applicationPreferences.rememberVolume else { return }
        guard volume != saved.playbackVolume else { pendingPlaybackVolume = nil; return }
        var candidate = saved; candidate.playbackVolume = volume
        do { try write(candidate); saved = candidate; pendingPlaybackVolume = nil }
        catch { preferencesError = error.localizedDescription }
    }
    var rememberedPlaybackVolume: PlaybackVolumeState { pendingPlaybackVolume ?? saved.playbackVolume }

    private func browsingLocationChanged() {
        guard !resolvingBrowsingLocation else { return }
        // Explicit navigation while the initial request is loading wins over
        // restoration. Details and management pages are never persisted.
        startupResolutionPending = false
        rememberBrowsingLocation()
    }
    private func rememberBrowsingLocation() {
        guard !resolvingBrowsingLocation, let connection, BrowseDestination(rawValue: page)?.isRestorable == true else { return }
        let library = libraries.contains { $0.id == selectedLibraryID } ? selectedLibraryID : nil
        guard page != "library" || library != nil else { return }
        let location = BrowsingLocation(connection: connection, page: page, libraryID: library)
        guard saved.browsingLocations.first(where: { $0.belongs(to: connection) }) != location else { return }
        var candidate = saved
        candidate.browsingLocations.removeAll { $0.belongs(to: connection) }
        candidate.browsingLocations.append(location)
        do { try write(candidate); saved = candidate }
        catch { preferencesError = error.localizedDescription }
    }
    private func resolveBrowsingLocation(available: [MediaLibrary], connection: ServerConnection) {
        resolvingBrowsingLocation = true
        if startupResolutionPending, applicationPreferences.startupPage == .lastBrowsed,
           let location = saved.browsingLocations.first(where: { $0.belongs(to: connection) }),
           BrowseDestination(rawValue: location.page)?.isRestorable == true {
            if ServerBrowseFeed.isPage(location.page) {
                if let library = location.libraryID, available.contains(where: { $0.id == library }) { selectedLibraryID = library }
                page = location.page
            } else if let library = location.libraryID, available.contains(where: { $0.id == library }) {
                selectedLibraryID = library; page = location.page
            } else { page = "home" }
        }
        startupResolutionPending = false
        if !available.contains(where: { $0.id == selectedLibraryID }) {
            if !selectedLibraryID.isEmpty { clearLibraryFilters(); if page == "library" { page = "home" } }
            selectedLibraryID = available.first?.id ?? ""
        }
        resolvingBrowsingLocation = false
        rememberBrowsingLocation()
    }
    private var librarySortIdentity: LibrarySortIdentity? {
        guard let connection, !selectedLibraryID.isEmpty else { return nil }
        return LibrarySortIdentity(connection: connection, libraryID: selectedLibraryID)
    }
    private func restoreLibrarySort() {
        restoringLibrarySort = true
        defer { restoringLibrarySort = false }
        guard let identity = librarySortIdentity else {
            sortOrder = applicationPreferences.defaultLibrarySort
            return
        }
        if let existing = saved.librarySortPreferences.first(where: { $0.identity == identity }) {
            sortOrder = existing.sort
        } else {
            sortOrder = applicationPreferences.defaultLibrarySort
            // Remember the first visit too, so changing the app default never
            // silently rearranges a library the user already browsed.
            var candidate = saved
            candidate.librarySortPreferences.append(.init(identity: identity, sort: sortOrder))
            do { try write(candidate); saved = candidate }
            catch { preferencesError = error.localizedDescription }
        }
    }
    private func rememberLibrarySort(previous: LibrarySortOrder) {
        guard !restoringLibrarySort, !restoringVisitQuery, let identity = librarySortIdentity else { return }
        var candidate = saved
        candidate.librarySortPreferences.removeAll { $0.identity == identity }
        candidate.librarySortPreferences.append(.init(identity: identity, sort: sortOrder))
        do { try write(candidate); saved = candidate; preferencesError = nil }
        catch {
            restoringLibrarySort = true; sortOrder = previous; restoringLibrarySort = false
            preferencesError = error.localizedDescription
        }
    }
    private func write(_ candidate: SavedApplication) throws {
        guard let storage else {
            storageErrorMessage = ApplicationPersistenceError.unavailable.localizedDescription
            errorMessage = storageErrorMessage
            throw ApplicationPersistenceError.unavailable
        }
        do {
            try storage.save(candidate)
            if let previous = storageErrorMessage, preferencesError == previous { preferencesError = nil }
            if let previous = storageErrorMessage, let message = errorMessage {
                let remaining = message.components(separatedBy: "\n").filter { $0 != previous }
                errorMessage = remaining.isEmpty ? nil : remaining.joined(separator: "\n")
            }
            storageErrorMessage = nil
        }
        catch {
            storageErrorMessage = ApplicationPersistenceError.saveFailed.localizedDescription
            errorMessage = storageErrorMessage
            throw ApplicationPersistenceError.saveFailed
        }
    }
    private func displayError(_ message: String? = nil) {
        let parts = [storageErrorMessage, message].compactMap { $0 }
        errorMessage = parts.isEmpty ? nil : Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }.joined(separator: "\n")
    }
    func client(for connection: ServerConnection) throws -> MediaServerClient {
        guard !revokingConnections.contains(connection.id) else { throw CertificateRevocationError.inProgress }
        try recoverCredentialIfNeeded(for: connection.id)
        // Requests launched after revocation must not revive a pin held by an older UI snapshot.
        var effectiveConnection = connection
        if let current = saved.connections.first(where: { $0.id == connection.id }) {
            effectiveConnection.certificatePin = current.certificatePin
        }
        let token: String
        if let cached = tokens[connection.id] { token = cached }
        else { token = try credentials.read(connection.id); tokens[connection.id] = token }
        return clientFactory(effectiveConnection, token, saved.deviceID)
    }

    private func credentialSnapshot(for id: UUID) throws -> CredentialSnapshot {
        try recoverCredentialIfNeeded(for: id)
        // Snapshot persistent state, not the browsing cache: a damaged or
        // unreadable file must not be silently overwritten during re-login.
        do { return .token(try credentials.read(id)) }
        catch CredentialStoreError.notFound { return .missing }
    }

    private func restoreCredential(_ snapshot: CredentialSnapshot, for id: UUID) throws {
        switch snapshot {
        case .missing:
            try credentials.remove(id)
            tokens.removeValue(forKey: id)
        case .token(let token):
            try credentials.save(token, id)
            tokens[id] = token
        }
    }

    private func recoverCredentialIfNeeded(for id: UUID) throws {
        guard let pending = pendingCredentialRestores[id] else { return }
        do {
            try restoreCredential(pending.snapshot, for: id)
            pendingCredentialRestores.removeValue(forKey: id)
        } catch {
            tokens.removeValue(forKey: id)
            throw CredentialRestoreError(operationError: pending.operationError, restoreError: error)
        }
    }

    private func rollbackCredential(_ snapshot: CredentialSnapshot, for id: UUID, after operationError: Error) throws {
        do { try restoreCredential(snapshot, for: id) }
        catch {
            tokens.removeValue(forKey: id)
            pendingCredentialRestores[id] = PendingCredentialRestore(snapshot: snapshot, operationError: operationError)
            let failure = CredentialRestoreError(operationError: operationError, restoreError: error)
            displayError(failure.localizedDescription)
            throw failure
        }
    }

    func add(_ authenticated: AuthenticatedServer, libraryIDs: [String], name: String) throws {
        var connection = authenticated.connection
        connection.libraryIDs = libraryIDs
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { connection.name = name }
        let previousConnection = saved.connections.first(where: { $0.serverID == connection.serverID && $0.userID == connection.userID && $0.baseURL == connection.baseURL })
        if let old = previousConnection { connection.id = old.id }
        var candidate = saved
        candidate.connections.removeAll { $0.id == connection.id }
        candidate.connections.append(connection)
        candidate.selectedID = connection.id
        let previousCredential = try credentialSnapshot(for: connection.id)
        try credentials.save(authenticated.token, connection.id)
        do { try write(candidate) }
        catch {
            // Configuration and local credentials form one user action.
            try rollbackCredential(previousCredential, for: connection.id, after: error)
            throw error
        }
        saved = candidate; tokens[connection.id] = authenticated.token
        if previousConnection?.certificatePin != connection.certificatePin {
            invalidatePosters(connection.id); posterRevision = UUID()
        }
        showLogin = false; reauthenticate = nil
        activateSelection()
    }
    func switchConnection(_ id: UUID) {
        guard saved.selectedID != id, saved.connections.contains(where: { $0.id == id }) else { return }
        var candidate = saved; candidate.selectedID = id
        do { try write(candidate); saved = candidate }
        catch { return }
        activateSelection()
    }
    private func activateSelection() {
        invalidateWindowPalette()
        deniedCatalogScopes.removeAll()
        browseHistory = BrowseHistory()
        invalidateServerBrowse()
        invalidatePlaybackIntent()
        userStateError = nil
        startupResolutionPending = false; resolvingBrowsingLocation = true
        page = "home"; clearLibraryFilters(); dismissDetail(); selectedLibraryID = ""
        libraries = []; continuing = []
        resolvingBrowsingLocation = false
        refresh()
    }
    /// A catalog belongs to one connection, user and library. Invalidate synchronously before
    /// starting any asynchronous work so late replies cannot repopulate a different scope.
    private func beginCatalogRequest(discoverLibraries: Bool = false, preservingHomeRecommendations: Bool = false) -> UUID {
        browseTask?.cancel()
        let requestID = UUID(); generation = requestID
        libraryDiscovery = discoverLibraries ? .fetching : .idle
        resumeReadFailed = false
        catalogComplete = false; catalogFailed = false; catalogLoading = true; continuingLoading = true
        items = []; total = 0; loading = true
        if !preservingHomeRecommendations { clearHomeRecommendations() }
        displayError()
        return requestID
    }
    private func clearHomeRecommendations() {
        homeRecommendations = []; homeRecommendationScope = nil
    }
    private func endToolbarRefresh() {
        if toolbarRefreshSession != nil { toolbarRefreshSession = nil }
    }

    func refreshFromToolbar() {
        guard let connection, browserNavigationAllowed, !userStateBusy else { return }
        refresh(preservingHomeRecommendations: true)
        let session = ToolbarRefreshSession(generation: generation, connection: connection, page: page,
                                           libraryID: selectedLibraryID, detailID: detail?.id)
        toolbarRefreshSession = session
        // Each task has already started. The catalog task also joins its
        // continuing-items request. Observe these exact jobs without taking
        // ownership of later automatic or route-specific refreshes.
        let jobs = [browseTask, serverBrowseTask, detailTask, seriesTask].compactMap { $0 }
        // Give an explicit click a visible loading state even for a very fast NAS.
        // Slow requests consume this interval while they run.
        let earliestReveal = ContinuousClock.now.advanced(by: .milliseconds(240))
        Task { [weak self] in
            for job in jobs {
                await job.value
                guard self?.toolbarRefreshSession?.generation == session.generation else { return }
            }
            try? await Task.sleep(until: earliestReveal, clock: .continuous)
            if self?.toolbarRefreshSession?.generation == session.generation { self?.endToolbarRefresh() }
        }
    }

    func refresh(preservingHomeRecommendations: Bool = false) {
        invalidateServerBrowse()
        let retainedScope = preservingHomeRecommendations && homeRecommendationScope == currentHomeRecommendationScope
            ? homeRecommendationScope : nil
        let retainedIDs = retainedScope == nil ? [] : homeRecommendations.map(\.id)
        let requestID = beginCatalogRequest(discoverLibraries: connection != nil, preservingHomeRecommendations: retainedScope != nil)
        guard let connection else { startupResolutionPending = false; page = "home"; loading = false; catalogLoading = false; continuingLoading = false; return }
        if ServerBrowseFeed.isPage(page) { refreshServerBrowse() }
        if let detail { showDetail(detail) }
        browseTask = Task {
            var checkingViews = false
            do {
                try Task.checkCancellation()
                let api = try client(for: connection)
                try await reconcilePendingUserState(api: api, connection: connection)
                try Task.checkCancellation()
                checkingViews = true
                let revision = libraryResponseRevision
                let response = try await api.libraries().filter { connection.libraryIDs.contains($0.id) }
                try Task.checkCancellation()
                guard generation == requestID else { return }
                let available = currentLibraryResponse(response, startingRevision: revision)
                deniedCatalogScopes.remove(.views)
                libraries = available
                libraryDiscovery = .idle
                resolveBrowsingLocation(available: available, connection: connection)
                // A removed library may resolve to a different one after the Views
                // response. Never carry the previous library's banner into it.
                let canRetain = retainedScope != nil && retainedScope == currentHomeRecommendationScope
                if !canRetain { clearHomeRecommendations() }
                async let resumeError = loadContinuing(api: api, requestID: requestID)
                if let library = selectedLibrary {
                    await loadCatalog(api: api, libraryID: library.id, requestID: requestID,
                                      retainingRecommendationIDs: canRetain ? retainedIDs : [])
                } else {
                    catalogComplete = true; catalogLoading = false; loading = false
                }
                try Task.checkCancellation()
                guard generation == requestID else { return }
                let message = await resumeError
                guard generation == requestID else { return }
                if let message, !catalogFailed { displayError(message) }
            } catch is CancellationError { }
            catch {
                if generation == requestID {
                    libraryDiscovery = .idle
                    resumeReadFailed = true
                    discardDeniedBrowseHistory(error, catalog: checkingViews ? .views : nil)
                    if startupResolutionPending { startupResolutionPending = false; page = "home" }
                    displayError(error.localizedDescription); catalogFailed = true; catalogLoading = false; continuingLoading = false; loading = false
                }
            }
        }
    }
    private func loadContinuing(api: MediaServerClient, requestID: UUID) async -> String? {
        defer {
            // An older cancelled response must not mark the next source's home
            // geometry ready while its own resume request is still in flight.
            if generation == requestID { continuingLoading = false }
        }
        do {
            try Task.checkCancellation()
            guard generation == requestID else { return nil }
            while generation == requestID {
                let revision = homeAccessRevision
                var recent: [MediaItem] = []
                var owners: [String: Set<String>] = [:]
                let authorized = (connection?.libraryIDs ?? []).filter {
                    accessibleHistoryLibraries.contains($0) && !deniedCatalogScopes.contains(.library($0))
                }
                do {
                    var requested: Set<String> = []
                    for library in authorized where requested.insert(library).inserted {
                        guard generation == requestID, revision == homeAccessRevision else { break }
                        let rows = try await api.resumeItems(libraryIDs: [library])
                        try Task.checkCancellation()
                        for item in rows {
                            if owners[item.id] == nil { recent.append(item) }
                            owners[item.id, default: []].insert(library)
                        }
                    }
                } catch {
                    if revision != homeAccessRevision { continue }
                    throw error
                }
                guard generation == requestID else { return nil }
                // An aggregate page may have discovered a narrower role while
                // Resume was in flight. Retry with the current libraries only.
                guard revision == homeAccessRevision else { continue }
                continuingLibrariesByItem = owners
                continuing = recent
                resumeReadFailed = false
                return nil
            }
        } catch is CancellationError { }
        catch {
            guard generation == requestID else { return nil }
            resumeReadFailed = true
            // A transport failure leaves the last confirmed rows usable. An
            // explicit access denial must also retire their authorization.
            let serverError = error as? MediaServerError
            if serverError == .httpStatus(401) || serverError == .httpStatus(403) || serverError == .invalidScope {
                continuingLibrariesByItem = [:]
                continuing = []
            }
            return "继续观看暂时无法加载，媒体库仍可浏览。\n" + error.localizedDescription
        }
        return nil
    }
    private func loadCatalog(api: MediaServerClient, libraryID: String, requestID: UUID,
                             retainingRecommendationIDs: [String] = []) async {
        do {
            try Task.checkCancellation()
            let result = try await api.libraryCatalog(libraryID: libraryID) { [weak self] snapshot in
                await self?.acceptCatalog(snapshot, libraryID: libraryID, requestID: requestID)
            }
            try Task.checkCancellation()
            guard generation == requestID, selectedLibraryID == libraryID else { return }
            deniedCatalogScopes.remove(.library(libraryID))
            acceptCatalog(result, libraryID: libraryID, requestID: requestID)
            // The final snapshot is also delivered through onProgress. Choose once
            // here so a completed load cannot reshuffle the visible banner twice.
            homeRecommendations = HomeRecommendationSelection.select(from: result.items, retainingIDs: retainingRecommendationIDs)
            homeRecommendationScope = currentHomeRecommendationScope
        } catch is CancellationError { return }
        catch {
            guard generation == requestID, selectedLibraryID == libraryID else { return }
            discardDeniedBrowseHistory(error, catalog: .library(libraryID))
            catalogFailed = true; catalogComplete = false
            displayError("完整媒体库读取未完成，当前搜索和筛选结果可能有遗漏。请重试。\n" + error.localizedDescription)
        }
        guard generation == requestID else { return }
        catalogLoading = false; loading = false
    }
    private func acceptCatalog(_ snapshot: LibraryCatalogSnapshot, libraryID: String, requestID: UUID) {
        guard generation == requestID, selectedLibraryID == libraryID else { return }
        items = snapshot.items; total = snapshot.total; catalogComplete = snapshot.isComplete
    }
    func searchChanged() { /* Search is local and always includes every fetched page. */ }

    func editSearchDraft(_ value: String) {
        if value.isEmpty {
            searchTerm = ""
        } else {
            searchDraft = value
        }
    }

    @discardableResult
    func submitSearchDraft() -> Bool {
        let term = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        searchTerm = term
        return true
    }
    private func invalidateServerBrowse() {
        endToolbarRefresh()
        serverBrowseTask?.cancel(); serverBrowseTask = nil; serverBrowseGeneration = UUID()
        serverBrowseLoading = false; serverBrowseComplete = false; serverBrowseError = nil
        serverRecentItems = []; serverContinuingItems = []; serverBrowseCatalogItems = []; serverBrowseMissingDateCount = 0
        serverBrowseLibraryIDs = []
    }

    /// Fetch the current server's selected, still-authorized libraries on demand.
    func refreshServerBrowse() {
        refreshServerBrowse(verifiedLibraryIDs: nil)
    }

    private func refreshServerBrowse(verifiedLibraryIDs: [String]?) {
        invalidateServerBrowse()
        guard ServerBrowseFeed.isPage(page), let connection, !terminating,
              !revokingConnections.contains(connection.id) else { return }
        let requestID = serverBrowseGeneration
        let requestedPage = page
        if let verifiedLibraryIDs { serverBrowseLibraryIDs = verifiedLibraryIDs }
        serverBrowseLoading = true
        serverBrowseTask = Task {
            var checkingCatalog: CatalogScope?
            do {
                try Task.checkCancellation()
                let api = try client(for: connection)
                try await reconcilePendingUserState(api: api, connection: connection)
                try Task.checkCancellation()
                if verifiedLibraryIDs == nil {
                    checkingCatalog = .views
                    let revision = libraryResponseRevision
                    let response = try await api.libraries().filter { connection.libraryIDs.contains($0.id) }
                    try Task.checkCancellation()
                    guard serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) else { return }
                    let available = currentLibraryResponse(response, startingRevision: revision)
                    deniedCatalogScopes.remove(.views)
                    checkingCatalog = nil
                    var seenLibraries: Set<String> = []
                    serverBrowseLibraryIDs = available.map(\.id).filter { seenLibraries.insert($0).inserted }
                    reconcileAggregateAccess(available, libraryIDs: serverBrowseLibraryIDs, connection: connection)
                }
                let libraryIDs = serverBrowseLibraryIDs
                if requestedPage == "continuing", !connection.compatibilityMode {
                    let result = try await api.completeResumeItems(libraryIDs: libraryIDs, maximumItems: ServerBrowseFeed.maximumItems) { [weak self] items in
                        await self?.acceptServerBrowse(items, requestID: requestID, page: requestedPage, connection: connection)
                    }
                    acceptServerBrowse(result, requestID: requestID, page: requestedPage, connection: connection)
                } else {
                    var accumulated: [MediaItem] = []
                    var rawCount = 0
                    for libraryID in libraryIDs {
                        try Task.checkCancellation()
                        checkingCatalog = .library(libraryID)
                        let completed = accumulated
                        let result = try await api.libraryCatalog(libraryID: libraryID, requestFavorites: requestedPage == "favorites",
                                                                  maximumItems: ServerBrowseFeed.maximumItems - rawCount) { [weak self] snapshot in
                            await self?.acceptServerBrowse(ServerBrowseFeed.merging(completed, snapshot.items), requestID: requestID,
                                                           page: requestedPage, connection: connection)
                        }
                        try Task.checkCancellation()
                        guard serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) else { return }
                        deniedCatalogScopes.remove(.library(libraryID))
                        rawCount += result.total
                        accumulated = ServerBrowseFeed.merging(accumulated, result.items)
                    }
                    acceptServerBrowse(accumulated, requestID: requestID, page: requestedPage, connection: connection)
                }
                try Task.checkCancellation()
                guard serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) else { return }
                serverBrowseComplete = true; serverBrowseLoading = false; serverBrowseTask = nil
            } catch is CancellationError {
                if serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) {
                    serverBrowseLoading = false; serverBrowseTask = nil
                }
            } catch {
                guard serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) else { return }
                discardDeniedBrowseHistory(error, catalog: checkingCatalog)
                serverBrowseComplete = false; serverBrowseLoading = false; serverBrowseTask = nil
                if error as? LibraryCatalogError == .tooLarge {
                    serverBrowseError = "当前服务器所选媒体库合计超过 100,000 项，无法确认完整结果。请减少所选媒体库后重试。"
                } else {
                    serverBrowseError = "内容未读取完整，当前结果可能有遗漏。请重试。\n" + error.localizedDescription
                }
            }
        }
    }

    private func serverBrowseIsCurrent(_ requestID: UUID, page requestedPage: String, connection requestedConnection: ServerConnection) -> Bool {
        serverBrowseGeneration == requestID && page == requestedPage && !terminating
            && !revokingConnections.contains(requestedConnection.id) && connection == requestedConnection
    }

    private func acceptServerBrowse(_ items: [MediaItem], requestID: UUID, page requestedPage: String, connection: ServerConnection) {
        guard serverBrowseIsCurrent(requestID, page: requestedPage, connection: connection) else { return }
        if requestedPage == "favorites" {
            let supported = items.filter { item in
                item.type == "Movie" || item.type == "Series" || (!connection.compatibilityMode && item.isPlayable)
            }
            serverBrowseCatalogItems = LibraryQuery(favoritesOnly: true).apply(to: supported)
        } else if requestedPage != "continuing" || connection.compatibilityMode {
            serverBrowseCatalogItems = items
        }
        if requestedPage == "recent" {
            serverRecentItems = ServerBrowseFeed.recent(items)
            serverBrowseMissingDateCount = ServerBrowseFeed.missingDateCount(items)
        } else if requestedPage == "continuing" {
            serverContinuingItems = connection.compatibilityMode ? ServerBrowseFeed.compatibilityContinuing(items) : items
        }
    }

    private var currentBrowseVisit: BrowseVisit {
        let location = detail.map {
            DetailLocation(item: $0, seasonID: selectedSeasonID, sequence: displayedSequence ?? detailEpisodeSequence, seriesPresentation: seriesPresentation)
        }
        return BrowseVisit(connection: connection, page: page, libraryID: selectedLibraryID, libraryQuery: currentLibraryQuery,
                           searchTerm: searchTerm, searchDraft: searchDraft,
                           detail: location, parents: detailHistory, detailOriginPage: detailOriginPage)
    }

    private func recordBrowserDeparture() {
        guard !applyingBrowserNavigation, !resolvingBrowsingLocation, !terminating else { return }
        browseHistory.depart(currentBrowseVisit)
    }

    // A check started before another Views response was accepted can narrow
    // that evidence, never widen it. A new check may grant access again.
    private func currentLibraryResponse(_ libraries: [MediaLibrary], startingRevision: Int) -> [MediaLibrary] {
        var accepted = libraries
        if startingRevision != libraryResponseRevision, let latestLibraryResponse {
            let permitted = Set(latestLibraryResponse.map(\.id))
            accepted.removeAll { !permitted.contains($0.id) }
        }
        latestLibraryResponse = accepted
        libraryResponseRevision += 1
        return accepted
    }

    private func reconcileAggregateAccess(_ available: [MediaLibrary], libraryIDs: [String], connection: ServerConnection) {
        // Browsing an aggregate never starts an unrelated home catalog on first
        // launch. If an established selection loses access, discard it now and
        // reuse the normal catalog transition for the first still-accessible library.
        let hasHomeCatalog = !selectedLibraryID.isEmpty || catalogComplete || catalogFailed
        if hasHomeCatalog && Set(libraries.map(\.id)) != Set(libraryIDs) {
            libraries = available
        } else {
            observeBrowserAccess(libraryIDs)
        }
        guard hasHomeCatalog, !libraryIDs.contains(selectedLibraryID),
              !selectedLibraryID.isEmpty || !available.isEmpty else { return }
        invalidatePlaybackIntent()
        clearLibraryFilters(resetSearch: page != "searchServer")
        selectedLibraryID = available.first?.id ?? ""
        loadSelectedCatalog(connection)
    }

    private func observeBrowserAccess(_ ids: [String]) {
        let newAccess = Set(ids)
        if !accessibleHistoryLibraries.isSubset(of: newAccess) {
            invalidateWindowPalette(remainingAccess: newAccess)
            homeAccessRevision += 1
            continuingLibrariesByItem = continuingLibrariesByItem.compactMapValues { libraries in
                let retained = libraries.intersection(newAccess)
                return retained.isEmpty ? nil : retained
            }
            continuing.removeAll { continuingLibrariesByItem[$0.id] == nil }
            latestLibraryResponse?.removeAll { !newAccess.contains($0.id) }
            libraryResponseRevision += 1
            browseHistory = BrowseHistory()
            endToolbarRefresh()
            dismissDetail()
        }
        accessibleHistoryLibraries = newAccess
        if retainedWindowPalette != nil && paletteLibraryIDs.isEmpty { paletteLibraryIDs = newAccess }
        // A feed may already be showing results, or still fetching a revoked
        // library. Replace both its data and its request generation immediately.
        if !Set(serverBrowseLibraryIDs).isSubset(of: newAccess) {
            refreshServerBrowse(verifiedLibraryIDs: ids)
        }
    }

    private func discardDeniedBrowseHistory(_ error: Error, catalog: CatalogScope? = nil) {
        guard let serverError = error as? MediaServerError,
              serverError == .httpStatus(401) || serverError == .httpStatus(403) else { return }
        if serverError == .httpStatus(403), case .library(let id) = catalog {
            invalidateWindowPalette(remainingAccess: accessibleHistoryLibraries.subtracting([id]))
        } else {
            invalidateWindowPalette()
        }
        browseHistory = BrowseHistory()
        dismissDetail()
        guard let catalog else { return }
        deniedCatalogScopes.insert(catalog)
        // Aggregate lists and resume summaries cannot attribute every item to
        // one library. Discard them when any contributing scope is denied.
        invalidateServerBrowse()
        continuing = []
        resumeReadFailed = true
        switch catalog {
        case .views: libraries = []
        case .library(let id):
            if libraries.contains(where: { $0.id == id }) {
                libraries.removeAll { $0.id == id }
            } else {
                // Aggregate pages can confirm access before the home list is populated.
                observeBrowserAccess(accessibleHistoryLibraries.filter { $0 != id }.sorted())
            }
        }
        guard catalog == .views || catalog == .library(selectedLibraryID) else { return }
        generation = UUID()
        browseTask?.cancel()
        libraryDiscovery = .idle
        invalidatePlaybackIntent()
        clearHomeRecommendations()
        items = []; total = 0
        catalogComplete = false; catalogFailed = true
        catalogLoading = false; continuingLoading = false; loading = false
        displayError(error.localizedDescription)
        if ServerBrowseFeed.isPage(page) { serverBrowseError = error.localizedDescription }
    }

    private var browserNavigationAllowed: Bool {
        if let id = saved.selectedID, revokingConnections.contains(id) { return false }
        return !terminating && !showLogin && recoveryPrompt == nil && !launchingPlayback
    }

    private func canRestore(_ visit: BrowseVisit?) -> Bool {
        guard let visit, browserNavigationAllowed, visit.connection == connection else { return false }
        return visit.libraryID.isEmpty || (connection?.libraryIDs.contains(visit.libraryID) == true
            && accessibleHistoryLibraries.contains(visit.libraryID) && libraries.contains { $0.id == visit.libraryID })
    }

    var canNavigateBack: Bool {
        canRestore(browseHistory.back.last) || (browserNavigationAllowed && detail != nil && browseHistory.back.isEmpty)
    }
    var canNavigateForward: Bool { canRestore(browseHistory.forward.last) }
    var backNavigationDetailID: String? {
        if let target = browseHistory.back.last { return target.detail?.item.id }
        return detailBackTargetID
    }

    /// A sidebar/search click can change the library, dismiss a detail, and
    /// select a page together. Record the visible origin exactly once.
    func navigate(to destination: String, libraryID: String? = nil) {
        guard BrowseDestination(rawValue: destination) != nil, browserNavigationAllowed else { return }
        if let libraryID, !libraries.contains(where: { $0.id == libraryID }) { return }
        if page != destination || detail != nil || (libraryID ?? selectedLibraryID) != selectedLibraryID {
            recordBrowserDeparture()
        }
        applyingBrowserNavigation = true
        defer { applyingBrowserNavigation = false }
        dismissDetail()
        if let libraryID { changeLibrary(libraryID) }
        page = destination
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        if let target = browseHistory.stepBack(from: currentBrowseVisit) { restoreBrowserVisit(target) }
        else { goBackFromDetail() }
    }

    func navigateForward() {
        guard canNavigateForward, let target = browseHistory.stepForward(from: currentBrowseVisit) else { return }
        restoreBrowserVisit(target)
    }

    private func restoreBrowserVisit(_ visit: BrowseVisit) {
        applyingBrowserNavigation = true
        defer { applyingBrowserNavigation = false }
        dismissDetail()
        if !visit.libraryID.isEmpty { changeLibrary(visit.libraryID) }
        if currentLibraryQuery != visit.libraryQuery {
            restoringVisitQuery = true
            query = visit.libraryQuery.text
            filterYear = visit.libraryQuery.year
            filterGenre = visit.libraryQuery.genre
            watchFilter = visit.libraryQuery.watched
            favoritesOnly = visit.libraryQuery.favoritesOnly
            sortOrder = visit.libraryQuery.sort
            restoringVisitQuery = false
            updateLibraryResults()
        }
        searchTerm = visit.searchTerm
        searchDraft = visit.searchDraft
        if page != visit.page { page = visit.page }
        if let location = visit.detail {
            detailOriginPage = visit.detailOriginPage
            detailHistory = visit.parents
            openDetail(location.item, preferredSeasonID: location.seasonID, episodeContext: location.sequence, presentation: location.seriesPresentation)
        }
    }

    func cancelSearch() {
        guard BrowseDestination(rawValue: page)?.isSearch == true else { return }
        while BrowseDestination(rawValue: page)?.isSearch == true, canRestore(browseHistory.back.last) {
            navigateBack()
        }
        if BrowseDestination(rawValue: page)?.isSearch == true { navigate(to: "home") }
    }

    func changeLibrary(_ id: String) {
        guard let connection, libraries.contains(where: { $0.id == id }), selectedLibraryID != id else { return }
        // The picker may establish its first selection as /Views arrives.
        // There is no previous library to revisit until one was selected.
        if !selectedLibraryID.isEmpty { recordBrowserDeparture() }
        invalidateServerBrowse()
        selectedLibraryID = id; clearLibraryFilters(); dismissDetail()
        loadSelectedCatalog(connection)
    }

    private func loadSelectedCatalog(_ connection: ServerConnection) {
        let requestID = beginCatalogRequest()
        let id = selectedLibraryID
        guard !id.isEmpty else {
            catalogComplete = true; catalogLoading = false; continuingLoading = false; loading = false
            return
        }
        browseTask = Task {
            do {
                let api = try client(for: connection)
                async let resumeError = loadContinuing(api: api, requestID: requestID)
                await loadCatalog(api: api, libraryID: id, requestID: requestID)
                let message = await resumeError
                guard generation == requestID else { return }
                if let message, !catalogFailed { displayError(message) }
            } catch {
                guard generation == requestID else { return }
                resumeReadFailed = true
                catalogFailed = true; catalogLoading = false; continuingLoading = false; loading = false
                displayError(error.localizedDescription)
            }
        }
    }
    private func pendingState(for connection: ServerConnection) -> PendingUserState? {
        saved.pendingUserStates.first { $0.serverID == connection.serverID && $0.userID == connection.userID }
    }
    private func userStateBlocksPlayback(for connection: ServerConnection) -> Bool {
        if let account = changingPlayedAccount, account.serverID == connection.serverID, account.userID == connection.userID { return true }
        if let pending = pendingState(for: connection), case .played = pending.action { return true }
        return false
    }
    var userStateNeedsRefresh: Bool { !userStateBusy && (connection.flatMap { pendingState(for: $0) } != nil) }
    var canEditPlayedState: Bool {
        guard !launchingPlayback else { return false }
        guard let player, let connection else { return true }
        // Keep stopping/finished controllers protected until the window's final stop
        // completes. Alternate IP/domain connections still share one user history.
        return player.connection.serverID != connection.serverID || player.connection.userID != connection.userID
    }
    func canFavorite(_ item: MediaItem) -> Bool {
        connection.map { MediaUserStateCapabilities.canFavorite(item: item, connection: $0) } ?? false
    }
    func canSetPlayed(_ item: MediaItem) -> Bool {
        connection.map { MediaUserStateCapabilities.canSetPlayed(item: item, connection: $0) } ?? false
    }
    func toggleFavorite(_ item: MediaItem) { changeUserState(item, action: .favorite(!item.userData.isFavorite)) }
    func setPlayed(_ item: MediaItem, played: Bool) { changeUserState(item, action: .played(played)) }
    private func changeUserState(_ item: MediaItem, action: MediaUserStateAction) {
        guard let connection, !terminating, !revokingConnections.contains(connection.id), !userStateBusy, !userStateNeedsRefresh,
              !detailLoading, detail?.id == item.id else { return }
        switch action {
        case .favorite: guard canFavorite(item) else { return }
        case .played: guard canSetPlayed(item), canEditPlayedState else { return }
        }
        userStateBusy = true; userStateError = nil; userStateConnectionID = connection.id
        if case .played = action { changingPlayedAccount = (connection.serverID, connection.userID) }
        userStateTask = Task {
            defer { userStateBusy = false; changingPlayedAccount = nil; userStateTask = nil; userStateConnectionID = nil }
            var dispatched = false
            var submittedIntentID: UUID?
            do {
                let api = try client(for: connection)
                var affectedIDs: Set<String> = [item.id]
                if case .played = action, item.type == "Series" {
                    affectedIDs.formUnion(try await api.episodes(seriesID: item.id).map(\.id))
                }
                try Task.checkCancellation()
                guard !terminating, saved.selectedID == connection.id,
                      saved.connections.contains(where: { $0.id == connection.id && $0.userID == connection.userID && $0.certificatePin == connection.certificatePin }),
                      !revokingConnections.contains(connection.id) else { return }
                if case .played = action { guard canEditPlayedState else { return } }
                let intent = PendingUserState(connectionID: connection.id, serverID: connection.serverID, userID: connection.userID,
                    itemID: item.id, itemType: item.type, action: action, affectedIDs: affectedIDs)
                submittedIntentID = intent.id
                var candidate = saved
                candidate.pendingUserStates.append(intent)
                // No server write may happen unless its uncertain outcome can survive a restart.
                try write(candidate); saved = candidate
                dispatched = true
                let full: MediaItem
                switch action {
                case .favorite(let value): full = try await api.setFavorite(item: item, isFavorite: value)
                case .played(let value): full = try await api.setPlayed(item: item, played: value)
                }
                try Task.checkCancellation()
                guard try reconcileUserState(full, connection: connection, expectedIntentID: intent.id) else { return }
                guard !terminating, let selected = self.connection,
                      selected.serverID == connection.serverID, selected.userID == connection.userID else { return }
                if selected.id == connection.id, detail?.id == item.id { detail = full }
                // Replace every read started before the mutation with authoritative state.
                refresh()
            } catch {
                var definitelyRejected = !dispatched
                if case MediaServerError.httpStatus(let code) = error, (400..<500).contains(code) { definitelyRejected = true }
                if definitelyRejected, let submittedIntentID { try? removePendingState(connection: connection, expectedIntentID: submittedIntentID) }
                guard saved.selectedID == connection.id, !terminating else { return }
                if let submittedIntentID, let pending = pendingState(for: connection), pending.id != submittedIntentID { return }
                if userStateError == nil { userStateError = error.localizedDescription }
            }
        }
    }
    private func removePendingState(connection: ServerConnection, expectedIntentID: UUID) throws {
        guard pendingState(for: connection)?.id == expectedIntentID else { return }
        var candidate = saved
        candidate.pendingUserStates.removeAll { $0.id == expectedIntentID && $0.serverID == connection.serverID && $0.userID == connection.userID }
        try write(candidate); saved = candidate
    }
    private func reconcileUserState(_ full: MediaItem, connection: ServerConnection, expectedIntentID: UUID) throws -> Bool {
        // A read belongs to the intent captured before its suspension. Another
        // read can finish that intent and let the user submit an identical new
        // one while this response is still in flight (an ABA replacement).
        guard let pending = pendingState(for: connection), pending.id == expectedIntentID else { return false }
        guard pending.itemID == full.id, pending.itemType == full.type,
              full.userData.playedKnown, full.userData.isFavoriteKnown, full.userData.playbackPositionKnown,
              full.userData.playbackPositionTicks >= 0 else { throw MediaUserStateError.outcomeUncertain }
        var candidate = saved
        candidate.pendingUserStates.removeAll { $0.id == expectedIntentID && $0.serverID == connection.serverID && $0.userID == connection.userID }
        if case .played(let desired) = pending.action, full.userData.played == desired {
            candidate.recovery.removeAll { $0.serverID == connection.serverID && $0.userID == connection.userID && pending.affectedIDs.contains($0.itemID) }
        }
        do { try write(candidate); saved = candidate }
        catch {
            // Retain the durable marker and block playback until local cleanup succeeds.
            userStateError = "服务器状态已读取，但本机旧续播记录未能安全清理。请修复存储问题后重新读取状态，再继续播放。"
            throw error
        }
        return true
    }
    private func reconcilePendingUserState(api: MediaServerClient, connection: ServerConnection) async throws {
        guard let pending = pendingState(for: connection), !userStateBusy else { return }
        let full = try await api.item(id: pending.itemID)
        try Task.checkCancellation()
        guard !userStateBusy, !terminating, !revokingConnections.contains(connection.id) else { return }
        let reconciled = try reconcileUserState(full, connection: connection, expectedIntentID: pending.id)
        if reconciled, saved.selectedID == connection.id { userStateError = nil }
    }
    func showDetail(_ item: MediaItem) {
        guard !terminating, canBrowseCurrentMedia else { return }
        if detail?.id != item.id { recordBrowserDeparture() }
        cancelResumeWatching()
        let preserveSeason: String? = detail?.id == item.id ? selectedSeasonID : nil
        let existingContext = displayedSequence ?? detailEpisodeSequence
        if let current = detail, current.id != item.id {
            detailHistory.append(.init(item: current, seasonID: selectedSeasonID, sequence: existingContext, seriesPresentation: seriesPresentation))
        } else if detail == nil {
            detailHistory = []
            detailOriginPage = page
        }
        openDetail(item, preferredSeasonID: preserveSeason, episodeContext: existingContext,
                   presentation: detail?.id == item.id ? seriesPresentation : SeriesPresentation())
    }
    var detailBackTitle: String {
        if seriesPresentation.showsAll && seriesPresentation.returnsToPreview { return "返回剧集" }
        if let previous = detailHistory.last { return "返回\(previous.item.type == "Series" ? "剧集" : "详情")" }
        return "返回" + (BrowseDestination(rawValue: detailOriginPage)?.title ?? "媒体库")
    }
    var detailBackTargetID: String? {
        seriesPresentation.showsAll && seriesPresentation.returnsToPreview ? detail?.id : detailHistory.last?.item.id
    }
    func hasDetailHistory(itemID: String) -> Bool { detailHistory.contains { $0.item.id == itemID } }
    func goBackFromDetail() {
        guard !terminating, detail != nil else { return }
        if seriesPresentation.showsAll && seriesPresentation.returnsToPreview {
            if canRestore(browseHistory.back.last), browseHistory.back.last?.detail?.item.id == detail?.id {
                _ = browseHistory.stepBack(from: currentBrowseVisit)
            }
            seriesPresentation.showsAll = false
            seriesPresentation.returnsToPreview = false
            return
        }
        browseHistory.returnFromDetail(currentBrowseVisit, to: detailBackTargetID, on: detailOriginPage)
        applyingBrowserNavigation = true
        defer { applyingBrowserNavigation = false }
        cancelResumeWatching()
        if let previous = detailHistory.popLast() {
            openDetail(previous.item, preferredSeasonID: previous.seasonID, episodeContext: previous.sequence, presentation: previous.seriesPresentation)
        } else {
            let origin = detailOriginPage
            dismissDetail()
            page = origin
        }
    }
    private func openDetail(_ item: MediaItem, preferredSeasonID: String?, episodeContext: EpisodeSequence?, presentation: SeriesPresentation = SeriesPresentation()) {
        guard !terminating else { return }
        endToolbarRefresh()
        detailTask?.cancel(); detailTask = nil
        let existingContext = episodeContext
        detailEpisodeSequence = item.type == "Episode" && existingContext?.orderedEpisodes.contains(where: { $0.id == item.id }) == true ? existingContext : nil
        detailMetadataID = item.id
        detail = item; detailLoading = true
        let requestID = UUID(); detailGeneration = requestID
        resetSeries()
        seriesPresentation = presentation
        guard let connection else { detailLoading = false; return }
        if item.type == "Series" { loadSeries(item.id, connection: connection, preferredSeasonID: preferredSeasonID) }
        detailTask = Task {
            defer { if detailGeneration == requestID { detailTask = nil } }
            do {
                try Task.checkCancellation()
                guard !terminating else { return }
                let full = try await client(for: connection).item(id: item.id)
                try Task.checkCancellation()
                guard !terminating, detailGeneration == requestID, saved.selectedID == connection.id else { return }
                guard full.id == item.id else { throw MediaServerError.invalidResponse }
                detail = full; detailLoading = false
            } catch is CancellationError { }
            catch {
                guard !terminating, detailGeneration == requestID, saved.selectedID == connection.id else { return }
                discardDeniedBrowseHistory(error)
                errorMessage = error.localizedDescription; detailLoading = false
            }
        }
    }
    private func resetSeries() {
        seriesTask?.cancel(); seriesTask = nil
        seriesGeneration = UUID(); displayedSequence = nil
        seasons = []; episodes = []; selectedSeasonID = ""; seriesLoading = false; seriesError = nil
        seriesPresentation = SeriesPresentation()
    }
    private func loadSeries(_ seriesID: String, connection: ServerConnection, preferredSeasonID: String?) {
        guard !terminating else { return }
        seriesTask?.cancel()
        let requestID = UUID(); seriesGeneration = requestID; seriesLoading = true
        seriesTask = Task {
            defer { if seriesGeneration == requestID { seriesTask = nil } }
            do {
                try Task.checkCancellation()
                guard !terminating else { return }
                let api = try client(for: connection)
                async let loadedSeasons = api.seasons(seriesID: seriesID)
                async let loadedEpisodes = api.episodes(seriesID: seriesID, seasonID: nil)
                let (newSeasons, allEpisodes) = try await (loadedSeasons, loadedEpisodes)
                try Task.checkCancellation()
                guard !terminating, seriesGeneration == requestID, detail?.id == seriesID, saved.selectedID == connection.id else { return }
                let sequence = EpisodeSequence(seriesID: seriesID, episodes: allEpisodes, seasons: newSeasons)
                displayedSequence = sequence; seasons = newSeasons
                let selection: String
                if let preferredSeasonID, preferredSeasonID.isEmpty || newSeasons.contains(where: { $0.id == preferredSeasonID }) { selection = preferredSeasonID }
                else { selection = newSeasons.first?.id ?? "" }
                selectedSeasonID = selection
                episodes = selection.isEmpty ? sequence.orderedEpisodes : sequence.episodes(in: selection)
                seriesLoading = false
            } catch is CancellationError { }
            catch {
                guard !terminating, seriesGeneration == requestID, saved.selectedID == connection.id else { return }
                seriesError = error.localizedDescription; seriesLoading = false
            }
        }
    }
    var previewEpisode: MediaItem? {
        episodes.first { $0.id == seriesPresentation.selectedEpisodeID }
    }
    var seriesPlaybackCandidate: MediaItem? { previewEpisode ?? displayedSequence?.resumeCandidate }

    func showAllEpisodes() {
        guard detail?.type == "Series", !seriesPresentation.showsAll else { return }
        recordBrowserDeparture()
        seriesPresentation.showsAll = true
        seriesPresentation.returnsToPreview = true
    }

    func selectEpisodeBatch(_ index: Int) {
        guard index >= 0, !episodes.isEmpty, index <= (episodes.count - 1) / 10 else { return }
        seriesPresentation.batch = index
    }

    func preview(_ episode: MediaItem) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        if seriesPresentation.showsAll && seriesPresentation.returnsToPreview { goBackFromDetail() }
        else { seriesPresentation.showsAll = false }
        seriesPresentation.batch = index / 10
        seriesPresentation.selectedEpisodeID = episode.id
    }
    /// Resolve an unknown parent before committing visual navigation. A caller
    /// may synchronously prepare its transition and call showDetail only once
    /// this lookup is still current and validated. History returns stay local.
    func showSeries(for episode: MediaItem, commitResolved: ((MediaItem) -> Void)? = nil) {
        guard !terminating, let seriesID = episode.seriesID ?? detailEpisodeSequence?.seriesID, let connection else { return }
        endToolbarRefresh()
        cancelResumeWatching()
        if let index = detailHistory.lastIndex(where: { $0.item.id == seriesID && $0.item.type == "Series" }) {
            browseHistory.returnFromDetail(currentBrowseVisit, to: seriesID, on: detailOriginPage)
            let previous = detailHistory[index]
            detailHistory.removeSubrange(index...)
            openDetail(previous.item, preferredSeasonID: previous.seasonID, episodeContext: previous.sequence, presentation: previous.seriesPresentation)
            seriesPresentation.showsAll = true
            return
        }
        detailTask?.cancel()
        detailMetadataID = nil
        let requestID = UUID(); detailGeneration = requestID; detailLoading = true
        detailTask = Task {
            defer { if detailGeneration == requestID { detailTask = nil } }
            do {
                try Task.checkCancellation()
                guard !terminating else { return }
                let series = try await client(for: connection).item(id: seriesID)
                try Task.checkCancellation()
                guard !terminating, detailGeneration == requestID, saved.selectedID == connection.id else { return }
                guard series.id == seriesID, series.type == "Series" else { throw MediaServerError.invalidResponse }
                if let commitResolved { commitResolved(series) }
                else { showDetail(series) }
                if detail?.id == seriesID { seriesPresentation.showsAll = true }
            } catch is CancellationError { }
            catch {
                guard !terminating, detailGeneration == requestID, saved.selectedID == connection.id else { return }
                detailLoading = false; errorMessage = error.localizedDescription
            }
        }
    }
    func selectSeason(_ id: String) {
        guard !terminating, let sequence = displayedSequence, id.isEmpty || seasons.contains(where: { $0.id == id }) else { return }
        if selectedSeasonID != id {
            seriesPresentation.batch = 0
            seriesPresentation.selectedEpisodeID = nil
        }
        selectedSeasonID = id; episodes = id.isEmpty ? sequence.orderedEpisodes : sequence.episodes(in: id)
    }
    func dismissDetail() {
        cancelResumeWatching()
        detailTask?.cancel(); detailTask = nil
        detailHistory = []
        detailGeneration = UUID(); detail = nil; detailLoading = false; detailEpisodeSequence = nil; resetSeries()
    }
    /// Resolve a browser resume intent without taking ownership of the current
    /// playback session. Only a definite target/version may replace that session.
    func resumeWatching(_ item: MediaItem) {
        guard let connection, canBrowseCurrentMedia, !terminating, !userStateBusy, !userStateNeedsRefresh else { return }
        cancelResumeWatching()
        if let active = player, active.isActive, active.connection.id == connection.id,
           active.item.id == item.id || (item.type == "Series" && (active.item.seriesID == item.id || active.episodeSequence?.seriesID == item.id)) {
            requestPlayback(active.item, mode: active.requestedMode, mediaSourceID: active.requestedMediaSourceID)
            return
        }
        guard item.isPlayable || item.type == "Series" else { showDetail(item); return }
        let requestID = resumeGeneration
        let openingScreen = Self.currentPlaybackScreen
        resumeLoadingID = item.id
        resumeTask = Task {
            defer {
                if resumeGeneration == requestID { resumeLoadingID = nil; resumeTask = nil }
            }
            do {
                let api = try client(for: connection)
                var sequence: EpisodeSequence?
                let target: MediaItem
                if item.type == "Series" {
                    async let loadedSeasons = api.seasons(seriesID: item.id)
                    async let loadedEpisodes = api.episodes(seriesID: item.id, seasonID: nil)
                    let (newSeasons, allEpisodes) = try await (loadedSeasons, loadedEpisodes)
                    try Task.checkCancellation()
                    guard resumeIntentIsCurrent(requestID, connection: connection) else { return }
                    let resolved = EpisodeSequence(seriesID: item.id, episodes: allEpisodes, seasons: newSeasons)
                    guard let episode = BrowseResumeSelection.target(in: resolved, rawEpisodes: allEpisodes) else {
                        showDetail(item)
                        return
                    }
                    target = episode; sequence = resolved
                } else { target = item }
                // Summary tiles may omit versions. Inspect fresh metadata before
                // changing the old playback generation or cancelling its EOF gate.
                let fresh = try await api.item(id: target.id)
                try Task.checkCancellation()
                guard resumeIntentIsCurrent(requestID, connection: connection) else { return }
                guard fresh.id == target.id, fresh.isPlayable else { throw MediaServerError.invalidResponse }
                if let sequence {
                    guard fresh.type == "Episode", fresh.seriesID == nil || fresh.seriesID == sequence.seriesID else { throw MediaServerError.invalidResponse }
                }
                let sourceIDs = Set(fresh.mediaSources.map(\.id))
                if sourceIDs.count > 1 {
                    showDetail(fresh)
                    if fresh.type == "Episode" { detailEpisodeSequence = sequence }
                    return
                }
                // A sole known edition is explicit even if subsequent server
                // metadata adds another version; the playback planner must not
                // silently choose a different timeline.
                let sourceID = sourceIDs.first
                let previousPlaybackGeneration = playbackGeneration
                requestPlayback(fresh, mediaSourceID: sourceID, resolvedSequence: sequence, openingScreen: openingScreen)
                if launchingPlayback, playbackGeneration != previousPlaybackGeneration {
                    resumePlaybackIntent = playbackGeneration
                    resumeLoadingID = item.id
                }
            } catch is CancellationError { }
            catch {
                guard resumeIntentIsCurrent(requestID, connection: connection) else { return }
                showDetail(item)
                displayError("暂时无法确认续播内容，请在详情中重试或选择播放资源。\n" + error.localizedDescription)
            }
        }
    }
    private func resumeIntentIsCurrent(_ requestID: UUID, connection: ServerConnection) -> Bool {
        !terminating && !userStateBusy && !userStateBlocksPlayback(for: connection)
            && resumeGeneration == requestID && saved.selectedID == connection.id
            && saved.connections.contains(where: { $0.id == connection.id && $0.certificatePin == connection.certificatePin })
            && !revokingConnections.contains(connection.id)
    }
    private func clearResumePreflight() {
        resumeGeneration = UUID(); resumeTask?.cancel(); resumeTask = nil; resumeLoadingID = nil
    }
    private func cancelResumeWatching() {
        clearResumePreflight()
        // Once a resolved resume has entered real playback preparation, browser
        // cancellation can invalidate that new intent. Preflight never owns the
        // existing player's completion generation or natural-end gate.
        if resumePlaybackIntent != nil { invalidatePlaybackIntent() }
    }
    func requestEpisodePlayback(_ item: MediaItem, fromBeginning: Bool = false) {
        guard item.type == "Episode" else { return }
        requestPlayback(item, fromBeginning: fromBeginning)
    }
    struct RecoveryPrompt: Identifiable {
        let id = UUID()
        let item: MediaItem
        let connection: ServerConnection
        let mode: PlaybackMode
        let mediaSourceID: String?
        let remoteTicks: Int64
        let localTicks: Int64
        let generation: UUID
        let sequence: EpisodeSequence?
        let reuseWindow: Bool
        let autoPlayNext: Bool
        let continuationOwner: NativePlaybackController?
        let manualSwitchID: UUID?
        let playbackDefaults: ApplicationPreferences
    }
    /// Invalidate synchronously before awaiting a stop, metadata request, or window close.
    private func invalidatePlaybackIntent() {
        clearResumePreflight(); resumePlaybackIntent = nil
        playbackGeneration = UUID(); recoveryPrompt = nil; launchingPlayback = false
        playbackOpeningScreen = nil
        player?.cancelAutomaticContinuation()
        player?.cancelEpisodeSwitch()
    }
    private func playbackIntentIsCurrent(_ requestID: UUID, connection: ServerConnection) -> Bool {
        !terminating && !userStateBlocksPlayback(for: connection) && playbackGeneration == requestID && saved.selectedID == connection.id
            && saved.connections.contains(where: { $0.id == connection.id && $0.certificatePin == connection.certificatePin })
            && !revokingConnections.contains(connection.id)
    }
    private func continuationIsCurrent(_ owner: NativePlaybackController?, manualSwitchID: UUID?) -> Bool {
        guard let owner else { return true }
        guard player === owner else { return false }
        if let manualSwitchID { return owner.isEpisodeSwitchCurrent(manualSwitchID) }
        return owner.autoPlayNextEpisode && owner.canAutomaticallyContinue
    }
    func requestEpisodeSwitch(to itemID: String, from owner: NativePlaybackController, fromBeginning: Bool = false) {
        guard !userStateBusy, !userStateNeedsRefresh, player === owner, owner.canSelectEpisode, let sequence = owner.episodeSequence,
              let target = sequence.orderedEpisodes.first(where: { $0.id == itemID }),
              fromBeginning || target.id != owner.item.id || !owner.isActive,
              connection?.id == owner.connection.id, !terminating else { return }
        invalidatePlaybackIntent()
        let requestID = playbackGeneration
        let switchID = owner.beginEpisodeSwitch()
        launchingPlayback = true
        Task {
            await preparePlayback(target, connection: owner.connection, mode: owner.requestedMode, mediaSourceID: nil,
                                  fromBeginning: fromBeginning, sequence: sequence, requestID: requestID,
                                  reuseWindow: true, autoPlayNext: owner.autoPlayNextEpisode,
                                  continuationOwner: owner, manualSwitchID: switchID)
        }
    }
    private static var currentPlaybackScreen: NSRect? {
        let app = NSApplication.shared
        let screen = app.keyWindow?.screen ?? app.mainWindow?.screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    func requestPlayback(_ item: MediaItem, mode: PlaybackMode = .automatic, mediaSourceID: String? = nil,
                         fromBeginning: Bool = false, resolvedSequence: EpisodeSequence? = nil, openingScreen: NSRect? = nil) {
        guard let connection, canBrowseCurrentMedia, item.isPlayable, !terminating, !userStateBusy, !userStateNeedsRefresh else { return }
        if !fromBeginning, let active = player, active.isActive,
           active.connection.id == connection.id, active.item.id == item.id,
           active.requestedMode == mode, active.requestedMediaSourceID == mediaSourceID {
            if let focusPlayback { focusPlayback() }
            else { playerWindow?.showWindow(nil); playerWindow?.window?.makeKeyAndOrderFront(nil) }
            return
        }
        let candidateSequence = resolvedSequence ?? displayedSequence ?? detailEpisodeSequence
        let sequence = candidateSequence?.orderedEpisodes.contains(where: { $0.id == item.id }) == true ? candidateSequence : nil
        invalidatePlaybackIntent()
        // Capture the launching display before metadata fetches or a recovery prompt can change focus.
        playbackOpeningScreen = openingScreen ?? Self.currentPlaybackScreen
        let requestID = playbackGeneration; launchingPlayback = true
        let defaults = applicationPreferences
        Task { await preparePlayback(item, connection: connection, mode: mode, mediaSourceID: mediaSourceID,
                                     fromBeginning: fromBeginning, sequence: sequence, requestID: requestID,
                                     reuseWindow: false, autoPlayNext: defaults.autoPlayNextEpisode,
                                     playbackDefaults: defaults) }
    }
    private func preparePlayback(_ item: MediaItem, connection: ServerConnection, mode: PlaybackMode, mediaSourceID: String?,
                                 fromBeginning: Bool, sequence: EpisodeSequence?, requestID: UUID,
                                 reuseWindow: Bool, autoPlayNext: Bool, continuationOwner: NativePlaybackController? = nil,
                                 manualSwitchID: UUID? = nil, playbackDefaults: ApplicationPreferences? = nil) async {
        let defaults = continuationOwner?.playbackDefaults ?? playbackDefaults ?? applicationPreferences
        func isCurrent() -> Bool {
            playbackIntentIsCurrent(requestID, connection: connection)
                && continuationIsCurrent(continuationOwner, manualSwitchID: manualSwitchID)
        }
        defer {
            if playbackGeneration == requestID {
                launchingPlayback = false
                if resumePlaybackIntent == requestID { resumeLoadingID = nil }
            }
            if let manualSwitchID, continuationOwner?.isEpisodeSwitchCurrent(manualSwitchID) == true,
               continuationOwner?.episodeRecoveryChoice == nil { continuationOwner?.cancelEpisodeSwitch() }
        }
        do {
            guard isCurrent() else { return }
            // Natural completion already finalized this owner. A second manual stop would cancel its handoff.
            if let manualSwitchID, let owner = continuationOwner {
                await owner.stop(forEpisodeSwitch: manualSwitchID)
                guard isCurrent() else { return }
                guard owner.recoverProgressForEpisodeSwitch() else {
                    owner.nextEpisodeMessage = "当前集进度未能保存到本机或服务器，已停止切换。请检查连接和磁盘后再试。"
                    return
                }
            } else if continuationOwner == nil, let previous = player { await previous.stop() }
            guard isCurrent() else { return }
            let api = try client(for: connection)
            let full = try await api.item(id: item.id)
            guard isCurrent() else { return }
            guard full.id == item.id, full.isPlayable else { throw MediaServerError.invalidResponse }
            if manualSwitchID != nil, let sequence {
                guard full.type == "Episode", full.seriesID == nil || full.seriesID == sequence.seriesID else { throw MediaServerError.invalidResponse }
            }
            var context = sequence
            if full.type == "Episode", context == nil, let seriesID = full.seriesID ?? item.seriesID {
                // Navigation is optional: a server without a usable series index can still play this episode.
                do {
                    async let allEpisodes = api.episodes(seriesID: seriesID, seasonID: nil)
                    async let allSeasons = api.seasons(seriesID: seriesID)
                    let (episodes, seasons) = try await (allEpisodes, allSeasons)
                    context = EpisodeSequence(seriesID: seriesID, episodes: episodes, seasons: seasons)
                } catch { context = nil }
            }
            guard isCurrent() else { return }
            let remote = fromBeginning || full.userData.played ? 0 : full.userData.playbackPositionTicks
            if !fromBeginning, let local = recovery(for: full.id, connection: connection), !local.confirmed, abs(local.ticks - remote) > 10_000_000 {
                let prompt = RecoveryPrompt(item: full, connection: connection, mode: mode, mediaSourceID: mediaSourceID,
                                               remoteTicks: remote, localTicks: local.ticks, generation: requestID,
                                               sequence: context, reuseWindow: reuseWindow, autoPlayNext: autoPlayNext,
                                               continuationOwner: continuationOwner, manualSwitchID: manualSwitchID,
                                               playbackDefaults: defaults)
                if manualSwitchID != nil, let owner = continuationOwner {
                    owner.episodeRecoveryChoice = EpisodeRecoveryChoice(localTicks: local.ticks, remoteTicks: remote)
                    owner.onChooseEpisodeRecovery = { [weak self] local in self?.resolveRecovery(prompt, local: local) }
                    owner.onCancelEpisodeRecovery = { [weak self, weak owner] in
                        guard let self, let owner, self.player === owner,
                              self.playbackIntentIsCurrent(requestID, connection: connection) else { return }
                        self.invalidatePlaybackIntent()
                        owner.nextEpisodeMessage = "已取消切换，可重新选择单集。"
                    }
                } else {
                    recoveryPrompt = prompt
                    continuationOwner?.nextEpisodeMessage = "下一集有不同的续播记录，请在主窗口选择播放位置。"
                    NSApplication.shared.windows.first { $0.title == "SeatSix" }?.makeKeyAndOrderFront(nil)
                }
                return
            }
            await startPlayback(full, connection: connection, mode: mode, mediaSourceID: mediaSourceID, ticks: remote,
                                sequence: context, requestID: requestID, reuseWindow: reuseWindow, autoPlayNext: autoPlayNext,
                                continuationOwner: continuationOwner, manualSwitchID: manualSwitchID, playbackDefaults: defaults)
        } catch {
            if isCurrent() {
                if let continuationOwner {
                    continuationOwner.nextEpisodeMessage = "切换未能完成，可在播放器中重新选集。"
                } else { errorMessage = error.localizedDescription }
            }
        }
    }
    func chooseRecovery(local: Bool) {
        guard let prompt = recoveryPrompt else { return }
        recoveryPrompt = nil
        resolveRecovery(prompt, local: local)
    }
    func playbackPausedForMinimization(_ owner: NativePlaybackController) {
        guard player === owner, let prompt = recoveryPrompt,
              prompt.continuationOwner === owner, prompt.manualSwitchID == nil else { return }
        recoveryPrompt = nil
        owner.nextEpisodeMessage = "已因最小化暂停，可重新选择单集。"
    }
    private func resolveRecovery(_ prompt: RecoveryPrompt, local: Bool) {
        guard playbackIntentIsCurrent(prompt.generation, connection: prompt.connection),
              continuationIsCurrent(prompt.continuationOwner, manualSwitchID: prompt.manualSwitchID) else { return }
        prompt.continuationOwner?.episodeRecoveryChoice = nil
        prompt.continuationOwner?.onChooseEpisodeRecovery = nil
        prompt.continuationOwner?.onCancelEpisodeRecovery = nil
        launchingPlayback = true
        Task {
            await startPlayback(prompt.item, connection: prompt.connection, mode: prompt.mode, mediaSourceID: prompt.mediaSourceID,
                                ticks: local ? prompt.localTicks : prompt.remoteTicks, sequence: prompt.sequence,
                                requestID: prompt.generation, reuseWindow: prompt.reuseWindow, autoPlayNext: prompt.autoPlayNext,
                                continuationOwner: prompt.continuationOwner, manualSwitchID: prompt.manualSwitchID,
                                playbackDefaults: prompt.playbackDefaults)
            if let switchID = prompt.manualSwitchID, prompt.continuationOwner?.isEpisodeSwitchCurrent(switchID) == true {
                prompt.continuationOwner?.cancelEpisodeSwitch()
            }
            if playbackGeneration == prompt.generation { launchingPlayback = false }
        }
    }
    private func startPlayback(_ item: MediaItem, connection: ServerConnection, mode: PlaybackMode, mediaSourceID: String?, ticks: Int64,
                               sequence: EpisodeSequence?, requestID: UUID, reuseWindow: Bool, autoPlayNext: Bool,
                               continuationOwner: NativePlaybackController? = nil, manualSwitchID: UUID? = nil,
                               playbackDefaults: ApplicationPreferences) async {
        guard playbackIntentIsCurrent(requestID, connection: connection) else { return }
        guard continuationIsCurrent(continuationOwner, manualSwitchID: manualSwitchID) else { return }
        // From this point the playback window, rather than the browsing page, owns
        // the intent. Returning to the library must not cancel its future episodes.
        if resumePlaybackIntent == requestID { resumePlaybackIntent = nil; resumeLoadingID = nil }
        let startTicks = ResumeRewindPolicy.startTicks(ticks, seconds: playbackDefaults.resumeRewindSeconds,
                                                     isContinuation: continuationOwner != nil)
        if let playbackLauncher {
            await playbackLauncher(item, connection, mode, mediaSourceID, startTicks)
            return
        }
        do {
            let api = try client(for: connection)
            let controller = NativePlaybackController(item: item, connection: connection, client: api, mediaSourceID: mediaSourceID, applicationPreferences: playbackDefaults) { [weak self] ticks, confirmed in
                self?.saveRecovery(item: item.id, connection: connection, ticks: ticks, confirmed: confirmed) ?? false
            }
            controller.preferenceAccess = playbackPreferencesAccess(item: item.id, connection: connection)
            controller.updateInterfacePreferences(applicationPreferences)
            controller.configureSeriesSkip(seriesPlaybackPreferencesAccess(item: item, sequence: sequence, connection: connection))
            controller.autoPlayNextEpisode = autoPlayNext
            controller.episodeSequence = sequence
            controller.onMinimizePause = { [weak self, weak controller] in
                guard let controller else { return }
                self?.playbackPausedForMinimization(controller)
            }
            controller.onSelectEpisode = { [weak self, weak controller] itemID, fromBeginning in
                guard let controller else { return }
                self?.requestEpisodeSwitch(to: itemID, from: controller, fromBeginning: fromBeginning)
            }
            flushPlaybackVolume()
            if let continuationOwner {
                controller.inheritContinuationVolume(from: continuationOwner)
                controller.inheritContinuationPlaybackRate(from: continuationOwner)
            } else if playbackDefaults.rememberVolume { controller.applyInitialVolume(rememberedPlaybackVolume) }
            controller.onVolumeChange = { [weak self, weak controller] state in
                guard let controller else { return }
                self?.rememberPlaybackVolume(state, from: controller)
            }
            controller.nextEpisodeMessage = continuationOwner?.episodeProgressWarning
            controller.onNaturalCompletion = { [weak self] completed in
                await self?.advanceEpisode(after: completed, sequence: sequence, requestID: requestID)
            }
            if reuseWindow, let window = playerWindow, window.canReplaceController {
                player = controller; window.replaceController(controller)
            } else {
                // Clear ownership before closing the old window: its callback cannot clear this new session.
                let oldWindow = playerWindow
                let openingScreen = (reuseWindow ? oldWindow?.window?.screen?.visibleFrame : playbackOpeningScreen)
                    ?? Self.currentPlaybackScreen
                player = controller; playerWindow = nil
                oldWindow?.close()
                let window = PlaybackWindowController(controller: controller, openingScreen: openingScreen, onClosing: { [weak self] closingController in
                    guard self?.player === closingController else { return }
                    self?.flushPlaybackVolume()
                    self?.invalidatePlaybackIntent()
                }, onClose: { [weak self] closedController in
                    guard let self, self.player === closedController else { return }
                    self.flushPlaybackVolume()
                    self.invalidatePlaybackIntent(); self.player = nil; self.playerWindow = nil
                    if self.connection?.id == connection.id { self.refresh(preservingHomeRecommendations: true) }
                    NSApplication.shared.windows.first { $0.title == "SeatSix" }?.makeKeyAndOrderFront(nil)
                })
                playerWindow = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
            }
            await controller.load(mode: mode, mediaSourceID: mediaSourceID, startTicks: startTicks)
        } catch {
            if playbackIntentIsCurrent(requestID, connection: connection) {
                if let continuationOwner { continuationOwner.nextEpisodeMessage = "切换未能完成，可在播放器中重新选集。" }
                else { errorMessage = error.localizedDescription }
            }
        }
    }
    /// Called only after this episode's final progress write and engine teardown complete.
    func advanceEpisode(after controller: NativePlaybackController, sequence: EpisodeSequence?, requestID: UUID) async {
        guard !userStateBlocksPlayback(for: controller.connection), player === controller, controller.item.type == "Episode", controller.autoPlayNextEpisode, controller.canAutomaticallyContinue,
              playbackIntentIsCurrent(requestID, connection: controller.connection) else { return }
        guard controller.recoverProgressForEpisodeSwitch() else {
            controller.nextEpisodeMessage = "当前集进度未能保存到本机或服务器，已停止自动连播。请检查连接和磁盘后重新选集。"
            return
        }
        guard let sequence, let next = sequence.next(after: controller.item.id) else {
            controller.nextEpisodeMessage = "本剧已播放完，或暂无可播放的下一集"
            return
        }
        launchingPlayback = true
        await preparePlayback(next, connection: controller.connection, mode: controller.requestedMode, mediaSourceID: nil,
                              fromBeginning: false, sequence: sequence, requestID: requestID,
                              reuseWindow: true, autoPlayNext: controller.autoPlayNextEpisode, continuationOwner: controller)
    }
    func recovery(for itemID: String, connection: ServerConnection) -> RecoveryPoint? {
        saved.recovery.first { $0.serverID == connection.serverID && $0.userID == connection.userID && $0.itemID == itemID }
    }

    func playbackPreferences(item: String, connection: ServerConnection, mediaSourceID: String) -> FilmPlaybackPreferences {
        let identity = FilmPlaybackIdentity(connection: connection, itemID: item, mediaSourceID: mediaSourceID)
        return saved.playbackPreferences.first { $0.identity == identity } ?? FilmPlaybackPreferences(identity: identity)
    }

    func seriesPlaybackPreferences(seriesID: String, connection: ServerConnection) -> SeriesPlaybackPreferences {
        let identity = SeriesPlaybackIdentity(connection: connection, seriesID: seriesID)
        return saved.seriesPlaybackPreferences.first { $0.identity == identity } ?? SeriesPlaybackPreferences(identity: identity)
    }

    func saveSeriesPlaybackPreferences(_ preferences: SeriesPlaybackPreferences) throws {
        _ = try preferences.settings.validated()
        guard !preferences.identity.seriesID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !revokingConnections.contains(preferences.identity.connectionID),
              saved.connections.contains(where: {
                  $0.id == preferences.identity.connectionID && $0.serverID == preferences.identity.serverID
                      && $0.userID == preferences.identity.userID
              }) else { throw ApplicationPersistenceError.unavailable }
        var candidate = saved
        var updated = preferences; updated.updatedAt = Date()
        candidate.seriesPlaybackPreferences.removeAll { $0.identity == updated.identity }
        candidate.seriesPlaybackPreferences.append(updated)
        try write(candidate)
        saved = candidate
    }

    func seriesPlaybackPreferencesAccess(item: MediaItem, sequence: EpisodeSequence?, connection: ServerConnection) -> SeriesPlaybackPreferencesAccess? {
        guard item.type == "Episode" else { return nil }
        let seriesID: String
        if let explicit = item.seriesID, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard sequence == nil || sequence?.seriesID == explicit else { return nil }
            seriesID = explicit
        } else {
            guard let sequence, sequence.orderedEpisodes.contains(where: { $0.id == item.id }),
                  !sequence.seriesID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            seriesID = sequence.seriesID
        }
        let identity = SeriesPlaybackIdentity(connection: connection, seriesID: seriesID)
        return SeriesPlaybackPreferencesAccess(load: { [weak self] in
            self?.seriesPlaybackPreferences(seriesID: seriesID, connection: connection).settings ?? .init()
        }, save: { [weak self] settings in
            guard let self, !self.terminating else { throw ApplicationPersistenceError.unavailable }
            try self.saveSeriesPlaybackPreferences(.init(identity: identity, settings: settings))
        })
    }

    func savePlaybackPreferences(_ preferences: FilmPlaybackPreferences) throws {
        guard saved.connections.contains(where: {
            $0.id == preferences.identity.connectionID && $0.serverID == preferences.identity.serverID && $0.userID == preferences.identity.userID
        }) else { throw ApplicationPersistenceError.unavailable }
        if case .local(let archive) = preferences.subtitle {
            guard archive.connectionID == preferences.identity.connectionID else { throw SubtitleArchiveError.invalidReference }
            // Keep a missing remembered subtitle until the user explicitly
            // replaces it, without blocking independent audio/style changes.
            try subtitleArchive.validateReference(archive)
        }
        var candidate = saved
        var updated = preferences; updated.updatedAt = Date()
        candidate.playbackPreferences.removeAll { $0.identity == updated.identity }
        candidate.playbackPreferences.append(updated)
        try write(candidate)
        saved = candidate
    }

    func playbackPreferencesAccess(item: String, connection: ServerConnection) -> PlaybackPreferencesAccess {
        let archive = subtitleArchive
        // A new controller is created only after the previous player has stopped;
        // its private engine copies can no longer refer back to old archive choices.
        let references = saved.playbackPreferences.compactMap { preference -> ArchivedSubtitle? in
            if case .local(let reference) = preference.subtitle { return reference }
            return nil
        }
        archive.prune(connectionID: connection.id, keeping: references)
        return PlaybackPreferencesAccess(load: { [weak self] mediaSourceID in
            self?.playbackPreferences(item: item, connection: connection, mediaSourceID: mediaSourceID)
                ?? FilmPlaybackPreferences(identity: .init(connection: connection, itemID: item, mediaSourceID: mediaSourceID))
        }, save: { [weak self] preferences in
            guard let self, preferences.identity.connectionID == connection.id,
                  preferences.identity.serverID == connection.serverID, preferences.identity.userID == connection.userID,
                  preferences.identity.itemID == item else { throw ApplicationPersistenceError.unavailable }
            try self.savePlaybackPreferences(preferences)
        }, archive: { url in
            try await archive.archive(url: url, connectionID: connection.id)
        }, url: { reference in
            guard reference.connectionID == connection.id else { throw SubtitleArchiveError.invalidReference }
            return try archive.url(for: reference)
        }, discard: { reference in
            guard reference.connectionID == connection.id else { return }
            archive.discard(reference)
        })
    }
    @discardableResult
    func saveRecovery(item: String, connection: ServerConnection, ticks: Int64, confirmed: Bool) -> Bool {
        var point = RecoveryPoint(serverID: connection.serverID, userID: connection.userID, itemID: item, ticks: max(0,ticks), updatedAt: Date(), confirmed: confirmed)
        var candidate = saved
        candidate.recovery.removeAll { $0.id == point.id }
        candidate.recovery.append(point)
        if candidate.recovery.count > 200 { candidate.recovery = Array(candidate.recovery.suffix(200)) }
        do { try write(candidate); saved = candidate; return true }
        catch {
            // Keep a volatile recovery point for this process, but do not call an unpersisted record safe or confirmed.
            point.confirmed = false
            candidate.recovery.removeAll { $0.id == point.id }; candidate.recovery.append(point)
            saved = candidate
            return false
        }
    }
    func revokeCertificateTrust(_ id: UUID) async {
        guard saved.connections.contains(where: { $0.id == id && $0.certificatePin != nil }),
              !revokingConnections.contains(id) else { return }
        if player?.connection.id == id || saved.selectedID == id { invalidatePlaybackIntent() }
        revokingConnections.insert(id)
        defer { revokingConnections.remove(id) }
        if saved.selectedID == id { invalidateServerBrowse() }
        if userStateConnectionID == id { userStateTask?.cancel(); await userStateTask?.value }
        if saved.selectedID == id {
            generation = UUID(); detailGeneration = UUID(); playbackGeneration = UUID()
            libraryDiscovery = .idle
            browseTask?.cancel(); continuingLoading = false
        }
        if recoveryPrompt?.connection.id == id { recoveryPrompt = nil }
        if player?.connection.id == id { await player?.stop(); playerWindow?.close() }
        // Re-read after the awaited stop, which can persist the final playback position.
        guard let index = saved.connections.firstIndex(where: { $0.id == id }) else { return }
        var candidate = saved
        candidate.connections[index].certificatePin = nil
        do { try write(candidate) }
        catch {
            displayError(error.localizedDescription)
            if saved.selectedID == id { loading = false; catalogLoading = false; detailLoading = false; launchingPlayback = false }
            return
        }
        saved = candidate
        invalidatePosters(id)
        if saved.selectedID == id {
            posterRevision = UUID()
            invalidateWindowPalette()
            browseHistory = BrowseHistory()
            dismissDetail()
            libraries = []; items = []; continuing = []; clearHomeRecommendations()
            loading = false; catalogLoading = false; launchingPlayback = false
            total = 0; catalogComplete = false; catalogFailed = false
            displayError("已撤销此服务器的证书信任。重新登录时将再次验证证书。")
        }
    }
    private enum CertificateRevocationError: LocalizedError {
        case inProgress
        var errorDescription: String? { "正在断开此服务器连接，请稍后重试。" }
    }

    func removeConnection(_ id: UUID) async {
        guard !revokingConnections.contains(id) else { return }
        revokingConnections.insert(id)
        defer { revokingConnections.remove(id) }
        if saved.selectedID == id { invalidateServerBrowse() }
        if userStateConnectionID == id { userStateTask?.cancel(); await userStateTask?.value }
        if player?.connection.id == id || saved.selectedID == id { invalidatePlaybackIntent() }
        if player?.connection.id == id { await player?.stop(); playerWindow?.close() }
        guard let removed = saved.connections.first(where: { $0.id == id }) else { return }
        var candidate = saved
        candidate.connections.removeAll { $0.id == id }
        if !candidate.connections.contains(where: { $0.serverID == removed.serverID && $0.userID == removed.userID }) {
            candidate.pendingUserStates.removeAll { $0.serverID == removed.serverID && $0.userID == removed.userID }
            candidate.recovery.removeAll { $0.serverID == removed.serverID && $0.userID == removed.userID }
        }
        candidate.playbackPreferences.removeAll { $0.identity.connectionID == id }
        candidate.seriesPlaybackPreferences.removeAll { $0.identity.connectionID == id }
        candidate.librarySortPreferences.removeAll { $0.identity.connectionID == id }
        candidate.browsingLocations.removeAll { $0.connectionID == id }
        let removedSelection = candidate.selectedID == id
        if removedSelection {
            candidate.selectedID = candidate.connections.first?.id
        }
        do {
            let previousCredential = try credentialSnapshot(for: id)
            try credentials.remove(id)
            do { try write(candidate) }
            catch {
                try rollbackCredential(previousCredential, for: id, after: error)
                throw error
            }
        } catch { displayError(error.localizedDescription); return }
        tokens.removeValue(forKey: id); saved = candidate
        invalidatePosters(id)
        subtitleArchive.removeConnection(id)
        guard removedSelection else { return }
        invalidateWindowPalette()
        deniedCatalogScopes.removeAll()
        browseHistory = BrowseHistory()
        dismissDetail()
        generation = UUID(); detailGeneration = UUID(); playbackGeneration = UUID()
        resolvingBrowsingLocation = true; startupResolutionPending = false
        selectedLibraryID = ""; page = "home"
        libraries = []; items = []; continuing = []; detail = nil; total = 0; catalogComplete = false; catalogFailed = false
        resolvingBrowsingLocation = false
        refresh()
    }
    func shutdown() async {
        invalidateServerBrowse()
        terminating = true; invalidatePlaybackIntent(); browseTask?.cancel(); generation = UUID()
        // Invalidate before the first await. Even a completed transport callback
        // waiting on MainActor must not reopen detail or publish an exit error.
        detailGeneration = UUID(); seriesGeneration = UUID()
        detailTask?.cancel(); detailTask = nil
        seriesTask?.cancel(); seriesTask = nil
        libraryDiscovery = .idle
        loading = false; catalogLoading = false; continuingLoading = false; detailLoading = false; seriesLoading = false
        await userStateTask?.value
        await player?.stop(); flushPlaybackVolume(); try? persist()
    }
}
