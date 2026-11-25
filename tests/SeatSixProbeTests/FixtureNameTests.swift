import XCTest
@testable import SeatSixProbe

final class FixtureNameTests: XCTestCase {
    func testUsesCurrentFixtureAndCanReadExistingVolumes() {
        for suffix in ["Test Movies", "Direct Test", "Compatibility Test"] {
            let old = "Theater " + suffix
            let current = "SeatSix " + suffix
            XCTAssertEqual(preferredFixture([old, current], named: suffix, name: \.self), current)
            XCTAssertEqual(preferredFixture([old], named: suffix, name: \.self), old)
            XCTAssertNil(preferredFixture(["My " + suffix], named: suffix, name: \.self))
        }
    }
}
