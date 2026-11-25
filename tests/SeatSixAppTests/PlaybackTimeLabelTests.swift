import XCTest
@testable import SeatSixApp

final class PlaybackTimeLabelTests: XCTestCase {
    func testElapsedClockMatchesObservedSourceFramesAcrossSecondBoundaries() {
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(0), "00:00")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(16.0 / 24), "00:01")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(60 + 163.0 / 24), "01:07")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(60 + 167.0 / 24), "01:07")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(67), "01:07")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(60 + 169.0 / 24), "01:08")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(72 + 183.0 / 24), "01:20")
        XCTAssertEqual(PlaybackTimeLabel.elapsedClock(.infinity), "00:00")
        XCTAssertEqual(PlaybackTimeLabel.clock(16.0 / 24), "00:00")
    }

    func testTotalAndRemainingLabelsUseTheSameDuration() {
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 90, duration: 600, display: .total), "10:00")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 90, duration: 600, display: .remaining), "−08:30")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 90, duration: 7_200, display: .remaining), "−1:58:30")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 599.9, duration: 600, display: .remaining), "−00:00")
    }

    func testScrubPreviewUsesPendingPositionAndClampsPastEitherEndpoint() {
        let elapsed = 90.0
        let scrubPosition = 450.0
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: elapsed, duration: 600, display: .remaining), "−08:30")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: scrubPosition, duration: 600, display: .remaining), "−02:30")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: -20, duration: 600, display: .remaining), "−10:00")
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 650, duration: 600, display: .remaining), "−00:00")
    }

    func testUnknownOrMalformedTimestampsNeverProduceInvalidClockText() {
        for invalid in [Double.nan, Double.infinity, -Double.infinity, -5] {
            XCTAssertEqual(PlaybackTimeLabel.clock(invalid), "00:00")
            XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 10, duration: invalid, display: .total), "00:00")
            XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: 10, duration: invalid, display: .remaining), "−00:00")
        }
        XCTAssertEqual(PlaybackTimeLabel.trailing(elapsed: .nan, duration: 600, display: .remaining), "−10:00")
        XCTAssertEqual(PlaybackTimeLabel.clock(1_000_000_000), "00:00")
    }
}
