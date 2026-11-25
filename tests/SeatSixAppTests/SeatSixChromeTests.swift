import AppKit
import SwiftUI
import XCTest
@testable import SeatSixApp

final class SeatSixChromeTests: XCTestCase {
    func testLargeAndCompactSurfacesKeepDifferentContrastBudgets() {
        let active = policy()
        XCTAssertLessThan(active.tintOpacity(for: .navigation), active.tintOpacity(for: .toolbar))
        XCTAssertLessThan(active.tintOpacity(for: .toolbar), active.tintOpacity(for: .popover))
        let inactive = policy(isActive: false)
        for role in SeatSixSurfaceRole.allCases {
            XCTAssertGreaterThanOrEqual(inactive.tintOpacity(for: role), active.tintOpacity(for: role),
                                        "An inactive window must calm the backdrop instead of becoming more transparent")
            XCTAssertLessThan(inactive.edgeOpacity(for: role), active.edgeOpacity(for: role))
        }
        // A fully white sampled backdrop is the upper bound for any public
        // material behind the control. Secondary labels remain readable even
        // when the underlying operating-system material is completely clear.
        let whiteBackdrop = SeatSixChromeRGB(red: 1, green: 1, blue: 1)
        let fill = SeatSixChromeRGB(red: 0.12, green: 0.14, blue: 0.17)
        for role in [SeatSixSurfaceRole.toolbar, .popover] {
            let background = composite(fill, alpha: active.tintOpacity(for: role), over: whiteBackdrop)
            XCTAssertGreaterThan(contrast(textOpacity: 0.84, background: background), 4.5)
        }
    }

    func testReadabilityAndMotionPreferencesApplyToEverySurface() {
        for role in SeatSixSurfaceRole.allCases {
            for active in [false, true] {
                for reducedMotion in [false, true] {
                    for options in [(true, false), (false, true), (true, true)] {
                        let value = policy(reduceTransparency: options.0, increasedContrast: options.1,
                                           reduceMotion: reducedMotion, isActive: active)
                        XCTAssertTrue(value.isOpaque)
                        XCTAssertEqual(value.tintOpacity(for: role), 1)
                        XCTAssertEqual(value.emphasizesBoundary, options.1)
                        XCTAssertEqual(value.allowsAnimation, !reducedMotion)
                        XCTAssertEqual(value.isActive, active)
                    }
                }
            }
        }
    }

    @MainActor
    func testWhitePosterHasQuarterBlackAtTheTopAndSettlesIntoThePageBackground() throws {
        let poster = try blurredPoster(width: 160, height: 90, left: .white, right: .white)
        let backdrop = HomeAtmosphereBackground(blurredBackground: poster).frame(width: 320, height: 180)
        let cg = try XCTUnwrap(ImageRenderer(content: backdrop).cgImage)
        let pixels = try sRGBPixels(in: cg)
        let top = pixels[cg.width + cg.width / 2].rgb
        let middle = pixels[(cg.height / 2) * cg.width + cg.width / 2].rgb
        let bottom = pixels[(cg.height - 2) * cg.width + cg.width / 2].rgb
        let topReference = ImageRenderer(content: Color.white.overlay(Color.black.opacity(0.25)).frame(width: 1, height: 1))
        let whiteUnderBlack = try sRGBPixels(in: XCTUnwrap(topReference.cgImage))[0].rgb
        let canvas = try sRGBPixels(in: XCTUnwrap(ImageRenderer(content: SeatSixStyle.background.frame(width: 1, height: 1)).cgImage))[0].rgb
        assertSameColor(top, whiteUnderBlack, accuracy: 0.025)
        assertSameColor(bottom, canvas, accuracy: 0.01)
        XCTAssertGreaterThan(top.relativeLuminance, middle.relativeLuminance + 0.1)
        XCTAssertGreaterThan(middle.relativeLuminance, bottom.relativeLuminance + 0.015)
    }

