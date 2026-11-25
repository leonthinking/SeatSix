import AppKit
import SwiftUI

/// Resolve the actual pane edge in the same layout pass as the window toolbar.
struct SidebarEdgeAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

/// Saved width describes the user's preference, while effective width adapts
/// to the current window without overwriting that preference.
enum SidebarLayout {
    static let defaultWidth: CGFloat = 192
    static let minWidth: CGFloat = 192
    static let maxWidth: CGFloat = 320
    static let rightContentMin: CGFloat = 738

    static func normalizedWidth(_ preferredWidth: Double) -> CGFloat {
        guard preferredWidth.isFinite else { return defaultWidth }
        return min(maxWidth, max(minWidth, CGFloat(preferredWidth)))
    }

    static func effectiveWidth(preferredWidth: Double, availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
        return min(normalizedWidth(preferredWidth), max(0, availableWidth - rightContentMin))
    }
}

@MainActor
enum SidebarPreferenceUpdate {
    /// Merge with the latest preferences so a drag cannot overwrite a concurrent
    /// change made in Settings. Failed writes leave the published width intact.
    @discardableResult
    static func width(_ width: CGFloat, model: ApplicationModel, onError: (String) -> Void) -> Bool {
        var preferences = model.applicationPreferences
        preferences.sidebarWidth = Double(SidebarLayout.normalizedWidth(Double(width)))
        guard preferences != model.applicationPreferences else { return true }
        guard model.updateApplicationPreferences(preferences) else {
            onError(model.preferencesError ?? "无法保存侧边栏宽度，请稍后重试。")
            return false
        }
        return true
    }
}

/// SwiftUI hosts both columns of HSplitView in the same view graph. The native
/// split item owns the divider and its collapse animation, while environment,
/// focus and content preferences still cross the column boundary.
struct SeatSixSidebarSplit<Detail: View>: View {
    @ObservedObject var model: ApplicationModel
    let availableWidth: CGFloat
    let appearance: SeatSixSidebarAppearancePolicy
    let onError: (String) -> Void
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HSplitView {
            GeometryReader { pane in
                SeatSixSidebar(model: model, appearanceOverride: appearance, width: pane.size.width)
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 0, maxWidth: SidebarLayout.maxWidth)
            detail()
                .ignoresSafeArea(.container, edges: .top)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .anchorPreference(key: SidebarEdgeAnchor.self, value: .bounds) { $0 }
                .background {
                    NativeSidebarDivider(preferred: model.applicationPreferences.sidebarWidth,
                        available: availableWidth, collapsed: model.applicationPreferences.sidebarCollapsed,
                        reduceMotion: !appearance.allowsAnimation, saveWidth: { width, previousWidth in
                            guard model.applicationPreferences.sidebarWidth == previousWidth,
                                  !model.applicationPreferences.sidebarCollapsed else { return false }
                            return SidebarPreferenceUpdate.width(width, model: model, onError: onError)
                        })
                    .frame(width: 0, height: 0).accessibilityHidden(true)
                }
        }
        .frame(width: max(0, availableWidth))
    }
}

/// HSplitView exposes its native divider for dragging and accessibility. Use
/// the enclosing public AppKit controller to request collapse and restore the
/// user's preferred width without installing a second resize gesture.
private struct NativeSidebarDivider: NSViewRepresentable {
    let preferred: Double
    let available: CGFloat
    let collapsed: Bool
    let reduceMotion: Bool
    let saveWidth: (CGFloat, Double) -> Bool

    struct Configuration: Equatable {
        var preferred: Double
        var available: CGFloat
        var collapsed: Bool
        var effective: CGFloat {
            SidebarLayout.effectiveWidth(preferredWidth: preferred, availableWidth: available)
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.saveWidth = saveWidth
        view.animate = !reduceMotion && !context.transaction.disablesAnimations
        view.update(.init(preferred: preferred, available: available, collapsed: collapsed))
    }

    final class Probe: NSView {
        private weak var split: NSSplitView?
        private var doubleClickMonitor: Any?
        var saveWidth: ((CGFloat, Double) -> Bool)?
        var animate = false
        private var configuration: Configuration?
        private var applied: Configuration?
        private var scheduled = false
        private var applying = false
        private var changingVisibility = false
        private var pendingWidthGeneration: Int?
        private var trackedWidth: CGFloat?
        private var startingWidths: [CGFloat] = []
        private var generation = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let doubleClickMonitor { NSEvent.removeMonitor(doubleClickMonitor); self.doubleClickMonitor = nil }
            generation += 1
            split = nil
            applied = nil
            changingVisibility = false
            trackedWidth = nil
            startingWidths.removeAll()
            if window != nil { schedule() }
        }

        func update(_ value: Configuration) {
            guard configuration != value else { return }
            configuration = value
            schedule()
        }

