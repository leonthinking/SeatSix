import AppKit
import ImageIO
import SwiftUI
import SeatSixCore
import SeatSixPlayback

enum SeatSixStyle {
    static let accent = Color(red: 0.65, green: 0.87, blue: 0.78)
    static let background = Color(red: 0.065, green: 0.075, blue: 0.09)
    static let panel = Color(red: 0.105, green: 0.12, blue: 0.14)
    static let secondary = Color(red: 0.55, green: 0.60, blue: 0.66)
}

extension View {
    /// A small backing follows the label and blends into the canvas as the poster fades.
    @ViewBuilder
    func posterCaptionBacking(_ isEnabled: Bool) -> some View {
        if isEnabled {
            self.foregroundStyle(.white)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(SeatSixStyle.background.opacity(0.82))
                        .padding(.horizontal, -3).padding(.vertical, -1)
                        .allowsHitTesting(false)
                }
        } else {
            self
        }
    }
}

struct SeatSixMark: View {
    private static let artwork: NSImage? = {
        let asset = Bundle.main.url(forResource: "SeatSix", withExtension: "icns")
            ?? Bundle.main.url(forResource: "SeatSix_SeatSixApp", withExtension: "bundle")?
                .appendingPathComponent("SeatSixMark.png")
        return asset.flatMap(NSImage.init(contentsOf:))
    }()

    var body: some View {
        Group {
            if let artwork = Self.artwork {
                Image(nsImage: artwork).resizable().interpolation(.high)
            } else {
                Image(systemName: "chair.lounge.fill").resizable()
            }
        }
        .scaledToFit()
        .accessibilityHidden(true)
    }
}

struct SeatSixRootView: View {
    @ObservedObject var model: ApplicationModel
    @State private var removing: ServerConnection?
    @State private var revokingTrust: ServerConnection?
    @State private var filtersExpanded = false
    @StateObject private var scrollMemory = BrowseScrollMemory()
    @StateObject private var navigation = SeatSixNavigation()
    @StateObject private var detailPresentation = DetailPresentation()
    @State private var lightDetailTitleID: String?
    @State private var scrolledDetailID: String?
    @StateObject private var libraryKeyboard = LibraryKeyboardNavigation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var toolbarFocused: Bool
    @State private var leadingHovered = false
    @State private var toolbarTracksOpenDivider = false
    @State private var trailingHovered = false
    @FocusState private var searchFocused: Bool
    @State private var sourceFrames: [String: CGRect] = [:]
    @State private var rootBounds = CGRect.zero
    @State private var contentFrame = CGRect.zero
    @State private var navigationError: String?
    @State private var searchRecommendationOffset = 0
    private var searchPage: BrowseDestination? {
        BrowseDestination(rawValue: model.page).flatMap { $0.isSearch ? $0 : nil }
    }
    private var sidebarCollapsed: Bool { model.applicationPreferences.sidebarCollapsed }
    private var detailContext: String {
        var parts = [model.page, libraryScrollScope]
        if searchPage != nil { parts.append(model.searchTerm) }
        return String(reflecting: parts)
    }
    private var presentationBounds: CGRect {
        CGRect(x: contentFrame.minX, y: rootBounds.minY, width: contentFrame.width, height: rootBounds.height)
    }
    private var navigationAllowed: Bool {
        !model.showLogin && model.recoveryPrompt == nil && !model.launchingPlayback
    }
    private var browseScope: String { "\(model.connection?.id.uuidString ?? "")|\(model.selectedLibraryID)" }
    private var homeAtmosphereIsVisible: Bool {
        model.page == "home" && model.detail == nil && model.applicationPreferences.showHomeRecommendations
            && !model.homeRecommendations.isEmpty
    }
    private var windowPalette: WindowArtworkPalette? {
        !reduceTransparency && contrast != .increased ? model.windowPalette : nil
    }
    private var toolbarOverBrowseArtwork: Bool {
        model.detail == nil && (homeAtmosphereIsVisible || windowPalette != nil)
    }
    private var hasBrowsePoster: Bool { windowPalette != nil }
    private var homeHasLibrarySection: Bool {
        !model.libraries.isEmpty || (model.libraryListPending && model.connection?.libraryIDs.isEmpty == false)
    }
    private var homeHasHero: Bool {
        model.applicationPreferences.showHomeRecommendations &&
            (!model.homeRecommendations.isEmpty || (homeHasLibrarySection && model.catalogContentPending && model.canBrowseCurrentMedia))
    }
    private var libraryScrollScope: String {
        String(reflecting: [browseScope, model.query, model.filterYear.map(String.init) ?? "", model.filterGenre ?? "",
                           String(describing: model.watchFilter), String(model.favoritesOnly), String(describing: model.sortOrder)])
    }
    private var libraryKeyboardScope: String { String(reflecting: HomeArtworkScope(model: model)) + libraryScrollScope }
    private var libraryIDs: [String] { model.displayedItems.map(\.id) }

    @MainActor init(model: ApplicationModel, scrollMemory: BrowseScrollMemory? = nil,
                    navigation: SeatSixNavigation? = nil, detailPresentation: DetailPresentation? = nil) {
        self.model = model
        _scrollMemory = StateObject(wrappedValue: scrollMemory ?? BrowseScrollMemory())
        _navigation = StateObject(wrappedValue: navigation ?? SeatSixNavigation())
        _detailPresentation = StateObject(wrappedValue: detailPresentation ?? DetailPresentation())
    }

