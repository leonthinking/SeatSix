import XCTest
@testable import SeatSixApp

final class HomeCarouselPositionTests: XCTestCase {
    func testRapidReversalKeepsNetForwardAndBackwardDirection() {
        let ids = (1...10).map(String.init)
        for (start, steps, arriving, target, expectedDirection) in [
            ("1", [1, 1, 1, -1], "2", "3", 1),
            ("5", [-1, -1, -1, 1], "4", "3", -1)
        ] {
            var position = HomeCarouselPosition()
            var motion = HomeCarouselMotion()
            position.select(start, in: ids)
            motion.reset(to: start)
            advance(steps[0], ids: ids, position: &position, motion: &motion)
            let first = motion.generation
            motion.setProgress(0.35, generation: first)
            for step in steps.dropFirst() {
                advance(step, ids: ids, position: &position, motion: &motion)
            }

            XCTAssertEqual(motion.currentID, arriving, "Rapid input must not replace a pair mid-slide")
            XCTAssertEqual(motion.progress, 0.35)
            XCTAssertEqual(position.selectedID, target)
            XCTAssertTrue(motion.finish(generation: first))
            XCTAssertEqual(motion.outgoingID, arriving)
            XCTAssertEqual(motion.currentID, target)
            XCTAssertEqual(motion.direction, expectedDirection,
                           "Undoing one queued step must not reverse the remaining net journey")
            XCTAssertEqual(motion.offset(for: target), Double(expectedDirection))
        }
    }

    func testQueuedStepsKeepNetDirectionAcrossWrapAndPagination() {
        let ids = (1...10).map(String.init)
        for (start, firstStep, queuedSteps, target, expectedDirection) in [
            ("9", 1, [1, 1, -1], "1", 1),
            ("2", -1, [-1, -1, 1], "10", -1)
        ] {
            var position = HomeCarouselPosition()
            var motion = HomeCarouselMotion()
            position.select(start, in: ids)
            motion.reset(to: start)
            advance(firstStep, ids: ids, position: &position, motion: &motion)
            let first = motion.generation
            for step in queuedSteps {
                advance(step, ids: ids, position: &position, motion: &motion)
            }
            XCTAssertTrue(motion.finish(generation: first))
            XCTAssertEqual(motion.currentID, target)
            XCTAssertEqual(motion.direction, expectedDirection,
                           "Wrapping must retain the net direction, rather than numeric index order")
        }

        for (start, direction, arriving, queuedPage, target) in [
            ("1", 1, "2", "9", "8"), ("10", -1, "9", "2", "3")
        ] {
            var position = HomeCarouselPosition()
            var motion = HomeCarouselMotion()
            position.select(start, in: ids)
            motion.reset(to: position.selectedID)
            advance(direction, ids: ids, position: &position, motion: &motion)
            let first = motion.generation
            position.select(queuedPage, in: ids, relativeTo: motion.currentID)
            motion.request(id: position.selectedID!, direction: position.direction, animated: true)
            advance(-direction, ids: ids, position: &position, motion: &motion)
            XCTAssertTrue(motion.finish(generation: first))
            XCTAssertEqual(motion.outgoingID, arriving)
            XCTAssertEqual(motion.currentID, target)
            XCTAssertEqual(motion.direction, direction,
                           "Undoing one step from a queued distant page must retain the net pagination direction")
        }
    }

    func testAlternatingInputSequencesSettleAtAccumulatedPositionWithoutStaleCompletion() {
        var shortSequences = [[Int]]()
        for length in 1...6 {
            for mask in 0..<(1 << length) {
                shortSequences.append((0..<length).map { mask & (1 << $0) == 0 ? -1 : 1 })
            }
        }
        for count in [2, 3, 10] {
            let ids = (1...count).map(String.init)
            let sequences = shortSequences + [Array(repeating: 1, count: count), Array(repeating: -1, count: count),
                                              Array(repeating: 1, count: count + 2) + [-1, -1],
                                              Array(repeating: -1, count: count + 2) + [1, 1]]
            let startIndices = Set([0, (count - 1) / 2, count - 1]).sorted()
            for startIndex in startIndices {
                for steps in sequences {
                    for completionInterval in [0, 2, 3] {
                        var position = HomeCarouselPosition()
                        var motion = HomeCarouselMotion()
                        position.select(ids[startIndex], in: ids)
                        motion.reset(to: position.selectedID)
                        var tokens = [Int]()
                        for (offset, step) in steps.enumerated() {
                            advance(step, ids: ids, position: &position, motion: &motion)
                            tokens.append(motion.generation)
                            motion.setProgress(0.4, generation: motion.generation)
                            if completionInterval > 0 && (offset + 1).isMultiple(of: completionInterval) {
                                motion.finish(generation: motion.generation)
                            }
                        }
                        // At most the active pair and one coalesced destination remain.
                        for _ in 0..<2 where motion.isTransitioning {
                            motion.finish(generation: motion.generation)
                        }
                        let expectedIndex = ((startIndex + steps.reduce(0, +)) % ids.count + ids.count) % ids.count
                        let context = "count=\(count), start=\(startIndex + 1), steps=\(steps), completion=\(completionInterval)"
                        XCTAssertEqual(position.selectedID, ids[expectedIndex], context)
                        XCTAssertEqual(motion.currentID, ids[expectedIndex], context)
                        XCTAssertFalse(motion.isTransitioning, context)
                        XCTAssertNil(motion.pendingID, context)
                        XCTAssertTrue(position.isPaused, context)
                        for token in tokens {
                            XCTAssertFalse(motion.finish(generation: token), context)
                            motion.setProgress(0, generation: token)
                        }
                        XCTAssertEqual(motion.currentID, ids[expectedIndex], context)
                        XCTAssertEqual(motion.progress, 1, context)
                    }
                }
            }
        }
    }

