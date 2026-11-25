import Foundation
import SeatSixCore

/// Uses actual episode IDs returned by the series endpoint. Public evidence is
/// limited to numbered cases and decoder/progress measurements.
@MainActor
enum SeriesPlaybackProbe {
    static func selectedPair(series: MediaItem, seasons: [MediaItem], episodes: [MediaItem]) throws -> [MediaItem] {
        guard series.type == "Series" else { throw ProbeFailure(message: "请选择剧集条目") }
        let sequence = EpisodeSequence(seriesID: series.id, episodes: episodes, seasons: seasons)
        let regularIDs = Set(seasons.filter { ($0.indexNumber ?? 0) > 0 }
            .flatMap { sequence.episodes(in: $0.id).map(\.id) })
        guard let first = sequence.orderedEpisodes.first(where: { ($0.parentIndexNumber ?? 0) > 0 || regularIDs.contains($0.id) }),
              let second = sequence.next(after: first.id), first.id != second.id else {
            throw ProbeFailure(message: "剧集需要至少两集且顺序明确才能验证独立进度")
        }
        return [first, second]
    }

    static func verify(client: MediaServerClient, series: MediaItem) async throws -> [String: Any] {
        guard series.type == "Series" else { throw ProbeFailure(message: "请选择剧集条目") }
        let seasons = try await client.seasons(seriesID: series.id)
        let episodes = try await client.episodes(seriesID: series.id)
        let selected = try selectedPair(series: series, seasons: seasons, episodes: episodes)
        let selectedSeasonID = selected[0].seasonID ?? selected[0].parentID
        var filteredPassed = false
        if let selectedSeasonID, seasons.contains(where: { $0.id == selectedSeasonID }) {
            let filtered = try await client.episodes(seriesID: series.id, seasonID: selectedSeasonID)
            filteredPassed = filtered.contains(where: { $0.id == selected[0].id })
                && filtered.allSatisfy { $0.seasonID == nil || $0.seasonID == selectedSeasonID }
        }
        guard filteredPassed else { throw ProbeFailure(message: "分季查询未返回预期单集") }
        var cases: [[String: Any]] = []
        var firstFinalTicks: Int64?
        for (index, candidate) in selected.enumerated() {
            let full = try await client.item(id: candidate.id)
            guard full.type == "Episode", full.id == candidate.id,
                  full.seriesID == nil || full.seriesID == series.id else {
                throw ProbeFailure(message: "单集详情的身份与剧集列表不一致")
            }
            var result = try await LocalDecoderProbe.verify(client: client, item: full)
            result["case"] = index + 1
            result["seasonNumber"] = candidate.parentIndexNumber
            result["episodeNumber"] = candidate.indexNumber
            cases.append(result)
            if index == 0 { firstFinalTicks = try await client.item(id: full.id).userData.playbackPositionTicks }
        }
        let finalFirst = try await client.item(id: selected[0].id)
        guard finalFirst.userData.playbackPositionTicks == firstFinalTicks else {
            throw ProbeFailure(message: "第二集播放影响了第一集保存的进度")
        }
        return ["seasonCount": seasons.count, "episodeCount": episodes.count,
                "seasonFilterPassed": filteredPassed, "independentProgressPassed": true,
                "episodeCases": cases, "nativeAutoplayVerified": false,
                "passed": true]
    }
}
