import SwiftUI

struct LightDetailTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

struct ScrolledDetailKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

/// Report only the change from artwork to scrolling content under the pinned toolbar.
struct DetailToolbarScrollMarker: ViewModifier {
    static let space = "detail-scroll-viewport"
    var itemID: String?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                Color.clear.preference(key: ScrolledDetailKey.self,
                                       value: geometry.frame(in: .named(Self.space)).minY < -8 ? itemID : nil)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct DetailArtworkAppearanceKey: EnvironmentKey {
    static let defaultValue = DetailArtworkAppearance.neutral
}

extension EnvironmentValues {
    var detailArtworkAppearance: DetailArtworkAppearance {
        get { self[DetailArtworkAppearanceKey.self] }
        set { self[DetailArtworkAppearanceKey.self] = newValue }
    }
}

enum DetailArtworkTone {
    case neutral, light, dark

    var panelFill: Color {
        switch self {
        case .neutral: SeatSixStyle.panel
        case .light: Color.white.opacity(0.20)
        case .dark: Color.black.opacity(0.22)
        }
    }

    var placeholderFill: Color {
        switch self {
        case .neutral: ShelfRefreshSkeleton.fill
        case .light: Color.black.opacity(0.16)
        case .dark: Color.white.opacity(0.16)
        }
    }
}

extension DetailArtworkAppearance {
    var tone: DetailArtworkTone { hasArtwork ? (isLight ? .light : .dark) : .neutral }

    var secondaryText: Color {
        guard hasArtwork else { return SeatSixStyle.secondary }
        return isLight ? .black.opacity(0.85) : .white.opacity(0.93)
    }

    var accentText: Color {
        guard hasArtwork else { return SeatSixStyle.accent }
        return isLight ? Color(red: 0.035, green: 0.16, blue: 0.14) : .white
    }

    var warningText: Color {
        guard hasArtwork else { return .orange }
        return isLight ? Color(red: 0.31, green: 0.10, blue: 0.025) : Color(red: 1, green: 0.89, blue: 0.71)
    }

    var panelFill: Color { tone.panelFill }
    var placeholderFill: Color { tone.placeholderFill }
}
