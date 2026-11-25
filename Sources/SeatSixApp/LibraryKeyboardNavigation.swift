import SwiftUI

struct LibraryKeyboardFocusRequest: Equatable, Identifiable {
    let id: UUID
    let itemID: String
}

/// Keeps keyboard intent attached to media identity while catalog pages arrive
/// and reorder. Only an explicit movement can request focus; data changes may
/// reconcile or discard that intent, but never select a replacement item.
@MainActor
final class LibraryKeyboardNavigation: ObservableObject {
    @Published private(set) var selectedID: String?
    @Published private(set) var focusRequest: LibraryKeyboardFocusRequest?
    private var currentScope: String?

    /// Native focus may move through Tab, pointer input, or detail return.
    /// Adopt that explicit focus without creating a new focus/scroll request.
    func select(itemID: String, ids: [String], scope: String) {
        adoptScope(scope)
        guard ids.contains(itemID) else { return }
        selectedID = itemID
        focusRequest = nil
    }

    /// Positive and negative deltas may represent a column or a row. With no
    /// selected item, forward movement enters at the first result and backward
    /// movement enters at the last. Zero explicitly focuses the current/first
    /// result, useful when moving from the search field into results.
    func move(delta: Int, ids: [String], scope: String) {
        adoptScope(scope)
        guard !ids.isEmpty else {
            focusRequest = nil
            return
        }
        let index: Int
        if let selectedID, let current = ids.firstIndex(of: selectedID) {
            // Clamp before adding: even an extreme delta cannot overflow.
            index = delta >= 0 ? current + min(delta, ids.count - 1 - current)
                               : current + max(delta, -current)
        } else {
            index = delta >= 0 ? 0 : ids.count - 1
        }
        selectedID = ids[index]
        focusRequest = LibraryKeyboardFocusRequest(id: UUID(), itemID: ids[index])
    }

    func reconcile(ids: [String], scope: String, isLoading: Bool) {
        adoptScope(scope)
        guard let selectedID, !ids.contains(selectedID) else { return }
        // A refresh may temporarily remove every visible card. Keep identity
        // until the final snapshot, but never revive a delayed focus request
        // when that card is mounted again.
        focusRequest = nil
        if !isLoading { self.selectedID = nil }
    }

    /// Consume before assigning UI focus. Capturing the request ID in a lazy
    /// card's task prevents a stale mount from consuming a newer user action.
    func takeFocusRequest(itemID: String, id: UUID) -> Bool {
        guard let request = focusRequest, request.itemID == itemID, request.id == id else { return false }
        focusRequest = nil
        return true
    }

    /// Leaving the results or opening detail cancels an undelivered focus
    /// request, while the stable ID remains available for deliberate return.
    func invalidatePendingFocus() { focusRequest = nil }

    func invalidate() {
        currentScope = nil
        selectedID = nil
        focusRequest = nil
    }

    private func adoptScope(_ scope: String) {
        guard currentScope != scope else { return }
        currentScope = scope
        selectedID = nil
        focusRequest = nil
    }
}
