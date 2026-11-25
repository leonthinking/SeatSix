import SwiftUI
import XCTest
@testable import SeatSixApp

@MainActor
final class SidebarToolbarLeadingLayoutTests: XCTestCase {
    func testHistoryPositionFollowsTheDividerThroughOpeningClosingAndReversal() {
        for (openWidth, menuWidth) in [(CGFloat(192), CGFloat(180)), (320, 75)] {
            let closed = 36 + 10 + menuWidth
            let opened = openWidth - 94
            // Restart in both directions before either endpoint is reached.
            let journey: [(CGFloat, Bool)] = [(1, true), (0.7, true), (0.4, true), (0.4, false),
                                              (0.65, false), (0.65, true), (0.25, true), (0, true),
                                              (0, false), (0.5, false), (1, false)]
            for (fraction, collapsed) in journey {
                let layout = SidebarToolbarLeadingLayout(paneWidth: fraction * openWidth, expandedPaneWidth: openWidth,
                    leadingInset: 94, collapsed: collapsed, trackingOpenDivider: false)
                let width = measuredWidth(layout, menuWidth: menuWidth)
                XCTAssertEqual(width, closed + (opened - closed) * fraction, accuracy: 1)
                XCTAssertEqual(layout.sourceReveal, 1 - fraction, accuracy: 0.001)
                XCTAssertEqual(layout.sourceIsAvailable, collapsed && fraction == 0)
            }
        }
    }

    func testLiveDividerDragKeepsHistoryAtThePaneEdgeAndSourceHidden() {
        for width in [CGFloat(192), 233, 320] {
            let layout = SidebarToolbarLeadingLayout(paneWidth: width, expandedPaneWidth: 320, leadingInset: 94,
                collapsed: false, trackingOpenDivider: true)
            XCTAssertEqual(measuredWidth(layout, menuWidth: 170), width - 94, accuracy: 1)
            XCTAssertEqual(layout.sourceReveal, 0)
            XCTAssertFalse(layout.sourceIsAvailable)
        }
        let noServer = SidebarToolbarLeadingLayout(paneWidth: 0, expandedPaneWidth: 192, leadingInset: 94,
            collapsed: true, trackingOpenDivider: false)
        XCTAssertEqual(measuredWidth(noServer, menuWidth: nil), 36, accuracy: 1)
    }

    func testSourceRemainsAvailableWhenTheScreenCannotFitASidebar() {
        let pane = SidebarLayout.effectiveWidth(preferredWidth: 192, availableWidth: 720)
        XCTAssertEqual(pane, 0)
        for tracking in [false, true] {
            let layout = SidebarToolbarLeadingLayout(paneWidth: pane, expandedPaneWidth: pane,
                leadingInset: 94, collapsed: false, trackingOpenDivider: tracking)
            XCTAssertTrue(layout.sourceIsAvailable)
            XCTAssertEqual(layout.sourceReveal, 1)
            XCTAssertEqual(measuredWidth(layout, menuWidth: 84), 36 + 10 + 84, accuracy: 1)
        }
    }

    private func measuredWidth(_ layout: SidebarToolbarLeadingLayout, menuWidth: CGFloat?) -> CGFloat {
        let controller = NSHostingController(rootView: layout {
            Color.clear.frame(width: 36, height: 36)
            if let menuWidth { Color.clear.frame(width: menuWidth, height: 36) }
        })
        return controller.sizeThatFits(in: CGSize(width: 900, height: 52)).width
    }
}
