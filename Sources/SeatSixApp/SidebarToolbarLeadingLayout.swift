import SwiftUI

/// Move the following toolbar items between their two real endpoints using
/// the native divider's presentation position, including interrupted motion.
struct SidebarToolbarLeadingLayout: Layout {
    let paneWidth: CGFloat
    let expandedPaneWidth: CGFloat
    let leadingInset: CGFloat
    let collapsed: Bool
    let trackingOpenDivider: Bool

    private let spacing: CGFloat = 10
    private var fullWidth: CGFloat { max(paneWidth, expandedPaneWidth) }
    var sourceReveal: CGFloat {
        guard fullWidth > 0.5 else { return 1 }
        if !collapsed && trackingOpenDivider { return 0 }
        return max(0, 1 - max(0, paneWidth) / fullWidth)
    }
    var sourceIsAvailable: Bool { paneWidth <= 0.5 && (collapsed || expandedPaneWidth <= 0.5) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let toggle = subviews.first else { return .zero }
        let button = toggle.sizeThatFits(.unspecified)
        let source = subviews.dropFirst().first?.sizeThatFits(.unspecified)
        let closed = button.width + (source.map { spacing + $0.width } ?? 0)
        let openEdge = !collapsed && trackingOpenDivider ? paneWidth : fullWidth
        let opened = max(button.width, openEdge - leadingInset)
        let width = opened + (closed - opened) * sourceReveal
        return CGSize(width: width, height: max(button.height, source?.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