    private var rootLayout: some View {
        GeometryReader { geometry in
        // AppKit can resolve its own appearance inside split items. Pass the
        // window's accessibility settings to both panes before that boundary.
        SeatSixSidebarSplit(model: model, availableWidth: geometry.size.width,
            appearance: .init(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                              reduceMotion: reduceMotion),
            onError: { navigationError = $0 }) {
            VStack(spacing: 0) {
                if let error = model.errorMessage { errorBanner(error).padding(.top, SeatSixSidebarMetrics.titlebarHeight) }
                ZStack {
                    // Keep the browse surfaces mounted while a detail is open. Their scroll
                    // views, focus and local presentation state belong to the browse route.
                    if model.connection != nil {
                        homeContent
                            .padding(pageInsets(immersive: homeHasHero))
                            .id(model.connection?.id)
                            .browseVisibility(model.page == "home" && model.detail == nil)
                        libraryContent
                            .padding(pageInsets())
                            .id("\(model.connection!.id)|\(model.selectedLibraryID)")
                            .browseVisibility(model.page == "library" && model.detail == nil)
                        if let searchPage {
                            searchContent(searchPage)
                                .padding(pageInsets())
                                .id("\(model.connection!.id)|\(searchPage.rawValue)")
                                .browseVisibility(model.detail == nil)
                        } else if let destination = BrowseDestination(rawValue: model.page), destination.isServerBrowse {
                            serverBrowseContent(destination)
                                .padding(pageInsets())
                                .id("\(model.connection!.id)|\(destination.rawValue)")
                                .browseVisibility(model.detail == nil)
                        }
                    } else {
                        welcome.padding(pageInsets()).browseVisibility(model.page != "servers")
                    }
                    if model.page == "servers" { servers.padding(pageInsets()) }
                    if model.page != "servers", let item = model.detail {
                        DetailArtworkHost(model: model, item: item, policyOverride: HomeAtmospherePolicy(
                            reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased,
                            reduceMotion: reduceMotion)) { artwork in
                            MediaDetailView(model: model, item: item, artwork: artwork, scrollMemory: scrollMemory,
                                            presentationScope: HomeArtworkScope(model: model))
                                .environment(\.detailArtworkAppearance, artwork.appearance)
                                .environment(\.colorScheme, artwork.appearance.isLight ? .light : .dark)
                                .tint(artwork.appearance.accentText)
                                .background {
                                    if artwork.appearance.hasArtwork || windowPalette == nil { artwork.background }
                                }
                                .preference(key: LightDetailTitleKey.self, value: artwork.appearance.isLight && model.detail?.id == item.id ? item.id : nil)
                        }
                            .id(String(reflecting: HomeArtworkScope(model: model)) + "|" + item.id)
                            .transition(detailPresentation.motion.transition)
                            .zIndex(2)
                    }
                }
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(ToolbarRefreshCover(model: model, usesWindowPalette: windowPalette != nil))
            .background(SeatSixSidebarGeometry(id: "content"))
        }
        .overlayPreferenceValue(SidebarEdgeAnchor.self) { sidebar in
            GeometryReader { window in
                let paneWidth = sidebar.map { max(0, window[$0].minX) } ?? 0
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: paneWidth, height: window.size.height)
                        .background(SeatSixSidebarGeometry(id: "sidebar-pane"))
                        .allowsHitTesting(false).accessibilityHidden(true)
                    toolbar(paneWidth: paneWidth, windowWidth: window.size.width)
                }
            }
        }
        .background { Color.clear.preference(key: NavigationLayoutKey.self, value: geometry.frame(in: .global)) }
        }
    }

    private func pageInsets(immersive: Bool = false) -> EdgeInsets {
        EdgeInsets(top: immersive || model.errorMessage != nil ? 0 : SeatSixSidebarMetrics.titlebarHeight,
                   leading: 0, bottom: immersive ? 0 : 12, trailing: immersive ? 0 : 12)
    }

    private var navigationContent: some View {
        rootLayout
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(NavigationLayoutKey.self) { rootBounds = $0 }
        .onPreferenceChange(SeatSixSidebarFrameKey.self) { if let frame = $0["content"] { contentFrame = frame } }
        .onPreferenceChange(DetailSourceFrameKey.self) { sourceFrames = $0 }
        .onPreferenceChange(LightDetailTitleKey.self) { lightDetailTitleID = $0 }
        .onPreferenceChange(ScrolledDetailKey.self) { scrolledDetailID = $0 }
        .onPreferenceChange(DetailWindowPaletteKey.self) { palette in
            if let palette { model.acceptWindowPalette(palette) }
        }
        .environment(\.detailInteractionActions, DetailInteractionActions(open: openDetail, goBack: goBack, showSeries: showSeries))
        .environment(\.detailFocusContext, DetailFocusContext(request: detailPresentation.returnFocusRequest,
            consume: { sourceID, frame in
                detailPresentation.consumeReturnFocus(sourceID: sourceID, scope: HomeArtworkScope(model: model),
                    context: detailContext, detailID: model.detail?.id, isVisible: navigationAllowed,
                    frame: frame, viewport: presentationBounds)
            }, cancel: { detailPresentation.cancelReturnFocus() }))
        .focusedSceneValue(\.seatSixNavigationActions, navigationActions)
        .onChange(of: HomeArtworkScope(model: model)) { _, _ in navigation.invalidate(); synchronizeDetail() }
        .onChange(of: libraryKeyboardScope) { _, _ in reconcileLibraryKeyboard() }
        .onChange(of: libraryIDs) { _, _ in reconcileLibraryKeyboard() }
        .onChange(of: model.catalogLoading) { _, _ in reconcileLibraryKeyboard() }
        .onChange(of: detailContext) { _, _ in
            if model.page != "library" && searchPage == nil { navigation.invalidate(); searchFocused = false; libraryKeyboard.invalidatePendingFocus() }
            synchronizeDetail()
        }
        .onChange(of: model.detail?.id) { _, value in
            if value != nil { libraryKeyboard.invalidatePendingFocus() }
            synchronizeDetail()
        }
        .onChange(of: presentationBounds) { _, _ in synchronizeDetail() }
        .onChange(of: reduceMotion) { _, _ in synchronizeDetail() }
        .onChange(of: navigationAllowed) { _, allowed in
            if !allowed { navigation.invalidate(); detailPresentation.cancelReturnFocus(); searchFocused = false; libraryKeyboard.invalidatePendingFocus() }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .task(id: detailPresentation.generation) {
            let token = detailPresentation.generation
            let duration = detailPresentation.motion.duration
            if duration > 0 { try? await Task.sleep(for: .seconds(duration)) }
            guard !Task.isCancelled else { return }
            detailPresentation.finish(generation: token)
        }
        .overlay(alignment: .bottom) {
            if let navigationError {
                HStack {
                    Label(navigationError, systemImage: "exclamationmark.circle").textSelection(.enabled)
                    Button("关闭") { self.navigationError = nil }.buttonStyle(.plain)
                }.font(.callout).padding(14).seatSixSurface(role: .popover)
                    .padding(20).accessibilityIdentifier("navigation-error")
            }
        }
    }

    var body: some View {
        navigationContent
        .transformPreference(HomeArtworkPreferenceKey.self) { artwork in
            if !homeAtmosphereIsVisible || model.isToolbarRefreshing || reduceTransparency || contrast == .increased {
                artwork = nil
            }
        }
        .onPreferenceChange(HomeArtworkPreferenceKey.self) { artwork in
            if let artwork { model.acceptHomeWindowPalette(artwork) }
        }
        .background {
            HomeAtmosphereBackground(blurredBackground: windowPalette?.field)
                .ignoresSafeArea(.container, edges: .top)
        }
        .sheet(isPresented: $model.showLogin, onDismiss: { model.reauthenticate = nil }) {
            ServerLoginView(model: model, existing: model.reauthenticate)
        }
        .confirmationDialog("解除此服务器连接？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("解除连接", role: .destructive) {
                if let id = removing?.id { Task { await model.removeConnection(id) } }
                removing = nil
            }
            Button("取消", role: .cancel) { removing = nil }
        } message: {
            Text("将移除此 Mac 上的登录信息和本机续播记录，服务器上的媒体与观看记录会保留。")
        }
        .confirmationDialog("撤销对此证书的信任？", isPresented: Binding(get: { revokingTrust != nil }, set: { if !$0 { revokingTrust = nil } }), titleVisibility: .visible) {
            Button("撤销信任", role: .destructive) {
                if let id = revokingTrust?.id { Task { await model.revokeCertificateTrust(id) } }
                revokingTrust = nil
            }
            Button("取消", role: .cancel) { revokingTrust = nil }
        } message: {
            Text("将停止此服务器的播放并移除此 Mac 上的证书例外。再次连接时会重新验证证书，服务器上的媒体和观看记录会保留。")
        }
        .alert("选择续播位置", isPresented: Binding(get: { model.recoveryPrompt != nil }, set: { if !$0 { model.recoveryPrompt = nil } })) {
            Button("使用本机进度") { model.chooseRecovery(local: true) }
            Button("使用服务器进度") { model.chooseRecovery(local: false) }
            Button("取消", role: .cancel) { model.recoveryPrompt = nil }
        } message: {
            if let prompt = model.recoveryPrompt {
                Text("上次播放的同步未确认。本机：\(durationText(Double(prompt.localTicks) / 10_000_000))，服务器：\(durationText(Double(prompt.remoteTicks) / 10_000_000))。")
            }
        }
    }

    private var navigationActions: SeatSixNavigationActions {
        .init(canRefresh: navigationAllowed && model.connection != nil && !model.userStateBusy && !model.isToolbarRefreshing,
              refresh: model.refreshFromToolbar, canSearch: navigation.canSearch(model: model), canGoBack: navigationAllowed && model.canNavigateBack,
              canGoForward: navigationAllowed && model.canNavigateForward,
              canToggleSidebar: navigationAllowed, sidebarVisible: !sidebarCollapsed,
              search: requestSearch, goBack: goBack, goForward: goForward, toggleSidebar: toggleSidebar)
    }

    private func requestSearch() {
        detailPresentation.cancelReturnFocus()
        libraryKeyboard.invalidatePendingFocus()
        _ = navigation.requestSearch(model: model)
    }

    private func reconcileLibraryKeyboard() {
        libraryKeyboard.reconcile(ids: libraryIDs, scope: libraryKeyboardScope, isLoading: model.catalogLoading || model.loading)
    }

    private func moveLibrarySelection(_ delta: Int) {
        guard navigationAllowed, model.page == "library", model.detail == nil, !libraryIDs.isEmpty else { return }
        searchFocused = false
        detailPresentation.cancelReturnFocus()
        libraryKeyboard.move(delta: delta, ids: libraryIDs, scope: libraryKeyboardScope)
    }

    private func moveLibrarySelection(_ direction: MoveCommandDirection) {
        let columns = max(1, Int((max(0, contentFrame.width - 12 - 48) + 18)
            / (model.applicationPreferences.posterSize.gridMinimum + 18)))
        switch direction {
        case .left: moveLibrarySelection(-1)
        case .right: moveLibrarySelection(1)
        case .up: moveLibrarySelection(-columns)
        case .down: moveLibrarySelection(columns)
        default: break
        }
    }

    private func toggleSidebar() {
        guard navigationAllowed else { return }
        detailPresentation.cancelReturnFocus()
        var preferences = model.applicationPreferences
        preferences.sidebarCollapsed.toggle()
        if !model.updateApplicationPreferences(preferences) { navigationError = model.preferencesError }
    }

    private func synchronizeDetail() {
        detailPresentation.synchronize(scope: HomeArtworkScope(model: model), context: detailContext,
            detailID: model.detail?.id, bounds: presentationBounds, reduceMotion: reduceMotion)
    }

    private func openDetail(_ item: MediaItem, sourceID: String, keyboardOrigin: Bool) {
        navigation.invalidate(); searchFocused = false
        detailPresentation.prepareOpen(itemID: item.id, from: model.detail?.id, sourceID: sourceID,
            scope: HomeArtworkScope(model: model), context: detailContext, sourceFrame: sourceFrames[sourceID],
            bounds: presentationBounds, reduceMotion: reduceMotion, restoreFocus: keyboardOrigin)
        withAnimation(detailPresentation.motion.animation) { model.showDetail(item) }
    }

    private func goBack() {
        guard navigationAllowed, model.canNavigateBack else { return }
        navigation.invalidate()
        guard let currentID = model.detail?.id else { model.navigateBack(); return }
        detailPresentation.prepareBack(from: currentID, to: model.backNavigationDetailID,
            scope: HomeArtworkScope(model: model), context: detailContext, sourceFrames: sourceFrames,
            bounds: presentationBounds, reduceMotion: reduceMotion)
        withAnimation(detailPresentation.motion.animation) { model.navigateBack() }
    }

    private func goForward() {
        guard navigationAllowed, model.canNavigateForward else { return }
        navigation.invalidate()
        detailPresentation.cancelReturnFocus()
        model.navigateForward()
    }

    private func showSeries(_ episode: MediaItem, sourceID: String, keyboardOrigin: Bool) {
        guard let seriesID = episode.seriesID else { model.showSeries(for: episode); return }
        if let currentID = model.detail?.id, model.hasDetailHistory(itemID: seriesID) {
            detailPresentation.prepareBack(from: currentID, to: seriesID, scope: HomeArtworkScope(model: model),
                context: detailContext, sourceFrames: sourceFrames, bounds: presentationBounds, reduceMotion: reduceMotion)
            withAnimation(detailPresentation.motion.animation) { model.showSeries(for: episode) }
        } else {
            // Resolve the parent first. A failed or cancelled lookup must not
            // replace the current episode's committed return provenance.
            model.showSeries(for: episode) { series in
                openDetail(series, sourceID: sourceID, keyboardOrigin: keyboardOrigin)
            }
        }
    }

    private var isHomeTabRoot: Bool { model.detail == nil && (model.page == "home" || model.page == "favorites") }
    private var showsHomeTabs: Bool { model.connection != nil && isHomeTabRoot }
    private var showsSearchToolbar: Bool { searchPage != nil && model.detail == nil }
    private var onLightDetailArtwork: Bool { lightDetailTitleID != nil && lightDetailTitleID == model.detail?.id }

    private func toolbar(paneWidth: CGFloat, windowWidth: CGFloat) -> some View {
        // Cap long server names so the centered tabs and trailing controls fit.
        let leadingInset: CGFloat = 94
        let sourceLimit = min(200, max(80, windowWidth / 2 - leadingInset - 220))
        let expandedWidth = SidebarLayout.effectiveWidth(preferredWidth: model.applicationPreferences.sidebarWidth,
                                                        availableWidth: windowWidth)
        let leading = SidebarToolbarLeadingLayout(paneWidth: paneWidth, expandedPaneWidth: expandedWidth,
                                                 leadingInset: leadingInset, collapsed: sidebarCollapsed,
                                                 trackingOpenDivider: toolbarTracksOpenDivider)
        return ZStack {
            HStack(spacing: 8) {
                leading {
                    SeatSixSidebarToggle(collapsed: sidebarCollapsed, toggle: toggleSidebar)
                        .environment(\.colorScheme, onLightDetailArtwork && paneWidth < leadingInset + 18 ? .light : .dark)
                        .background { if toolbarOverBrowseArtwork { toolbarControlShadow.opacity(leading.sourceReveal) } }
                        .focused($toolbarFocused)
                    if model.connection != nil, !showsSearchToolbar {
                        ToolbarSourcePicker(model: model, maxWidth: sourceLimit)
                            .background { if toolbarOverBrowseArtwork { toolbarControlShadow } }
                            .focused($toolbarFocused)
                            .opacity(leading.sourceReveal)
                            .disabled(!leading.sourceIsAvailable)
                            .allowsHitTesting(leading.sourceIsAvailable)
                            .accessibilityHidden(!leading.sourceIsAvailable)
                            .background {
                                if leading.sourceIsAvailable { SeatSixSidebarGeometry(id: "toolbar-source") }
                            }
                    }
                }
                .clipped()
                .onHover { leadingHovered = $0 }
                // Divider drags keep the source hidden and follow the user's width
                // before AppKit commits the new preference on mouse-up.
                .onChange(of: sidebarCollapsed, initial: true) { _, collapsed in
                    if collapsed { toolbarTracksOpenDivider = false }
                }
                .onChange(of: !sidebarCollapsed && abs(paneWidth - expandedWidth) < 0.5, initial: true) { _, atOpenEdge in
                    if atOpenEdge { toolbarTracksOpenDivider = true }
                }

                if !isHomeTabRoot, model.canNavigateBack || model.canNavigateForward {
                    historyControls
                        .background { if toolbarOverBrowseArtwork { toolbarControlShadow } }
                }
                if !showsHomeTabs && !showsSearchToolbar {
                    Text(model.detail?.name ?? (model.page == "library" ? model.selectedLibrary?.name : nil)
                         ?? BrowseDestination(rawValue: model.page)?.title ?? "")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(onLightDetailArtwork ? Color.black.opacity(0.88) : SeatSixChrome.primaryText)
                        .shadow(color: model.detail != nil || toolbarOverBrowseArtwork
                                ? (onLightDetailArtwork ? Color.white : Color.black).opacity(0.85) : .clear, radius: 1.5)
                        .background(SeatSixSidebarGeometry(id: "toolbar-title"))
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if showsSearchToolbar {
                        searchToolbar
                    } else {
                        toolbarButton("刷新媒体库", symbol: "arrow.clockwise", action: model.refreshFromToolbar)
                            .disabled(model.connection == nil || model.isToolbarRefreshing || model.userStateBusy)
                            .focused($toolbarFocused)
                            .accessibilityLabel("刷新媒体库").help("刷新媒体库（⌘R）")
                            .accessibilityIdentifier("toolbar-refresh")
                            .background(SeatSixSidebarGeometry(id: "toolbar-refresh"))
                        if model.page == "library", model.detail == nil, model.connection != nil {
                            librarySearchField
                        } else {
                            toolbarButton("搜索当前媒体库", symbol: "magnifyingglass", action: requestSearch)
                                .disabled(!navigation.canSearch(model: model))
                                .focused($toolbarFocused)
                                .accessibilityLabel("搜索当前媒体库").help("搜索当前媒体库（⌘F）")
                                .accessibilityIdentifier("toolbar-search")
                                .background(SeatSixSidebarGeometry(id: "toolbar-search"))
                        }
                    }
                }
                .background { if toolbarOverBrowseArtwork { toolbarControlShadow } }
                .onHover { trailingHovered = $0 }
            }
            .padding(.leading, leadingInset)
            .padding(.trailing, 8)

            if showsHomeTabs {
                Picker("浏览视图", selection: Binding(get: { model.page }, set: { model.navigate(to: $0) })) {
                    Text("首页").tag("home")
                    Text("收藏").tag("favorites")
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.large)
                .fixedSize()
                .background { if toolbarOverBrowseArtwork { toolbarControlShadow } }
                .focused($toolbarFocused)
                .accessibilityIdentifier("toolbar-tabs")
                .background(SeatSixSidebarGeometry(id: "toolbar-tabs"))
                .padding(.leading, paneWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .modifier(WindowToolbarAlignment())
        .background {
            if let item = model.detail, scrolledDetailID == item.id {
                Rectangle().fill(.regularMaterial)
                    .padding(.leading, paneWidth)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else if homeAtmosphereIsVisible {
                LinearGradient(colors: [.black.opacity(0.38 * Double(leading.sourceReveal)), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .disabled(!navigationAllowed)
        .foregroundStyle(.primary)
        .tint(nil)
        .environment(\.colorScheme, onLightDetailArtwork ? .light : .dark)
        .background(SeatSixSidebarGeometry(id: "navigation-toolbar"))
    }

    private var toolbarControlShadow: some View {
        Capsule().fill(.black.opacity(0.78)).blur(radius: 5)
            .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var searchToolbar: some View {
        HStack(spacing: 9) {
            Picker("搜索范围", selection: Binding(get: { searchPage ?? .searchLibrary }, set: { model.navigate(to: $0.rawValue) })) {
                Text("媒体库").tag(BrowseDestination.searchLibrary)
                Text("影视服务器").tag(BrowseDestination.searchServer)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索", text: Binding(get: { model.searchDraft }, set: model.editSearchDraft))
                    .focused($searchFocused).textFieldStyle(.plain)
                    .onSubmit {
                        if model.submitSearchDraft() { searchFocused = false }
                    }
                    .accessibilityIdentifier("search-query")
                    .task(id: navigation.searchRequest?.id) {
                        guard let id = navigation.searchRequest?.id else { return }
                        await Task.yield()
                        if !Task.isCancelled, navigation.consumeSearchRequest(model: model, requestID: id) { searchFocused = true }
                    }
                if !model.searchDraft.isEmpty {
                    Button { model.editSearchDraft(""); searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .frame(minWidth: 75, idealWidth: 205, maxWidth: 240)
            .padding(.horizontal, 10).frame(height: 34)
            .modifier(ToolbarCapsuleBackground())
            Button("取消") { model.cancelSearch() }.keyboardShortcut(.cancelAction)
        }
    }

    private var historyControls: some View {
        HStack(spacing: 8) {
            if model.canNavigateBack { historyBack }
            if model.canNavigateForward { historyForward }
        }
        .labelStyle(.iconOnly)
        .fixedSize()
        .background(SeatSixSidebarGeometry(id: "toolbar-history"))
    }

    private var historyBack: some View {
        historyButton("后退", symbol: "chevron.backward", shortcut: "⌘[", action: goBack)
            .accessibilityIdentifier("toolbar-back")
    }

    private var historyForward: some View {
        historyButton("前进", symbol: "chevron.forward", shortcut: "⌘]", action: goForward)
            .accessibilityIdentifier("toolbar-forward")
    }

    private func historyButton(_ title: String, symbol: String, shortcut: String, action: @escaping () -> Void) -> some View {
        toolbarButton(title, symbol: symbol, action: action)
            .focused($toolbarFocused)
            .help("\(title)（\(shortcut)）")
    }

    private func toolbarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            NavigationToolbarIcon(symbol: symbol)
        }
        .accessibilityLabel(title)
        .navigationIconButton()
        .frame(width: 36, height: 36)
    }

    private var librarySearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(SeatSixChrome.secondaryText)
            TextField("搜索当前媒体库", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 12)).onChange(of: model.query) { _, _ in model.searchChanged() }
                .accessibilityLabel("搜索当前媒体库")
                .accessibilityIdentifier("library-search")
                .focused($searchFocused)
                .task(id: navigation.searchRequest?.id) {
                    guard let requestID = navigation.searchRequest?.id else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if navigation.consumeSearchRequest(model: model, requestID: requestID) { searchFocused = true }
                }
                .onSubmit { requestSearch() }
                .help("按名称搜索当前所选媒体库，包括尚未显示的影片和剧集")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(SeatSixChrome.secondaryText)
                    .accessibilityLabel("清除搜索关键词").help("清除搜索关键词，保留筛选条件")
            }
        }.padding(.horizontal, 11).frame(width: 240, height: 34)
            .modifier(ToolbarCapsuleBackground())
            .background(SeatSixSidebarGeometry(id: "toolbar-search"))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let connection = model.connection {
                Button("重新登录") { model.reauthenticate = connection; model.showLogin = true }.buttonStyle(.link)
            }
            Button("重试") { model.refresh() }.buttonStyle(.link)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
        }.padding(14).background(Color.orange.opacity(0.08))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            SeatSixMark().frame(width: 72, height: 72)
            Text("好电影，\n在这里继续。").font(.system(size: 47, weight: .semibold)).lineSpacing(8)
            Text("连接你的 Emby 或 Jellyfin 媒体服务器，\n浏览媒体库、播放影片，并同步观看进度。")
                .font(.system(size: 14)).lineSpacing(8).foregroundStyle(SeatSixStyle.secondary)
            Button { model.showLogin = true } label: { Label("添加媒体服务器", systemImage: "plus").padding(.horizontal, 14).padding(.vertical, 7) }
                .buttonStyle(.borderedProminent)
            HStack(spacing: 18) { Label("Emby", systemImage: "server.rack"); Label("Jellyfin", systemImage: "server.rack") }
                .font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary).padding(.top, 8)
            Spacer()
            Text("仅呈现你已连接服务器中的真实媒体").font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary).padding(.bottom, 30)
        }.padding(.horizontal, 64).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homeContent: some View {
      GeometryReader { geometry in
        let contentInset: CGFloat = geometry.size.width < 760 ? 24 : 40
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if homeHasHero {
                    Group {
                        if model.homeRecommendations.isEmpty {
                            ShelfRefreshSkeleton(.hero)
                                .accessibilityRepresentation { Text("正在加载推荐影片") }
                        } else {
                            HomeHeroCarousel(model: model, items: model.homeRecommendations,
                                             libraryName: model.selectedLibrary?.name ?? "当前媒体库",
                                             isVisible: model.page == "home" && model.detail == nil,
                                             toolbarInteracting: model.isToolbarRefreshing || toolbarFocused || leadingHovered || trailingHovered,
                                             toolbarBottom: rootBounds.minY + SeatSixSidebarMetrics.titlebarHeight)
                        }
                    }.padding(.horizontal, -contentInset).padding(.top, -24)
                } else {
                  HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("开始观看").font(.system(size: 30, weight: .semibold)).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
                        Text("接着上次的故事，或挑一部新的。").font(.system(size: 13)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
                    }
                    Spacer()
                    Button { model.navigate(to: "library") } label: { Label("浏览片库", systemImage: "arrow.right") }
                        .buttonStyle(.plain).foregroundStyle(SeatSixStyle.accent)
                  }
                }
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("继续观看", subtitle: model.connection?.compatibilityMode == true ? "当前媒体库" : "当前服务器 · 已选媒体库")
                    if model.displayedContinuing.isEmpty && model.continuingContentPending && homeHasLibrarySection && model.canBrowseCurrentMedia {
                        ShelfRefreshSkeleton(.continuingRail)
                            .accessibilityRepresentation { Text("正在加载继续观看") }
                    } else if model.displayedContinuing.isEmpty {
                        let failed = model.continuingContentFailed
                        HStack(spacing: 14) {
                            Image(systemName: failed ? "exclamationmark.circle" : "play.circle").font(.system(size: 28, weight: .light))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(failed ? "暂时无法读取继续观看" : "从片库开始观看")
                                Text(failed ? "可刷新媒体库重试。" : "有播放进度的内容会显示在这里。")
                                    .font(.caption).foregroundStyle(SeatSixStyle.secondary)
                            }
                            Spacer()
                        }.padding(22).frame(maxWidth: .infinity).background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                            .shelfRefreshRegion(cornerRadius: 14)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) {
                                ForEach(model.displayedContinuing) { item in
                                    ContinueCard(model: model, item: item, kind: "home-continue").frame(width: 254)
                                }
                            }.padding(.bottom, 4)
                        }.scrollIndicators(.hidden)
                    }
                }.accessibilityIdentifier("home-continue-watching")
                if homeHasLibrarySection {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("我的媒体库", subtitle: model.libraries.isEmpty ? "" : "\(model.libraries.count) 个")
                        if model.libraries.isEmpty {
                            ShelfRefreshSkeleton(.libraryTiles(count: model.connection?.libraryIDs.count ?? 0))
                                .accessibilityRepresentation { Text("正在加载媒体库") }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                                ForEach(model.libraries) { library in
                                    Button {
                                        model.navigate(to: "library", libraryID: library.id)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: library.collectionType == "tvshows" ? "tv" : "film")
                                                .font(.system(size: 20)).foregroundStyle(SeatSixStyle.accent)
                                            Text(library.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(SeatSixStyle.secondary)
                                        }.padding(17).background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 12)).shelfRefreshRegion(cornerRadius: 12)
                                    }.buttonStyle(.plain).help("浏览 \(library.name)")
                                }
                            }
                        }
                    }
                    if model.applicationPreferences.showRecentlyAdded { homeLibraryRail }
                } else if !model.libraryListPending && !model.catalogFailed {
                    emptyState(icon: "rectangle.stack", title: "还没有可浏览的媒体库", text: "为此连接选择媒体库后，即可开始浏览。")
                    Button("选择媒体库") { model.reauthenticate = model.connection; model.showLogin = true }
                }
            }.padding(.horizontal, contentInset).padding(.vertical, 24).background {
                BrowseScrollRestoration(memory: scrollMemory, scope: "home|\(browseScope)",
                    provisionalScope: "home|\(model.connection?.id.uuidString ?? "")|",
                    isReady: { model.homeContentReady && !model.isToolbarRefreshing }, isVisible: { model.page == "home" && model.detail == nil })
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }.coordinateSpace(name: "home-scroll-viewport")
            .accessibilityIdentifier("home-scroll")
      }
    }

    private var homeLibraryRail: some View {
        let recent = HomeLibraryContent.recentlyAdded(from: model.items)
        let hasDates = !recent.isEmpty
        let rail = hasDates ? recent : Array(model.items.prefix(12))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle(hasDates || (rail.isEmpty && model.catalogContentPending) ? "最近添加" : "浏览片库",
                             subtitle: model.selectedLibrary?.name ?? "当前媒体库")
                Spacer()
                libraryPicker
                    .opacity(model.libraries.isEmpty ? 0 : 1)
                    .disabled(model.libraries.isEmpty)
                    .accessibilityHidden(model.libraries.isEmpty)
                Button("查看全部") { model.navigate(to: "library") }.buttonStyle(.plain).foregroundStyle(SeatSixStyle.accent)
                    .disabled(model.libraries.isEmpty)
            }
            if rail.isEmpty && model.catalogContentPending && model.canBrowseCurrentMedia {
                ShelfRefreshSkeleton(.posterRail, posterSize: model.applicationPreferences.posterSize)
                    .accessibilityRepresentation { Text("正在加载最近添加") }
            } else if rail.isEmpty && !model.catalogFailed {
                Text("此媒体库暂无可展示的内容。")
                    .font(.system(size: 13)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary).padding(.vertical, 20)
            } else if !rail.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(rail) { item in
                            DetailEntryButton(model: model, item: item, kind: "home-recent") {
                                MovieCard(model: model, item: item, hasBrowsePoster: hasBrowsePoster).frame(width: model.applicationPreferences.posterSize.homeWidth)
                            }
                        }
                    }.padding(.bottom, 6)
                }.scrollIndicators(.hidden)
            }
            if model.catalogFailed { catalogStatus }
            if !hasDates && model.catalogComplete && !model.items.isEmpty {
                Text("服务器未提供添加时间，以下显示当前片库内容。").font(.caption).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
            }
        }
    }

    private var libraryPicker: some View {
        Picker("媒体库", selection: Binding(get: { model.selectedLibraryID }, set: { model.changeLibrary($0) })) {
            if model.libraries.isEmpty { Text("媒体库").tag(model.selectedLibraryID) }
            ForEach(model.libraries) { Text($0.name).tag($0.id) }
        }.labelsHidden().frame(maxWidth: 190)
            .accessibilityLabel("当前媒体库").help("切换当前浏览的媒体库")
    }

    private var libraryHeading: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.selectedLibrary?.name ?? "媒体库").font(.system(size: 28, weight: .semibold)).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
                Text("搜索、筛选和排序范围：\(model.connection?.name ?? "当前服务器") · \(model.selectedLibrary?.name ?? "当前媒体库")")
                    .font(.system(size: 11)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
            }

            Spacer()
            if !model.libraries.isEmpty {
                libraryPicker
            }
        }
    }

    private var libraryDisclosure: some View {
        DisclosureGroup(isExpanded: $filtersExpanded) { libraryFilters.padding(.top, 12) } label: {
            HStack {
                Label("筛选与排序", systemImage: "line.3.horizontal.decrease.circle")
                Spacer()
                Text(BrowsePresentation.filterSummary(query: model.query, year: model.filterYear,
                    genre: model.filterGenre, watched: model.watchFilter, favoritesOnly: model.favoritesOnly,
                    sort: model.sortOrder)).foregroundStyle(SeatSixStyle.secondary).lineLimit(2)
            }.font(.system(size: 12))
        }.padding(16).background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 12))
            .shelfRefreshRegion(cornerRadius: 12)
            .accessibilityIdentifier("library-filter-disclosure")
    }

    // Native text, the disclosure and status rows determine the actual grid origin.
    // Use their layout during a first refresh, including expanded or wrapping filters.
    private var libraryRefreshHeader: some View {
        VStack(alignment: .leading, spacing: 26) {
            libraryHeading.redacted(reason: .placeholder)
            libraryDisclosure.hidden().overlay {
                RoundedRectangle(cornerRadius: 12).fill(ShelfRefreshSkeleton.fill)
            }
            catalogStatus.hidden().overlay(alignment: .leading) {
                Capsule().fill(ShelfRefreshSkeleton.fill).frame(width: 136, height: 9)
            }
            sectionTitle(model.selectedLibrary?.name ?? "当前媒体库", subtitle: libraryResultCount)
                .redacted(reason: .placeholder)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var libraryContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if model.libraryListPending && model.libraries.isEmpty {
                    libraryRefreshHeader
                    loadingGrid(label: "正在加载媒体库", identifier: "library-grid-loading")
                } else if model.libraries.isEmpty && model.catalogFailed {
                    libraryHeading
                    catalogStatus
                } else if model.libraries.isEmpty {
                    libraryHeading
                    emptyState(icon: "rectangle.stack", title: "还没有可浏览的媒体库", text: "此连接未选择媒体库，或服务器尚未建立媒体库。可重新登录后调整选择。")
                    Button("选择媒体库") { model.reauthenticate = model.connection; model.showLogin = true }
                } else {
                    libraryHeading
                    libraryDisclosure
                    catalogStatus
                    sectionTitle(model.selectedLibrary?.name ?? "当前媒体库", subtitle: libraryResultCount)
                    if model.displayedItems.isEmpty && model.catalogContentPending {
                        loadingGrid(label: "正在读取媒体内容", identifier: "library-grid-loading")
                    } else if model.displayedItems.isEmpty {
                        libraryEmptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.applicationPreferences.posterSize.gridMinimum,
                                                              maximum: model.applicationPreferences.posterSize.gridMaximum), spacing: 18, alignment: .top)], alignment: .leading, spacing: 24) {
                            ForEach(model.displayedItems) { item in
                                DetailEntryButton(model: model, item: item, kind: "library",
                                    focusChanged: { focused in
                                        if focused {
                                            libraryKeyboard.select(itemID: item.id, ids: libraryIDs, scope: libraryKeyboardScope)
                                        }
                                    },
                                    keyboardFocusRequest: libraryKeyboard.focusRequest,
                                    consumeKeyboardFocus: { id in
                                        guard model.page == "library", model.detail == nil, navigationAllowed else { return false }
                                        return libraryKeyboard.takeFocusRequest(itemID: item.id, id: id)
                                    }, keyboardMove: moveLibrarySelection) { MovieCard(model: model, item: item, hasBrowsePoster: hasBrowsePoster) }
                                    .id(item.id)
                            }
                        }.background(BrowseViewProbe(identifier: "library-results-grid"))
                    }
                }
            }.padding(24).background {
                BrowseScrollRestoration(memory: scrollMemory, scope: libraryScrollScope,
                    isReady: { !model.catalogContentPending && !model.isToolbarRefreshing }, isVisible: { model.page == "library" && model.detail == nil })
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("library-scroll")
        .onChange(of: libraryKeyboard.focusRequest?.id) { _, _ in
            guard model.page == "library", model.detail == nil, let request = libraryKeyboard.focusRequest else { return }
            proxy.scrollTo(request.itemID)
        }
        }
    }

    private func loadingGrid(continuing: Bool = false, label: String, identifier: String) -> some View {
        ShelfRefreshSkeleton(.grid(continuing: continuing), posterSize: model.applicationPreferences.posterSize)
            .background(BrowseViewProbe(identifier: identifier))
            .overlay {
                Color.clear.accessibilityElement(children: .ignore).accessibilityLabel(label)
                    .allowsHitTesting(false)
            }
    }

    private func searchContent(_ destination: BrowseDestination) -> some View {
        let server = destination == .searchServer
        let candidates = server ? model.serverBrowseCatalogItems : model.items
        let query = model.searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = SearchPresentation.results(candidates, query: query, offset: searchRecommendationOffset)
        let loading = server ? model.serverBrowseContentPending : model.catalogContentPending
        let noLibraries = model.connection?.libraryIDs.isEmpty == true
        let canShowEmpty = server ? (model.serverBrowseComplete || noLibraries) && model.serverBrowseError == nil
                                  : (model.catalogComplete || noLibraries) && !model.catalogFailed
        let scrollScope = String(reflecting: [serverBrowseScope(destination), server ? "" : model.selectedLibraryID, query])
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if server, let error = model.serverBrowseError {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    Button("重新读取") { model.refreshServerBrowse() }
                }
                if query.isEmpty {
                    HStack {
                        searchSectionHeading("推荐观看", loading: loading)
                        Spacer()
                        Button("换一批") {
                            let count = candidates.count
                            guard count > 1 else { return }
                            searchRecommendationOffset = (searchRecommendationOffset + min(24, count - 1)) % count
                        }.disabled(candidates.count < 2)
                    }
                }
                if results.isEmpty {
                    if loading {
                        if !query.isEmpty {
                            Text("搜索结果").font(.title2.bold()).redacted(reason: .placeholder).shelfRefreshRegion()
                                .accessibilityHidden(true)
                        }
                        loadingGrid(label: "正在读取搜索内容", identifier: "search-grid-loading")
                    } else if canShowEmpty {
                        Text(query.isEmpty ? "暂无推荐内容" : "未找到影片")
                            .posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
                            .shelfRefreshRegion().padding(.vertical, 40)
                            .background(BrowseViewProbe(identifier: "search-complete-empty"))
                    }
                } else if query.isEmpty {
                    searchGrid(results)
                } else {
                    let groups = SearchPresentation.groups(results)
                    ForEach(groups, id: \.title) { group in
                        searchSectionHeading(group.title, loading: loading && group.title == groups.first?.title)
                        searchGrid(group.items)
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    BrowseScrollRestoration(memory: scrollMemory, scope: scrollScope,
                        isReady: { (server ? model.serverBrowseComplete : model.catalogComplete) && !model.isToolbarRefreshing },
                        isVisible: { model.page == destination.rawValue && model.detail == nil })
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                    BrowseViewProbe(identifier: "server-browse-scroll-probe-\(destination.rawValue)")
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                }
        }.accessibilityIdentifier("search-results")
    }

    private func searchSectionHeading(_ title: String, loading: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.title2.bold()).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
            if loading {
                ProgressView().controlSize(.mini).accessibilityLabel("正在读取媒体")
            }
        }
    }

    private func searchGrid(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.applicationPreferences.posterSize.gridMinimum,
                                               maximum: model.applicationPreferences.posterSize.gridMaximum), spacing: 18)], alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                DetailEntryButton(model: model, item: item, kind: "search") { MovieCard(model: model, item: item, hasBrowsePoster: hasBrowsePoster) }
            }
        }.background(BrowseViewProbe(identifier: "search-results-grid"))
    }

    private func serverBrowseItems(_ destination: BrowseDestination) -> [MediaItem] {
        switch destination {
        case .favorites: return model.serverBrowseCatalogItems
        case .continuing: return model.serverContinuingItems
        case .recent: return model.serverRecentItems
        case .movies: return LibraryQuery().apply(to: model.serverBrowseCatalogItems.filter { $0.type == "Movie" })
        case .series: return LibraryQuery().apply(to: model.serverBrowseCatalogItems.filter { $0.type == "Series" })
        case .other: return LibraryQuery().apply(to: model.serverBrowseCatalogItems.filter {
            $0.type != "Movie" && $0.type != "Series" && $0.isPlayable
        })
        default: return []
        }
    }

    private func serverBrowseScope(_ destination: BrowseDestination) -> String {
        String(reflecting: [destination.rawValue, model.connection?.id.uuidString ?? "",
                           model.connection?.serverID ?? "", model.connection?.userID ?? ""]
            + (model.connection?.libraryIDs.sorted() ?? []))
    }

    private func serverBrowseContent(_ destination: BrowseDestination) -> some View {
        let items = serverBrowseItems(destination)
        let isContinuing = destination == .continuing
        let loading = model.serverBrowseContentPending
        let scope = serverBrowseScope(destination)
        var status = model.serverBrowseComplete ? "共 \(items.count) 项" : "已读取 \(items.count) 项 · 结果尚不完整"
        if items.isEmpty && loading {
            status = isContinuing ? "正在读取全部观看记录…" : "正在读取已选媒体库…"
        }
        let missingDateCount = destination == .recent ? model.serverBrowseMissingDateCount : 0
        if missingDateCount > 0 {
            status += " · \(missingDateCount) 项未提供添加时间，未列入最近添加。"
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(destination.title).font(.system(size: 28, weight: .semibold)).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
                    Text(loading ? "当前服务器 · 已选媒体库"
                         : "当前服务器 · 已选的 \(model.serverBrowseLibraryIDs.count) 个媒体库")
                        .font(.system(size: 12)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
                }


                if let error = model.serverBrowseError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("内容未能完整读取", systemImage: "exclamationmark.circle")
                            .font(.headline).foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).foregroundStyle(SeatSixStyle.secondary)
                        Button("重新读取") { model.refreshServerBrowse() }
                            .buttonStyle(.link).disabled(model.serverBrowseLoading || model.userStateBusy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        .background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                        .background(BrowseViewProbe(identifier: "server-browse-state-\(destination.rawValue)-error"))
                }

                if loading || !items.isEmpty || missingDateCount > 0 {
                    Text(status).font(.system(size: 12)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
                }

                if items.isEmpty && loading {
                    loadingGrid(continuing: isContinuing, label: "正在读取\(destination.title)",
                                identifier: "server-browse-state-\(destination.rawValue)-loading")
                } else if items.isEmpty && model.serverBrowseError == nil
                            && (model.serverBrowseComplete || model.connection?.libraryIDs.isEmpty == true) {
                    emptyState(icon: destination == .favorites ? "star" : (isContinuing ? "play.circle" : "rectangle.stack"),
                               title: model.serverBrowseLibraryIDs.isEmpty ? "还没有可浏览的媒体库" : "暂无\(destination.title)内容",
                               text: model.serverBrowseLibraryIDs.isEmpty ? "请在此服务器的连接设置中选择可用的媒体库。"
                                   : (isContinuing ? "有未看完的内容后，会在这里显示。"
                                      : (destination == .recent ? "服务器提供添加时间后，内容会按时间从新到旧排列。"
                                         : (destination == .favorites ? "在影片、剧集或单集详情中添加的收藏会显示在这里。" : "当前已选媒体库中没有此类型的内容。"))))
                        .background(BrowseViewProbe(identifier: "server-browse-state-\(destination.rawValue)-empty"))
                } else if !items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(
                        minimum: isContinuing ? 230 : model.applicationPreferences.posterSize.gridMinimum,
                        maximum: isContinuing ? 340 : model.applicationPreferences.posterSize.gridMaximum),
                        spacing: 18, alignment: .top)], alignment: .leading, spacing: 24) {
                        ForEach(items) { item in
                            Group {
                                if isContinuing {
                                    ContinueCard(model: model, item: item, kind: "server-\(destination.rawValue)-continue")
                                } else {
                                    DetailEntryButton(model: model, item: item, kind: "server-\(destination.rawValue)") { MovieCard(model: model, item: item, hasBrowsePoster: hasBrowsePoster) }
                                }
                            }
                            .id(item.id)
                            .background {
                                if item.id == items.last?.id {
                                    BrowseViewProbe(identifier: "server-browse-last-item-\(destination.rawValue)-\(item.id)")
                                }
                            }
                        }
                    }.background(BrowseViewProbe(identifier: "server-browse-grid-\(destination.rawValue)"))
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    BrowseScrollRestoration(memory: scrollMemory, scope: "server|\(scope)",
                        isReady: { !model.serverBrowseContentPending && !model.isToolbarRefreshing },
                        isVisible: { model.page == destination.rawValue && model.detail == nil })
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                    BrowseViewProbe(identifier: "server-browse-scroll-probe-\(destination.rawValue)")
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                }
        }.accessibilityIdentifier("server-\(destination.rawValue)-scroll")
    }

    private var libraryFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("筛选与排序", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.hasActiveFilters {
                    Button("清除搜索与筛选") { model.clearLibraryFilters() }
                        .buttonStyle(.link).font(.system(size: 11))
                        .accessibilityLabel("清除搜索与筛选")
                        .help("清除关键词、年份、类型、观看状态和收藏筛选，保留排序方式")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    filterLabel("年份")
                    Picker("年份", selection: $model.filterYear) {
                        Text("全部年份").tag(Int?.none)
                        ForEach(selectableYears, id: \.self) { year in
                            Text(String(year)).tag(Optional(year))
                        }
                    }.labelsHidden().accessibilityLabel("年份筛选")
                        .accessibilityIdentifier("library-year-filter")
                        .help("按影片或剧集的发行年份筛选")
                }
                VStack(alignment: .leading, spacing: 6) {
                    filterLabel("类型")
                    Picker("类型", selection: $model.filterGenre) {
                        Text("全部类型").tag(String?.none)
                        ForEach(selectableGenres, id: \.self) { genre in
                            Text(genre).tag(Optional(genre))
                        }
                    }.labelsHidden().accessibilityLabel("类型筛选")
                        .accessibilityIdentifier("library-genre-filter")
                        .help("按服务器提供的题材分类筛选，例如剧情、动作或喜剧")
                }
                VStack(alignment: .leading, spacing: 6) {
                    filterLabel("观看状态")
                    Picker("观看状态", selection: $model.watchFilter) {
                        Text("全部状态").tag(LibraryWatchFilter.all)
                        Text("已看").tag(LibraryWatchFilter.watched)
                        Text("未看").tag(LibraryWatchFilter.unwatched)
                    }.labelsHidden().accessibilityLabel("观看状态筛选")
                        .accessibilityIdentifier("library-watch-filter")
                        .help("按服务器记录的已看或未看状态筛选")
                }
                VStack(alignment: .leading, spacing: 6) {
                    filterLabel("排序")
                    Picker("排序", selection: $model.sortOrder) {
                        Text("名称 · 升序").tag(LibrarySortOrder.nameAscending)
                        Text("名称 · 降序").tag(LibrarySortOrder.nameDescending)
                        Text("年份 · 从新到旧").tag(LibrarySortOrder.yearDescending)
                        Text("年份 · 从旧到新").tag(LibrarySortOrder.yearAscending)
                    }.labelsHidden().accessibilityLabel("媒体库排序")
                        .accessibilityIdentifier("library-sort-order")
                        .help("对当前媒体库的全部匹配结果排序；没有年份的内容排在最后")
                }
                VStack(alignment: .leading, spacing: 6) {
                    filterLabel("收藏")
                    Toggle("只看收藏", isOn: $model.favoritesOnly)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("收藏筛选")
                        .accessibilityIdentifier("library-favorites-filter")
                        .help("只显示当前媒体库中已在服务器收藏的内容，可与其他筛选条件组合使用")
                }
            }
        }
        .padding(16).background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private func filterLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary)
    }

    private var selectableYears: [Int] {
        var years = model.catalogFacets.years
        if let selected = model.filterYear, !years.contains(selected) { years.append(selected) }
        return years.sorted(by: >)
    }

    private var selectableGenres: [String] {
        var genres = model.catalogFacets.genres
        if let selected = model.filterGenre, !genres.contains(selected) { genres.append(selected) }
        return genres.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var catalogStatus: some View {
        HStack(alignment: .center, spacing: 9) {
            if model.catalogLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.catalogComplete ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(model.catalogComplete ? SeatSixStyle.accent : .orange)
            }
            Text(model.catalogStatus)
                .font(.system(size: 11)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("library-catalog-status")
            Spacer(minLength: 8)
            if model.catalogFailed {
                Button("重新读取完整媒体库") { model.refresh() }
                    .buttonStyle(.link).font(.system(size: 11))
                    .disabled(model.catalogLoading)
                    .accessibilityLabel("重新读取完整媒体库")
                    .help("重新读取当前媒体库的全部内容，完成后获得完整的搜索和筛选结果")
            }
        }
    }

    private var libraryResultCount: String {
        let count = model.displayedItems.count
        if model.catalogComplete {
            return model.hasActiveFilters ? "\(count) 项匹配 · 共 \(model.items.count) 项" : "共 \(count) 项"
        }
        return "当前已读取内容中 \(count) 项\(model.hasActiveFilters ? "匹配" : "可浏览") · 结果尚不完整"
    }

    @ViewBuilder
    private var libraryEmptyState: some View {
        if model.catalogComplete {
            emptyState(icon: "film", title: model.hasActiveFilters ? "没有找到匹配的内容" : "媒体库中暂无内容",
                       text: model.hasActiveFilters ? "已搜索当前媒体库的全部内容。试试其他关键词、调整筛选条件，或切换媒体库。" : "在服务器添加媒体后，点击刷新。")
        } else {
            emptyState(icon: "exclamationmark.circle", title: "媒体库尚未读取完整",
                       text: "目前已读取的内容中暂无匹配项。请重新读取完整媒体库后查看最终结果。")
        }
    }

    private var servers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("媒体服务器").font(.system(size: 28, weight: .semibold)).posterCaptionBacking(hasBrowsePoster)
                    Spacer()
                    Button { model.reauthenticate = nil; model.showLogin = true } label: { Label("添加服务器", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }.padding(.bottom, 8)
                if model.saved.connections.isEmpty { emptyState(icon: "server.rack", title: "尚未添加服务器", text: "连接 Emby 或 Jellyfin，把你的媒体库带到这里。") }
                ForEach(model.saved.connections) { connection in
                    HStack(spacing: 17) {
                        serverIcon(connection.kind, size: 42)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(connection.name).font(.system(size: 15, weight: .medium))
                            Text("\(connection.kind.name) · \(connection.username) · \(connection.libraryIDs.count) 个媒体库").font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary)
                            Text(connection.baseURL.absoluteString).font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary).textSelection(.enabled)
                            if connection.compatibilityMode { Text("Emby 兼容接口 · 仅支持原始媒体直放").font(.system(size: 10)).foregroundStyle(SeatSixStyle.accent) }
                            if let pin = connection.certificatePin {
                                Label("使用你确认的自定义证书", systemImage: "lock.trianglebadge.exclamationmark")
                                    .font(.system(size: 10)).foregroundStyle(.orange)
                                Text("SHA-256  " + pin.sha256Fingerprint).font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(SeatSixStyle.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        Button("打开") {
                            if model.connection?.id == connection.id { model.navigate(to: "home") }
                            else { model.switchConnection(connection.id) }
                        }
                        ContentOverflowMenu(name: "更多服务器操作，\(connection.name)", side: 28) {
                            Button("重新登录 / 选择媒体库") { model.reauthenticate = connection; model.showLogin = true }
                            if connection.certificatePin != nil {
                                Button("撤销证书信任…", role: .destructive) { revokingTrust = connection }
                            }
                            Button("解除连接…", role: .destructive) { removing = connection }
                        }
                    }.padding(20).background(SeatSixStyle.panel, in: RoundedRectangle(cornerRadius: 10)).shelfRefreshRegion(cornerRadius: 10)
                }
            }.padding(30)
        }
    }
}

