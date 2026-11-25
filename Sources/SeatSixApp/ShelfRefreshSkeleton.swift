import SwiftUI

/// The original bounds preserve rounded edges when part of a card is scrolled out of view.
struct ShelfRefreshRegion: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let cornerRadius: CGFloat
    let isBackdrop: Bool
    let detailTone: DetailArtworkTone

    init?(frame: CGRect, viewport: CGRect, scrollClips: [CGRect], cornerRadius: CGFloat,
          isBackdrop: Bool = false, detailTone: DetailArtworkTone = .neutral) {
        guard !frame.isInfinite, !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
        let visible = scrollClips.reduce(frame.intersection(viewport)) { $0.intersection($1) }
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        self.frame = frame
        self.visibleFrame = visible
        self.cornerRadius = cornerRadius
        self.isBackdrop = isBackdrop
        self.detailTone = detailTone
    }
}

struct ShelfRefreshRegionsKey: PreferenceKey {
    static var defaultValue: [ShelfRefreshRegion] { [] }
    static func reduce(value: inout [ShelfRefreshRegion], nextValue: () -> [ShelfRefreshRegion]) {
        value.append(contentsOf: nextValue())
    }
}

private enum ShelfViewportKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

private enum ShelfVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

private extension EnvironmentValues {
    var shelfViewportSize: CGSize? {
        get { self[ShelfViewportKey.self] }
        set { self[ShelfViewportKey.self] = newValue }
    }
    var shelfVisible: Bool {
        get { self[ShelfVisibleKey.self] }
        set { self[ShelfVisibleKey.self] = newValue }
    }
}

extension View {
    func shelfRefreshViewport(_ size: CGSize) -> some View {
        coordinateSpace(name: "shelf-refresh-viewport").environment(\.shelfViewportSize, size)
    }

    func shelfRefreshRegionsVisible(_ visible: Bool) -> some View {
        transformEnvironment(\.shelfVisible) { $0 = $0 && visible }
    }

    func shelfRefreshRegion(cornerRadius: CGFloat = 6, isBackdrop: Bool = false) -> some View {
        modifier(ShelfRegionMeasurement(cornerRadius: cornerRadius, isBackdrop: isBackdrop))
    }
}

private struct ShelfRegionMeasurement: ViewModifier {
    @Environment(\.detailArtworkAppearance) private var appearance
    @Environment(\.shelfViewportSize) private var size
    @Environment(\.shelfVisible) private var visible
    let cornerRadius: CGFloat
    let isBackdrop: Bool

    func body(content: Content) -> some View {
        content.background {
            if visible, let size {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .named("shelf-refresh-viewport"))
                    let clips = [Axis.horizontal, .vertical].compactMap { axis in
                        geometry.bounds(of: .scrollView(axis: axis))?.offsetBy(dx: frame.minX, dy: frame.minY)
                    }
                    if let region = ShelfRefreshRegion(frame: frame, viewport: CGRect(origin: .zero, size: size),
                                                       scrollClips: clips, cornerRadius: cornerRadius,
                                                       isBackdrop: isBackdrop, detailTone: appearance.tone) {
                        Color.clear.preference(key: ShelfRefreshRegionsKey.self, value: [region])
                    }
                }
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

/// Draw the pre-refresh viewport; the original scroll view remains mounted behind it.
struct ShelfRefreshSnapshot: View {
    let regions: [ShelfRefreshRegion]
    var keepsDetailBackground = false
    var revealsWindowPalette = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, _ in
            for backdrop in [true, false] {
                for region in regions where region.isBackdrop == backdrop {
                    let tone = keepsDetailBackground && !reduceTransparency && contrast != .increased ? region.detailTone : .neutral
                    let color = backdrop ? (tone == .neutral ? ShelfRefreshSkeleton.backdrop : tone.panelFill) : tone.placeholderFill
                    var clipped = context
                    clipped.clip(to: Path(region.visibleFrame))
                    let path = Path(roundedRect: region.frame, cornerRadius: region.cornerRadius, style: .continuous)
                    clipped.fill(path, with: .color(color))
                }
            }
        }
        .background {
            if !keepsDetailBackground && !revealsWindowPalette { SeatSixStyle.background }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Place these inside the existing page's scroll hierarchy when the first load
/// has no cards to measure. The caller supplies the page's padding and headings.
struct ShelfRefreshSkeleton: View {
    enum Layout {
        case hero, continuingRail, libraryTiles(count: Int), posterRail, grid(continuing: Bool)
    }

    static let backdrop = Color(red: 0.105, green: 0.12, blue: 0.148)
    static let fill = Color(red: 0.16, green: 0.18, blue: 0.21)
    let layout: Layout
    let posterSize: PosterSize

    init(_ layout: Layout, posterSize: PosterSize = .standard) {
        self.layout = layout
        self.posterSize = posterSize
    }

    var body: some View {
        Group {
            switch layout {
            case .hero:
                Rectangle().fill(Self.backdrop)
                    .aspectRatio(16 / 9, contentMode: .fit).frame(minHeight: 440, maxHeight: 780)
                    .shelfRefreshRegion(cornerRadius: 0, isBackdrop: true)
                    .overlay(alignment: .bottomLeading) {
                        GeometryReader { geometry in
                            VStack(alignment: .leading, spacing: 12) {
                                bar(width: 72, height: 10)
                                bar(width: min(320, geometry.size.width * 0.54), height: 36)
                                bar(width: 112, height: 12)
                                bar(width: min(480, geometry.size.width * 0.66), height: 12)
                            }
                            .padding(.leading, geometry.size.width < 760 ? 24 : 40)
                            .padding(.bottom, HomeHeroCarousel.copyBottomInset)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
            case .continuingRail:
                rail(continuing: true)
            case .posterRail:
                rail(continuing: false)
            case .libraryTiles(let count):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(0..<max(0, count), id: \.self) { _ in
                        shape(12).frame(height: 56)
                    }
                }
            case .grid(let continuing):
                let columns = [GridItem(.adaptive(minimum: continuing ? 230 : posterSize.gridMinimum,
                                                  maximum: continuing ? 340 : posterSize.gridMaximum),
                                        spacing: 18, alignment: .top)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(0..<18, id: \.self) { _ in
                        card(continuing: continuing)
                    }
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func rail(continuing: Bool) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: continuing ? 16 : 18) {
                ForEach(0..<12, id: \.self) { _ in
                    card(continuing: continuing).frame(width: continuing ? 254 : posterSize.homeWidth)
                }
            }
            .padding(.bottom, continuing ? 4 : 6)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func card(continuing: Bool) -> some View {
        if continuing {
            VStack(alignment: .leading, spacing: 0) {
                shape(0).aspectRatio(16 / 9, contentMode: .fit)
                Color.clear.frame(height: 2)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 100, height: 16)
                    bar(width: 68, height: 13)
                }
                .padding(14)
            }
            .background(SeatSixStyle.panel).clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                shape(9).aspectRatio(2 / 2.85, contentMode: .fit)
                bar(width: 92, height: 14)
                bar(width: 48, height: 12)
            }
        }
    }

    private func shape(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Self.fill)
            .shelfRefreshRegion(cornerRadius: radius)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Capsule().fill(Color.white.opacity(0.12)).frame(width: width, height: height)
            .shelfRefreshRegion(cornerRadius: height / 2)
    }
}
