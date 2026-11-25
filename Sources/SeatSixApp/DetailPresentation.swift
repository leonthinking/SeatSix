import Foundation
import SwiftUI
import SeatSixCore

/// A movie may appear in several places at once. An entrance belongs to a
/// particular control, not just to the media ID shared by those controls.
struct DetailSourceKey: Hashable, Identifiable {
    let kind: String
    let itemID: String
    var id: String { String(reflecting: [kind, itemID]) }
}

struct DetailSourceFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct DetailSourceGeometry: View {
    let id: String
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: DetailSourceFrameKey.self,
                                   value: [id: geometry.frame(in: .global)])
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func detailSource(id: String) -> some View { background(DetailSourceGeometry(id: id)) }
}

/// Child controls retain their normal model actions when no root coordinator
/// is present (for example, a small isolated component preview).
struct DetailInteractionActions {
    var open: ((MediaItem, String, Bool) -> Void)?
    var goBack: (() -> Void)?
    var showSeries: ((MediaItem, String, Bool) -> Void)?

    init(open: ((MediaItem, String, Bool) -> Void)? = nil, goBack: (() -> Void)? = nil,
         showSeries: ((MediaItem, String, Bool) -> Void)? = nil) {
        self.open = open; self.goBack = goBack; self.showSeries = showSeries
    }
}

private struct DetailInteractionActionsKey: EnvironmentKey {
    static let defaultValue = DetailInteractionActions()
}

extension EnvironmentValues {
    var detailInteractionActions: DetailInteractionActions {
        get { self[DetailInteractionActionsKey.self] }
        set { self[DetailInteractionActionsKey.self] = newValue }
    }
}

/// A restrained hint of the originating control's direction. It deliberately
/// does not pretend a landscape banner and a portrait poster are the same image.
struct DetailTransitionMotion: Equatable {
    let offset: CGSize
    let scale: CGFloat
    let anchor: UnitPoint
    let duration: TimeInterval

    init(sourceFrame: CGRect?, bounds: CGRect, reduceMotion: Bool) {
        guard !reduceMotion else {
            offset = .zero; scale = 1; anchor = .center; duration = 0
            return
        }
        guard let sourceFrame, Self.isVisible(sourceFrame, in: bounds) else {
            offset = .zero; scale = 1; anchor = .center; duration = 0.14
            return
        }
        let visibleFrame = sourceFrame.intersection(bounds)
        let x = min(1, max(0, (visibleFrame.midX - bounds.minX) / bounds.width))
        let y = min(1, max(0, (visibleFrame.midY - bounds.minY) / bounds.height))
        offset = CGSize(width: (x - 0.5) * 32, height: (y - 0.5) * 24)
        scale = 0.985; anchor = UnitPoint(x: x, y: y); duration = 0.22
    }

    var animation: Animation? { duration > 0 ? .easeOut(duration: duration) : nil }
    var transition: AnyTransition {
        guard duration > 0 else { return .identity }
        return .opacity.combined(with: .offset(x: offset.width, y: offset.height))
            .combined(with: .scale(scale: scale, anchor: anchor))
    }

    static func isVisible(_ frame: CGRect, in bounds: CGRect) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0 && rect.height > 0
        }
        guard valid(frame), valid(bounds) else { return false }
        let intersection = frame.intersection(bounds)
        return !intersection.isNull && intersection.width > 1 && intersection.height > 1
    }
}

struct DetailReturnFocusRequest: Identifiable, Equatable {
    let id: UUID
    let sourceID: String
    let scope: HomeArtworkScope
    let context: String
    let detailID: String?
    let expiresAt: TimeInterval
}

/// Process-local visual provenance only. ApplicationModel owns the real detail
/// history and resolves every target; this coordinator never navigates or loads.
@MainActor
final class DetailPresentation: ObservableObject {
    private struct Visit {
        let itemID: String
        let sourceID: String?
        let restoresFocus: Bool
    }

    @Published private(set) var generation = UUID()
    @Published private(set) var isTransitioning = false
    @Published private(set) var motion = DetailTransitionMotion(sourceFrame: nil, bounds: .zero, reduceMotion: true)
    @Published private(set) var returnFocusRequest: DetailReturnFocusRequest?
    private var visits: [Visit] = []
    private var scope: HomeArtworkScope?
    private var context = ""
    private var detailID: String?
    private var bounds = CGRect.zero
    private var reduceMotion = false
    private var hasEnvironment = false