private extension SeatSixRootView {
    func sectionTitle(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 18, weight: .semibold)).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
            Text(subtitle).font(.system(size: 10)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary)
        }
    }

    func emptyState(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(SeatSixStyle.secondary)
            Text(title).font(.system(size: 17, weight: .medium)).posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
            Text(text).font(.system(size: 12)).posterCaptionBacking(hasBrowsePoster).foregroundStyle(SeatSixStyle.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }.frame(maxWidth: .infinity).padding(.vertical, 75)
    }
}

private func serverIcon(_ kind: ServerKind, size: CGFloat) -> some View {
    Image(systemName: kind == .emby ? "play.fill" : "triangle.fill")
        .font(.system(size: size * 0.42, weight: .medium))
        .foregroundStyle(kind == .emby ? Color.green.opacity(0.8) : Color.purple.opacity(0.85))
        .frame(width: size, height: size)
        .background((kind == .emby ? Color.green : Color.purple).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
}

func durationText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "00:00" }
    let value = Int(seconds), hours = value / 3600, minutes = value / 60 % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, value % 60) : String(format: "%02d:%02d", minutes, value % 60)
}

private struct MovieCard: View {
    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    let hasBrowsePoster: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaPoster(model: model, item: item)
                .aspectRatio(2 / 2.85, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let rating = item.communityRating {
                        Text(rating, format: .number.precision(.fractionLength(1)))
                            .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                            .foregroundStyle(.white).background(.black.opacity(0.65))
                            .accessibilityLabel("评分 \(rating.formatted())")
                    }
                }
                .overlay(alignment: .topLeading) {
                    if item.userData.isFavorite {
                        Image(systemName: "heart.fill").foregroundStyle(SeatSixStyle.accent)
                            .font(.system(size: 14)).padding(7)
                            .background(Color.black.opacity(0.65), in: Circle()).padding(8)
                            .accessibilityLabel("已收藏")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.userData.played { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Color.black, SeatSixStyle.accent).font(.system(size: 20)).padding(9) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shelfRefreshRegion(cornerRadius: 9)
            Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .posterCaptionBacking(hasBrowsePoster).shelfRefreshRegion()
            HStack {
                Text(item.productionYear.map(String.init) ?? (item.type == "Series" ? "剧集" : "影片"))
                    .posterCaptionBacking(hasBrowsePoster)
                Spacer()
                if item.durationSeconds > 0 {
                    Text("\(Int(item.durationSeconds / 60)) 分钟").posterCaptionBacking(hasBrowsePoster)
                }
            }.font(.system(size: 10)).foregroundStyle(SeatSixStyle.secondary)
        }.contentShape(Rectangle())
    }
}

