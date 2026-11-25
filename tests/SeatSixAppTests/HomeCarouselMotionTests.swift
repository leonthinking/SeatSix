import XCTest
@testable import SeatSixApp

final class HomeCarouselMotionTests: XCTestCase {
    func testForwardAndBackwardSlidesKeepBothSurfacesTogether() {
        for direction in [-1, 1] {
            var motion = HomeCarouselMotion()
            motion.reset(to: "old")
            XCTAssertTrue(motion.request(id: "new", direction: direction, animated: true))
            let token = motion.generation
            XCTAssertEqual(motion.offset(for: "old"), 0)
            XCTAssertEqual(motion.offset(for: "new"), Double(direction))
            motion.setProgress(0.5, generation: token)
            XCTAssertEqual(motion.offset(for: "old"), -Double(direction) * 0.5)
            XCTAssertEqual(motion.offset(for: "new"), Double(direction) * 0.5)
            XCTAssertTrue(motion.isVisible("old"))
            XCTAssertFalse(motion.isInteractive("old"))
            XCTAssertTrue(motion.isInteractive("new"))
            XCTAssertFalse(motion.isVisible("neighbor"))
            motion.setProgress(1, generation: token)
            XCTAssertEqual(motion.offset(for: "old"), -Double(direction))
            XCTAssertEqual(motion.offset(for: "new"), 0)
            XCTAssertFalse(motion.finish(generation: token))
            XCTAssertFalse(motion.isTransitioning)
            XCTAssertNil(motion.outgoingID)
            XCTAssertEqual(motion.currentID, "new")
        }
    }

    func testWraparoundUsesInputDirectionInsteadOfArrayIndexOrder() {
        var motion = HomeCarouselMotion()
        motion.reset(to: "last")
        XCTAssertTrue(motion.request(id: "first", direction: 1, animated: true))
        XCTAssertEqual(motion.offset(for: "first"), 1)
        let forward = motion.generation
        motion.setProgress(1, generation: forward)
        motion.finish(generation: forward)
        XCTAssertTrue(motion.request(id: "last", direction: -1, animated: true))
        XCTAssertEqual(motion.offset(for: "last"), -1)
    }

    func testRapidRequestsCoalesceAndDoNotChangeVisibleActionsEarly() {
        var motion = HomeCarouselMotion()
        motion.reset(to: "one")
        motion.request(id: "two", direction: 1, animated: true)
        let selectedTwo = motion.selectionID
        XCTAssertNotNil(selectedTwo)
        let first = motion.generation
        motion.setProgress(0.4, generation: first)
        XCTAssertFalse(motion.request(id: "three", direction: 1, animated: true))
        XCTAssertFalse(motion.request(id: "four", direction: 1, animated: true))
        XCTAssertEqual(motion.currentID, "two")
        XCTAssertEqual(motion.pendingID, "four")
        XCTAssertEqual(motion.selectionID, selectedTwo, "A queued recommendation cannot claim the visible poster color")
        XCTAssertEqual(motion.progress, 0.4)
        XCTAssertFalse(motion.isInteractive("four"))
        XCTAssertTrue(motion.finish(generation: first))
        let second = motion.generation
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(motion.outgoingID, "two")
        XCTAssertEqual(motion.currentID, "four")
        XCTAssertNotEqual(motion.selectionID, selectedTwo)
        XCTAssertEqual(motion.progress, 0)
        XCTAssertFalse(motion.finish(generation: first), "A late completion cannot finish the queued slide")
        motion.setProgress(1, generation: first)
        XCTAssertEqual(motion.progress, 0)
        motion.request(id: "one", direction: -1, animated: true)
        XCTAssertTrue(motion.finish(generation: second))
        XCTAssertEqual(motion.currentID, "one")
        XCTAssertEqual(motion.direction, -1)
        let selectedOne = motion.selectionID
        motion.reset(to: "one")
        XCTAssertEqual(motion.selectionID, selectedOne, "Restoring the same slide is a duplicate presentation")
    }

    func testReturningToArrivingSlideCancelsPendingJump() {
        var motion = HomeCarouselMotion()
        motion.reset(to: "one")
        motion.request(id: "two", direction: 1, animated: true)
        let token = motion.generation
        motion.request(id: "three", direction: 1, animated: true)
        motion.request(id: "two", direction: -1, animated: true)
        XCTAssertNil(motion.pendingID)
        XCTAssertFalse(motion.finish(generation: token))
        XCTAssertEqual(motion.currentID, "two")
    }

    func testResetAndReducedMotionInvalidateCallbacksAndClearQueue() {
        var motion = HomeCarouselMotion()
        motion.reset(to: "one")
        motion.request(id: "two", direction: 1, animated: true)
        let token = motion.generation
        motion.request(id: "three", direction: 1, animated: true)
        XCTAssertFalse(motion.request(id: "four", direction: 1, animated: false))
        XCTAssertEqual(motion.currentID, "four")
        XCTAssertNil(motion.pendingID)
        XCTAssertNil(motion.outgoingID)
        XCTAssertEqual(motion.progress, 1)
        XCTAssertFalse(motion.finish(generation: token))
        motion.setProgress(0, generation: token)
        XCTAssertEqual(motion.progress, 1)
        motion.reset(to: nil)
        XCTAssertNil(motion.currentID)
        XCTAssertEqual(motion.renderedIDs(in: ["one", "two"]), [])
    }

    func testRenderedSlidesAreUniqueFilteredAndBoundedForSmallAndLargeCatalogs() {
        var motion = HomeCarouselMotion()
        XCTAssertFalse(motion.request(id: "one", direction: 1, animated: true), "Initial appearance must not slide in from an empty home")
        XCTAssertFalse(motion.request(id: "one", direction: 1, animated: true))
        XCTAssertEqual(motion.renderedIDs(in: []), [])
        XCTAssertEqual(motion.renderedIDs(in: ["one"]), ["one"])
        XCTAssertEqual(motion.renderedIDs(in: ["one", "two"]), ["one", "two"])
        let ids = (1...10).map(String.init)
        motion.reset(to: "1")
        XCTAssertEqual(Set(motion.renderedIDs(in: ids)), Set(["1", "10", "2"]))
        motion.request(id: "5", direction: 1, animated: true)
        motion.request(id: "9", direction: 1, animated: true)
        XCTAssertEqual(Set(motion.renderedIDs(in: ids)), Set(["1", "4", "5", "6", "9"]))
        XCTAssertEqual(motion.renderedIDs(in: ids).count, 5)
        XCTAssertEqual(motion.renderedIDs(in: ["5", "5", "6"]), ["5", "6"])
        XCTAssertEqual(motion.renderedIDs(in: ["unrelated"]), [])
    }

    func testProgressRejectsInvalidValuesAndClampsToViewport() {
        var motion = HomeCarouselMotion()
        motion.reset(to: "one")
        motion.request(id: "two", direction: Int.min, animated: true)
        let token = motion.generation
        XCTAssertEqual(motion.direction, -1)
        motion.setProgress(.nan, generation: token)
        motion.setProgress(.infinity, generation: token)
        XCTAssertEqual(motion.progress, 0)
        motion.setProgress(-1, generation: token)
        XCTAssertEqual(motion.progress, 0)
        motion.setProgress(2, generation: token)
        XCTAssertEqual(motion.progress, 1)
        XCTAssertFalse(motion.request(id: "", direction: 1, animated: true))
        XCTAssertEqual(motion.currentID, "two")
    }
}