    @MainActor
    func testBlurredBackdropKeepsImageRegionsAndSoftensTheBoundary() throws {
        let poster = try blurredPoster(width: 1600, height: 900, left: .red, right: .blue)
        let cg = try XCTUnwrap(poster.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), HomeAtmosphereArtwork.maximumDimension)
        let pixels = try sRGBPixels(in: cg)
        let row = cg.height / 2 * cg.width
        let left = pixels[row + cg.width / 8].rgb
        let seam = pixels[row + cg.width / 2].rgb
        let right = pixels[row + cg.width * 7 / 8].rgb
        XCTAssertGreaterThan(left.red, 0.85)
        XCTAssertGreaterThan(right.blue, 0.85)
        XCTAssertGreaterThan(seam.red, 0.18)
        XCTAssertGreaterThan(seam.blue, 0.18)
        XCTAssertTrue(pixels.allSatisfy { $0.alpha >= 0.995 })
    }

    @MainActor
    func testPosterHuesSurviveAtTheTopAndFadeTogetherAcrossWindowActivation() throws {
        let poster = try blurredPoster(width: 160, height: 90,
                                       left: NSColor(srgbRed: 0.85, green: 0.60, blue: 0.45, alpha: 1),
                                       right: NSColor(srgbRed: 0.45, green: 0.60, blue: 0.85, alpha: 1))
        for state in [ControlActiveState.active, .inactive] {
            let rendered = ImageRenderer(content: HomeAtmosphereBackground(blurredBackground: poster)
                .environment(\.controlActiveState, state).frame(width: 320, height: 180))
            let cg = try XCTUnwrap(rendered.cgImage)
            let pixels = try sRGBPixels(in: cg)
            func edges(at row: Int) -> (warm: SeatSixChromeRGB, cool: SeatSixChromeRGB) {
                (pixels[row * cg.width + cg.width / 8].rgb, pixels[row * cg.width + cg.width * 7 / 8].rgb)
            }
            let upper = edges(at: cg.height / 12)
            let middle = edges(at: cg.height / 2)
            let bottom = edges(at: cg.height - 1)
            XCTAssertGreaterThan(upper.warm.red - upper.warm.blue, 0.22)
            XCTAssertGreaterThan(upper.cool.blue - upper.cool.red, 0.22)
            XCTAssertGreaterThan(middle.warm.red - middle.cool.red, 0.045)
            XCTAssertLessThan(middle.warm.red - middle.cool.red, upper.warm.red - upper.cool.red - 0.03)
            assertSameColor(bottom.warm, bottom.cool, accuracy: 0.01)
        }
    }

    @MainActor
    func testGrayscalePostersPreserveNeutralityAndShadowDetail() throws {
        let grays = try [0.05, 0.4, 0.95].map { gray in
            let color = NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1)
            let poster = try blurredPoster(width: 16, height: 9, left: color, right: color)
            let cg = try XCTUnwrap(poster.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return try sRGBPixels(in: cg)[cg.width * cg.height / 2].rgb
        }
        for point in grays {
            XCTAssertEqual(point.red, point.green, accuracy: 0.01)
            XCTAssertEqual(point.green, point.blue, accuracy: 0.01)
        }
        XCTAssertGreaterThan(grays[1].red - grays[0].red, 0.25)
        XCTAssertGreaterThan(grays[2].red - grays[1].red, 0.4)
    }

    @MainActor
    func testBrightPostersRetainSourceColorAndTransparentImagesCannotReplaceTheBackground() throws {
        for color in [NSColor.white, .green, .yellow] {
            let poster = try blurredPoster(width: 3, height: 2, left: color, right: color)
            let cg = try XCTUnwrap(poster.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(cg.width, 3)
            XCTAssertEqual(cg.height, 2)
            let pixels = try sRGBPixels(in: cg)
            XCTAssertGreaterThan(pixels[cg.width + 1].rgb.green, 0.9)
        }
        let clear = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: image(width: 8, height: 4, left: .clear, right: .clear)))
        XCTAssertNil(HomeAtmosphereArtwork.blurredBackground(from: clear))
        let partial = try blurredPoster(width: 32, height: 24, left: .clear, right: .green)
        let cg = try XCTUnwrap(partial.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(try sRGBPixels(in: cg)[cg.width - 1].rgb.green, 0.80,
                             "Visible artwork with a transparent margin can still supply the shared background")
    }

    @MainActor
    private func blurredPoster(width: Int, height: Int, left: NSColor, right: NSColor) throws -> NSImage {
        let source = try image(width: width, height: height, left: left, right: right)
        let thumbnail = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: source))
        return try XCTUnwrap(HomeAtmosphereArtwork.blurredBackground(from: thumbnail))
    }

    private func assertSameColor(_ actual: SeatSixChromeRGB, _ expected: SeatSixChromeRGB, accuracy: Double,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.red, expected.red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: accuracy, file: file, line: line)
    }

    private func policy(reduceTransparency: Bool = false, increasedContrast: Bool = false,
                        reduceMotion: Bool = false, isActive: Bool = true) -> SeatSixSurfacePolicy {
        SeatSixSurfacePolicy(reduceTransparency: reduceTransparency, increasedContrast: increasedContrast,
                             reduceMotion: reduceMotion, isActive: isActive)
    }

    private func composite(_ foreground: SeatSixChromeRGB, alpha: Double, over background: SeatSixChromeRGB) -> SeatSixChromeRGB {
        SeatSixChromeRGB(red: foreground.red * alpha + background.red * (1 - alpha),
                         green: foreground.green * alpha + background.green * (1 - alpha),
                         blue: foreground.blue * alpha + background.blue * (1 - alpha))
    }

    private func contrast(textOpacity: Double, background: SeatSixChromeRGB) -> Double {
        let text = composite(SeatSixChromeRGB(red: 1, green: 1, blue: 1), alpha: textOpacity, over: background)
        return (text.relativeLuminance + 0.05) / (background.relativeLuminance + 0.05)
    }

    private func sRGBPixels(in image: CGImage) throws -> [(rgb: SeatSixChromeRGB, alpha: Double)] {
        // colorAt() reports calibrated NSColor components even when the bitmap
        // carries an sRGB profile. Converting that NSColor to sRGB would apply
        // an extra gamma transform. Sample through an explicitly tagged sRGB
        // render target, which also tests the NSImage/CGImage colour-space hop.
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data)
        let bytes = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return stride(from: 0, to: image.width * image.height * 4, by: 4).map { index in
            (SeatSixChromeRGB(red: Double(bytes[index]) / 255,
                              green: Double(bytes[index + 1]) / 255,
                              blue: Double(bytes[index + 2]) / 255), Double(bytes[index + 3]) / 255)
        }
    }

    @MainActor
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
