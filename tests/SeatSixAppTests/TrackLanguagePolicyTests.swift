import XCTest
@testable import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

final class TrackLanguagePolicyTests: XCTestCase {
    func testLanguageMetadataAliasesAndRegionsWithoutTitleGuessing() {
        for code in ["zh", "zho", "chi", "cmn", "zh-CN", "zh_TW", " ZHO "] {
            XCTAssertTrue(TrackLanguagePolicy.matches(code, preferred: .chinese), code)
        }
        for code in ["eng", "en-US", "en"] { XCTAssertTrue(TrackLanguagePolicy.matches(code, preferred: .english)) }
        for code in ["fra", "fre", "fr-CA"] { XCTAssertTrue(TrackLanguagePolicy.matches(code, preferred: .french)) }
        for code in ["deu", "ger", "de"] { XCTAssertTrue(TrackLanguagePolicy.matches(code, preferred: .german)) }
        for (code, language): (String, MediaLanguage) in [("jpn", .japanese), ("ja-JP", .japanese), ("kor", .korean), ("ko", .korean), ("spa", .spanish), ("es", .spanish), ("yue", .cantonese), ("zh-yue", .cantonese)] {
            XCTAssertTrue(TrackLanguagePolicy.matches(code, preferred: language))
        }
        for code in [nil, "", "und", "English", "en", "yue", "zh-yue-HK"] {
            XCTAssertFalse(TrackLanguagePolicy.matches(code, preferred: .chinese))
        }
        XCTAssertFalse(TrackLanguagePolicy.matches("zh-HK", preferred: .cantonese), "Region alone does not establish spoken Cantonese")
        let unknown = LocalPlaybackTrack(id: 1, kind: .audio, title: "Chinese original", language: nil)
        XCTAssertNil(TrackLanguagePolicy.audioTrackID(in: [unknown], preferred: .chinese))
    }

    func testAudioUsesMatchingDefaultAndStableOrder() {
        let tracks = [LocalPlaybackTrack(id: 1, kind: .audio, language: "eng", isDefault: true),
                      LocalPlaybackTrack(id: 2, kind: .audio, language: "chi"),
                      LocalPlaybackTrack(id: 3, kind: .audio, language: "zho", isDefault: true),
                      LocalPlaybackTrack(id: 4, kind: .subtitle, language: "jpn", isDefault: true)]
        XCTAssertEqual(TrackLanguagePolicy.audioTrackID(in: tracks, preferred: .chinese), 3)
        XCTAssertEqual(TrackLanguagePolicy.audioTrackID(in: Array(tracks.prefix(2)), preferred: .chinese), 2)
        XCTAssertNil(TrackLanguagePolicy.audioTrackID(in: tracks, preferred: .japanese))
    }

    func testFullCaptionsPrecedeForcedAcrossEmbeddedAndServerTracks() {
        let forced = LocalPlaybackTrack(id: 1, kind: .subtitle, language: "zh", isDefault: true, isForced: true)
        let full = LocalPlaybackTrack(id: 2, kind: .subtitle, language: "chi")
        let other = LocalPlaybackTrack(id: 3, kind: .subtitle, language: "eng", isDefault: true)
        let server = ServerSubtitle(itemID: "i", mediaSourceID: "m", streamIndex: 9, title: "Chinese", language: "zho",
            isDefault: false, isForced: false, fileExtension: "srt", connectionID: UUID(), serverID: "s", userID: "u",
            requestURL: URL(string: "https://example.test/subtitle")!)
        XCTAssertEqual(TrackLanguagePolicy.subtitle(in: [forced, full, other], serverSubtitles: [], preferred: .chinese), .embedded(2))
        XCTAssertEqual(TrackLanguagePolicy.subtitle(in: [forced, other], serverSubtitles: [server], preferred: .chinese), .server(server))
        XCTAssertEqual(TrackLanguagePolicy.subtitle(in: [forced], serverSubtitles: [], preferred: .chinese), .embedded(1))
        XCTAssertNil(TrackLanguagePolicy.subtitle(in: [forced, full], serverSubtitles: [server], preferred: .korean))
    }
}
