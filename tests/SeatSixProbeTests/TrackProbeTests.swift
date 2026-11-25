import XCTest
@testable import SeatSixProbe

final class TrackProbeTests: XCTestCase {
    @MainActor func testBoundedScanKeepsStableAnchorsWhenResumeChanges() {
        for original in [121.0, 130, 131] {
            let positions = TrackProbe.candidatePositions(original: original, duration: 10_000)
            XCTAssertEqual(positions.first, original)
            XCTAssertTrue(positions.contains(156))
            XCTAssertLessThanOrEqual(positions.count, 15)
            XCTAssertEqual(positions.count, Set(positions).count)
        }
    }
    @MainActor func testShortOrInvalidMediaClampsScanWithoutInvalidSeeks() {
        XCTAssertEqual(TrackProbe.candidatePositions(original: 70, duration: 0), [0])
        let short = TrackProbe.candidatePositions(original: 0, duration: 3)
        XCTAssertTrue(short.allSatisfy { (0...2).contains($0) })
        let invalid = TrackProbe.candidatePositions(original: .nan, duration: .infinity)
        XCTAssertTrue(invalid.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 300 })
    }
}
