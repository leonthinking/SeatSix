import Foundation

/// Navigation over one complete Shows/{id}/Episodes response, never over a library page.
/// Missing or conflicting metadata remains browsable but cannot produce a trusted adjacent episode.
public struct EpisodeSequence: Sendable {
    private struct Coordinate: Equatable, Sendable {
        var season: Int
        var episode: Int
        var end: Int
    }
    public let seriesID: String
    public let orderedEpisodes: [MediaItem]
    /// Season picker entries: unique actual IDs, ordered by valid season number.
    public let displaySeasons: [MediaItem]
    // Keep the original metadata so display deduplication cannot hide ambiguous season mappings.
    private let seasons: [MediaItem]
    private let coordinates: [String: Coordinate]
    private let duplicateIDs: Set<String>

    public init(seriesID: String, episodes: [MediaItem], seasons: [MediaItem] = []) {
        self.seriesID = seriesID
        self.seasons = seasons.filter { $0.type == "Season" && ($0.seriesID == nil || $0.seriesID == seriesID) && ($0.parentID == nil || $0.parentID == seriesID) }
        var seenSeasonIDs: Set<String> = []
        self.displaySeasons = self.seasons.filter { seenSeasonIDs.insert($0.id).inserted }.enumerated().sorted { lhs, rhs in
            let left = lhs.element.indexNumber.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            let right = rhs.element.indexNumber.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        var indexesBySeasonID: [String: Set<Int>] = [:]
        for season in self.seasons {
            if let index = season.indexNumber, index >= 0 { indexesBySeasonID[season.id, default: []].insert(index) }
        }
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        var unique: [MediaItem] = []
        var resolved: [String: Coordinate] = [:]
        var displaySeasons: [String: Int] = [:]
        for item in episodes where item.type == "Episode" && (item.seriesID == nil || item.seriesID == seriesID) {
            guard seen.insert(item.id).inserted else { duplicates.insert(item.id); continue }
            unique.append(item)
            if let index = item.parentIndexNumber, index < 0 { continue }
            var seasonIndexes: Set<Int> = []
            if let index = item.parentIndexNumber, index >= 0 { seasonIndexes.insert(index) }
            for id in [item.seasonID, item.parentID].compactMap({ $0 }) {
                if let indexes = indexesBySeasonID[id] { seasonIndexes.formUnion(indexes) }
            }
            guard seasonIndexes.count == 1, let season = seasonIndexes.first else { continue }
            // Two different explicit parent IDs cannot safely identify the same season.
            if let seasonID = item.seasonID, let parentID = item.parentID, seasonID != parentID { continue }
            displaySeasons[item.id] = season
            guard let episode = item.indexNumber, episode >= 0,
                  (item.indexNumberEnd ?? episode) >= episode else { continue }
            resolved[item.id] = Coordinate(season: season, episode: episode, end: item.indexNumberEnd ?? episode)
        }
        self.coordinates = resolved
        self.duplicateIDs = duplicates
        self.orderedEpisodes = unique.enumerated().sorted { lhs, rhs in
            let left = resolved[lhs.element.id], right = resolved[rhs.element.id]
            let leftSeason = displaySeasons[lhs.element.id] ?? Int.max, rightSeason = displaySeasons[rhs.element.id] ?? Int.max
            if leftSeason != rightSeason { return leftSeason < rightSeason }
            let leftEpisode = left?.episode ?? Int.max, rightEpisode = right?.episode ?? Int.max
            if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    public func episodes(in seasonID: String) -> [MediaItem] {
        let matchingSeasons = seasons.filter { $0.id == seasonID }
        let index = matchingSeasons.count == 1 ? matchingSeasons.first?.indexNumber : nil
        let uniqueIndex = index.map { number in seasons.filter { $0.indexNumber == number }.count == 1 } ?? false
        return orderedEpisodes.filter { item in
            if let explicit = item.seasonID { return explicit == seasonID }
            if let explicit = item.parentID { return explicit == seasonID }
            return uniqueIndex && item.parentIndexNumber == index
        }
    }

    /// First unfinished regular episode with progress, then first unplayed, then first regular episode.
    /// This is deterministic selection; it does not claim to know the last episode viewed elsewhere.
    public var resumeCandidate: MediaItem? {
        let regular = orderedEpisodes.filter { (coordinates[$0.id]?.season ?? 0) > 0 }
        return regular.first { !$0.userData.played && $0.userData.playbackPositionTicks > 0 }
            ?? regular.first { !$0.userData.played }
            ?? regular.first
    }

    public func next(after episodeID: String) -> MediaItem? {
        adjacent(to: episodeID, offset: 1)
    }

    public func previous(before episodeID: String) -> MediaItem? {
        adjacent(to: episodeID, offset: -1)
    }

    private func adjacent(to episodeID: String, offset: Int) -> MediaItem? {
        guard coordinates.count == orderedEpisodes.count,
              let index = orderedEpisodes.firstIndex(where: { $0.id == episodeID }),
              orderedEpisodes.indices.contains(index + offset),
              let current = coordinates[episodeID], !duplicateIDs.contains(episodeID) else { return nil }
        let candidate = orderedEpisodes[index + offset]
        guard let adjacent = coordinates[candidate.id], !duplicateIDs.contains(candidate.id),
              (current.season == 0) == (adjacent.season == 0),
              !hasOverlappingIndex(episodeID), !hasOverlappingIndex(candidate.id) else { return nil }
        return candidate
    }

    private func hasOverlappingIndex(_ id: String) -> Bool {
        guard let coordinate = coordinates[id] else { return true }
        return coordinates.contains { otherID, other in
            otherID != id && other.season == coordinate.season
                && other.episode <= coordinate.end && coordinate.episode <= other.end
        }
    }
}