private struct ContinueCard: View {
    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    let kind: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.resumeWatching(item) } label: {
                MediaPoster(model: model, item: item, role: .landscape)
                    .aspectRatio(16 / 9, contentMode: .fit).clipped().shelfRefreshRegion(cornerRadius: 10)
                    .overlay {
                        if model.resumeLoadingID == item.id { ProgressView().padding(12).background(.regularMaterial, in: Circle()) }
                        else { Image(systemName: "play.circle.fill").font(.system(size: 38)).foregroundStyle(.white).shadow(radius: 8) }
                    }
            }.buttonStyle(.plain)
                .accessibilityLabel("继续观看 \(item.seriesName ?? item.name)，\(BrowsePresentation.continueSubtitle(item))")
                .accessibilityIdentifier("resume-\(item.id)")
                .disabled(model.launchingPlayback || model.resumeLoadingID != nil || model.userStateBusy || model.userStateNeedsRefresh)
            GeometryReader { geometry in
                Rectangle().fill(Color.white.opacity(0.1))
                Rectangle().fill(SeatSixStyle.accent).frame(width: geometry.size.width * (item.isPlayable ? EpisodeDisplay.progress(item) : 0))
            }.frame(height: 2)
            DetailEntryButton(model: model, item: item, kind: kind) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.type == "Episode" ? (item.seriesName ?? item.name) : item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).shelfRefreshRegion()
                        Text(BrowsePresentation.continueSubtitle(item)).shelfRefreshRegion().font(.system(size: 11)).foregroundStyle(SeatSixStyle.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(SeatSixStyle.secondary)
                }.padding(14).contentShape(Rectangle())
            }
        }.background(SeatSixStyle.panel).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// The native pull-down owns the whole glass surface, its focus ring and its menu.