    func testFullQueuedLapCancelsBeforeNewReverseRequest() {
        let ids = (1...10).map(String.init)
        for (start, direction, arriving, returned) in [
            ("1", 1, "2", "1"), ("5", -1, "4", "5")
        ] {
            var position = HomeCarouselPosition()
            var motion = HomeCarouselMotion()
            position.select(start, in: ids)
            motion.reset(to: start)
            advance(direction, ids: ids, position: &position, motion: &motion)
            let first = motion.generation
            for _ in ids {
                advance(direction, ids: ids, position: &position, motion: &motion)
            }
            XCTAssertEqual(position.selectedID, arriving)
            XCTAssertNil(motion.pendingID, "A full queued lap returns to the already arriving page")

            advance(-direction, ids: ids, position: &position, motion: &motion)
            XCTAssertTrue(motion.finish(generation: first))
            XCTAssertEqual(motion.outgoingID, arriving)
            XCTAssertEqual(motion.currentID, returned)
            XCTAssertEqual(motion.direction, -direction,
                           "A cancelled full lap must not leak its old direction into a fresh reverse request")
        }
    }

    func testQueuedReversalUsesNewArrivingPageAfterFirstCompletion() {
        let ids = (1...10).map(String.init)
        for (start, direction, secondArrival, target) in [
            ("1", 1, "5", "4"), ("10", -1, "6", "7")
        ] {
            var position = HomeCarouselPosition()
            var motion = HomeCarouselMotion()
            position.select(start, in: ids)
            motion.reset(to: start)
            advance(direction, ids: ids, position: &position, motion: &motion)
            let first = motion.generation
            for _ in 0..<3 {
                advance(direction, ids: ids, position: &position, motion: &motion)
            }
            XCTAssertTrue(motion.finish(generation: first))
            XCTAssertEqual(motion.currentID, secondArrival)
            let second = motion.generation
            motion.setProgress(0.25, generation: second)
            for step in [-direction, -direction, direction] {
                advance(step, ids: ids, position: &position, motion: &motion)
            }
            XCTAssertFalse(motion.finish(generation: first), "The first completion is now stale")
            XCTAssertEqual(motion.currentID, secondArrival)
            XCTAssertEqual(motion.progress, 0.25)
            XCTAssertTrue(motion.finish(generation: second))
            XCTAssertEqual(motion.outgoingID, secondArrival)
            XCTAssertEqual(motion.currentID, target)
            XCTAssertEqual(motion.direction, -direction,
                           "New queued input must use the second arriving page, not the first pair's origin")
        }
    }

    private func advance(_ step: Int, ids: [String], position: inout HomeCarouselPosition,
                         motion: inout HomeCarouselMotion) {
        position.advance(by: step, in: ids, relativeTo: motion.currentID)
        motion.request(id: position.selectedID!, direction: position.direction, animated: true)
    }

    func testQueuedPaginationUsesDisplayedPageAsItsDirectionalOrigin() {
        let ids = (1...10).map(String.init)
        var position = HomeCarouselPosition()
        var motion = HomeCarouselMotion()
        position.reconcile(with: ids); motion.reset(to: position.selectedID)
        position.advance(by: 1, in: ids)
        motion.request(id: position.selectedID!, direction: position.direction, animated: true)
        let token = motion.generation
        for target in ["9", "5"] {
            position.select(target, in: ids, relativeTo: motion.currentID)
            motion.request(id: position.selectedID!, direction: position.direction, animated: true)
        }
        XCTAssertEqual(motion.currentID, "2")
        motion.finish(generation: token)
        XCTAssertEqual(motion.currentID, "5")
        XCTAssertEqual(motion.direction, 1, "The pending dot is right of the displayed page, regardless of an earlier queued dot")
        position.select("1", in: ids, relativeTo: motion.currentID)
        motion.request(id: position.selectedID!, direction: position.direction, animated: true)
        motion.finish(generation: motion.generation)
        XCTAssertEqual(motion.direction, -1)
    }

