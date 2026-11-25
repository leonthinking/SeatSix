import AppKit
import SwiftUI
import XCTest
@testable import SeatSixApp

final class BrowseCaptionContrastTests: XCTestCase {
    @MainActor
    func testBrowseCaptionsKeepReadableContrastOnLightAndDarkPosters() throws {
        for color in [NSColor.white, .black] {
            let source = NSImage(size: CGSize(width: 160, height: 90), flipped: false) { bounds in
                color.setFill()
                bounds.fill()
                return true
            }
            let thumbnail = try XCTUnwrap(HomeAtmosphereArtwork.thumbnail(from: source))
            let background = try XCTUnwrap(HomeAtmosphereArtwork.blurredBackground(from: thumbnail))
            for (label, size) in [("共 127 项", CGFloat(12)), ("2024 · 118 分钟", CGFloat(10))] {
                func render(showText: Bool) throws -> [Double] {
                    let content = HomeAtmosphereBackground(blurredBackground: background)
                        .frame(width: 210, height: 80)
                        .overlay(alignment: .topLeading) {
                            Text(label)
                                .font(.system(size: size))
                                .opacity(showText ? 1 : 0)
                                .posterCaptionBacking(true)
                                .foregroundStyle(SeatSixStyle.secondary)
                                .padding(4)
                        }
                        .environment(\.colorScheme, .dark)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    return try luminances(of: XCTUnwrap(renderer.cgImage))
                }
                // Hide only the glyphs in the reference. Each visible glyph is
                // compared with the exact backdrop and backing behind it.
                let visible = try render(showText: true)
                let backing = try render(showText: false)
                let glyphContrasts = zip(visible, backing).compactMap { glyph, behind -> Double? in
                    guard abs(glyph - behind) > 0.01 else { return nil }
                    return (max(glyph, behind) + 0.05) / (min(glyph, behind) + 0.05)
                }.sorted()
                XCTAssertGreaterThan(glyphContrasts.count, 100, "The small label must have painted actual text")
                if !glyphContrasts.isEmpty {
                    // Ignore antialiasing at stroke edges. Require at least the
                    // strongest quarter of the text pixels to clear 4.5:1.
                    XCTAssertGreaterThanOrEqual(glyphContrasts[glyphContrasts.count * 3 / 4], 4.5, label)
                }
            }
        }
    }

    private func luminances(of image: CGImage) throws -> [Double] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return stride(from: 0, to: image.width * image.height * 4, by: 4).map { offset in
            SeatSixChromeRGB(red: Double(bytes[offset]) / 255,
                             green: Double(bytes[offset + 1]) / 255,
                             blue: Double(bytes[offset + 2]) / 255).relativeLuminance
        }
    }
}