    /// Returns a generation token for a presentation-only completion callback.
    /// Reopening the same detail is metadata refresh, not a new visual entrance.
    @discardableResult
    func prepareOpen(itemID: String, from currentDetailID: String?, sourceID: String?,
                     scope: HomeArtworkScope?, context: String, sourceFrame: CGRect?,
                     bounds: CGRect, reduceMotion: Bool, restoreFocus: Bool = true) -> UUID {
        setEnvironment(scope: scope, context: context, bounds: bounds, reduceMotion: reduceMotion)
        guard !itemID.isEmpty else { return generation }
        if currentDetailID == itemID, detailID == itemID { return generation }
        returnFocusRequest = nil
        if currentDetailID == nil {
            visits = []
        } else if visits.last?.itemID != currentDetailID {
            visits = [Visit(itemID: currentDetailID!, sourceID: nil, restoresFocus: false)]
        }
        visits.append(Visit(itemID: itemID, sourceID: normalized(sourceID), restoresFocus: restoreFocus))
        detailID = itemID
        return start(sourceFrame: scope == nil ? nil : sourceFrame, bounds: bounds, reduceMotion: reduceMotion)
    }

    /// `targetDetailID` is the result already resolved by ApplicationModel.
    /// Nested returns use the departing detail's entrance in its parent; a
    /// return to browsing uses the first entrance, never an episode row.
    @discardableResult
    func prepareBack(from currentDetailID: String, to targetDetailID: String?, scope: HomeArtworkScope?,
                     context: String, sourceFrames: [String: CGRect], bounds: CGRect,
                     reduceMotion: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID {
        setEnvironment(scope: scope, context: context, bounds: bounds, reduceMotion: reduceMotion)
        var origin: Visit?
        if visits.last?.itemID == currentDetailID {
            if let targetDetailID, let target = visits.dropLast().lastIndex(where: { $0.itemID == targetDetailID }) {
                origin = visits.last
                visits.removeSubrange((target + 1)...)
            } else if targetDetailID == nil {
                origin = visits.first
                visits = []
            } else {
                visits = []
            }
        } else { visits = [] }
        detailID = targetDetailID
        let sourceID = origin?.sourceID
        let token = start(sourceFrame: scope == nil ? nil : sourceID.flatMap { sourceFrames[$0] },
                          bounds: bounds, reduceMotion: reduceMotion)
        if let sourceID, origin?.restoresFocus == true, let scope {
            returnFocusRequest = DetailReturnFocusRequest(id: UUID(), sourceID: sourceID, scope: scope,
                context: context, detailID: targetDetailID, expiresAt: now + 1)
        } else { returnFocusRequest = nil }
        return token
    }

    /// Call when identity, route/filter scope, external navigation, geometry or
    /// accessibility changes. No transition may keep old-account visuals alive.
    func synchronize(scope: HomeArtworkScope?, context: String, detailID: String?,
                     bounds: CGRect, reduceMotion: Bool) {
        let environmentChanged = !hasEnvironment || self.scope != scope || self.context != context
        let geometryChanged = self.bounds != bounds
        let motionChanged = self.reduceMotion != reduceMotion
        setEnvironment(scope: scope, context: context, bounds: bounds, reduceMotion: reduceMotion)
        if environmentChanged || self.detailID != detailID {
            visits = []
            self.detailID = detailID
            cancelMotion()
            returnFocusRequest = nil
        } else if geometryChanged || motionChanged {
            cancelMotion()
            returnFocusRequest = nil
        }
    }

    @discardableResult
    func finish(generation token: UUID) -> Bool {
        guard token == generation else { return false }
        isTransitioning = false
        return true
    }

    func cancelReturnFocus() { returnFocusRequest = nil }

    /// A late catalog reply or stale hidden surface cannot consume the request.
    /// The caller sets its local FocusState only after this returns true.
    @discardableResult
    func consumeReturnFocus(sourceID: String, scope: HomeArtworkScope?, context: String, detailID: String?,
                            isVisible: Bool, frame: CGRect?, viewport: CGRect,
                            now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let request = returnFocusRequest else { return false }
        guard now <= request.expiresAt else { returnFocusRequest = nil; return false }
        guard request.sourceID == sourceID, request.scope == scope, request.context == context,
              request.detailID == detailID, self.detailID == detailID, isVisible,
              let frame, DetailTransitionMotion.isVisible(frame, in: viewport) else { return false }
        returnFocusRequest = nil
        return true
    }

    private func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func setEnvironment(scope: HomeArtworkScope?, context: String, bounds: CGRect, reduceMotion: Bool) {
        if !hasEnvironment || self.scope != scope || self.context != context {
            visits = []; detailID = nil; returnFocusRequest = nil; cancelMotion()
        }
        self.scope = scope; self.context = context; self.bounds = bounds
        self.reduceMotion = reduceMotion; hasEnvironment = true
    }

    private func start(sourceFrame: CGRect?, bounds: CGRect, reduceMotion: Bool) -> UUID {
        generation = UUID()
        motion = DetailTransitionMotion(sourceFrame: sourceFrame, bounds: bounds, reduceMotion: reduceMotion)
        isTransitioning = motion.duration > 0
        return generation
    }

    private func cancelMotion() {
        generation = UUID(); isTransitioning = false
        motion = DetailTransitionMotion(sourceFrame: nil, bounds: .zero, reduceMotion: true)
    }
}
