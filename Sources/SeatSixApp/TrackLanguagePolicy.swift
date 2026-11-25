import Foundation
import SeatSixCore
import SeatSixPlayback

/// Use declared language metadata only. Titles are not reliable evidence for
/// original audio, bilingual captions, or simplified/traditional writing systems.
enum TrackLanguagePolicy {
    enum SubtitleChoice: Equatable {
        case embedded(Int)
        case server(ServerSubtitle)
    }

    static func matches(_ metadata: String?, preferred: MediaLanguage) -> Bool {
        guard let metadata else { return false }
        let code = metadata.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        let primary = code.split(separator: "-").first.map(String.init) ?? ""
        switch preferred {
        case .chinese: return ["zh", "zho", "chi", "cmn"].contains(primary) && !code.hasPrefix("zh-yue")
        case .english: return ["en", "eng"].contains(primary)
        case .japanese: return ["ja", "jpn"].contains(primary)
        case .korean: return ["ko", "kor"].contains(primary)
        case .french: return ["fr", "fra", "fre"].contains(primary)
        case .german: return ["de", "deu", "ger"].contains(primary)
        case .spanish: return ["es", "spa"].contains(primary)
        case .cantonese: return primary == "yue" || code == "zh-yue" || code.hasPrefix("zh-yue-")
        }
    }

    static func audioTrackID(in tracks: [LocalPlaybackTrack], preferred: MediaLanguage) -> Int? {
        let matches = tracks.filter { $0.kind == .audio && self.matches($0.language, preferred: preferred) }
        return (matches.first(where: \.isDefault) ?? matches.first)?.id
    }

    static func subtitle(in tracks: [LocalPlaybackTrack], serverSubtitles: [ServerSubtitle], preferred: MediaLanguage) -> SubtitleChoice? {
        struct Candidate {
            let choice: SubtitleChoice
            let forced: Bool
            let isDefault: Bool
        }
        let local = tracks.filter { $0.kind == .subtitle && matches($0.language, preferred: preferred) }
            .map { Candidate(choice: .embedded($0.id), forced: $0.isForced, isDefault: $0.isDefault) }
        let remote = serverSubtitles.filter { matches($0.language, preferred: preferred) }
            .map { Candidate(choice: .server($0), forced: $0.isForced, isDefault: $0.isDefault) }
        // Full captions precede forced-only dialogue, including across embedded
        // and server choices. Equal candidates retain their original order.
        return (local + remote).enumerated().min {
            let lhs = ($0.element.forced ? 1 : 0, $0.element.isDefault ? 0 : 1, $0.offset)
            let rhs = ($1.element.forced ? 1 : 0, $1.element.isDefault ? 0 : 1, $1.offset)
            return lhs < rhs
        }?.element.choice
    }
}