private struct DetailPlaybackMenu: NSViewRepresentable {
    var restart: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    final class Coordinator: NSObject {
        var restart: () -> Void
        init(restart: @escaping () -> Void) { self.restart = restart }
        @objc func playFromBeginning(_ sender: NSMenuItem) { restart() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(restart: restart) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.controlSize = .large
        if #available(macOS 26, *) {
            button.bezelStyle = .glass
            button.borderShape = .circle
        } else {
            button.bezelStyle = .circular
        }
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.imagePosition = .imageOnly
        let menu = NSMenu()
        // AppKit uses the first item as the face of a pull-down and hides it in the menu.
        let name = "更多播放操作"
        let face = menu.addItem(withTitle: name, action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: name)
        let item = menu.addItem(withTitle: "从头播放", action: #selector(Coordinator.playFromBeginning(_:)), keyEquivalent: "")
        item.target = context.coordinator
        button.menu = menu
        button.toolTip = name
        button.setAccessibilityTitle(name)
        button.setAccessibilityLabel(name)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.restart = restart
        button.isEnabled = isEnabled
    }
}

private struct MediaDetailView: View {
    @ObservedObject var model: ApplicationModel
    let item: MediaItem
    let artwork: DetailArtwork
    @ObservedObject var scrollMemory: BrowseScrollMemory
    let presentationScope: HomeArtworkScope?
    private var isCurrentPresentation: Bool {
        model.detail?.id == item.id && HomeArtworkScope(model: model) == presentationScope
    }
    @State private var versionSelection = PlaybackVersionSelection()
    private var selectedSourceID: String { versionSelection.id }
    @State private var mode: PlaybackMode = .automatic
    private var detailScope: String { "\(model.connection?.id.uuidString ?? "")|\(item.id)" }
    private var overviewExpanded: Bool {
        get { scrollMemory.overviewExpanded(for: detailScope) }
        nonmutating set { scrollMemory.setOverviewExpanded(newValue, for: detailScope) }
    }
    private var resourcesExpanded: Bool {
        get { scrollMemory.resourcesExpanded(for: detailScope) }
        nonmutating set { scrollMemory.setResourcesExpanded(newValue, for: detailScope) }
    }
    @Environment(\.detailInteractionActions) private var detailActions
    @State private var playedChange: PlayedChangeConfirmation?
    @State private var actionFeedback = DetailActionFeedback()
    private struct PlayedChangeConfirmation {
        let item: MediaItem
        let played: Bool
        let connectionID: UUID?
    }
    private var source: MediaSource? {
        item.mediaSources.first { $0.id == selectedSourceID }
    }
    private var needsVersionChoice: Bool { versionSelection.requiresChoice }
    private var heroImage: NSImage? {
        artwork.appearance.hasArtwork ? artwork.landscape : nil
    }
    private var showsCinematicHeader: Bool { heroImage != nil || artwork.landscapePending }

