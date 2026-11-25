import Foundation

public struct MediaServerClient: Sendable {
    public let connection: ServerConnection
    public let deviceID: String
    private let token: String
    private let session: URLSession

    public init(connection: ServerConnection, token: String, deviceID: String, session: URLSession? = nil) {
        self.connection = connection; self.token = token; self.deviceID = deviceID
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = CertificateSessionFactory.makeSession(pin: connection.certificatePin, configuration: configuration)
        }
    }

    public static func authenticate(kind: ServerKind, address: String, username: String, password: String, allowInsecureHTTP: Bool = false, deviceID: String, compatibilityMode: Bool = false, certificatePin: CertificatePin? = nil, session: URLSession? = nil) async throws -> AuthenticatedServer {
        let endpoint = try ServerEndpoint(address: address, allowInsecureHTTP: allowInsecureHTTP)
        if let certificatePin, (try? CertificatePin.origin(for: endpoint.baseURL)) != certificatePin.origin { throw MediaServerError.certificate(.originMismatch) }
        let seed = ServerConnection(kind: kind, name: kind.name, baseURL: endpoint.baseURL, serverID: "", userID: "", username: username, compatibilityMode: compatibilityMode, certificatePin: certificatePin)
        let client = MediaServerClient(connection: seed, token: "", deviceID: deviceID, session: session)
        let info: PublicServerInfo = compatibilityMode ? PublicServerInfo() : try await client.decode(path: ["System", "Info", "Public"])
        if let product = info.productName?.lowercased(), (kind == .emby && product.contains("jellyfin")) || (kind == .jellyfin && product.contains("emby")) { throw MediaServerError.wrongServerKind }
        let result: AuthenticationResponse = try await client.decode(path: ["Users", "AuthenticateByName"], method: "POST", body: ["Username": username, "Pw": password])
        guard !result.accessToken.isEmpty, !result.user.id.isEmpty, let serverID = result.serverID ?? info.id, !serverID.isEmpty else { throw MediaServerError.invalidResponse }
        if let publicID = info.id, let authID = result.serverID, publicID != authID { throw MediaServerError.invalidResponse }
        let connection = ServerConnection(kind: kind, name: info.serverName ?? kind.name, baseURL: endpoint.baseURL, serverID: serverID, userID: result.user.id, username: result.user.name ?? username, compatibilityMode: compatibilityMode, certificatePin: certificatePin)
        return AuthenticatedServer(connection: connection, token: result.accessToken)
    }

    public func identity(for item: MediaItem) -> MediaIdentity { MediaIdentity(serverID: connection.serverID, userID: connection.userID, itemID: item.id) }

    public func libraries() async throws -> [MediaLibrary] {
        let result: LibraryResult = try await decode(path: ["Users", connection.userID, "Views"])
        return result.items.filter { $0.collectionType == nil || ["movies", "tvshows", "mixed", "homevideos", "boxsets"].contains($0.collectionType!.lowercased()) }
    }

    public func items(libraryID: String, startIndex: Int = 0, search: String? = nil) async throws -> MediaPage {
        guard connection.libraryIDs.contains(libraryID) else { throw MediaServerError.invalidScope }
        var query = ["ParentId": libraryID, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Video", "Fields": "Overview,MediaSources,DateCreated,PrimaryImageAspectRatio", "EnableImages": "true", "EnableUserData": "true", "StartIndex": String(max(0, startIndex)), "Limit": "60", "SortBy": "DateCreated,SortName", "SortOrder": "Descending"]
        if connection.compatibilityMode { query["IncludeItemTypes"] = "Movie,Series" }
        else if let term = search?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty { query["SearchTerm"] = term }
        return try await decode(path: ["Users", connection.userID, "Items"], query: query)
    }

    public func item(id: String) async throws -> MediaItem {
        try await decode(path: ["Users", connection.userID, "Items", id])
    }

    public func setFavorite(item: MediaItem, isFavorite: Bool) async throws -> MediaItem {
        guard MediaUserStateCapabilities.canFavorite(item: item, connection: connection) else { throw MediaUserStateError.unsupportedAction }
        return try await mutateUserState(item: item, action: .favorite(isFavorite))
    }

    public func setPlayed(item: MediaItem, played: Bool) async throws -> MediaItem {
        guard MediaUserStateCapabilities.canSetPlayed(item: item, connection: connection) else { throw MediaUserStateError.unsupportedAction }
        return try await mutateUserState(item: item, action: .played(played))
    }

    private func mutateUserState(item original: MediaItem, action: MediaUserStateAction) async throws -> MediaItem {
        try Task.checkCancellation()
        let endpoint = try url(path: ["Users", connection.userID, action.resource, original.id])
        do {
            // A successful HTTP response is only an acknowledgement. Some servers
            // return UserData, others an empty body; always confirm with a fresh GET.
            _ = try await request(url: endpoint, method: action.enabled ? "POST" : "DELETE", body: nil)
        } catch let error as MediaServerError {
            switch error {
            case .network, .invalidResponse: throw MediaUserStateError.outcomeUncertain
            case .httpStatus(let status) where status >= 500: throw MediaUserStateError.outcomeUncertain
            default: throw error
            }
        } catch {
            // Cancellation after dispatch cannot prove the write did not reach the server.
            throw MediaUserStateError.outcomeUncertain
        }
        do {
            try Task.checkCancellation()
            let refreshed = try await item(id: original.id)
            guard refreshed.id == original.id, refreshed.type == original.type,
                  refreshed.userData.playbackPositionKnown, refreshed.userData.playbackPositionTicks >= 0,
                  refreshed.userData.playedKnown, refreshed.userData.isFavoriteKnown,
                  action.isConfirmed(by: refreshed.userData) else { throw MediaUserStateError.outcomeUncertain }
            return refreshed
        } catch {
            throw MediaUserStateError.outcomeUncertain
        }
    }

    /// The normal library always reads the complete catalog. Favorites can ask
    /// the server for fewer rows, but the caller still checks UserData because
    /// some servers ignore filters. Totals and offsets describe the raw pages.
    public func libraryCatalog(libraryID: String, requestFavorites: Bool = false, maximumItems: Int = 100_000, onProgress: @escaping @Sendable (LibraryCatalogSnapshot) async -> Void = { _ in }) async throws -> LibraryCatalogSnapshot {
        guard connection.libraryIDs.contains(libraryID) else { throw MediaServerError.invalidScope }
        let maximumItems = min(100_000, max(0, maximumItems))
        var items: [MediaItem] = []
        var seen: Set<String> = []
        var expectedTotal: Int?
        let types: String
        if connection.compatibilityMode { types = "Movie,Series" }
        else { types = requestFavorites ? "Movie,Series,Video,Episode" : "Movie,Series,Video" }
        while true {
            try Task.checkCancellation()
            let offset = items.count
            var query = ["ParentId": libraryID, "Recursive": "true", "IncludeItemTypes": types, "Fields": "Overview,Genres,SortName,DateCreated,PrimaryImageAspectRatio", "EnableImages": "true", "EnableUserData": "true", "EnableTotalRecordCount": "true", "StartIndex": String(offset), "Limit": "60", "SortBy": "SortName", "SortOrder": "Ascending"]
            if requestFavorites { query["Filters"] = "IsFavorite" }
            let page: SeriesPage = try await decode(path: ["Users", connection.userID, "Items"], query: query)
            try Task.checkCancellation()
            guard let total = page.totalRecordCount, total >= 0,
                  page.startIndex == nil || page.startIndex == offset else { throw LibraryCatalogError.invalidPage }
            guard total <= maximumItems else { throw LibraryCatalogError.tooLarge }
            if let expectedTotal, expectedTotal != total { throw LibraryCatalogError.changedDuringLoading }
            expectedTotal = total
            guard page.items.count <= total - offset,
                  !page.items.isEmpty || offset == total else { throw LibraryCatalogError.invalidPage }
            // Validate the entire page before publishing or accepting any of its rows.
            var pageIDs: Set<String> = []
            for item in page.items {
                guard Self.validPlaybackIdentifier(item.id), !seen.contains(item.id), pageIDs.insert(item.id).inserted else { throw LibraryCatalogError.invalidPage }
            }
            seen.formUnion(pageIDs)
            items.append(contentsOf: page.items)
            let snapshot = LibraryCatalogSnapshot(items: items, total: total, isComplete: items.count == total)
            await onProgress(snapshot)
            try Task.checkCancellation()
            if snapshot.isComplete { return snapshot }
        }
    }

    public func seasons(seriesID: String) async throws -> [MediaItem] {
        let items = try await seriesChildren(seriesID: seriesID, seasonID: nil, kind: "Seasons", paginated: !connection.compatibilityMode && connection.kind == .emby)
        return items.filter { $0.type == "Season" }
    }

    public func episodes(seriesID: String, seasonID: String? = nil) async throws -> [MediaItem] {
        let items = try await seriesChildren(seriesID: seriesID, seasonID: seasonID, kind: "Episodes", paginated: !connection.compatibilityMode)
        return items.filter { $0.type == "Episode" }
    }

    /// Return a complete list or fail. A truncated queue must never select a false next episode.
    private func seriesChildren(seriesID: String, seasonID: String?, kind: String, paginated: Bool) async throws -> [MediaItem] {
        guard Self.validPlaybackIdentifier(seriesID), seasonID.map(Self.validPlaybackIdentifier) ?? true else { throw MediaServerError.invalidResponse }
        var query = ["UserId": connection.userID, "Fields": "Overview,MediaSources,MediaStreams,ParentId,PrimaryImageAspectRatio", "EnableImages": "true", "EnableUserData": "true"]
        if let seasonID { query["SeasonId"] = seasonID }
        if !connection.compatibilityMode { query["IsMissing"] = "false" }
        var result: [MediaItem] = []
        var seen: Set<String> = []
        var offset = 0
        var expectedTotal: Int?
        let maximumItems = 10_000
        for _ in 0..<100 {
            try Task.checkCancellation()
            if paginated { query["StartIndex"] = String(offset); query["Limit"] = "100" }
            let page: SeriesPage = try await decode(path: ["Shows", seriesID, kind], query: query)
            guard page.startIndex == nil || page.startIndex == offset,
                  page.items.count <= maximumItems - offset else { throw MediaServerError.invalidResponse }
            if let total = page.totalRecordCount {
                guard total >= 0, total <= maximumItems, expectedTotal == nil || expectedTotal == total,
                      offset + page.items.count <= total else { throw MediaServerError.invalidResponse }
                expectedTotal = total
            }
            for item in page.items {
                guard Self.validPlaybackIdentifier(item.id), seen.insert(item.id).inserted,
                      item.seriesID == nil || item.seriesID == seriesID else { throw MediaServerError.invalidResponse }
                if kind == "Seasons", let parent = item.parentID, parent != seriesID { throw MediaServerError.invalidResponse }
                if let seasonID, item.type == "Episode" {
                    guard item.seasonID == nil || item.seasonID == seasonID,
                          item.parentID == nil || item.parentID == seasonID else { throw MediaServerError.invalidResponse }
                }
            }
            result.append(contentsOf: page.items)
            offset += page.items.count
            if !paginated {
                guard expectedTotal == nil || expectedTotal == offset else { throw MediaServerError.invalidResponse }
                return result
            }
            if let expectedTotal, offset == expectedTotal { return result }
            if page.items.isEmpty {
                guard expectedTotal == nil else { throw MediaServerError.invalidResponse }
                return result
            }
        }
        throw MediaServerError.invalidResponse
    }

    public func resumeItems() async throws -> [MediaItem] {
        try await resumeItems(libraryIDs: connection.libraryIDs)
    }

    public func resumeItems(libraryIDs: [String]) async throws -> [MediaItem] {
        guard libraryIDs.allSatisfy(connection.libraryIDs.contains) else { throw MediaServerError.invalidScope }
        // This subset does not promise ParentId filtering on Resume; never leak other libraries.
        if connection.compatibilityMode { return [] }
        var result: [MediaItem] = []
        var seen: Set<String> = []
        var libraries: Set<String> = []
        for libraryID in libraryIDs where libraries.insert(libraryID).inserted {
            try Task.checkCancellation()
            let page: MediaPage = try await decode(path: ["Users", connection.userID, "Items", "Resume"], query: ["ParentId": libraryID, "Limit": "20", "MediaTypes": "Video", "Fields": "Overview,MediaSources,PrimaryImageAspectRatio", "EnableImages": "true", "EnableUserData": "true"])
            for item in page.items where seen.insert(item.id).inserted { result.append(item) }
        }
        return result
    }

    /// A full resume page is distinct from the deliberately short home rail.
    /// Each library is paginated independently; repeated IDs across libraries
    /// are merged, while repeated IDs inside a library indicate a broken page.
    public func completeResumeItems(libraryIDs: [String], maximumItems: Int = 100_000,
                                    onProgress: @escaping @Sendable ([MediaItem]) async -> Void = { _ in }) async throws -> [MediaItem] {
        guard libraryIDs.allSatisfy(connection.libraryIDs.contains) else { throw MediaServerError.invalidScope }
        if connection.compatibilityMode { return [] }
        let maximumItems = min(100_000, max(0, maximumItems))
        var uniqueLibraries: Set<String> = []
        var result: [MediaItem] = []
        var seenAcrossLibraries: Set<String> = []
        var acceptedCount = 0
        for libraryID in libraryIDs where uniqueLibraries.insert(libraryID).inserted {
            var offset = 0
            var expectedTotal: Int?
            var seenInLibrary: Set<String> = []
            while true {
                try Task.checkCancellation()
                let page: SeriesPage = try await decode(path: ["Users", connection.userID, "Items", "Resume"], query: [
                    "ParentId": libraryID, "StartIndex": String(offset), "Limit": "60", "MediaTypes": "Video",
                    "Fields": "Overview,MediaSources,PrimaryImageAspectRatio", "EnableImages": "true",
                    "EnableUserData": "true", "EnableTotalRecordCount": "true"
                ])
                try Task.checkCancellation()
                guard let total = page.totalRecordCount, total >= 0,
                      page.startIndex == nil || page.startIndex == offset else { throw LibraryCatalogError.invalidPage }
                guard total <= maximumItems - acceptedCount else { throw LibraryCatalogError.tooLarge }
                if let expectedTotal, total != expectedTotal { throw LibraryCatalogError.changedDuringLoading }
                expectedTotal = total
                guard page.items.count <= total - offset,
                      !page.items.isEmpty || offset == total else { throw LibraryCatalogError.invalidPage }
                var pageIDs: Set<String> = []
                for item in page.items {
                    guard Self.validPlaybackIdentifier(item.id), !seenInLibrary.contains(item.id),
                          pageIDs.insert(item.id).inserted else { throw LibraryCatalogError.invalidPage }
                }
                seenInLibrary.formUnion(pageIDs)
                for item in page.items where seenAcrossLibraries.insert(item.id).inserted { result.append(item) }
                offset += page.items.count
                await onProgress(result)
                try Task.checkCancellation()
                if offset == total { acceptedCount += total; break }
            }
        }
        return result
    }

    public func imageURL(item: MediaItem, width: Int = 600) -> URL? {
        guard let source = item.artworkSources(for: .poster).first else { return nil }
        return imageURL(source: source, width: width)
    }

    public func imageURL(source: MediaArtworkSource, width: Int = 600, role: MediaArtworkRole = .poster) -> URL? {
        guard source.isValid else { return nil }
        var path = ["Items", source.itemID, "Images", source.type.rawValue]
        // Compatible NAS interfaces expose the first backdrop at the unindexed
        // endpoint; /Backdrop/0 is not necessarily implemented by that subset.
        if let index = source.index,
           !(connection.compatibilityMode && source.type == .backdrop && index == 0) {
            path.append(String(index))
        }
        var query = ["Tag": source.tag, "MaxWidth": String(role.boundedWidth(width)), "Quality": "85"]
        if source.type == .logo { query["Format"] = "Png" }
        return try? url(path: path, query: query)
    }

    public func imageData(item: MediaItem, width: Int = 600) async throws -> Data? {
        guard let source = item.artworkSources(for: .poster).first else { return nil }
        return try await imageData(source: source, width: width)
    }

    public func imageData(source: MediaArtworkSource, width: Int = 600, role: MediaArtworkRole = .poster) async throws -> Data? {
        guard let imageURL = imageURL(source: source, width: width, role: role) else { return nil }
        try Task.checkCancellation()
        let data = try await request(url: imageURL, method: "GET", body: nil)
        // A server can ignore MaxWidth. Reject this image while allowing another
        // declared source to supply the artwork. Request and trust failures still throw.
        guard data.count <= 15 * 1024 * 1024 else { return nil }
        return data
    }

    public func playbackPlan(item: MediaItem, mediaSourceID: String? = nil, mode: PlaybackMode = .automatic, startTicks: Int64 = 0, capability: PlaybackCapability = .avFoundation) async throws -> PlaybackPlan {
        guard item.isPlayable else { throw MediaServerError.unsupportedMedia }
        let local = capability == .localDecoder
        if local && mode != .automatic { throw MediaServerError.unsupportedLocalMedia }
        guard Self.validPlaybackIdentifier(item.id), mediaSourceID.map(Self.validPlaybackIdentifier) ?? true else { throw MediaServerError.invalidResponse }
        if connection.compatibilityMode && mode == .compatible { throw MediaServerError.unsupportedCompatibilityMedia }
        var query = ["UserId": connection.userID, "StartTimeTicks": "0", "IsPlayback": "true", "AutoOpenLiveStream": "false", "MaxStreamingBitrate": "8000000", "MaxAudioChannels": "2", "AllowVideoStreamCopy": "false", "AllowAudioStreamCopy": "false", "EnableDirectPlay": mode == .automatic ? "true" : "false", "EnableDirectStream": "false", "EnableTranscoding": local || connection.compatibilityMode ? "false" : "true"]
        if local {
            query["MaxStreamingBitrate"] = "200000000"
            query.removeValue(forKey: "MaxAudioChannels")
            query["AllowVideoStreamCopy"] = "true"
            query["AllowAudioStreamCopy"] = "true"
        }
        if let mediaSourceID { query["MediaSourceId"] = mediaSourceID }
        let info: PlaybackInfo = try await decode(path: ["Items", item.id, "PlaybackInfo"], method: "POST", query: query, body: connection.compatibilityMode ? [:] : ["DeviceProfile": local ? Self.localDecoderProfile : Self.deviceProfile])
        let candidates = info.mediaSources.filter { $0.requiresOpening != true && Self.validPlaybackIdentifier($0.id) && (mediaSourceID == nil || $0.id == mediaSourceID) }
        guard !candidates.isEmpty, info.errorCode == nil, let playSessionID = info.playSessionID, Self.validPlaybackIdentifier(playSessionID) else { throw local ? MediaServerError.unsupportedLocalMedia : MediaServerError.unsupportedMedia }
        let playable: (MediaSource) -> Bool = local ? Self.canPlayLocally : Self.canPlayDirectly
        if connection.compatibilityMode {
            guard let source = candidates.first(where: playable), let path = source.path,
                  source.protocolName?.lowercased() == "http" || source.protocolName?.lowercased() == "https" else { throw local ? MediaServerError.unsupportedLocalMedia : MediaServerError.unsupportedCompatibilityMedia }
            if local { try Self.validateOriginalPath(path) }
            return PlaybackPlan(itemID: item.id, mediaSourceID: source.id, playSessionID: playSessionID, url: try authorizedStreamURL(path, rootRelativeToOrigin: true, forceZeroOffset: false), method: .directPlay, resumeTicks: max(0, startTicks), runtimeTicks: source.runTimeTicks ?? item.runTimeTicks, externalSubtitles: externalSubtitles(itemID: item.id, source: source))
        }
        if mode == .automatic, let source = candidates.first(where: playable) {
            // Static returns original bytes; seek happens once in the selected local player.
            let suffix = local ? Self.localContainerExtension(source.container)! : "mp4"
            let stream = try url(path: ["Videos", item.id, "stream.\(suffix)"], query: ["Static": "true", "MediaSourceId": source.id, "PlaySessionId": playSessionID, "DeviceId": deviceID])
            return PlaybackPlan(itemID: item.id, mediaSourceID: source.id, playSessionID: playSessionID, url: try authorizedStreamURL(stream.absoluteString), method: .directPlay, resumeTicks: max(0, startTicks), runtimeTicks: source.runTimeTicks ?? item.runTimeTicks, externalSubtitles: externalSubtitles(itemID: item.id, source: source))
        }
        if local { throw MediaServerError.unsupportedLocalMedia }
        guard let source = candidates.first(where: { $0.supportsTranscoding == true && $0.transcodingURL != nil }), let rawURL = source.transcodingURL else { throw MediaServerError.unsupportedMedia }
        let stream = try authorizedStreamURL(rawURL)
        return PlaybackPlan(itemID: item.id, mediaSourceID: source.id, playSessionID: playSessionID, url: stream, method: .transcode, resumeTicks: max(0, startTicks), runtimeTicks: source.runTimeTicks ?? item.runTimeTicks, externalSubtitles: externalSubtitles(itemID: item.id, source: source))
    }

    private static let subtitleExtensions = ["srt": "srt", "subrip": "srt", "ass": "ass", "ssa": "ssa", "webvtt": "vtt", "vtt": "vtt"]
    private static let maximumSubtitleBytes = 10 * 1024 * 1024

    private func externalSubtitles(itemID: String, source: MediaSource) -> [ServerSubtitle] {
        var indexes: Set<Int> = []
        return (source.mediaStreams ?? []).compactMap { stream in
            // Some compatible servers label PGS as text. Only known text codecs qualify.
            guard stream.type?.lowercased() == "subtitle", stream.isExternal == true,
                  let fileExtension = Self.subtitleExtensions[stream.codec?.lowercased() ?? ""],
                  let index = stream.index, (0...Int(Int32.max)).contains(index), indexes.insert(index).inserted else { return nil }
            let target: URL
            if let delivery = stream.deliveryURL {
                guard let resolved = try? subtitleDeliveryURL(delivery) else { return nil }
                target = resolved
            } else {
                // The compatibility subset does not define the standard subtitle route.
                guard !connection.compatibilityMode,
                      let resolved = try? url(path: ["Videos", itemID, source.id, "Subtitles", String(index), "Stream.\(fileExtension)"], query: ["StartPositionTicks": "0", "CopyTimestamps": "true"]) else { return nil }
                target = resolved
            }
            let title = [stream.displayTitle, stream.title, stream.language].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "字幕 \(index + 1)"
            return ServerSubtitle(itemID: itemID, mediaSourceID: source.id, streamIndex: index, title: title, language: stream.language, isDefault: stream.isDefault ?? false, isForced: stream.isForced ?? false, fileExtension: fileExtension, connectionID: connection.id, serverID: connection.serverID, userID: connection.userID, requestURL: target)
        }
    }

    private func subtitleDeliveryURL(_ raw: String) throws -> URL {
        guard !raw.isEmpty, raw.utf8.count <= 16_384, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var parts = URLComponents(string: raw), [parts.user, parts.password].allSatisfy({ $0 == nil }), parts.fragment == nil else { throw MediaServerError.externalStream }
        if parts.scheme == nil && parts.host == nil {
            guard let base = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false) else { throw MediaServerError.invalidAddress }
            if !parts.path.hasPrefix("/") { parts.path = connection.baseURL.path + "/" + parts.path }
            parts.scheme = base.scheme; parts.host = base.host; parts.port = base.port
        }
        guard let resolved = parts.url, ["http", "https"].contains(resolved.scheme?.lowercased() ?? ""), ServerEndpoint.sameOrigin(connection.baseURL, resolved) else { throw MediaServerError.externalStream }
        // Delivery URLs can carry stale credentials. Authenticate with this connection's headers.
        parts.queryItems = (parts.queryItems ?? []).filter { !["api_key", "x-emby-token", "token", "access_token", "authorization", "startpositionticks", "copytimestamps"].contains($0.name.lowercased()) }
        parts.queryItems?.append(contentsOf: [URLQueryItem(name: "StartPositionTicks", value: "0"), URLQueryItem(name: "CopyTimestamps", value: "true")])
        guard let result = parts.url else { throw MediaServerError.externalStream }
        return result
    }

    public func downloadSubtitle(_ subtitle: ServerSubtitle) async throws -> DownloadedSubtitle {
        try Task.checkCancellation()
        guard subtitle.connectionID == connection.id, subtitle.serverID == connection.serverID, subtitle.userID == connection.userID else { throw MediaServerError.invalidScope }
        guard Self.subtitleExtensions.values.contains(subtitle.fileExtension),
              [subtitle.requestURL.user, subtitle.requestURL.password].allSatisfy({ $0 == nil }), subtitle.requestURL.fragment == nil,
              ServerEndpoint.sameOrigin(connection.baseURL, subtitle.requestURL) else { throw MediaServerError.externalStream }
        if let pin = connection.certificatePin, (try? CertificatePin.origin(for: subtitle.requestURL)) != pin.origin { throw MediaServerError.certificate(.originMismatch) }
        var request = authorizedRequest(url: subtitle.requestURL, method: "GET")
        request.setValue("text/plain, text/vtt, application/x-subrip, text/x-ass, text/x-ssa", forHTTPHeaderField: "Accept")
        let delegate = CertificateSessionDelegate(pin: connection.certificatePin)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse, let responseURL = response.url, ServerEndpoint.sameOrigin(connection.baseURL, responseURL) else { throw MediaServerError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw MediaServerError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= Self.maximumSubtitleBytes else { throw MediaServerError.subtitleTooLarge }
            var data = Data()
            data.reserveCapacity(min(Self.maximumSubtitleBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumSubtitleBytes else { throw MediaServerError.subtitleTooLarge }
                data.append(byte)
            }
            guard !data.isEmpty else { throw MediaServerError.invalidResponse }
            return DownloadedSubtitle(data: data, fileExtension: subtitle.fileExtension)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let trustError = delegate.lastTrustError { throw MediaServerError.certificate(trustError) }
            if let safeError = error as? MediaServerError { throw safeError }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                    throw MediaServerError.certificate(connection.certificatePin == nil ? .untrusted : .invalidCertificate)
                case .cancelled: throw CancellationError()
                default: break
                }
            }
            throw MediaServerError.network
        }
    }

    public func stopTranscoding(plan: PlaybackPlan) async throws {
        guard plan.isTranscoding else { return }
        _ = try await request(url: url(path: ["Videos", "ActiveEncodings"], query: ["DeviceId": deviceID, "PlaySessionId": plan.playSessionID]), method: "DELETE", body: nil)
    }

    func report(_ event: PlaybackEvent, plan: PlaybackPlan) async throws {
        var body: [String: Any] = ["ItemId": plan.itemID, "MediaSourceId": plan.mediaSourceID, "PlaySessionId": plan.playSessionID, "PositionTicks": max(0, event.positionTicks), "PlayMethod": plan.method.rawValue]
        if let duration = plan.runtimeTicks, duration > 0 { body["RunTimeTicks"] = duration }
        if event.kind != .stopped { body["IsPaused"] = event.isPaused; body["CanSeek"] = true }
        let path: [String]
        switch event.kind {
        case .started: path = ["Sessions", "Playing"]
        case .progress: path = ["Sessions", "Playing", "Progress"]; body["EventName"] = event.isPaused ? "Pause" : "TimeUpdate"
        case .stopped: path = ["Sessions", "Playing", "Stopped"]
        }
        _ = try await request(url: url(path: path), method: "POST", body: body)
    }

    private static func canPlayDirectly(_ source: MediaSource) -> Bool {
        guard source.supportsDirectPlay == true, let container = source.container?.lowercased(), ["mp4", "m4v", "mov"].contains(container), let streams = source.mediaStreams else { return false }
        let video = streams.filter { $0.type?.lowercased() == "video" }
        let audio = streams.filter { $0.type?.lowercased() == "audio" }
        return !video.isEmpty && video.allSatisfy { $0.codec?.lowercased() == "h264" && ($0.bitDepth ?? 8) <= 8 } && audio.allSatisfy { $0.codec?.lowercased() == "aac" }
    }

    private static func validPlaybackIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    // Explicit mappings avoid inventing a file extension from untrusted server metadata.
    private static let localContainers = ["mkv": "mkv", "matroska": "mkv", "mp4": "mp4", "m4v": "m4v", "mov": "mov", "avi": "avi", "webm": "webm", "ts": "ts", "mpegts": "ts", "m2ts": "m2ts", "mts": "mts", "mpeg": "mpeg", "mpg": "mpg", "vob": "vob", "flv": "flv", "wmv": "wmv", "asf": "asf", "ogv": "ogv"]
    private static let localVideoCodecs: Set<String> = ["h264", "hevc", "h265", "vp8", "vp9", "av1", "mpeg4", "mpeg2video", "mpeg1video", "vc1", "wmv3", "theora", "mjpeg"]
    private static let localAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "dts", "dca", "truehd", "mlp", "flac", "alac", "mp3", "mp2", "opus", "vorbis", "wmav1", "wmav2", "wmapro", "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8", "pcm_bluray", "pcm_dvd"]
    private static func localContainerExtension(_ container: String?) -> String? {
        container.flatMap { localContainers[$0.lowercased()] }
    }

    private static func canPlayLocally(_ source: MediaSource) -> Bool {
        guard source.supportsDirectPlay == true, localContainerExtension(source.container) != nil, let streams = source.mediaStreams else { return false }
        let video = streams.filter { $0.type?.lowercased() == "video" }
        let audio = streams.filter { $0.type?.lowercased() == "audio" }
        return !video.isEmpty && video.allSatisfy { localVideoCodecs.contains($0.codec?.lowercased() ?? "") }
            && audio.allSatisfy { localAudioCodecs.contains($0.codec?.lowercased() ?? "") }
    }

    private static func validateOriginalPath(_ value: String) throws {
        guard !value.isEmpty, !value.contains("\\"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value), !components.path.isEmpty,
              !["m3u", "m3u8", "mpd", "pls", "ffconcat", "sdp", "strm"].contains((components.path as NSString).pathExtension.lowercased()) else { throw MediaServerError.unsupportedLocalMedia }
    }

    private static var localDecoderProfile: [String: Any] {
        ["Name": "SeatSix Local Decoder", "MaxStreamingBitrate": 200_000_000, "MaxStaticBitrate": 200_000_000,
         "DirectPlayProfiles": [["Container": localContainers.keys.sorted().joined(separator: ","), "Type": "Video", "VideoCodec": localVideoCodecs.sorted().joined(separator: ","), "AudioCodec": localAudioCodecs.sorted().joined(separator: ",")]],
         "TranscodingProfiles": [], "CodecProfiles": [], "SubtitleProfiles": []]
    }

    static var deviceProfile: [String: Any] {
        ["Name": "SeatSix AVPlayer", "MaxStreamingBitrate": 8_000_000, "MaxStaticBitrate": 200_000_000, "MusicStreamingTranscodingBitrate": 192_000,
         "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac"]],
         "TranscodingProfiles": [["Container": "ts", "Type": "Video", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac", "MaxAudioChannels": "2", "MinSegments": 2, "SegmentLength": 6, "BreakOnNonKeyFrames": false, "Context": "Streaming"]],
         "CodecProfiles": [["Type": "Video", "Codec": "h264", "Conditions": [["Condition": "LessThanEqual", "Property": "Width", "Value": "1920", "IsRequired": true], ["Condition": "LessThanEqual", "Property": "Height", "Value": "1080", "IsRequired": true], ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": true], ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "high|main|baseline|constrained baseline", "IsRequired": true]]]],
         "SubtitleProfiles": []]
    }

    func authorizedStreamURL(_ rawValue: String, rootRelativeToOrigin: Bool = false, forceZeroOffset: Bool = true) throws -> URL {
        guard var raw = URLComponents(string: rawValue), raw.fragment == nil else { throw MediaServerError.externalStream }
        if raw.user != nil || raw.password != nil { throw MediaServerError.externalStream }
        let basePath = connection.baseURL.path
        if raw.scheme == nil && raw.host == nil {
            if !raw.path.hasPrefix("/") { raw.path = basePath + "/" + raw.path }
            else if !rootRelativeToOrigin && !basePath.isEmpty && raw.path != basePath && !raw.path.hasPrefix(basePath + "/") { raw.path = basePath + raw.path }
            guard let base = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false) else { throw MediaServerError.invalidAddress }
            raw.scheme = base.scheme; raw.host = base.host; raw.port = base.port
        }
        guard let resolved = raw.url, ServerEndpoint.sameOrigin(connection.baseURL, resolved) else { throw MediaServerError.externalStream }
        var parameters = (raw.queryItems ?? []).filter { !["api_key", "x-emby-token"].contains($0.name.lowercased()) && (!forceZeroOffset || $0.name.lowercased() != "starttimeticks") }
        parameters.append(URLQueryItem(name: "api_key", value: token))
        if forceZeroOffset { parameters.append(URLQueryItem(name: "StartTimeTicks", value: "0")) }
        raw.queryItems = parameters
        guard let result = raw.url else { throw MediaServerError.externalStream }
        return result
    }

    private func url(path: [String], query: [String: String] = [:]) throws -> URL {
        var result = connection.baseURL
        for component in path {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\\") else { throw MediaServerError.invalidResponse }
            result.appendPathComponent(component)
        }
        guard var parts = URLComponents(url: result, resolvingAgainstBaseURL: false) else { throw MediaServerError.invalidAddress }
        if !query.isEmpty { parts.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) } }
        guard let finalURL = parts.url else { throw MediaServerError.invalidAddress }
        return finalURL
    }

    private func decode<Value: Decodable>(path: [String], method: String = "GET", query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Value {
        let data = try await request(url: url(path: path, query: query), method: method, body: body)
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw MediaServerError.invalidResponse }
    }

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let safeID = deviceID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let identification = "MediaBrowser Client=\"SeatSix\", Device=\"macOS\", DeviceId=\"\(safeID)\", Version=\"0.1.0\""
        request.setValue(identification, forHTTPHeaderField: "X-Emby-Authorization")
        if !connection.compatibilityMode {
            let escapedToken = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            request.setValue(identification + (token.isEmpty ? "" : ", Token=\"\(escapedToken)\""), forHTTPHeaderField: "Authorization")
        }
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        return request
    }

    private func request(url: URL, method: String, body: [String: Any]?) async throws -> Data {
        guard ServerEndpoint.sameOrigin(connection.baseURL, url) else { throw MediaServerError.externalStream }
        if let pin = connection.certificatePin, (try? CertificatePin.origin(for: url)) != pin.origin { throw MediaServerError.certificate(.originMismatch) }
        var request = authorizedRequest(url: url, method: method)
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data
        let response: URLResponse
        let trustDelegate = CertificateSessionDelegate(pin: connection.certificatePin)
        do { (data, response) = try await session.data(for: request, delegate: trustDelegate) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if let trustError = trustDelegate.lastTrustError { throw MediaServerError.certificate(trustError) }
            if let urlError = error as? URLError {
                switch urlError.code {
                case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                    throw MediaServerError.certificate(connection.certificatePin == nil ? .untrusted : .invalidCertificate)
                case .cancelled: throw CancellationError()
                default: break
                }
            }
            throw MediaServerError.network
        }
        guard let response = response as? HTTPURLResponse, let responseURL = response.url, ServerEndpoint.sameOrigin(connection.baseURL, responseURL) else { throw MediaServerError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw MediaServerError.httpStatus(response.statusCode) }
        return data
    }
}

private struct PublicServerInfo: Decodable {
    var id: String?; var serverName: String?; var productName: String?
    enum CodingKeys: String, CodingKey { case id = "Id", serverName = "ServerName", productName = "ProductName" }
}
private struct AuthenticationResponse: Decodable {
    struct User: Decodable { var id: String; var name: String?; enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" } }
    var user: User; var accessToken: String; var serverID: String?
    enum CodingKeys: String, CodingKey { case user = "User", accessToken = "AccessToken", serverID = "ServerId" }
}
private struct LibraryResult: Decodable { var items: [MediaLibrary]; enum CodingKeys: String, CodingKey { case items = "Items" } }
private struct SeriesPage: Decodable {
    var items: [MediaItem]
    var totalRecordCount: Int?
    var startIndex: Int?
    enum CodingKeys: String, CodingKey { case items = "Items", totalRecordCount = "TotalRecordCount", startIndex = "StartIndex" }
}
private struct PlaybackInfo: Decodable {
    var mediaSources: [MediaSource]; var playSessionID: String?; var errorCode: String?
    enum CodingKeys: String, CodingKey { case mediaSources = "MediaSources", playSessionID = "PlaySessionId", errorCode = "ErrorCode" }
}
