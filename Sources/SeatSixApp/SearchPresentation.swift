import Foundation
import SeatSixCore

enum SearchPresentation {
    struct Group {
        let title: String
        let items: [MediaItem]
    }

    static func results(_ items: [MediaItem], query: String, offset: Int) -> [MediaItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            return items.filter { $0.name.localizedStandardContains(term) || $0.seriesName?.localizedStandardContains(term) == true }
        }
        guard !items.isEmpty else { return [] }
        let start = max(0, offset) % items.count
        return (0..<min(items.count, 24)).map { items[(start + $0) % items.count] }
    }

    static func groups(_ items: [MediaItem]) -> [Group] {
        let byType = Dictionary(grouping: items) { item in
            switch item.type {
            case "Movie": return "电影"
            case "Series": return "电视剧"
            case "Episode": return "分集"
            default: return "其他"
            }
        }
        return ["电影", "电视剧", "分集", "其他"].compactMap { title in
            byType[title].map { Group(title: title, items: $0) }
        }
    }
}