    private var headerAppearance: DetailArtworkAppearance {
        showsCinematicHeader ? DetailArtworkAppearance(colorField: artwork.appearance.colorField, isLight: false) : artwork.appearance
    }

    var body: some View {
        GeometryReader { viewport in
            let inset: CGFloat = viewport.size.width >= 760 ? 32 : 20
            let topInset = model.errorMessage == nil ? SeatSixSidebarMetrics.titlebarHeight : 0
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !model.seriesPresentation.showsAll {
                        if showsCinematicHeader {
                            DetailCinematicHero(image: heroImage, hasArtwork: artwork.appearance.hasArtwork,
                                                viewport: viewport.size, inset: inset) {
                                cinematicInfo(width: viewport.size.width)
                                    .opacity(model.isToolbarRefreshing ? 0 : 1)
                            }
                            .environment(\.detailArtworkAppearance, headerAppearance)
                            .environment(\.colorScheme, .dark)
                            .foregroundStyle(.white)
                            .tint(.white)
                        } else {
                            compactHeader(width: viewport.size.width)
                                .opacity(model.isToolbarRefreshing ? 0 : 1)
                                .padding(.horizontal, inset)
                                .padding(.top, topInset + 24)
                        }
                    }
                    VStack(alignment: .leading, spacing: 28) { detailSections }
                        .opacity(model.isToolbarRefreshing ? 0 : 1)
                        .padding(.horizontal, inset)
                        .padding(.top, model.seriesPresentation.showsAll ? topInset + 24 : 20)
                        .padding(.bottom, 36)
                }
                .modifier(DetailToolbarScrollMarker(itemID: isCurrentPresentation ? item.id : nil))
                .background {
                    BrowseScrollRestoration(memory: scrollMemory,
                        scope: "\(model.connection?.id.uuidString ?? "")|\(item.id)|\(model.selectedSeasonID)|\(model.seriesPresentation.showsAll ? "episodes" : "detail")",
                        isReady: { !model.seriesLoading && !model.detailLoading && !model.isToolbarRefreshing &&
                                (model.seriesPresentation.showsAll || !artwork.landscapePending) }, isVisible: { model.detail?.id == item.id })
                        .frame(width: 0, height: 0).accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: DetailToolbarScrollMarker.space)
        }
        .onAppear { updateSourceSelection() }
        .onChange(of: model.userStateBusy) { _, _ in updateActionFeedback() }
        .onChange(of: HomeArtworkScope(model: model)) { _, _ in actionFeedback.invalidate() }
        .onChange(of: isCurrentPresentation) { _, visible in if !visible { actionFeedback.invalidate() } }
        .task(id: actionFeedback.message?.id) {
            guard let id = actionFeedback.message?.id else { return }
            try? await Task.sleep(for: .seconds(DetailActionFeedback.displayDuration))
            guard !Task.isCancelled else { return }
            actionFeedback.dismiss(messageID: id)
        }
        .onChange(of: item.mediaSources) { _, _ in updateSourceSelection() }
        .confirmationDialog(playedChange?.played == true ? "标记为已看？" : "标记为未看？", isPresented: Binding(get: { playedChange != nil }, set: { if !$0 { playedChange = nil } }), titleVisibility: .visible) {
            if let change = playedChange {
                Button(change.played ? "标记已看" : "标记未看") {
                    if model.connection?.id == change.connectionID,
                       model.detail?.id == change.item.id,
                       !model.detailLoading, !model.userStateBusy, !model.userStateNeedsRefresh,
                       model.canEditPlayedState, model.canSetPlayed(change.item) {
                        actionFeedback.begin(itemID: item.id, scope: HomeArtworkScope(model: model), action: .played(change.played))
                        model.setPlayed(change.item, played: change.played)
                        updateActionFeedback()
                    }
                    playedChange = nil
                }
                .disabled(model.detailLoading || model.userStateBusy || model.userStateNeedsRefresh || !model.canEditPlayedState)
            }
            Button("取消", role: .cancel) { playedChange = nil }
        } message: {
            if let change = playedChange {
                Text(playedChangeMessage(change))
            }
        }
        // Keep the departing visual available for its removal transition, but
        // never retain imagery across connection/account/library boundaries.
        .opacity(HomeArtworkScope(model: model) == presentationScope ? 1 : 0)
        .allowsHitTesting(isCurrentPresentation)
        .accessibilityHidden(!isCurrentPresentation)
        .disabled(!isCurrentPresentation)
        .id(item.id)
    }

