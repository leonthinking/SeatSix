import AppKit
import SeatSixCore
import XCTest
@testable import SeatSixApp

@MainActor
final class SessionWindowPaletteTests: XCTestCase {
    private let connection = ServerConnection(kind: .emby, name: "Private NAS",
        baseURL: URL(string: "https://private.test")!, serverID: "private-server",
        userID: "private-user", username: "private-name", libraryIDs: ["private-library", "theater"])
    private let authorized: Set<String> = ["private-library", "theater"]

    private func image(_ colors: [UInt8] = [45, 0, 0, 0, 48, 0, 0, 0, 54, 46, 22, 0]) throws -> NSImage {
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: 6, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), bitmapInfo: [],
            provider: XCTUnwrap(CGDataProvider(data: Data(colors) as CFData)), decode: nil,
            shouldInterpolate: true, intent: .defaultIntent))
        return NSImage(cgImage: image, size: NSSize(width: 2, height: 2))
    }

    func testChangingPosterColorsDoesNotWriteOrRestoreAWindowPalette() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CountingPaletteStorage(try ApplicationStorage(directory: directory))
        var profile = SavedApplication()
        profile.selectedID = connection.id
        profile.connections = [connection]
        try store.save(profile)
        let model = ApplicationModel(storage: store)
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Film","Type":"Movie"}"#.utf8))
        let libraries = authorized.sorted().map { MediaLibrary(id: $0, name: $0) }
        model.libraries = libraries
        model.selectedLibraryID = libraries[0].id
        model.detail = item
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        let field = try image()
        func accept(_ field: NSImage) {
            model.acceptWindowPalette(.init(scope: scope, accessRevision: model.windowArtworkRevision, itemID: item.id, field: field))
        }
        let initialWrites = store.writes
        accept(field)
        XCTAssertTrue(model.windowColorField === field)
        accept(field)
        let replacement = try image([10, 10, 10, 12, 12, 12, 14, 14, 14, 16, 16, 16])
        accept(replacement)
        XCTAssertTrue(model.windowColorField === replacement)
        XCTAssertEqual(store.writes, initialWrites, "Applying an artwork color must not write the profile")
        try model.persist()
        let storedProfile = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("connections.json"))) as? [String: Any])
        XCTAssertNil(storedProfile["windowPalette"])
        let reopened = ApplicationModel(storage: store)
        reopened.libraries = libraries
        XCTAssertEqual(reopened.connection?.id, connection.id)
        XCTAssertNil(reopened.windowColorField, "A new session cannot restore the previous film's colors")
    }

    func testLegacyWindowPaletteIsIgnoredWithoutLosingProfilePreferences() throws {
        var profile = SavedApplication()
        profile.connections = [connection]
        profile.selectedID = connection.id
        profile.applicationPreferences.showHomeRecommendations = false
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        let digest = Data(repeating: 0, count: 32).base64EncodedString()
        let v1Palette: [String: Any] = ["scope": digest, "libraries": [digest], "width": 1, "height": 1,
                                        "rgb": Data([45, 0, 0]).base64EncodedString()]
        for legacyValue: Any in [v1Palette, "damaged record"] {
            var legacy = base
            legacy["windowPalette"] = legacyValue
            let decoded = try JSONDecoder().decode(SavedApplication.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertEqual(decoded.selectedID, connection.id)
            XCTAssertEqual(decoded.connections, [connection])
            XCTAssertFalse(decoded.applicationPreferences.showHomeRecommendations)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            XCTAssertNil(encoded["windowPalette"], "The next normal save drops the ignored legacy field")
        }
    }

    func testRevokingLaterLibraryKeepsOriginalFieldAndRejectsOldDetailReplies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ApplicationStorage(directory: directory)
        var profile = SavedApplication()
        profile.connections = [connection]; profile.selectedID = connection.id
        try store.save(profile)
        let model = ApplicationModel(storage: store)
        let movie = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Film","Type":"Movie"}"#.utf8))
        let original = MediaLibrary(id: "private-library", name: "Original")
        let added = MediaLibrary(id: "theater", name: "Additional")
        model.libraries = [original]; model.selectedLibraryID = original.id; model.detail = movie
        let scope = try XCTUnwrap(HomeArtworkScope(model: model))
        let revision = model.windowArtworkRevision
        let field = try image()
        model.acceptWindowPalette(.init(scope: scope, accessRevision: revision, itemID: movie.id, field: field))
        model.libraries = [original, added]
        model.libraries = [original]
        XCTAssertNotEqual(model.windowArtworkRevision, revision)
        let restored = try XCTUnwrap(model.windowColorField)
        XCTAssertEqual(ArtworkColorSamples(image: restored, maximumDimension: 8)?.pixels,
                       ArtworkColorSamples(image: field, maximumDimension: 8)?.pixels)
        model.detail = movie
        let late = try image(Array(repeating: 12, count: 12))
        model.acceptWindowPalette(.init(scope: scope, accessRevision: revision, itemID: movie.id, field: late))
        XCTAssertTrue(model.windowColorField === restored)
        model.libraries = [added]
        XCTAssertNil(model.windowColorField)
        model.libraries = [added, original]
        XCTAssertNil(model.windowColorField)
    }

    func testRemovingInactiveConnectionCleansItsAssetsAndKeepsActiveSelectionAndPalette() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ApplicationStorage(directory: directory)
        var removed = connection
        removed.id = UUID(); removed.name = "Removed mirror"; removed.baseURL = URL(string: "https://mirror.test")!
        var first = removed
        first.id = UUID(); first.serverID = "unrelated"
        var profile = SavedApplication()
        profile.connections = [first, removed, connection]; profile.selectedID = connection.id
        try store.save(profile)
        let archive = SubtitleArchive(directory: directory.appendingPathComponent("Archive"))
        let input = directory.appendingPathComponent("Example.srt")
        try Data("1\n00:00:00,000 --> 00:00:05,000\nExample\n".utf8).write(to: input)
        let aSubtitle = try await archive.archive(url: input, connectionID: connection.id)
        let bSubtitle = try await archive.archive(url: input, connectionID: removed.id)
        var removedCredentials: [UUID] = [], removedArt: [UUID] = []
        let credentials = CredentialAccess(read: { _ in "fixture" }, save: { _, _ in }, remove: { removedCredentials.append($0) })
        let model = ApplicationModel(storage: store, credentials: credentials, subtitleArchive: archive,
                                     invalidatePosters: { removedArt.append($0) })
        let movie = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Film","Type":"Movie"}"#.utf8))
        model.libraries = authorized.sorted().map { MediaLibrary(id: $0, name: $0) }
        model.selectedLibraryID = "theater"; model.page = "library"
        model.items = [movie]; model.detail = movie
        XCTAssertTrue(model.saveRecovery(item: movie.id, connection: connection, ticks: 10, confirmed: true))
        let field = try image()
        model.acceptWindowPalette(.init(scope: try XCTUnwrap(HomeArtworkScope(model: model)), accessRevision: model.windowArtworkRevision,
                                         itemID: movie.id, field: field))
        await model.removeConnection(removed.id)
        XCTAssertEqual(removedCredentials, [removed.id])
        XCTAssertEqual(removedArt, [removed.id])
        XCTAssertThrowsError(try archive.url(for: bSubtitle))
        XCTAssertNoThrow(try archive.url(for: aSubtitle))
        XCTAssertEqual(model.connection?.id, connection.id)
        XCTAssertEqual(model.saved.connections.map(\.id), [first.id, connection.id])
        XCTAssertEqual(model.saved.recovery.first?.itemID, movie.id)
        XCTAssertEqual(model.selectedLibraryID, "theater")
        XCTAssertEqual(model.page, "library")
        XCTAssertEqual(model.items.map(\.id), [movie.id])
        XCTAssertEqual(model.detail?.id, movie.id)
        XCTAssertTrue(model.windowColorField === field)
    }
}

private final class CountingPaletteStorage: ApplicationPersisting {
    private let wrapped: ApplicationStorage
    private(set) var writes = 0
    init(_ wrapped: ApplicationStorage) { self.wrapped = wrapped }
    func load() throws -> SavedApplication { try wrapped.load() }
    func save(_ data: SavedApplication) throws {
        try wrapped.save(data)
        writes += 1
    }
}
