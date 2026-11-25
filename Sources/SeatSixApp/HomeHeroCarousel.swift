import SwiftUI
import SeatSixCore

/// A banner can be visible before its artwork finishes loading.
struct HomeBannerSelection: Equatable {
    let scope: HomeArtworkScope
    let itemID: String
    let selectionID: UUID?

    func matches(scope: HomeArtworkScope, itemID: String, selectionID: UUID?) -> Bool {
        self.scope == scope && self.itemID == itemID && (selectionID == nil || self.selectionID == selectionID)
    }
}

/// Keeps the selected work stable across detail visits and harmless metadata updates.
struct HomeCarouselPosition {
    private(set) var selectedID: String?
    private(set) var direction = 1
    var isPaused = false

    func index(in ids: [String]) -> Int? {
        guard !ids.isEmpty else { return nil }
        return selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
    }

    mutating func select(_ id: String, in ids: [String], relativeTo displayedID: String? = nil) {
        guard let target = ids.firstIndex(of: id) else { return }
        let origin = displayedID.flatMap { ids.firstIndex(of: $0) } ?? index(in: ids)
        if let current = origin, target != current { direction = target > current ? 1 : -1 }
        selectedID = id; isPaused = true
    }

    mutating func reconcile(with ids: [String]) {
        if selectedID.map({ ids.contains($0) }) != true { selectedID = ids.first }
    }

    mutating func advance(by delta: Int, in ids: [String], relativeTo displayedID: String? = nil) {
        isPaused = true
        move(by: delta, in: ids, relativeTo: displayedID)
    }

    mutating func automaticRotationPreferenceChanged(to enabled: Bool) {
        if enabled { isPaused = false }
    }

    mutating func advanceAutomatically(in ids: [String], isAllowed: Bool, rotationEnabled: Bool = true,
                                       controlsEngaged: Bool = false) {
        guard rotationEnabled, isAllowed, !controlsEngaged, !isPaused, ids.count > 1 else { return }
        move(by: 1, in: ids)
    }

    private mutating func move(by delta: Int, in ids: [String], relativeTo displayedID: String? = nil) {
        guard let current = index(in: ids) else { selectedID = nil; return }
        let offset = delta % ids.count
        var travel = offset
        if let displayed = displayedID.flatMap({ ids.firstIndex(of: $0) }) {
            // Requests accumulate while the visible pair finishes. Undoing one
            // queued step must not reverse a journey still ahead of that pair.
            // Unwrap along the previous intent so first/last wrap keeps its path.
            let pending = direction > 0
                ? (current - displayed + ids.count) % ids.count
                : -((displayed - current + ids.count) % ids.count)
            travel += pending
        }
        if travel != 0 { direction = travel > 0 ? 1 : -1 }
        selectedID = ids[(current + offset + ids.count) % ids.count]
    }
}

struct HomeHeroCarousel: View {
    static let copyBottomInset: CGFloat = 36

    @ObservedObject var model: ApplicationModel
    let items: [MediaItem]
    let libraryName: String
    let isVisible: Bool
    var toolbarInteracting = false
    var toolbarBottom = SeatSixSidebarMetrics.titlebarHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var position = HomeCarouselPosition()
    @State private var motion = HomeCarouselMotion()
    @State private var isHovered = false
    @State private var intersectsViewport = true
    @State private var entryFocused = false
    private let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()
    private var ids: [String] { items.map(\.id) }
    private var scope: HomeArtworkScope? { HomeArtworkScope(model: model) }
    private var displayedIndex: Int? {
        motion.currentID.flatMap { ids.firstIndex(of: $0) } ?? position.index(in: ids)
    }

    private var visibleSelection: HomeBannerSelection? {
        guard isVisible, intersectsViewport, !motion.isTransitioning, !model.isToolbarRefreshing,
              let scope, let index = displayedIndex else { return nil }
        return HomeBannerSelection(scope: scope, itemID: items[index].id, selectionID: motion.selectionID)
    }

