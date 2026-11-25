import SwiftUI

/// An explicit user request, never a consequence of catalog progress. The
/// artwork scope already carries connection, account, library and revocation
/// identity, so a delayed focus request cannot cross those boundaries.
struct LibrarySearchRequest: Equatable, Identifiable {
    let id: UUID
    let scope: HomeArtworkScope
}

@MainActor
final class SeatSixNavigation: ObservableObject {
    @Published private(set) var searchRequest: LibrarySearchRequest?

    func canSearch(model: ApplicationModel) -> Bool {
        guard model.canBrowseCurrentMedia, let connection = model.connection,
              !model.selectedLibraryID.isEmpty,
              connection.libraryIDs.contains(model.selectedLibraryID),
              model.selectedLibrary != nil else { return false }
        return !model.showLogin && model.recoveryPrompt == nil && !model.launchingPlayback
    }

    /// All search entrances share this action. Searching does not refresh the
    /// catalog, clear filters, or change the selected server/library.
    @discardableResult
    func requestSearch(model: ApplicationModel) -> Bool {
        guard canSearch(model: model), let scope = HomeArtworkScope(model: model) else {
            invalidate()
            return false
        }
        if BrowseDestination(rawValue: model.page)?.isSearch != true {
            let initialTerm = model.page == "library" && model.detail == nil ? model.query : ""
            model.navigate(to: BrowseDestination.searchLibrary.rawValue)
            model.searchTerm = initialTerm
        } else if model.detail != nil {
            model.navigate(to: model.page)
        }
        searchRequest = LibrarySearchRequest(id: UUID(), scope: scope)
        return true
    }

    /// Call only once the visible search field has mounted. A caller that
    /// schedules this asynchronously can pass its captured ID; an older task
    /// must not consume a newer explicit request.
    func consumeSearchRequest(model: ApplicationModel, requestID: UUID? = nil) -> Bool {
        guard let request = searchRequest,
              requestID == nil || requestID == request.id else { return false }
        searchRequest = nil
        return canSearch(model: model) && BrowseDestination(rawValue: model.page)?.isSearch == true && model.detail == nil
            && HomeArtworkScope(model: model) == request.scope
    }

    /// Explicit navigation away should discard pending focus immediately,
    /// including a rapid away-and-back before the next SwiftUI update.
    func invalidate() { searchRequest = nil }
}

/// A main-window scene supplies these actions. Settings, login and playback
/// must not navigate an unrelated background browser through global shortcuts.
struct SeatSixNavigationActions {
    let canRefresh: Bool
    let refresh: @MainActor () -> Void
    let canSearch: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let canToggleSidebar: Bool
    let sidebarVisible: Bool
    let search: @MainActor () -> Void
    let goBack: @MainActor () -> Void
    let goForward: @MainActor () -> Void
    let toggleSidebar: @MainActor () -> Void
}

private struct SeatSixNavigationActionsKey: FocusedValueKey {
    typealias Value = SeatSixNavigationActions
}

extension FocusedValues {
    var seatSixNavigationActions: SeatSixNavigationActions? {
        get { self[SeatSixNavigationActionsKey.self] }
        set { self[SeatSixNavigationActionsKey.self] = newValue }
    }
}

@MainActor
struct SeatSixNavigationCommands: Commands {
    @FocusedValue(\.seatSixNavigationActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("刷新媒体库") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.canRefresh != true)
        }
        CommandMenu("导航") {
            Button("搜索当前媒体库") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions?.canSearch != true)
            Button("返回") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.canGoBack != true)
            Button("前进") { actions?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(actions?.canGoForward != true)
            Divider()
            Button(actions?.sidebarVisible == false ? "显示侧栏" : "隐藏侧栏") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(actions?.canToggleSidebar != true)
        }
    }
}
