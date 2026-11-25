import Foundation
import SeatSixCore

/// These collections belong to the selected server's permitted libraries, not
/// the single library whose catalog backs Home and the library browser.
enum ServerBrowseFeed {
    static let maximumItems = 100_000

    static func isPage(_ page: String) -> Bool { BrowseDestination(rawValue: page)?.isServerBrowse == true }

    static func merging(_ completed: [MediaItem], _ next: [MediaItem]) -> [MediaItem] {
        var seen: Set<String> = []
        return (completed + next).filter { seen.insert($0.id).inserted }
    }

    static func recent(_ items: [MediaItem]) -> [MediaItem] {
        HomeLibraryContent.recentlyAdded(from: items, limit: items.count)
    }

    static func missingDateCount(_ items: [MediaItem]) -> Int {
        items.filter { ($0.isPlayable || $0.type == "Series") && $0.dateCreated == nil }.count
    }

    static func compatibilityContinuing(_ items: [MediaItem]) -> [MediaItem] {
        items.filter {
            ($0.isPlayable || $0.type == "Series") && $0.userData.playbackPositionKnown
                && $0.userData.playedKnown && !$0.userData.played && $0.userData.playbackPositionTicks > 0
        }
    }
}