    var body: some View {
        if let index = displayedIndex {
            let currentID = items[index].id
            let renderedIDs = motion.currentID == nil ? [currentID] : motion.renderedIDs(in: ids)
            Rectangle().fill(.clear)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(minHeight: 440, maxHeight: 780)
                .overlay {
                    GeometryReader { geometry in
                        let coveredHeight = min(geometry.size.height, max(0, toolbarBottom - geometry.frame(in: .global).minY))
                        ZStack(alignment: .bottomLeading) {
                            // Stable IDs retain loaded adjacent posters. Only the two
                            // moving pages are visible, and only the current one acts.
                            ForEach(renderedIDs, id: \.self) { id in
                                if let item = items.first(where: { $0.id == id }) {
                                    slide(item, geometry: geometry, isCurrent: id == currentID)
                                        .frame(width: geometry.size.width, height: geometry.size.height)
                                        .offset(x: motion.offset(for: id) * geometry.size.width)
                                        .opacity(id == currentID || id == motion.outgoingID ? 1 : 0)
                                        .zIndex(id == motion.outgoingID ? 1 : 0)
                                        .allowsHitTesting(id == currentID && !motion.isTransitioning)
                                        .disabled(id != currentID || motion.isTransitioning)
                                        .accessibilityHidden(id != currentID)
                                }
                            }
                            detailEntry(items[index])
                                .accessibilityHidden(coveredHeight >= geometry.size.height)
                                .padding(.top, coveredHeight)
                                .zIndex(2)
                        }
                        .preference(key: HeroVisibilityKey.self,
                                    value: geometry.frame(in: .named("home-scroll-viewport")).maxY > 0)
                    }
                }
                .clipped()
                .transformPreference(HomeArtworkPreferenceKey.self) { artwork in
                    guard isVisible, intersectsViewport, !motion.isTransitioning,
                          artwork?.itemID == currentID else { artwork = nil; return }
                    artwork?.selectionID = motion.selectionID
                }
                .shelfRefreshRegion(cornerRadius: 0, isBackdrop: true)
                .background {
                    if !model.isToolbarRefreshing {
                        HomeCarouselScrollInput(
                            isEnabled: isVisible && intersectsViewport && items.count > 1
                                && model.player == nil && !model.showLogin && model.recoveryPrompt == nil,
                            scope: String(reflecting: scope), onNavigate: { change(by: $0) })
                            .accessibilityHidden(true)
                    }
                }
                .onHover { isHovered = $0 }
                .onPreferenceChange(HeroVisibilityKey.self) { intersectsViewport = $0 }
                .onChange(of: visibleSelection, initial: true) { _, selection in
                    if let selection { model.recordVisibleHomeBanner(selection) }
                }
                .onChange(of: ids, initial: true) { _, new in
                    position.reconcile(with: new)
                    settleMotion()
                }
                .onChange(of: scope) { _, _ in settleMotion() }
                .onChange(of: isVisible) { _, visible in if !visible { settleMotion() } }
                .onChange(of: reduceMotion) { _, reduced in if reduced { settleMotion() } }
                .onDisappear { settleMotion() }
                .onChange(of: model.applicationPreferences.autoRotateHomeRecommendations) { _, enabled in
                    position.automaticRotationPreferenceChanged(to: enabled)
                }
                .onReceive(timer) { _ in
                    let allowed = isVisible && intersectsViewport && scenePhase == .active && !reduceMotion
                        && model.player == nil && !model.showLogin && model.recoveryPrompt == nil && !motion.isTransitioning
                    position.advanceAutomatically(in: ids, isAllowed: allowed,
                                                  rotationEnabled: model.applicationPreferences.autoRotateHomeRecommendations,
                                                  controlsEngaged: isHovered || entryFocused || toolbarInteracting)
                    presentRequestedPosition()
                }
                .task(id: motion.generation) {
                    let generation = motion.generation
                    guard motion.isTransitioning, !reduceMotion, isVisible else { return }
                    // The initial offsets must be laid out before animating them.
                    await Task.yield()
                    guard !Task.isCancelled, generation == motion.generation else { return }
                    withAnimation(.easeInOut(duration: 0.42), completionCriteria: .removed) {
                        motion.setProgress(1, generation: generation)
                    } completion: {
                        withoutMotion { _ = motion.finish(generation: generation) }
                    }
                }
                .accessibilityIdentifier("home-featured-carousel")
        }
    }

