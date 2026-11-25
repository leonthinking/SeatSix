import XCTest
@testable import SeatSixApp

final class PlaybackTrackLabelTests: XCTestCase {
    func testSubtitleTypeUsesCodecRatherThanIncorrectServerTextFlag() {
        XCTAssertEqual(PlaybackTrackLabel.text(id: 4, kind: .subtitle, title: nil, language: "chi", codec: "hdmv_pgs_subtitle", channels: nil, external: false, forced: false), "中文 · PGS")
        XCTAssertEqual(PlaybackTrackLabel.text(id: 2, kind: .subtitle, title: "验证字幕", language: nil, codec: "subrip", channels: nil, external: true, forced: false), "验证字幕 · SRT · 外挂")
    }

    func testAudioLanguageAndChannelsAndSubtitleFallbackRemainDistinguishable() {
        XCTAssertEqual(PlaybackTrackLabel.text(id: 2, kind: .audio, title: "中文配音", language: "zho", codec: "ac3", channels: 6, external: false, forced: false), "中文配音 · AC-3 · 6 声道")
        XCTAssertEqual(PlaybackTrackLabel.text(id: 3, kind: .subtitle, title: "  ", language: "und", codec: "ass", channels: nil, external: false, forced: true), "字幕 3 · ASS · 强制")
        XCTAssertEqual(PlaybackTrackLabel.text(id: 7, kind: .audio, title: nil, language: "hin", codec: "aac", channels: 6, external: false, forced: false), "印地语 · AAC · 6 声道")
    }
}
