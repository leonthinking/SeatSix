import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

private final class SeriesSkipMemoryStorage: ApplicationPersisting {
    private(set) var data: Data
    var failWrites = false
    private(set) var writeCount = 0

    init(_ value: SavedApplication) throws { data = try JSONEncoder().encode(value) }
    func load() throws -> SavedApplication { try JSONDecoder().decode(SavedApplication.self, from: data) }
    func save(_ value: SavedApplication) throws {
        writeCount += 1
        guard !failWrites else { throw CocoaError(.fileWriteOutOfSpace) }
        data = try JSONEncoder().encode(value)
    }
}

/// Removal may refresh the remaining connection; all requests remain inside this fixture.
private final class SeriesSkipEmptyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SeriesSkipApplicationTests: XCTestCase {
    private func connection(server: String = "server", user: String = "user") -> ServerConnection {
        ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!,
                         serverID: server, userID: user, username: "test", libraryIDs: [])
    }

    private func storage(connections: [ServerConnection]) throws -> SeriesSkipMemoryStorage {
        var saved = SavedApplication()
        saved.connections = connections; saved.selectedID = connections.first?.id
        return try SeriesSkipMemoryStorage(saved)
    }

    private func model(_ storage: SeriesSkipMemoryStorage) -> ApplicationModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesSkipEmptyProtocol.self]
        let session = URLSession(configuration: configuration)
        let archiveDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SeriesSkipTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: archiveDirectory) }
        return ApplicationModel(storage: storage,
                                credentials: .init(read: { _ in "fixture-token" }, save: { _, _ in }, remove: { _ in }),
                                clientFactory: { MediaServerClient(connection: $0, token: $1, deviceID: $2, session: session) },
                                subtitleArchive: SubtitleArchive(directory: archiveDirectory), invalidatePosters: { _ in })
    }

    private func episode(id: String = "episode", series: String? = "series", type: String = "Episode") throws -> MediaItem {
        var json: [String: Any] = ["Id": id, "Name": id, "Type": type, "IndexNumber": 1, "ParentIndexNumber": 1]
        if let series { json["SeriesId"] = series }
        return try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testSavedSettingsSurviveApplicationReloadAndUpdateOneRecord() throws {
        let connection = connection(), storage = try storage(connections: [connection])
        let first = model(storage)
        let identity = SeriesPlaybackIdentity(connection: connection, seriesID: "series")
        try first.saveSeriesPlaybackPreferences(.init(identity: identity, settings: .init(introSeconds: 90, outroSeconds: 60), updatedAt: .distantPast))
        let second = model(storage)
        XCTAssertEqual(second.seriesPlaybackPreferences(seriesID: "series", connection: connection).settings,
                       .init(introSeconds: 90, outroSeconds: 60))
        XCTAssertGreaterThan(second.saved.seriesPlaybackPreferences[0].updatedAt, .distantPast)
        try second.saveSeriesPlaybackPreferences(.init(identity: identity, settings: .init(introSeconds: 95, outroSeconds: 0)))
        let third = model(storage)
        XCTAssertEqual(third.saved.seriesPlaybackPreferences.count, 1)
        XCTAssertEqual(third.seriesPlaybackPreferences(seriesID: "series", connection: connection).settings,
                       .init(introSeconds: 95, outroSeconds: 0))
    }

    func testSettingsAreIsolatedByConnectionServerUserAndSeries() throws {
        let connections = [connection(), connection(), connection(server: "other"), connection(user: "other")]
        let storage = try storage(connections: connections), model = model(storage)
        for (index, connection) in connections.enumerated() {
            try model.saveSeriesPlaybackPreferences(.init(identity: .init(connection: connection, seriesID: "series"),
                                                           settings: .init(introSeconds: 10 + index, outroSeconds: 20 + index)))
        }
        try model.saveSeriesPlaybackPreferences(.init(identity: .init(connection: connections[0], seriesID: "other-series"),
                                                       settings: .init(introSeconds: 300, outroSeconds: 200)))
        for (index, connection) in connections.enumerated() {
            XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "series", connection: connection).settings,
                           .init(introSeconds: 10 + index, outroSeconds: 20 + index))
        }
        XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "other-series", connection: connections[0]).settings,
                       .init(introSeconds: 300, outroSeconds: 200))
        XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "missing", connection: connections[0]).settings, .init())
        var changedServer = connections[0]; changedServer.serverID = "unregistered-server"
        var changedUser = connections[0]; changedUser.userID = "unregistered-user"
        XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "series", connection: changedServer).settings, .init())
        XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "series", connection: changedUser).settings, .init())
        for changed in [changedServer, changedUser] {
            XCTAssertThrowsError(try model.saveSeriesPlaybackPreferences(.init(identity: .init(connection: changed, seriesID: "series"), settings: .init(introSeconds: 1))))
        }
        XCTAssertEqual(try storage.load().seriesPlaybackPreferences.count, 5)
    }

    func testFailedWritePreservesPublishedAndStoredSettingsAndCanRetry() throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let access = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: try episode(), sequence: nil, connection: connection))
        try access.save(.init(introSeconds: 90, outroSeconds: 60))
        let published = model.saved.seriesPlaybackPreferences, persisted = storage.data
        storage.failWrites = true
        XCTAssertThrowsError(try access.save(.init(introSeconds: 120, outroSeconds: 30)))
        XCTAssertEqual(model.saved.seriesPlaybackPreferences, published)
        XCTAssertEqual(storage.data, persisted)
        XCTAssertEqual(access.load(), .init(introSeconds: 90, outroSeconds: 60))
        XCTAssertNotNil(model.errorMessage)
        storage.failWrites = false
        try access.save(.init(introSeconds: 120, outroSeconds: 30))
        XCTAssertEqual(access.load(), .init(introSeconds: 120, outroSeconds: 30))
        XCTAssertEqual(try storage.load().seriesPlaybackPreferences.first?.settings, access.load())
    }

    func testInvalidDraftsAndEmptySeriesNeverWriteOrPublish() throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let identity = SeriesPlaybackIdentity(connection: connection, seriesID: "series")
        for settings in [SeriesSkipSettings(introSeconds: -1), .init(outroSeconds: -1),
                         .init(introSeconds: 1801), .init(outroSeconds: Int.max)] {
            XCTAssertThrowsError(try model.saveSeriesPlaybackPreferences(.init(identity: identity, settings: settings)))
        }
        for series in ["", " \n "] {
            XCTAssertThrowsError(try model.saveSeriesPlaybackPreferences(.init(identity: .init(connection: connection, seriesID: series), settings: .init(introSeconds: 90))))
        }
        XCTAssertEqual(storage.writeCount, 0)
        XCTAssertTrue(model.saved.seriesPlaybackPreferences.isEmpty)
        XCTAssertTrue(try storage.load().seriesPlaybackPreferences.isEmpty)
    }

    func testConnectionRemovalClearsOnlyItsSettingsAndRejectsRetainedAccess() async throws {
        let first = connection(), second = connection(), storage = try storage(connections: [first, second]), model = model(storage)
        let oldAccess = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: try episode(), sequence: nil, connection: first))
        try oldAccess.save(.init(introSeconds: 90, outroSeconds: 60))
        try model.saveSeriesPlaybackPreferences(.init(identity: .init(connection: first, seriesID: "other-series"), settings: .init(introSeconds: 30)))
        let retained = SeriesPlaybackPreferences(identity: .init(connection: second, seriesID: "series"), settings: .init(outroSeconds: 45))
        try model.saveSeriesPlaybackPreferences(retained)
        await model.removeConnection(first.id)
        XCTAssertEqual(model.saved.seriesPlaybackPreferences.map(\.identity), [retained.identity])
        XCTAssertEqual(model.seriesPlaybackPreferences(seriesID: "series", connection: second).settings, retained.settings)
        XCTAssertThrowsError(try oldAccess.save(.init(introSeconds: 300)))
        XCTAssertEqual(oldAccess.load(), .init())
        XCTAssertEqual(try storage.load().seriesPlaybackPreferences.map(\.identity), [retained.identity])
    }

    func testRetainedAccessCannotSaveAfterShutdown() async throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let access = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: try episode(), sequence: nil, connection: connection))
        await model.shutdown()
        let writes = storage.writeCount
        XCTAssertThrowsError(try access.save(.init(introSeconds: 90)))
        XCTAssertEqual(storage.writeCount, writes)
        XCTAssertTrue(model.saved.seriesPlaybackPreferences.isEmpty)
    }

    func testExplicitSeriesIdentityDoesNotRequireSequenceAndSharesAcrossEpisodes() throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let first = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: try episode(id: "first"), sequence: nil, connection: connection))
        try first.save(.init(introSeconds: 90, outroSeconds: 60))
        let second = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: try episode(id: "second"), sequence: nil, connection: connection))
        XCTAssertEqual(second.load(), first.load())
        XCTAssertEqual(model.saved.seriesPlaybackPreferences.first?.identity.seriesID, "series")
    }

    func testMissingSeriesIdentityRequiresMembershipInNonemptySequence() throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let item = try episode(series: nil)
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: item, sequence: nil, connection: connection))
        let sequence = EpisodeSequence(seriesID: "resolved-series", episodes: [item])
        let access = try XCTUnwrap(model.seriesPlaybackPreferencesAccess(item: item, sequence: sequence, connection: connection))
        try access.save(.init(introSeconds: 85, outroSeconds: 65))
        XCTAssertEqual(model.saved.seriesPlaybackPreferences.first?.identity.seriesID, "resolved-series")
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: item, sequence: EpisodeSequence(seriesID: "resolved-series", episodes: []), connection: connection))
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: item, sequence: EpisodeSequence(seriesID: " \n ", episodes: [item]), connection: connection))
    }

    func testMismatchedSeriesAndMoviesCannotAcquireSeriesPreferences() throws {
        let connection = connection(), storage = try storage(connections: [connection]), model = model(storage)
        let item = try episode(), sequence = EpisodeSequence(seriesID: "another-series", episodes: [])
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: item, sequence: sequence, connection: connection))
        let matching = EpisodeSequence(seriesID: "series", episodes: [item])
        XCTAssertNotNil(model.seriesPlaybackPreferencesAccess(item: item, sequence: matching, connection: connection))
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: try episode(type: "Movie"), sequence: nil, connection: connection))
        XCTAssertNil(model.seriesPlaybackPreferencesAccess(item: try episode(type: "Series"), sequence: matching, connection: connection))
    }
}