    func testTransitionDirectionFollowsInputAcrossWrapAndDirectSelection() {
        var position = HomeCarouselPosition()
        let ids = ["one", "two", "three"]
        position.reconcile(with: ids)
        position.advance(by: -1, in: ids)
        XCTAssertEqual(position.selectedID, "three")
        XCTAssertEqual(position.direction, -1)
        position.advance(by: 1, in: ids)
        XCTAssertEqual(position.selectedID, "one")
        XCTAssertEqual(position.direction, 1)
        position.select("three", in: ids)
        XCTAssertEqual(position.direction, 1)
        position.select("two", in: ids)
        XCTAssertEqual(position.direction, -1)
        position.isPaused = false
        position.advanceAutomatically(in: ids, isAllowed: true)
        XCTAssertEqual(position.direction, 1)
    }

    func testAutomaticAdvanceHonorsVisibilityGateAndKeepsManualPauseAcrossReturn() {
        var position = HomeCarouselPosition()
        let ids = ["one", "two", "three"]
        position.reconcile(with: ids)
        position.advanceAutomatically(in: ids, isAllowed: true)
        XCTAssertEqual(position.selectedID, "two")
        position.advanceAutomatically(in: ids, isAllowed: false)
        XCTAssertEqual(position.selectedID, "two", "Hidden or obstructed home must not advance")
        position.select("three", in: ids)
        position.reconcile(with: ids)
        position.advanceAutomatically(in: ids, isAllowed: true)
        XCTAssertEqual(position.selectedID, "three", "Returning to home must not undo a manual pause")
        position.isPaused = false
        position.advanceAutomatically(in: ids, isAllowed: true)
        XCTAssertEqual(position.selectedID, "one")
        position.advance(by: 1, in: ids)
        position.advanceAutomatically(in: ids, isAllowed: true)
        XCTAssertEqual(position.selectedID, "two", "Manual next also pauses the timer")
    }

    func testDisabledAutomaticRotationStillAllowsManualNavigationAndExplicitReenable() {
        var position = HomeCarouselPosition()
        let ids = ["one", "two", "three"]
        position.reconcile(with: ids)
        position.advanceAutomatically(in: ids, isAllowed: true, rotationEnabled: false)
        XCTAssertEqual(position.selectedID, "one")
        position.advance(by: 1, in: ids)
        XCTAssertEqual(position.selectedID, "two", "The setting must not disable manual navigation")
        position.automaticRotationPreferenceChanged(to: false)
        position.advanceAutomatically(in: ids, isAllowed: true, rotationEnabled: false)
        XCTAssertEqual(position.selectedID, "two")
        position.automaticRotationPreferenceChanged(to: true)
        position.advanceAutomatically(in: ids, isAllowed: false, rotationEnabled: true)
        XCTAssertEqual(position.selectedID, "two", "Enabling the setting must still respect hidden/hover/focus gates")
        position.advanceAutomatically(in: ids, isAllowed: true, rotationEnabled: true)
        XCTAssertEqual(position.selectedID, "three", "Explicitly enabling automatic rotation resumes it")
    }

    func testToolbarInteractionTemporarilyHoldsRotationAndRespectsManualPause() {
        let ids = ["one", "two", "three"]
        var position = HomeCarouselPosition()
        position.reconcile(with: ids)
        position.advanceAutomatically(in: ids, isAllowed: true, controlsEngaged: true)
        XCTAssertEqual(position.selectedID, "one")
        position.advanceAutomatically(in: ids, isAllowed: true, controlsEngaged: false)
        XCTAssertEqual(position.selectedID, "two", "Leaving toolbar focus allows automatic rotation to resume")

        position.advance(by: 1, in: ids)
        for engaged in [true, false] {
            position.advanceAutomatically(in: ids, isAllowed: true, controlsEngaged: engaged)
            XCTAssertEqual(position.selectedID, "three", "Toolbar focus changes must preserve manual pause")
        }
    }

    func testSelectionSurvivesMetadataUpdatesAndReorderingButNotRemovedWorks() {
        var position = HomeCarouselPosition()
        let ids = ["one", "two", "three"]
        position.reconcile(with: ids)
        position.select("two", in: ids)
        position.reconcile(with: ids)
        XCTAssertEqual(position.selectedID, "two")
        position.reconcile(with: ids.reversed())
        XCTAssertEqual(position.selectedID, "two")
        position.select("another-source", in: ids)
        XCTAssertEqual(position.selectedID, "two")
        position.reconcile(with: ["new-source-first", "new-source-second"])
        XCTAssertEqual(position.selectedID, "new-source-first")
    }

    func testNavigationWrapsBothDirectionsAndHandlesEmptyOrSingleRecommendation() {
        var position = HomeCarouselPosition()
        let ids = ["one", "two", "three"]
        position.advance(by: -1, in: ids)
        XCTAssertEqual(position.selectedID, "three")
        position.advance(by: 1, in: ids)
        XCTAssertEqual(position.selectedID, "one")
        position.advance(by: 8, in: ids)
        XCTAssertEqual(position.selectedID, "three")
        position.advance(by: Int.min, in: ["only"])
        XCTAssertEqual(position.selectedID, "only")
        position.advance(by: 1, in: [])
        XCTAssertNil(position.selectedID)
        XCTAssertNil(position.index(in: []))
    }
}
