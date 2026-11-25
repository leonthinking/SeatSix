import Foundation

public enum MediaUserStateAction: Codable, Equatable, Sendable {
    case favorite(Bool)
    case played(Bool)

    var enabled: Bool {
        switch self {
        case .favorite(let value), .played(let value): return value
        }
    }

    var resource: String {
        switch self {
        case .favorite: return "FavoriteItems"
        case .played: return "PlayedItems"
        }
    }

    func isConfirmed(by data: MediaUserData) -> Bool {
        switch self {
        case .favorite(let value): return data.isFavoriteKnown && data.isFavorite == value
        case .played(let value): return data.playedKnown && data.played == value
        }
    }
}

public enum MediaUserStateError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedAction
    case outcomeUncertain

    public var errorDescription: String? {
        switch self {
        case .unsupportedAction: return "此服务器暂不支持修改该条目的收藏或已看状态。"
        case .outcomeUncertain: return "暂时无法确认服务器是否已保存。请刷新状态后再操作，避免重复提交。"
        }
    }
}

public enum MediaUserStateCapabilities {
    public static func canFavorite(item: MediaItem, connection: ServerConnection) -> Bool {
        supports(item: item, connection: connection)
    }

    public static func canSetPlayed(item: MediaItem, connection: ServerConnection) -> Bool {
        supports(item: item, connection: connection)
    }

    private static func supports(item: MediaItem, connection: ServerConnection) -> Bool {
        guard !item.id.isEmpty, item.id.utf8.count <= 512,
              item.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return false }
        if connection.compatibilityMode {
            // The compatible NAS contract only promises top-level numeric IDs.
            // Never substitute an Episode's SeriesId: that would modify the whole series.
            return ["Movie", "Series"].contains(item.type) && item.id.utf8.allSatisfy { (48...57).contains($0) }
        }
        return ["Movie", "Series", "Episode", "Video"].contains(item.type)
    }
}