        private func schedule() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.apply()
            }
        }

        private func apply() {
            guard window != nil, let configuration, configuration.available > 0 else { return }
            if split == nil {
                var ancestor = superview
                while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
                guard let split = ancestor as? NSSplitView else { return }
                self.split = split
                observeDividerDoubleClicks(in: split)
                NotificationCenter.default.addObserver(self, selector: #selector(willResize),
                    name: NSSplitView.willResizeSubviewsNotification, object: split)
                NotificationCenter.default.addObserver(self, selector: #selector(resized),
                    name: NSSplitView.didResizeSubviewsNotification, object: split)
            }
            guard let split, let controller = split.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first, split.arrangedSubviews.count == 2,
                  applied != configuration else { return }
            let previous = applied
            trackedWidth = nil
            generation += 1
            let generation = self.generation
            applied = configuration
            applying = true
            defer { applying = false }
            let divider = split.dividerThickness
            let minimum = max(0, min(SidebarLayout.minWidth, configuration.effective) - divider)
            let maximum = max(minimum, min(SidebarLayout.maxWidth,
                configuration.available - SidebarLayout.rightContentMin) - divider)
            item.maximumThickness = maximum
            item.minimumThickness = minimum
            item.collapseBehavior = .useConstraints
            item.canCollapse = false // Dragging adjusts width. The toolbar controls visibility.
            item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
            if item.isCollapsed != configuration.collapsed {
                changingVisibility = true
                if previous == nil && configuration.collapsed {
                    // Let AppKit remember where to expand even when first launched collapsed.
                    split.layoutSubtreeIfNeeded()
                    split.setPosition(max(0, configuration.effective - divider), ofDividerAt: 0)
                }
                if !configuration.collapsed {
                    item.minimumThickness = max(minimum, configuration.effective - divider)
                    split.layoutSubtreeIfNeeded()
                }
                let finish = { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.changingVisibility = false
                    item.minimumThickness = minimum
                    self.restoreWidth()
                }
                if animate && previous != nil {
                    NSAnimationContext.runAnimationGroup { _ in
                        item.animator().isCollapsed = configuration.collapsed
                    } completionHandler: { MainActor.assumeIsolated { finish() } }
                } else {
                    item.isCollapsed = configuration.collapsed
                    finish()
                }
            } else {
                changingVisibility = false
                restoreWidth()
            }
        }

        private func restoreWidth() {
            guard let split, let applied, !applied.collapsed else { return }
            let target = max(0, applied.effective - split.dividerThickness)
            split.layoutSubtreeIfNeeded()
            split.setPosition(target, ofDividerAt: 0)
        }

        private func observeDividerDoubleClicks(in split: NSSplitView) {
            doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak split] event in
                guard let self, let split, event.clickCount == 2, event.window === split.window,
                      let applied = self.applied, !applied.collapsed, let detail = split.arrangedSubviews.last else { return event }
                let point = split.convert(event.locationInWindow, from: nil)
                guard split.bounds.contains(point), abs(point.x - detail.frame.minX) <= 3 else { return event }
                if self.saveWidth?(SidebarLayout.defaultWidth, applied.preferred) == false { self.restoreWidth() }
                return nil
            }
        }

        @objc private func willResize(_ note: Notification) {
            guard (note.userInfo?["NSSplitViewDividerIndex"] as? NSNumber)?.intValue == 0,
                  let width = split?.arrangedSubviews.last?.frame.minX else { return }
            startingWidths.append(width)
        }

        @objc private func resized(_ note: Notification) {
            guard (note.userInfo?["NSSplitViewDividerIndex"] as? NSNumber)?.intValue == 0 else { return }
            let start = startingWidths.popLast()
            guard !applying, !changingVisibility,
                  let split, let applied, applied == configuration, !applied.collapsed,
                  abs(split.bounds.width - applied.available) < 1,
                  split.arrangedSubviews.count == 2, let detail = split.arrangedSubviews.last else { return }

            // AppKit also reports a divider index after host layout refits a
            // pane. A native adjustment (including AX) moves the edge between
            // its will/did notifications. Keep its position before a later refit.
            if let start, abs(detail.frame.minX - start) > 0.5 {
                trackedWidth = detail.frame.minX
            }
            if let event = NSApp.currentEvent, event.type == .leftMouseDragged, event.window === split.window {
                let x = split.convert(event.locationInWindow, from: nil).x
                let allowed = SidebarLayout.effectiveWidth(preferredWidth: Double(x), availableWidth: applied.available)
                if abs(allowed - detail.frame.minX) <= 5 { trackedWidth = detail.frame.minX }
            }
            let generation = self.generation
            guard pendingWidthGeneration != generation else { return }
            pendingWidthGeneration = generation
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                guard let self, self.pendingWidthGeneration == generation else { return }
                self.pendingWidthGeneration = nil
                guard self.generation == generation, !self.changingVisibility, self.applied == self.configuration,
                      let split = self.split, !split.inLiveResize, split.arrangedSubviews.count == 2,
                      let detail = split.arrangedSubviews.last,
                      abs(split.bounds.width - applied.available) < 1 else { return }
                let width = self.trackedWidth ?? applied.effective
                self.trackedWidth = nil
                guard width >= SidebarLayout.minWidth - 1 else { return }
                if abs(width - applied.effective) <= 0.5 {
                    if abs(detail.frame.minX - width) > 0.5 { self.restoreWidth() }
                } else if self.saveWidth?(width, applied.preferred) == false {
                    self.restoreWidth()
                }
            }
        }
    }
}
