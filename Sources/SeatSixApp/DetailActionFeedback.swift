import Foundation
import SeatSixCore

/// Success feedback belongs to an explicitly accepted operation in this detail,
/// never to arbitrary metadata refreshes. Persistent errors remain model-owned.
struct DetailActionFeedback {
    enum Action: Equatable {
        case favorite(Bool)
        case played(Bool)

        fileprivate func isConfirmed(by item: MediaItem) -> Bool {
            switch self {
            case .favorite(let desired): return item.userData.isFavoriteKnown && item.userData.isFavorite == desired
            case .played(let desired): return item.userData.playedKnown && item.userData.played == desired
            }
        }

        fileprivate var confirmationText: String {
            switch self {
            case .favorite(true): return "已加入收藏"
            case .favorite(false): return "已取消收藏"
            case .played(true): return "已标记为已看"
            case .played(false): return "已标记为未看"
            }
        }
    }

    struct Message: Identifiable, Equatable {
        let id: UUID
        let text: String
    }

    private struct Identity: Equatable {
        let itemID: String
        let scope: HomeArtworkScope
    }

    private struct Pending {
        let identity: Identity
        let action: Action
        var observedBusy = false
    }

    static let displayDuration: TimeInterval = 2
    private(set) var message: Message?
    private var messageIdentity: Identity?
    private var pending: Pending?

    mutating func begin(itemID: String, scope: HomeArtworkScope?, action: Action) {
        invalidate()
        guard !itemID.isEmpty, let scope else { return }
        pending = Pending(identity: Identity(itemID: itemID, scope: scope), action: action)
    }

    /// Call immediately after asking the model to start the action, then when
    /// its busy flag changes. If the model rejected the action synchronously,
    /// discard it instead of allowing a later unrelated operation to confirm it.
    @discardableResult
    mutating func complete(item: MediaItem, scope: HomeArtworkScope?, isBusy: Bool,
                           error: String?, needsRefresh: Bool) -> Bool {
        guard let scope else { invalidate(); return false }
        let current = Identity(itemID: item.id, scope: scope)
        if let messageIdentity, messageIdentity != current { invalidate(); return false }
        guard var pending else { return false }
        guard pending.identity == current else { invalidate(); return false }
        if isBusy {
            pending.observedBusy = true
            self.pending = pending
            return false
        }
        self.pending = nil
        guard pending.observedBusy, error == nil, !needsRefresh,
              pending.action.isConfirmed(by: item) else { return false }
        message = Message(id: UUID(), text: pending.action.confirmationText)
        messageIdentity = current
        return true
    }

    /// Old dismiss timers cannot remove a more recent success message.
    @discardableResult
    mutating func dismiss(messageID: UUID) -> Bool {
        guard message?.id == messageID else { return false }
        message = nil; messageIdentity = nil
        return true
    }

    mutating func invalidate() {
        pending = nil; message = nil; messageIdentity = nil
    }
}
