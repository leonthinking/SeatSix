import SeatSixCore

/// Conservative resolution for a series-level Continue Watching tile. A deterministic
/// first episode is useful in a detail page but is not always a safe one-click resume.
enum BrowseResumeSelection {
    static func target(in sequence: EpisodeSequence, rawEpisodes: [MediaItem]) -> MediaItem? {
        let progressing = sequence.orderedEpisodes.filter { !$0.userData.played && $0.userData.playbackPositionTicks > 0 }
        let candidate: MediaItem?
        if progressing.count == 1 {
            candidate = progressing.first
        } else if progressing.isEmpty, let next = sequence.resumeCandidate,
                  next.userData.playedKnown, !next.userData.played {
            candidate = next
        } else {
            candidate = nil
        }
        guard let candidate, candidate.userData.playedKnown, candidate.userData.playbackPositionKnown,
              candidate.userData.playbackPositionTicks >= 0,
              rawEpisodes.filter({ $0.id == candidate.id }).count == 1 else { return nil }
        return candidate
    }
}
