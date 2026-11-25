import SwiftUI

/// Follow the real text's line height so resolving a placeholder preserves
/// the surrounding card layout, including fonts with a taller CJK ascent.
struct DetailPlaceholderLine: View {
    @Environment(\.detailArtworkAppearance) private var appearance
    let width: CGFloat
    let font: Font

    var body: some View {
        Text(verbatim: "影")
            .font(font).hidden()
            .frame(maxWidth: width, alignment: .leading)
            .overlay { Capsule().fill(appearance.placeholderFill).shelfRefreshRegion().padding(.vertical, 3) }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
