import AppKit
import SwiftUI

/// An inert native anchor for identifying a mounted browse surface and its
/// terminal card without relying on offscreen accessibility or scroll heights.
struct BrowseViewProbe: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.setAccessibilityElement(false)
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
