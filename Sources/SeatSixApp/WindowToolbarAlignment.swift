import AppKit
import SwiftUI

/// Text fields retain their native focus and accessibility while the
/// non-interactive capsule supplies the system glass finish.
struct ToolbarCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            Group {
                if #available(macOS 26, *) {
                    Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Align the entire control row to this window's traffic lights. AppKit can
/// place their center closer to the edge than a 36pt button can safely fit.
struct WindowToolbarAlignment: ViewModifier {
    @State private var verticalOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.offset(y: verticalOffset)
            .frame(height: SeatSixSidebarMetrics.titlebarHeight)
            .background {
                WindowButtonMeasurement { offset in
                    if verticalOffset != offset { verticalOffset = offset }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct WindowButtonMeasurement: NSViewRepresentable {
    let report: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.report = report
        view.scheduleMeasurement()
    }

    final class Probe: NSView {
        var report: ((CGFloat) -> Void)?
        private var scheduled = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didChangeBackingPropertiesNotification, NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(scheduleMeasurement), name: name, object: window)
            }
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        @objc func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window, self.bounds.height > 0 else { return }
                self.report?(self.controlOffset(in: window))
            }
        }

        private func controlOffset(in window: NSWindow) -> CGFloat {
            guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else { return 0 }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), button.window === window,
                      !button.isHiddenOrHasHiddenAncestor, !button.bounds.isEmpty else { continue }
                let center = button.convert(button.bounds, to: self).midY
                let clearance: CGFloat = 18 + 1
                let aligned = min(bounds.maxY - clearance, max(bounds.minY + clearance, center))
                return aligned - bounds.midY
            }
            return 0
        }
    }
}
