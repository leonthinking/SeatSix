import Foundation

/// Recommendations come from a completed, unfiltered library snapshot. The caller
/// owns the source scope and keeps the chosen order until the next catalog load.
public enum HomeRecommendationSelection {
    public static func select(from items: [MediaItem], retainingIDs: [String] = [], limit: Int = 10) -> [MediaItem] {
        var generator = SystemRandomNumberGenerator()
        return select(from: items, retainingIDs: retainingIDs, limit: limit, using: &generator)
    }

    public static func select<R: RandomNumberGenerator>(from items: [MediaItem], retainingIDs: [String] = [], limit: Int = 10,
                                                        using generator: inout R) -> [MediaItem] {
        let count = min(10, max(0, limit))
        guard count > 0 else { return [] }
        var seen: Set<String> = []
        let eligible = items.filter {
            ["Movie", "Series", "Video"].contains($0.type)
                && !$0.landscapeArtworkSources.isEmpty
                && seen.insert($0.id).inserted
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        var retainedIDs: Set<String> = []
        let retained = Array(retainingIDs.compactMap { id -> MediaItem? in
            guard retainedIDs.insert(id).inserted else { return nil }
            return byID[id]
        }.prefix(count))
        let remaining = eligible.filter { !retainedIDs.contains($0.id) }
        return retained + Array(remaining.shuffled(using: &generator).prefix(count - retained.count))
    }
}
