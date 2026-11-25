import Foundation

/// A catalog contains every accepted page, but is complete only after the server's
/// explicit total has been reached without gaps, duplicate IDs, or changed totals.
public struct LibraryCatalogSnapshot: Sendable, Equatable {
    public let items: [MediaItem]
    public let total: Int
    public let isComplete: Bool

    public init(items: [MediaItem], total: Int, isComplete: Bool) {
        self.items = items; self.total = total; self.isComplete = isComplete
    }
}

public enum LibraryCatalogError: Error, LocalizedError, Equatable, Sendable {
    case invalidPage
    case changedDuringLoading
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidPage:
            return "服务器未返回完整、连续的媒体库目录。当前搜索和筛选结果可能不完整，请重新载入媒体库。"
        case .changedDuringLoading:
            return "媒体库在读取期间发生了变化，当前结果可能不完整。请重新载入媒体库。"
        case .tooLarge:
            return "媒体库超过当前支持的 100,000 项，无法确认完整搜索结果。请选择更小的媒体库。"
        }
    }
}

public enum LibraryWatchFilter: String, CaseIterable, Identifiable, Sendable {
    case all, unwatched, watched
    public var id: String { rawValue }
}

public enum LibrarySortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case nameAscending, nameDescending, yearDescending, yearAscending
    public var id: String { rawValue }
}

/// All filters operate on the catalog supplied by the caller, independently of
/// server-side search/filter support and independently of visible grid pagination.
public struct LibraryQuery: Equatable, Sendable {
    public var text: String
    public var year: Int?
    public var genre: String?
    public var watched: LibraryWatchFilter
    public var sort: LibrarySortOrder
    public var favoritesOnly: Bool

    public init(text: String = "", year: Int? = nil, genre: String? = nil, watched: LibraryWatchFilter = .all, sort: LibrarySortOrder = .nameAscending, favoritesOnly: Bool = false) {
        self.text = text; self.year = year; self.genre = genre; self.watched = watched; self.sort = sort
        self.favoritesOnly = favoritesOnly
    }

    public func apply(to items: [MediaItem]) -> [MediaItem] {
        let terms = LibraryCatalogText.normalized(text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let wantedGenre = genre.map(LibraryCatalogText.normalized).flatMap { $0.isEmpty ? nil : $0 }
        return items.filter { item in
            if favoritesOnly && !item.userData.isFavorite { return false }
            if let year, item.productionYear != year { return false }
            if let wantedGenre, !item.genres.contains(where: { LibraryCatalogText.normalized($0) == wantedGenre }) { return false }
            // Match the app's existing MediaUserData decoding: missing Played is false.
            if watched == .watched && !item.userData.played { return false }
            if watched == .unwatched && item.userData.played { return false }
            if !terms.isEmpty {
                let name = LibraryCatalogText.normalized(item.name)
                if !terms.allSatisfy({ name.contains($0) }) { return false }
            }
            return true
        }.sorted { left, right in
            if sort == .yearAscending || sort == .yearDescending {
                if left.productionYear != right.productionYear {
                    // Unknown years remain at the end in both directions.
                    guard let leftYear = left.productionYear else { return false }
                    guard let rightYear = right.productionYear else { return true }
                    return sort == .yearAscending ? leftYear < rightYear : leftYear > rightYear
                }
            }
            let order = LibraryCatalogText.compare(left.name, right.name)
            if order == .orderedSame { return left.id < right.id }
            return sort == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}

public struct LibraryCatalogFacets: Equatable, Sendable {
    public let years: [Int]
    public let genres: [String]

    public init(items: [MediaItem]) {
        years = Set(items.compactMap(\.productionYear)).sorted(by: >)
        var labels: [String: String] = [:]
        for label in items.flatMap(\.genres) {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = LibraryCatalogText.normalized(trimmed)
            guard !key.isEmpty else { continue }
            // Pick the same spelling regardless of server page order.
            labels[key] = labels[key].map { min($0, trimmed) } ?? trimmed
        }
        genres = labels.values.sorted {
            let order = LibraryCatalogText.compare($0, $1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }
}

private enum LibraryCatalogText {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func compare(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric], locale: Locale(identifier: "zh_Hans_CN"))
    }
}
