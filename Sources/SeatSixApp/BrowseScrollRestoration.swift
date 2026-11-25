import AppKit
import SwiftUI

/// Process-local browsing positions. No media or account data is written to disk.
@MainActor
final class BrowseScrollMemory: ObservableObject {
    private var positions: [String: CGFloat] = [:]
    // Disclosure geometry is part of a detail's return position. Restoring an
    // offset against a newly collapsed synopsis would land on a different episode.
    @Published private var overviewScopes: Set<String> = []
    @Published private var resourceScopes: Set<String> = []
    func overviewExpanded(for scope: String) -> Bool { overviewScopes.contains(scope) }
    func setOverviewExpanded(_ expanded: Bool, for scope: String) {
        if expanded { overviewScopes.insert(scope) } else { overviewScopes.remove(scope) }
    }
    func resourcesExpanded(for scope: String) -> Bool { resourceScopes.contains(scope) }
    func setResourcesExpanded(_ expanded: Bool, for scope: String) {
        if expanded { resourceScopes.insert(scope) } else { resourceScopes.remove(scope) }
    }
    func position(for scope: String) -> CGFloat? { positions[scope] }
    func record(_ position: CGFloat, for scope: String) {
        guard position.isFinite else { return }
        positions[scope] = max(0, position)
    }
}

/// Observe the real clip view so programmatic catalog replacement and nested
/// detail navigation obey the same rules as mouse/trackpad scrolling on macOS 14+.
struct BrowseScrollRestoration: NSViewRepresentable {
    let memory: BrowseScrollMemory
    let scope: String
    var provisionalScope: String? = nil
    let isReady: () -> Bool
    let isVisible: () -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.changed = { [weak coordinator = context.coordinator, weak probe] in
            guard let probe else { return }
            coordinator?.attach(probe)
        }
        return probe
    }
    func updateNSView(_ view: Probe, context: Context) {
        context.coordinator.configure(memory: memory, scope: scope, provisionalScope: provisionalScope, ready: isReady, visible: isVisible)
        context.coordinator.attach(view)
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            if let view { coordinator?.attach(view) }
        }
    }
    static func dismantleNSView(_ view: Probe, coordinator: Coordinator) {
        view.changed = nil
        coordinator.detach()
    }

    final class Probe: NSView {
        var changed: (() -> Void)?
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); changed?() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); changed?() }
        override func layout() { super.layout(); changed?() }
    }

    @MainActor
    final class Coordinator {
        private weak var scroll: NSScrollView?
        private var memory: BrowseScrollMemory?
        private var scope = ""
        private var ready: () -> Bool = { false }
        private var visible: () -> Bool = { false }
        private var wasReady = false
        private var wasVisible = false
        private var needsRestore = true
        private var scheduled = false
        private var attempts = 0
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollObserver: NSObjectProtocol?
        private var userScrollDuringLoad: CGFloat?

        func configure(memory: BrowseScrollMemory, scope: String, provisionalScope: String?, ready: @escaping () -> Bool, visible: @escaping () -> Bool) {
            let nowReady = ready(), nowVisible = visible()
            if self.scope != scope {
                // Startup may discover this page's first library after the user
                // has scrolled. Only that unassigned scope can transfer a gesture.
                if self.scope == provisionalScope, wasVisible, nowVisible, let y = userScrollDuringLoad {
                    memory.record(y, for: scope)
                }
                userScrollDuringLoad = nil
            }
            if nowReady || !nowVisible { userScrollDuringLoad = nil }
            if self.scope != scope || (!wasReady && nowReady) || (!wasVisible && nowVisible) {
                needsRestore = true; attempts = 0
            }
            self.memory = memory; self.scope = scope; self.ready = ready; self.visible = visible
            wasReady = nowReady; wasVisible = nowVisible
            scheduleRestoration()
        }

        func attach(_ probe: Probe) {
            guard let enclosing = probe.enclosingScrollView else { return }
            if scroll !== enclosing {
                detach()
                scroll = enclosing; needsRestore = true; attempts = 0
                enclosing.contentView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: enclosing.contentView, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.recordPosition() }
                    }
                liveScrollObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
                    object: enclosing, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.recordLiveScroll() }
                    }
            }
            scheduleRestoration()
        }

        private func recordPosition() {
            guard !needsRestore, ready(), visible(), let scroll else { return }
            memory?.record(scroll.contentView.bounds.origin.y, for: scope)
        }

        private func recordLiveScroll() {
            guard visible(), let scroll else { return }
            let offset = scroll.contentView.bounds.minY
            if !ready() { userScrollDuringLoad = offset }
            needsRestore = false
            memory?.record(offset, for: scope)
        }

        private func scheduleRestoration() {
            guard needsRestore, !scheduled, scroll != nil, ready(), visible() else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.restore()
            }
        }

        private func restore() {
            guard needsRestore, ready(), visible(), let scroll, let document = scroll.documentView else { return }
            guard let desired = memory?.position(for: scope) else {
                needsRestore = false
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                return
            }
            // The catalog's completion notification can precede the new SwiftUI
            // document layout. Do not consume its saved position against a placeholder.
            scroll.window?.contentView?.layoutSubtreeIfNeeded()
            document.layoutSubtreeIfNeeded()
            let maximum = max(0, document.frame.height - scroll.contentView.bounds.height)
            if maximum + 1 < desired && attempts < 5 {
                attempts += 1; scheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    self?.scheduled = false; self?.restore()
                }
                return
            }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(desired, maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
            needsRestore = false
        }

        func detach() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
            boundsObserver = nil; liveScrollObserver = nil; scroll = nil
        }
        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
        }
    }
}
