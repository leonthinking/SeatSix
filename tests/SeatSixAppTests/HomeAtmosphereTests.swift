import AppKit
import XCTest
@testable import SeatSixApp

@MainActor
final class HomeAtmosphereTests: XCTestCase {
    func testBackdropThumbnailPreservesSpatialColorAndBoundsMemory() throws {
        let original = try image(width: 1600, height: 900, left: .red, right: .blue)
        let thumbnail = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: original))
        let cgImage = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cgImage.width, 160)
        XCTAssertEqual(cgImage.height, 90)
        let pixels = NSBitmapImageRep(cgImage: cgImage)
        let left = try XCTUnwrap(pixels.colorAt(x: 20, y: 45)?.usingColorSpace(.sRGB))
        let right = try XCTUnwrap(pixels.colorAt(x: 140, y: 45)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(left.redComponent, 0.9)
        XCTAssertLessThan(left.blueComponent, 0.1)
        XCTAssertGreaterThan(right.blueComponent, 0.9)
        XCTAssertLessThan(right.redComponent, 0.1,
                          "The ambient image must retain regional colors instead of flattening to an average")
    }

    func testSmallArtworkIsNotUpscaledAndSolidSourcesStayDistinct() throws {
        let red = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: image(width: 60, height: 30, left: .red, right: .red)))
        let blue = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: image(width: 60, height: 30, left: .blue, right: .blue)))
        XCTAssertEqual(red.size, NSSize(width: 60, height: 30))
        XCTAssertEqual(blue.size, red.size)
        let redPixels = NSBitmapImageRep(cgImage: try XCTUnwrap(red.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let bluePixels = NSBitmapImageRep(cgImage: try XCTUnwrap(blue.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertGreaterThan(try XCTUnwrap(redPixels.colorAt(x: 30, y: 15)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(bluePixels.colorAt(x: 30, y: 15)).blueComponent, 0.9)
    }

    func testBlurSoftensBoundariesAndExtendsOpaqueEdgeColors() throws {
        let original = try image(width: 1600, height: 900, left: .red, right: .blue)
        let snapshot = try XCTUnwrap(HomeArtworkSnapshot.make(scope: scope(), itemID: "movie", requestKey: "hero",
                                     loadedKey: "hero", image: original, accessRevision: UUID()))
        let bitmap = try XCTUnwrap(snapshot.blurredBackground.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(bitmap.width, 160)
        XCTAssertEqual(bitmap.height, 90)
        let pixels = NSBitmapImageRep(cgImage: bitmap)
        func color(x: Int, y: Int) throws -> NSColor {
            try XCTUnwrap(pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        let left = try color(x: 0, y: 0), right = try color(x: 159, y: 89)
        XCTAssertEqual(left.alphaComponent, 1, accuracy: 0.01)
        XCTAssertEqual(right.alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(left.redComponent, 0.95)
        XCTAssertLessThan(left.blueComponent, 0.05)
        XCTAssertGreaterThan(right.blueComponent, 0.95)
        XCTAssertLessThan(right.redComponent, 0.05)
        let before = try color(x: 76, y: 45), after = try color(x: 83, y: 45)
        XCTAssertGreaterThan(before.blueComponent, 0.1)
        XCTAssertGreaterThan(after.redComponent, 0.1)
        XCTAssertGreaterThan(before.redComponent, after.redComponent)
        XCTAssertGreaterThan(after.blueComponent, before.blueComponent)
    }

    func testPortraitPosterBlursVerticalColorBandsAtWindowScale() throws {
        for width in [2, 107] {
            let height = 160
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
            let portrait = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
            let blurred = try XCTUnwrap(HomeAtmosphereArtwork.blurredBackground(from: portrait))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(blurred.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            // Ten thumbnail rows are about 61 points at the default height.
            for y in [69, 90] {
                let color = try XCTUnwrap(bitmap.colorAt(x: width / 2, y: y)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(min(color.redComponent, color.blueComponent), 0.16)
            }
        }
    }

    func testSnapshotRejectsUnloadedMissingAndChangedRequests() throws {
        let scope = scope(), artwork = try image(width: 320, height: 180, left: .red, right: .blue)
        let accessRevision = UUID()
        func snapshot(_ loadedKey: String?, image: NSImage? = nil) -> HomeArtworkSnapshot? {
            HomeArtworkSnapshot.make(scope: scope, itemID: "movie", requestKey: "current-request",
                                     loadedKey: loadedKey, image: image, accessRevision: accessRevision)
        }
        XCTAssertNil(snapshot(nil, image: artwork))
        XCTAssertNil(snapshot("previous-request", image: artwork))
        XCTAssertNil(snapshot("current-request"))
        let transparent = try image(width: 320, height: 180, left: .clear, right: .clear)
        XCTAssertNil(snapshot("current-request", image: transparent), "A decoded image with no visible pixels cannot set a window color")
        let partiallyVisible = try image(width: 320, height: 180, left: .clear, right: .blue)
        XCTAssertNotNil(snapshot("current-request", image: partiallyVisible))
        XCTAssertNil(HomeArtworkSnapshot.make(scope: nil, itemID: "movie", requestKey: "current-request",
                                              loadedKey: "current-request", image: artwork, accessRevision: accessRevision))
        let accepted = try XCTUnwrap(snapshot("current-request", image: artwork))
        XCTAssertEqual(accepted.itemID, "movie")
        XCTAssertTrue(accepted.isCurrent(requestKey: "current-request", scope: scope))
        XCTAssertFalse(accepted.isCurrent(requestKey: "next-request", scope: scope),
                       "A late or previously loaded image must not tint the newly selected hero")
        XCTAssertFalse(accepted.isCurrent(requestKey: "current-request", scope: nil))
        XCTAssertEqual(accepted, accepted)
    }

    func testScopeRejectsEveryConnectionAccountLibraryAndRevisionChange() throws {
        let original = scope()
        let artwork = try image(width: 320, height: 180, left: .red, right: .blue)
        let snapshot = try XCTUnwrap(HomeArtworkSnapshot.make(scope: original, itemID: "movie", requestKey: "loaded",
                                                              loadedKey: "loaded", image: artwork, accessRevision: UUID()))
        let changed: [HomeArtworkScope] = [
            scope(connectionID: UUID()), scope(serverID: "other-server"), scope(userID: "other-user"),
            scope(baseURL: "https://other.example.invalid"), scope(libraryID: "other-library"), scope(posterRevision: UUID())
        ]
        XCTAssertTrue(snapshot.matches(scope: original))
        XCTAssertFalse(snapshot.matches(scope: nil))
        for value in changed {
            XCTAssertFalse(snapshot.matches(scope: value), "Old artwork must be cleared when any scope identity changes")
        }
    }

    func testAccessibilityPolicyUsesNeutralBackdropAndHonorsReducedMotion() {
        for reduceTransparency in [false, true] {
            for highContrast in [false, true] {
                let normal = HomeAtmospherePolicy(reduceTransparency: reduceTransparency,
                                                  increasedContrast: highContrast, reduceMotion: false)
                let reduced = HomeAtmospherePolicy(reduceTransparency: reduceTransparency,
                                                   increasedContrast: highContrast, reduceMotion: true)
                XCTAssertEqual(normal.showsArtwork, !reduceTransparency && !highContrast)
                XCTAssertEqual(reduced.showsArtwork, normal.showsArtwork)
                XCTAssertEqual(normal.allowsAnimation, normal.showsArtwork)
                XCTAssertFalse(reduced.allowsAnimation)
            }
        }
    }

    private func scope(connectionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                       serverID: String = "server", userID: String = "user",
                       baseURL: String = "https://example.invalid", libraryID: String = "movies",
                       posterRevision: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!) -> HomeArtworkScope {
        HomeArtworkScope(connectionID: connectionID, serverID: serverID, userID: userID,
                         baseURL: baseURL, libraryID: libraryID, posterRevision: posterRevision)
    }

    private func image(width: Int, height: Int, left: NSColor, right: NSColor) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(left.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(right.cgColor)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: width, height: height))
    }
}