    private func cinematicInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(width: width, cinematic: true)
            if width >= 800 {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 9) { playbackActions; userStateActions }
                        .frame(width: min(248, width * 0.24), alignment: .leading)
                    VStack(alignment: .leading, spacing: 9) { metadata; overview }
                        .frame(maxWidth: 960, alignment: .leading)
                }
            } else {
                metadata
                playbackActions
                userStateActions
                overview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SeatSixSidebarGeometry(id: "detail-hero-info"))
    }

    private func compactHeader(width: CGFloat) -> some View {
        let layout = width >= 540
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        let posterWidth = min(205, max(108, width * 0.22))
        return layout {
            MediaPosterContent(image: artwork.poster, pending: artwork.posterPending, item: item)
                .frame(width: posterWidth, height: posterWidth * 1.425)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shelfRefreshRegion(cornerRadius: 10)
                .accessibilityLabel("\(item.name) 海报")
            VStack(alignment: .leading, spacing: 14) {
                heading(width: width, cinematic: false)
                metadata
                playbackActions
                userStateActions
                overview
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heading(width: CGFloat, cinematic: Bool) -> some View {
        let title = Text(item.name)
            .font(.system(size: cinematic && width >= 800 ? 42 : 33, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        return VStack(alignment: .leading, spacing: 5) {
            if item.type == "Episode" {
                Text([item.seriesName, EpisodeDisplay.number(item)].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline).foregroundStyle(headerAppearance.secondaryText)
            }
            Group {
                if cinematic, !item.artworkSources(for: .logo).isEmpty {
                    // Keep the wrapped text's footprint when a title treatment arrives from the server.
                    ZStack(alignment: .bottomLeading) {
                        title.opacity(artwork.logo == nil ? 1 : 0)
                            .allowsHitTesting(artwork.logo == nil)
                            .accessibilityHidden(artwork.logo != nil)
                        if let logo = artwork.logo {
                            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                                .frame(width: min(width * 0.52, 280), height: 62, alignment: .bottomLeading)
                                .accessibilityLabel(item.name)
                                .background(SeatSixSidebarGeometry(id: "detail-hero-logo"))
                        }
                    }
                    .frame(minHeight: 62, alignment: .bottomLeading)
                } else {
                    title
                }
            }
            .accessibilityAddTraits(.isHeader)
            .background(SeatSixSidebarGeometry(id: "detail-hero-title"))
            .shelfRefreshRegion()
        }
    }

    private var metadata: some View {
        let facts: [String] = [
            item.communityRating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) },
            item.premiereDate?.formatted(.iso8601.year().month().day().dateSeparator(.dash)) ?? item.productionYear.map(String.init),
            item.officialRating,
            item.durationSeconds > 0 ? "\(Int(item.durationSeconds / 60)) 分钟" : nil,
            item.genres.isEmpty ? nil : item.genres.joined(separator: " · "),
            item.userData.played ? "已观看" : nil,
            item.userData.isFavorite ? "已收藏" : nil
        ].compactMap { $0 }.filter { !$0.isEmpty }
        let size = source?.size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil }
        let video = source?.mediaStreams?.first { $0.type == "Video" }
        let technical = [size, video?.displayTitle ?? video?.codec?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 5) {
            if !facts.isEmpty {
                Text(facts.joined(separator: "   ·   ")).font(.system(size: 13, weight: .semibold))
            } else if model.isLoadingPresentedDetailMetadata {
                DetailPlaceholderLine(width: 128, font: .system(size: 13))
            }
            if !technical.isEmpty {
                Text(technical.joined(separator: "   ·   ")).font(.caption).foregroundStyle(headerAppearance.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var overview: some View {
        if let preview = model.previewEpisode {
            Text(EpisodeDisplay.number(preview) + " · " + preview.name).font(.headline)
        }
        MediaOverviewView(connection: model.connection, item: model.previewEpisode ?? item,
                          hideUnwatched: model.applicationPreferences.hideUnwatchedEpisodeOverview,
                          expanded: Binding(get: { overviewExpanded }, set: { overviewExpanded = $0 }),
                          isLoading: model.isLoadingPresentedDetailMetadata && model.previewEpisode == nil)
            .shelfRefreshRegion()
    }

    @ViewBuilder private var playbackActions: some View {
        if item.isPlayable {
            HStack(spacing: 12) {
                Button { play(fromBeginning: false) } label: {
                    Label(BrowsePresentation.playbackTitle(item), systemImage: "play.fill")
                }.seatSixGlassButton(prominent: true).buttonBorderShape(.capsule).controlSize(.large)
                    .accessibilityIdentifier("detail-primary-play")
                    .background(SeatSixSidebarGeometry(id: "detail-primary-play"))
                    .shelfRefreshRegion()
                if !item.userData.played && item.userData.playbackPositionTicks > 0 {
                    DetailPlaybackMenu { play(fromBeginning: true) }
                        .frame(width: 32, height: 32)
                        .background(SeatSixSidebarGeometry(id: "detail-more-playback"))
                }
                if model.launchingPlayback || model.detailLoading { ProgressView().controlSize(.small) }
            }.disabled(model.launchingPlayback || model.detailLoading || model.userStateBusy || model.userStateNeedsRefresh || needsVersionChoice)
            if needsVersionChoice {
                Text("请在下方确认播放版本，避免不同版本使用同一续播位置。").font(.caption).foregroundStyle(headerAppearance.accentText)
            }
        } else if item.type == "Series" {
            if let candidate = model.seriesPlaybackCandidate {
                Button { model.resumeWatching(candidate) } label: {
                    Label(BrowsePresentation.playbackTitle(candidate), systemImage: "play.fill")
                }.seatSixGlassButton(prominent: true).buttonBorderShape(.capsule).controlSize(.large)
                    .accessibilityIdentifier("detail-primary-play")
                    .background(SeatSixSidebarGeometry(id: "detail-primary-play"))
                    .shelfRefreshRegion()
                    .disabled(model.launchingPlayback || model.resumeLoadingID != nil || model.seriesLoading || model.userStateBusy || model.userStateNeedsRefresh)
                if model.resumeLoadingID != nil { ProgressView("正在确认播放资源…").controlSize(.small) }
            } else if model.seriesLoading {
                RoundedRectangle(cornerRadius: 8).fill(headerAppearance.placeholderFill)
                    .frame(width: 94, height: 32)
                    .accessibilityElement(children: .ignore).accessibilityLabel("正在确认可播放的分集")
            } else {
                Text("请在下方选择分集播放。").font(.callout).foregroundStyle(headerAppearance.secondaryText)
            }
            Text("每集分别保存观看进度，可在播放器中设置自动连播。")
                .font(.system(size: 12)).foregroundStyle(headerAppearance.secondaryText)
        }
    }

    @ViewBuilder private var detailSections: some View {
        if item.type == "Series" {
            SeriesEpisodesView(model: model, series: item)
        } else if item.isPlayable {
            let compactOptions = showsCinematicHeader && !needsVersionChoice && !resourcesExpanded && item.mediaSources.count <= 1
            if item.type == "Episode", item.seriesID != nil {
                DetailEntryButton(model: model, item: item, kind: "episode-series", showsSeries: true,
                                  accessibilityName: "查看全部分集", appearance: .action) { Text("查看全部分集") }
            }
            DisclosureGroup(isExpanded: Binding(get: { resourcesExpanded }, set: { resourcesExpanded = $0 })) {
                VStack(alignment: .leading, spacing: 17) {
                    if item.mediaSources.isEmpty {
                        if model.isLoadingPresentedDetailMetadata {
                            VStack(alignment: .leading, spacing: 8) {
                                DetailPlaceholderLine(width: 240, font: .callout)
                                DetailPlaceholderLine(width: 156, font: .caption)
                            }
                            .accessibilityElement(children: .ignore).accessibilityLabel("正在获取播放资源")
                        } else {
                            Text("将在播放时向服务器确认可用资源。").font(.system(size: 12)).foregroundStyle(artwork.appearance.secondaryText)
                        }
                    } else {
                        Picker("版本", selection: Binding(get: { selectedSourceID }, set: { versionSelection.select($0) })) {
                            if needsVersionChoice || item.mediaSources.count > 1 { Text("请选择播放版本").tag("") }
                            ForEach(item.mediaSources) { source in Text(source.name ?? source.container?.uppercased() ?? "媒体资源").tag(source.id) }
                        }.frame(maxWidth: 460)
                        if let source {
                            HStack(spacing: 18) {
                                if let container = source.container { Text(container.uppercased()) }
                                ForEach(Array((source.mediaStreams ?? []).filter { $0.type == "Video" || $0.type == "Audio" }.prefix(3).enumerated()), id: \.offset) { _, stream in
                                    Text(stream.displayTitle ?? stream.codec?.uppercased() ?? "未知编码").lineLimit(1)
                                }
                            }.font(.system(size: 11)).foregroundStyle(artwork.appearance.secondaryText)
                        }
                    }
                    if model.connection?.compatibilityMode == true {
                        Label(LocalPlaybackEngine.isAvailable
                              ? "在 Mac 本地解码 MKV、HEVC 等常见格式，无需服务器转码。"
                              : "此来源仅支持原画直放。请选择 H.264 视频和 AAC 音频的 MP4、M4V 或 MOV 版本。",
                              systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(artwork.appearance.secondaryText)
                    } else {
                        Picker("播放方式", selection: $mode) {
                            Text(LocalPlaybackEngine.isAvailable ? "本地原画（无需转码）" : "自动（优先直放，按需转码）").tag(PlaybackMode.automatic)
                            Text("兼容播放（服务器转码）").tag(PlaybackMode.compatible)
                        }.frame(maxWidth: 460)
                    }
                }.padding(.top, 16)
            } label: {
                HStack {
                    Label("版本与播放设置", systemImage: "slider.horizontal.3").font(.system(size: 14, weight: .medium))
                    Spacer()
                    if !compactOptions {
                        Text(source?.name ?? source?.container?.uppercased() ?? (needsVersionChoice ? "请选择版本" : "自动选择可用资源"))
                            .font(.caption).foregroundStyle(artwork.appearance.secondaryText).lineLimit(1)
                    }
                }
            }
                .padding(.horizontal, compactOptions ? 2 : 22)
                .padding(.vertical, compactOptions ? 5 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if !compactOptions { RoundedRectangle(cornerRadius: 14).fill(artwork.appearance.panelFill) }
                }
                .shelfRefreshRegion(cornerRadius: 14, isBackdrop: !compactOptions)
                .accessibilityIdentifier("detail-playback-options")
        }
        if !model.seriesPresentation.showsAll {
            let metadataItem = model.previewEpisode ?? item
            let selectedSource = model.previewEpisode == nil ? source :
                (metadataItem.mediaSources.count == 1 ? metadataItem.mediaSources.first : nil)
            MediaDetailInformationView(model: model, people: item.people,
                streams: MediaDetailInformation.streams(item: metadataItem, source: selectedSource),
                awaitsCredits: model.isLoadingPresentedDetailMetadata,
                awaitsStreams: model.isLoadingPresentedDetailMetadata && model.previewEpisode == nil
                    && metadataItem.isPlayable && !needsVersionChoice)
        }
    }

    private var userStateActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if model.canFavorite(item) {
                    Button {
                        actionFeedback.begin(itemID: item.id, scope: HomeArtworkScope(model: model), action: .favorite(!item.userData.isFavorite))
                        model.toggleFavorite(item)
                        updateActionFeedback()
                    } label: {
                        Label(item.userData.isFavorite ? "取消收藏" : "收藏", systemImage: item.userData.isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-favorite-action")
                    .help(item.userData.isFavorite ? "取消服务器上的收藏" : "收藏到服务器，登录其他客户端时也可查看")
                    .disabled(model.detailLoading || model.userStateBusy || model.userStateNeedsRefresh)
                }
                if model.canSetPlayed(item) {
                    Button {
                        playedChange = PlayedChangeConfirmation(item: item, played: !item.userData.played, connectionID: model.connection?.id)
                    } label: {
                        Label(item.userData.played ? "标记未看" : "标记已看", systemImage: item.userData.played ? "arrow.uturn.backward.circle" : "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("detail-played-action")
                    .help("更新服务器上的观看状态")
                    .disabled(model.detailLoading || model.userStateBusy || model.userStateNeedsRefresh || !model.canEditPlayedState)
                }
                if model.userStateBusy {
                    ProgressView().controlSize(.small)
                    Text("正在同步…").font(.system(size: 11)).foregroundStyle(headerAppearance.secondaryText)
                }
            }
            if let message = actionFeedback.message, model.userStateError == nil {
                Label(message.text, systemImage: "checkmark.circle")
                    .font(.system(size: 11)).foregroundStyle(headerAppearance.accentText)
                    .accessibilityIdentifier("detail-action-success")
            }
            if let message = model.userStateError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(headerAppearance.warningText)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("detail-user-state-error")
            }
            if model.userStateNeedsRefresh {
                HStack(spacing: 10) {
                    Text("需重新确认服务器状态后，才能继续播放或修改。")
                        .font(.system(size: 11)).foregroundStyle(headerAppearance.secondaryText)
                    Button("重新读取状态") { model.refresh() }
                        .buttonStyle(.link)
                        .disabled(model.loading || model.userStateBusy)
                        .accessibilityIdentifier("detail-user-state-refresh")
                }
            }
            if model.canSetPlayed(item) && !model.canEditPlayedState {
                Text("请先关闭此服务器的播放窗口，再修改观看状态。")
                    .font(.system(size: 10)).foregroundStyle(headerAppearance.secondaryText)
            } else if !model.detailLoading && !model.canFavorite(item) && !model.canSetPlayed(item) {
                Text("此服务器暂不支持修改该条目的收藏和观看状态。")
                    .font(.system(size: 10)).foregroundStyle(headerAppearance.secondaryText)
            }
        }
    }

    private func updateActionFeedback() {
        guard isCurrentPresentation else { actionFeedback.invalidate(); return }
        actionFeedback.complete(item: model.detail ?? item, scope: HomeArtworkScope(model: model),
            isBusy: model.userStateBusy, error: model.userStateError, needsRefresh: model.userStateNeedsRefresh)
    }

    private func playedChangeMessage(_ change: PlayedChangeConfirmation) -> String {
        let scope = change.item.type == "Series" ? "整部剧集及其分集" : "《\(change.item.name)》"
        if change.played {
            return "将\(scope)标记为已看，并同步到服务器。将改变观看状态，服务器可能调整续播位置。"
        }
        return "将\(scope)标记为未看，并同步到服务器。该条目的续播位置将被清除。"
    }

    private func play(fromBeginning: Bool) {
        guard !needsVersionChoice else { resourcesExpanded = true; return }
        model.requestPlayback(item, mode: model.connection?.compatibilityMode == true ? .automatic : mode, mediaSourceID: selectedSourceID.isEmpty ? nil : selectedSourceID, fromBeginning: fromBeginning)
    }

    private func updateSourceSelection() {
        versionSelection.update(sourceIDs: item.mediaSources.map(\.id))
        if needsVersionChoice { resourcesExpanded = true }
    }
}
