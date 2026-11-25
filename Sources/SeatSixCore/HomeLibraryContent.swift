import Foundation

/// Home sections derive from the unfiltered catalog supplied by the caller.
/// The caller retains its library scope and must disclose an incomplete catalog.
public enum HomeLibraryContent {
    public static func recentlyAdded(from items: [MediaItem], limit: Int = 12) -> [MediaItem] {
        guard limit > 0 else { return [] }
        return Array(items.filter {
            $0.dateCreated != nil && ($0.isPlayable || $0.type == "Series")
        }.sorted { left, right in
            if left.dateCreated != right.dateCreated {
                return left.dateCreated! > right.dateCreated!
            }
            let nameOrder = left.name.compare(right.name, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return left.id < right.id
        }.prefix(limit))
    }
}
