import SwiftUI

/// Retain visible geometry without retaining media or invalidating the window
/// for each scroll event. Freeze it while the toolbar request is outstanding.
private final class RefreshViewport {
    var regions: [ShelfRefreshRegion] = []
    var size = CGSize.zero
    var route = ""

    func hasSnapshot(size: CGSize, route: String) -> Bool {
        self.size == size && self.route == route && !regions.isEmpty
    }

    func record(_ regions: [ShelfRefreshRegion], size: CGSize, route: String) {
        self.regions = regions
        self.size = size
        self.route = route
    }
}

struct ToolbarRefreshCover: ViewModifier {
    @ObservedObject var model: ApplicationModel
    let usesWindowPalette: Bool
    @State private var viewport = RefreshViewport()

    private var route: String {
        let search = BrowseDestination(rawValue: model.page)?.isSearch == true ? model.searchTerm : ""
        return String(reflecting: [model.connection?.id.uuidString ?? "", model.selectedLibraryID,
                                   model.page, model.detail?.id ?? "", search])
    }

    func body(content: Content) -> some View {
        let showsDetail = model.detail != nil && model.page != "servers"
        let revealsWindowPalette = usesWindowPalette && !showsDetail
        GeometryReader { geometry in
            content
                .shelfRefreshViewport(geometry.size)
                .onPreferenceChange(ShelfRefreshRegionsKey.self) { regions in
                    guard !model.isToolbarRefreshing || !viewport.hasSnapshot(size: geometry.size, route: route) else { return }
                    viewport.record(regions, size: geometry.size, route: route)
                }
                .disabled(model.isToolbarRefreshing)
                .allowsHitTesting(!model.isToolbarRefreshing)
                .accessibilityHidden(model.isToolbarRefreshing)
                // Let the existing window background show through the skeleton
                // at its original coordinates while the scroll views stay mounted.
                .opacity(model.isToolbarRefreshing && revealsWindowPalette ? 0 : 1)
                .overlayPreferenceValue(ShelfRefreshRegionsKey.self) { currentRegions in
                    ZStack {
                        if model.isToolbarRefreshing {
                            // A first-frame refresh or a window resize can precede
                            // caching. Draw this layout's actual cards and sections.
                            ShelfRefreshSnapshot(regions: viewport.hasSnapshot(size: geometry.size, route: route)
                                ? viewport.regions : currentRegions,
                                keepsDetailBackground: showsDetail, revealsWindowPalette: revealsWindowPalette)
                                .overlay {
                                    Color.clear.accessibilityElement(children: .ignore)
                                        .accessibilityLabel("正在刷新媒体库")
                                        .accessibilityIdentifier("toolbar-refresh-status")
                                }
                                .contentShape(Rectangle())
                                .background(SeatSixSidebarGeometry(id: "toolbar-refresh-skeleton"))
                                .transition(.identity)
                        }
                    }
                    .onChange(of: model.isToolbarRefreshing) { _, refreshing in
                        if !refreshing { viewport.record(currentRegions, size: geometry.size, route: route) }
                    }
                }
        }
    }
}
