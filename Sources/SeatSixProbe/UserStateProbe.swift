import CoreFoundation
import Foundation
import SeatSixCore

/// Explicitly scoped, reversible acceptance. Never tests watched state on a series,
/// never fabricates playback events, and compares the entire original UserData object.
@MainActor
enum UserStateProbe {
    struct RawState {
        let played: Bool
        let favorite: Bool
        let position: Int64
        let playCount: Int64?
        private let canonical: Data

        init(_ object: [String: Any]) throws {
            func boolean(_ key: String) throws -> Bool {
                guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw ProbeFailure(message: "服务器未返回明确的用户状态，停止写入验收")
                }
                return value.boolValue
            }
            func integer(_ key: String) -> Int64? {
                guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue >= 0,
                      value.doubleValue < Double(Int64.max), value.doubleValue.rounded(.towardZero) == value.doubleValue else { return nil }
                return value.int64Value
            }
            played = try boolean("Played"); favorite = try boolean("IsFavorite")
            guard let ticks = integer("PlaybackPositionTicks") else { throw ProbeFailure(message: "服务器未返回明确的播放进度，停止写入验收") }
            position = ticks; playCount = integer("PlayCount")
            canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }

        func isIdentical(to other: RawState) -> Bool { canonical == other.canonical }
        var publicSummary: [String: Any] {
            ["played": played, "favorite": favorite, "positionTicks": position, "playCount": playCount.map { $0 as Any } ?? NSNull()]
        }
    }

    struct Dependencies {
        var item: (String) async throws -> MediaItem
        var rawState: (MediaItem) async throws -> RawState
        var catalog: (String) async throws -> LibraryCatalogSnapshot
        var favorite: (MediaItem, Bool) async throws -> MediaItem
        var played: (MediaItem, Bool) async throws -> MediaItem
    }

    static func verify(client: MediaServerClient, token: String, libraries: [MediaLibrary], movieID: String, seriesID: String,
                       persist: @escaping ([String: Any]) throws -> Void = { _ in }) async -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        let session = CertificateSessionFactory.makeSession(pin: client.connection.certificatePin, configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await verify(libraryIDs: libraries.map(\.id), movieID: movieID, seriesID: seriesID,
            dependencies: Dependencies(item: { try await client.item(id: $0) }, rawState: { item in
                var url = client.connection.baseURL
                for component in ["Users", client.connection.userID, "Items", item.id] {
                    guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\\") else {
                        throw ProbeFailure(message: "验收条目标识无效")
                    }
                    url.appendPathComponent(component)
                }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                request.setValue("MediaBrowser Client=\"SeatSix\", Device=\"macOS\", DeviceId=\"seatsix-private-server-probe\", Version=\"0.1.0\"", forHTTPHeaderField: "X-Emby-Authorization")
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4 * 1_024 * 1_024,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["Id"] as? String == item.id, object["Type"] as? String == item.type,
                      let state = object["UserData"] as? [String: Any] else { throw ProbeFailure(message: "独立用户状态读取未通过校验") }
                return try RawState(state)
            }, catalog: { try await client.libraryCatalog(libraryID: $0) },
            favorite: { try await client.setFavorite(item: $0, isFavorite: $1) },
            played: { try await client.setPlayed(item: $0, played: $1) }), persist: persist)
    }

    static func verify(libraryIDs: [String], movieID: String, seriesID: String, dependencies d: Dependencies,
                       persist: @escaping ([String: Any]) throws -> Void = { _ in }) async -> [String: Any] {
        var report: [String: Any] = ["passed": false, "playbackEventsIssued": 0, "seriesWatchedWritesIssued": 0]
        var checks: [[String: Any]] = []
        var attempts: [String] = []
        var originals: [String: RawState] = [:]
        var items: [String: MediaItem] = [:]
        var scopes: [String: String] = [:]
        var touched: Set<String> = []
        var dispatchCount = 0
        var completed = false
        func save() throws {
            report["checks"] = checks; report["mutationAttempts"] = attempts; report["mutationAttemptCount"] = attempts.count
            report["writeDispatchCount"] = dispatchCount
            try persist(report)
        }
        func check(_ name: String, _ passed: Bool) throws {
            checks.append(["name": name, "passed": passed])
            try save()
            guard passed else { throw ProbeFailure(message: "用户状态验收步骤未通过") }
        }
        func stateMatches(_ item: MediaItem, _ raw: RawState) -> Bool {
            item.userData.playedKnown && item.userData.isFavoriteKnown && item.userData.playbackPositionKnown &&
                item.userData.played == raw.played && item.userData.isFavorite == raw.favorite && item.userData.playbackPositionTicks == raw.position
        }
        func checkpoint(_ label: String, _ role: String, favorite: Bool, played: Bool) async throws {
            guard let item = items[role], let library = scopes[role] else { throw ProbeFailure(message: "验收基线缺失") }
            let raw = try await d.rawState(item)
            let snapshot = try await d.catalog(library)
            let rows = snapshot.items.filter { $0.id == item.id }
            try check(label + ".independentDetail", stateMatches(item, raw) && raw.favorite == favorite && raw.played == played)
            try check(label + ".completeCatalog", snapshot.isComplete && snapshot.items.count == snapshot.total && rows.count == 1 && rows.allSatisfy { stateMatches($0, raw) })
            let favorites = LibraryQuery(favoritesOnly: true).apply(to: snapshot.items).contains { $0.id == item.id }
            try check(label + ".favoritesFilter", favorites == favorite)
            if role == "movie" {
                let watched = LibraryQuery(watched: .watched).apply(to: snapshot.items).contains { $0.id == item.id }
                let unwatched = LibraryQuery(watched: .unwatched).apply(to: snapshot.items).contains { $0.id == item.id }
                let combined = LibraryQuery(watched: played ? .watched : .unwatched, favoritesOnly: true).apply(to: snapshot.items).contains { $0.id == item.id }
                try check(label + ".watchedFilters", watched == played && unwatched != played && combined == favorite)
            }
        }
        func mutate(_ role: String, _ action: String, enabled: Bool, cleanup: Bool = false) async throws {
            guard ["favorite", "played"].contains(action), role != "series" || action == "favorite" else {
                throw ProbeFailure(message: "验收禁止改写整剧观看状态")
            }
            guard let item = items[role] else { throw ProbeFailure(message: "验收基线缺失") }
            let key = role + "." + action
            attempts.append((cleanup ? "cleanup." : "") + key + (enabled ? ".enable" : ".disable"))
            // Persist the impending action before dispatch, so an interrupted process
            // leaves an explicit incomplete report rather than an old success report.
            if cleanup { try? save() } else { try save() }
            touched.insert(key)
            dispatchCount += 1
            if action == "favorite" { items[role] = try await d.favorite(item, enabled) }
            else { items[role] = try await d.played(item, enabled) }
        }
        do {
            guard movieID != seriesID else { throw ProbeFailure(message: "电影和剧集必须是不同条目") }
            let movie = try await d.item(movieID), series = try await d.item(seriesID)
            try check("explicitSampleTypes", movie.id == movieID && movie.type == "Movie" && series.id == seriesID && series.type == "Series")
            items = ["movie": movie, "series": series]
            for role in ["movie", "series"] {
                let raw = try await d.rawState(items[role]!)
                originals[role] = raw
                try check(role + ".baselineKnown", stateMatches(items[role]!, raw))
                report[role + "Before"] = raw.publicSummary
            }
            let baseline = originals["movie"]!
            try check("movieIsPristineUnwatched", !baseline.played && baseline.playCount == 0 && baseline.position == 0)
            for libraryID in libraryIDs {
                let catalog = try await d.catalog(libraryID)
                guard catalog.isComplete && catalog.items.count == catalog.total else { throw ProbeFailure(message: "验收媒体库目录不完整") }
                for role in ["movie", "series"] where catalog.items.contains(where: { $0.id == items[role]!.id }) {
                    if scopes[role] == nil { scopes[role] = libraryID }
                }
                if scopes.count == 2 { break }
            }
            try check("bothSamplesFoundInCompleteLibraries", scopes.count == 2)
            for role in ["movie", "series"] {
                let original = originals[role]!
                // Complete catalog traversal can take time. Never overwrite a user
                // action that occurred since the initial baseline was captured.
                let beforeWrite = try await d.rawState(items[role]!)
                try check(role + ".baselineUnchangedBeforeWrite", beforeWrite.isIdentical(to: original))
                try await mutate(role, "favorite", enabled: !original.favorite)
                try await checkpoint(role + ".favoriteToggled", role, favorite: !original.favorite, played: original.played)
                try await mutate(role, "favorite", enabled: original.favorite)
                try await checkpoint(role + ".favoriteRestored", role, favorite: original.favorite, played: original.played)
                touched.remove(role + ".favorite")
            }
            let beforePlayed = try await d.rawState(items["movie"]!)
            try check("movie.baselineUnchangedBeforePlayedWrite", beforePlayed.isIdentical(to: baseline))
            try await mutate("movie", "played", enabled: true)
            try await checkpoint("movie.markedWatched", "movie", favorite: baseline.favorite, played: true)
            try await mutate("movie", "played", enabled: false)
            try await checkpoint("movie.markedUnwatched", "movie", favorite: baseline.favorite, played: false)
            touched.remove("movie.played")
            completed = true
        } catch {
            report["operationCompleted"] = false
            report["failure"] = "An acceptance step failed; inspect named checks and final full-state comparison. No raw server errors are published."
            // A write may have reached the server even if its response failed. Restore
            // only actions actually dispatched; never introduce unrelated writes.
            // An unstructured task does not inherit a cancelled parent's cancellation.
            await Task { @MainActor in
                for role in ["movie", "series"] {
                    guard let original = originals[role] else { continue }
                    for action in ["favorite", "played"] where touched.contains(role + "." + action) {
                        do { try await mutate(role, action, enabled: action == "favorite" ? original.favorite : original.played, cleanup: true) }
                        catch { checks.append(["name": "cleanup." + role + "." + action, "passed": false]) }
                    }
                }
            }.value
        }
        var restored = originals.count == 2
        for role in ["movie", "series"] {
            guard let original = originals[role], let item = items[role] else { restored = false; continue }
            do {
                // Finish the restore check even when the original acceptance task
                // was cancelled after a mutation reached the server.
                let final = try await Task { @MainActor in try await d.rawState(item) }.value
                let identical = final.isIdentical(to: original)
                checks.append(["name": role + ".entireUserDataRestored", "passed": identical])
                report[role + "After"] = final.publicSummary
                restored = restored && identical
            } catch {
                checks.append(["name": role + ".entireUserDataRestored", "passed": false]); restored = false
            }
        }
        report["operationCompleted"] = completed
        report["entireOriginalUserDataRestored"] = restored
        report["passed"] = completed && restored && checks.allSatisfy { $0["passed"] as? Bool == true }
        do { try save() }
        catch { report["passed"] = false; report["reportPersistenceFailed"] = true }
        return report
    }
}