    private func slide(_ item: MediaItem, geometry: GeometryProxy, isCurrent: Bool) -> some View {
        // Let the window's prepared backdrop reach the titlebar without
        // blurring the artwork or controls in the foreground banner.
        let maskHeight = max(100, geometry.size.height)
        return ZStack(alignment: .bottomLeading) {
            ZStack {
                MediaPoster(model: model, item: item, role: .landscape, requestWidth: 1600,
                            landscapeContentMode: .fill, showsPlaceholder: false,
                            reportsHomeArtwork: true, contributesHomeArtwork: isCurrent)
                    .accessibilityHidden(true)
                HomeHeroLegibilityScrim()
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 32 / maskHeight),
                    .init(color: .white, location: 80 / maskHeight),
                    .init(color: .white, location: 0.82),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("为你推荐 · \(libraryName)")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                Text(item.name)
                    .font(.system(size: geometry.size.width < 760 ? 36 : 52, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    .accessibilityAddTraits(.isHeader)
                    .shelfRefreshRegion()
                HStack(spacing: 12) {
                    Text(item.type == "Series" ? "剧集" : "影片")
                    if let year = item.productionYear { Text(String(year)) }
                    if item.durationSeconds > 0 { Text("\(Int(item.durationSeconds / 60)) 分钟") }
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                    Text(overview).font(.system(size: 13)).lineSpacing(4)
                        .lineLimit(2).foregroundStyle(.white.opacity(0.85)).shelfRefreshRegion()
                }
            }.frame(maxWidth: min(680, geometry.size.width * 0.68), alignment: .leading)
                .background {
                    // Copy can grow upward with a two-line title and synopsis.
                    // Attach its backing to the measured text, not a fraction of
                    // the poster, so bright artwork stays readable at any width.
                    HomeHeroCopyScrim()
                }
                .padding(.horizontal, geometry.size.width < 760 ? 24 : 40)
                .padding(.bottom, Self.copyBottomInset)
                .shelfRefreshRegionsVisible(isCurrent)
        }
    }

    /// Keep the button mounted when the selected movie changes so keyboard
    /// navigation keeps its focus while the artwork slides beneath it.
    private func detailEntry(_ item: MediaItem) -> some View {
        DetailEntryButton(model: model, item: item, kind: "hero-detail",
            beforeOpen: { pause(at: item.id) }, focusChanged: { entryFocused = $0 },
            accessibilityName: "查看推荐 \(item.name) 详情", accessibilityID: "home-featured-detail",
            activationAllowed: isVisible && !motion.isTransitioning && !model.isToolbarRefreshing) {
                Color.clear.contentShape(Rectangle())
            }
            .allowsHitTesting(isVisible && !motion.isTransitioning)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { key in
                guard entryFocused, isVisible, items.count > 1,
                      key.modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return .ignored }
                change(by: key.key == .leftArrow ? -1 : 1)
                return .handled
            }
            .contextMenu { carouselActions }
            .accessibilityActions { carouselActions }
            .help(items.count > 1 ? "查看详情，横向滑动或按左右方向键切换推荐" : "查看详情")
    }

    @ViewBuilder private var carouselActions: some View {
        if items.count > 1 {
            Button("上一部推荐") { change(by: -1) }
            Button("下一部推荐") { change(by: 1) }
            if model.applicationPreferences.autoRotateHomeRecommendations && !reduceMotion {
                Button(position.isPaused ? "继续自动轮播" : "暂停自动轮播") { position.isPaused.toggle() }
            }
        }
    }

    private func change(by delta: Int) {
        position.advance(by: delta, in: ids, relativeTo: motion.currentID)
        presentRequestedPosition()
    }
    private func pause(at id: String) { position.select(id, in: ids); settleMotion() }
    private func presentRequestedPosition() {
        guard let id = position.selectedID else { return }
        withoutMotion { _ = motion.request(id: id, direction: position.direction, animated: !reduceMotion && isVisible) }
    }
    private func settleMotion() { withoutMotion { motion.reset(to: position.selectedID) } }
    private func withoutMotion(_ action: () -> Void) {
        // Reset page offsets without suppressing the ambient backdrop's own
        // color crossfade when its active artwork preference changes.
        withTransaction(Transaction(animation: nil), action)
    }
}

/// Explicit feathering avoids depending on compositor blur (which may be
/// unavailable in offscreen rendering). The fully shaded area fits the copy;
/// only its surrounding margins fade into the original artwork.
private struct HomeHeroCopyScrim: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width + 184
            let height = geometry.size.height + 160
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0),
                                   .init(color: .black.opacity(0.8), location: (geometry.size.width + 64) / width),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: width, height: height)
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0),
                                           .init(color: .white, location: 80 / height),
                                           .init(color: .white, location: (height - 80) / height),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .offset(x: -64, y: -80)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Gentle edge treatment only. The copy carries its own adaptive backing,
/// leaving the upper and right-hand picture clear, including bright artwork.
struct HomeHeroLegibilityScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.24), location: 0),
                                   .init(color: .clear, location: 0.24)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: .clear, location: 0.76),
                                   .init(color: .black.opacity(0.3), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct HeroVisibilityKey: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}
