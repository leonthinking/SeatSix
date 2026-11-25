import XCTest
import SeatSixCore
@testable import SeatSixApp

final class PlaybackEpisodeSkipSettingsTests: XCTestCase {
    func testAcceptsWholeSecondsIncludingDisabledAndMaximumValues() {
        for (input, expected) in [("0", 0), ("90", 90), ("1800", 1800), (" 120\n", 120), ("0015", 15)] {
            XCTAssertEqual(EpisodeSkipSettingsPresentation.seconds(from: input), expected, input)
        }
    }

    func testRejectsBlankNegativeFractionalAndNonNumericInput() {
        for input in ["", " \n", "-1", "-0", "+1", "1.5", "90.0", "1e2", "1 20", "90秒", "１２", "NaN", "inf"] {
            XCTAssertNil(EpisodeSkipSettingsPresentation.seconds(from: input), input)
        }
    }

    func testRejectsValuesBeyondLimitAndIntegerOverflowWithoutClamping() {
        for input in ["1801", "999999", String(Int.max), String(repeating: "9", count: 100)] {
            XCTAssertNil(EpisodeSkipSettingsPresentation.seconds(from: input), input)
        }
    }

    func testEitherInvalidFieldPreventsCreatingSettings() {
        XCTAssertNil(EpisodeSkipSettingsPresentation.settings(intro: "90", outro: "-5"))
        XCTAssertNil(EpisodeSkipSettingsPresentation.settings(intro: "90.5", outro: "60"))
        XCTAssertEqual(EpisodeSkipSettingsPresentation.settings(intro: "90", outro: "60"),
                       SeriesSkipSettings(introSeconds: 90, outroSeconds: 60))
        XCTAssertEqual(EpisodeSkipSettingsPresentation.settings(intro: "0", outro: "0"), SeriesSkipSettings())
    }

    func testSummaryDistinguishesDisabledAndEnabledDurations() {
        XCTAssertEqual(EpisodeSkipSettingsPresentation.summary(SeriesSkipSettings()), "片头关闭 · 片尾关闭")
        XCTAssertEqual(EpisodeSkipSettingsPresentation.summary(SeriesSkipSettings(introSeconds: 90, outroSeconds: 60)),
                       "片头 90 秒 · 片尾 60 秒")
        XCTAssertEqual(EpisodeSkipSettingsPresentation.summary(SeriesSkipSettings(introSeconds: 0, outroSeconds: 30)),
                       "片头关闭 · 片尾 30 秒")
    }
}
