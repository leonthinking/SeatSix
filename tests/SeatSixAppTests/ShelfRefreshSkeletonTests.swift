import AppKit
import SwiftUI
import XCTest
@testable import SeatSixApp

final class ShelfRefreshSkeletonTests: XCTestCase {
    func testSnapshotClipsOriginalCardInsteadOfRoundingItsCutEdge() throws {
        let window = CGRect(x: 0, y: 0, width: 200, height: 150)
        let rail = CGRect(x: 20, y: 30, width: 140, height: 90)
        let frame = CGRect(x: -50, y: 55, width: 120, height: 92)
        let region = try XCTUnwrap(ShelfRefreshRegion(frame: frame, viewport: window, scrollClips: [rail], cornerRadius: 14))
        XCTAssertEqual(region.visibleFrame, CGRect(x: 20, y: 55, width: 50, height: 65))
        XCTAssertEqual(region.frame, frame)
        XCTAssertEqual(region.cornerRadius, 14)
        for outside in [CGRect.zero, CGRect(x: 160, y: 40, width: 80, height: 70),
                        CGRect(x: 4, y: -300, width: 60, height: 100)] {
            XCTAssertNil(ShelfRefreshRegion(frame: outside, viewport: window, scrollClips: [rail], cornerRadius: 4))
        }
    }

    @MainActor
    func testRenderedSnapshotCoversOldArtworkAndOnlyPaintsVisibleCardPixels() throws {
        let viewport = CGRect(x: 0, y: 0, width: 150, height: 80)
        let clippedCard = try XCTUnwrap(ShelfRefreshRegion(frame: CGRect(x: 0, y: 10, width: 110, height: 60),
            viewport: viewport, scrollClips: [CGRect(x: 40, y: 0, width: 110, height: 80)], cornerRadius: 14))
        let backdrop = try XCTUnwrap(ShelfRefreshRegion(frame: CGRect(x: 30, y: 0, width: 90, height: 80),
            viewport: viewport, scrollClips: [], cornerRadius: 0, isBackdrop: true))
        let rendered = ImageRenderer(content: Color.red.frame(width: viewport.width, height: viewport.height)
            .overlay { ShelfRefreshSnapshot(regions: [clippedCard, backdrop]) })
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(rendered.cgImage))
        func sample(_ x: Int) throws -> NSColor {
            try XCTUnwrap(bitmap.colorAt(x: x, y: 40)?.usingColorSpace(.sRGB))
        }
        let background = try sample(130)
        let original = try sample(20)
        let visible = try sample(60)
        XCTAssertLessThan(background.redComponent, 0.2, "The old bright red artwork must be fully covered")
        XCTAssertEqual(original.redComponent, background.redComponent, accuracy: 0.01)
        let hero = try sample(35)
        XCTAssertGreaterThan(hero.blueComponent, background.blueComponent + 0.025)
        XCTAssertGreaterThan(visible.blueComponent, hero.blueComponent + 0.04, "Hero copy must be painted above its backdrop")
    }

    @MainActor
    func testMeasuredSkeletonFollowsBothScrollAxesAndIgnoresHiddenPages() async throws {
        let size = CGSize(width: 240, height: 180)
        var measured: [ShelfRefreshRegion] = []
        let root = ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 64)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(0..<60, id: \.self) { _ in
                                Color.blue.frame(width: 80, height: 56).shelfRefreshRegion(cornerRadius: 11)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: 160, height: 56)
                    Color.clear.frame(height: 200)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            Color.clear.frame(width: 90, height: 90).shelfRefreshRegion(cornerRadius: 22)
                .shelfRefreshRegionsVisible(true).shelfRefreshRegionsVisible(false)
        }
        .shelfRefreshViewport(size)
        .onPreferenceChange(ShelfRefreshRegionsKey.self) { measured = $0 }
        let host = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        host.sizingOptions = []
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        host.view.frame = CGRect(origin: .zero, size: size)
        defer { window.contentViewController = nil; window.close() }
        try await settle(host.view)

        let first = try XCTUnwrap(measured.first)
        XCTAssertEqual(measured.count, 2, "Only the two onscreen rail cards should contribute")
        XCTAssertTrue(measured.allSatisfy { $0.cornerRadius == 11 })
        XCTAssertEqual(first.frame, CGRect(x: 40, y: 64, width: 80, height: 56))
        let initial = measured
        let scrolls = scrollViews(in: host.view)
        let horizontal = try XCTUnwrap(scrolls.first { ($0.documentView?.bounds.width ?? 0) > 400 })
        let vertical = try XCTUnwrap(scrolls.first { ($0.documentView?.bounds.height ?? 0) > 240 })
        horizontal.contentView.scroll(to: CGPoint(x: 34, y: 0))
        horizontal.reflectScrolledClipView(horizontal.contentView)
        vertical.contentView.scroll(to: CGPoint(x: 0, y: 75))
        vertical.reflectScrolledClipView(vertical.contentView)
        try await settle(host.view)

        XCTAssertNotEqual(initial, measured)
        XCTAssertEqual(measured.count, 3)
        let clipped = try XCTUnwrap(measured.first)
        XCTAssertEqual(clipped.frame.minY, -11, accuracy: 1)
        XCTAssertEqual(clipped.visibleFrame.minY, 0, accuracy: 1)
        XCTAssertEqual(clipped.frame.minX, 6, accuracy: 1)
        XCTAssertEqual(clipped.visibleFrame.minX, 40, accuracy: 1)
        XCTAssertTrue(measured.allSatisfy { $0.visibleFrame.maxX <= 200 && $0.visibleFrame.maxY <= 180 })
    }

    @MainActor
    func testColdStartHeroAndRailsReserveTheSameSpaceAsFinalArtwork() {
        for width in [CGFloat(666), 1000, 1607] {
            let proposal = CGSize(width: width, height: 2000)
            let hero = NSHostingController(rootView: ShelfRefreshSkeleton(.hero)
                .frame(width: width).fixedSize(horizontal: false, vertical: true)).sizeThatFits(in: proposal)
            XCTAssertEqual(hero.height, min(780, max(440, width * 9 / 16)), accuracy: 1)
            for poster in PosterSize.allCases {
                let rail = NSHostingController(rootView: ShelfRefreshSkeleton(.posterRail, posterSize: poster))
                    .sizeThatFits(in: proposal)
                XCTAssertEqual(rail.height, poster.homeWidth * 2.85 / 2 + 14 + 12 + 16 + 6, accuracy: 2)
                XCTAssertLessThanOrEqual(rail.width, width + 1)
            }
            let resume = NSHostingController(rootView: ShelfRefreshSkeleton(.continuingRail)).sizeThatFits(in: proposal)
            let previewHeight = CGFloat(254) * 9 / 16
            let captionAndPadding: CGFloat = 2 + 16 + 6 + 13 + 28 + 4
            XCTAssertEqual(resume.height, previewHeight + captionAndPadding, accuracy: 2)
        }
    }

    @MainActor
    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        if let scroll = view as? NSScrollView {
            return [scroll] + view.subviews.flatMap { scrollViews(in: $0) }
        }
        return view.subviews.flatMap { scrollViews(in: $0) }
    }
}
