import XCTest
@testable import SeatSixApp

@MainActor
final class LibraryKeyboardNavigationTests: XCTestCase {
    func testNativeFocusAdoptionMakesArrowMovementStartFromActualCardWithoutRefocusing() throws {
        let navigation = LibraryKeyboardNavigation()
        let ids = ["a", "b", "c", "d"]
        navigation.move(delta: 0, ids: ids, scope: "scope")
        let stale = try XCTUnwrap(navigation.focusRequest)
        navigation.select(itemID: "c", ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "c")
        XCTAssertNil(navigation.focusRequest)
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "a", id: stale.id))
        navigation.reconcile(ids: ["inserted"] + ids, scope: "scope", isLoading: false)
        XCTAssertEqual(navigation.selectedID, "c")
        XCTAssertNil(navigation.focusRequest)
        navigation.move(delta: 1, ids: ["inserted"] + ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "d")
        navigation.select(itemID: "missing", ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "d")
    }
    func testExplicitMovementUsesCurrentIdentityAfterResultsReorder() throws {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["b", "c"], scope: "scope")
        let originalRequest = try XCTUnwrap(navigation.focusRequest)
        XCTAssertEqual(navigation.selectedID, "b")
        XCTAssertTrue(navigation.takeFocusRequest(itemID: "b", id: originalRequest.id))

        navigation.reconcile(ids: ["a", "b", "c"], scope: "scope", isLoading: true)
        XCTAssertEqual(navigation.selectedID, "b", "An inserted earlier result must not change the selected media")
        XCTAssertNil(navigation.focusRequest, "A page arrival cannot steal focus")
        navigation.move(delta: 1, ids: ["a", "b", "c"], scope: "scope")
        XCTAssertEqual(navigation.selectedID, "c", "Explicit movement starts from the selected ID's new index")
        XCTAssertEqual(navigation.focusRequest?.itemID, "c")
    }

    func testPagingPreservesPendingExplicitRequestWithoutReplacingIt() throws {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["b"], scope: "scope")
        let request = try XCTUnwrap(navigation.focusRequest)
        navigation.reconcile(ids: ["a", "b", "c"], scope: "scope", isLoading: true)
        XCTAssertEqual(navigation.selectedID, "b")
        XCTAssertEqual(navigation.focusRequest, request)
        navigation.reconcile(ids: ["a", "b", "c"], scope: "scope", isLoading: false)
        XCTAssertEqual(navigation.focusRequest, request)
    }

    func testRefreshTemporarilyEmptyResultsRetainIdentityWithoutAutomaticRefocus() throws {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 1, ids: ["b", "c"], scope: "scope")
        let oldRequest = try XCTUnwrap(navigation.focusRequest)
        navigation.reconcile(ids: [], scope: "scope", isLoading: true)
        XCTAssertEqual(navigation.selectedID, "b")
        XCTAssertNil(navigation.focusRequest)
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "b", id: oldRequest.id))
        navigation.reconcile(ids: ["a"], scope: "scope", isLoading: true)
        XCTAssertEqual(navigation.selectedID, "b", "The selected item may appear on a later page")
        navigation.reconcile(ids: ["a", "b", "c"], scope: "scope", isLoading: false)
        XCTAssertEqual(navigation.selectedID, "b")
        XCTAssertNil(navigation.focusRequest, "Remounting a refreshed card must not replay focus")
    }

    func testFinalRemovalClearsSelectionWithoutChoosingAnotherResult() {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["removed", "survivor"], scope: "scope")
        navigation.reconcile(ids: ["survivor"], scope: "scope", isLoading: false)
        XCTAssertNil(navigation.selectedID)
        XCTAssertNil(navigation.focusRequest)
        navigation.reconcile(ids: ["earlier", "survivor"], scope: "scope", isLoading: false)
        XCTAssertNil(navigation.selectedID)
        XCTAssertNil(navigation.focusRequest)
    }

    func testScopeChangesClearEvenIdenticalIDsWhileLoading() {
        for nextScope in ["other account", "other library", "new query", "new filter", "new revision"] {
            let navigation = LibraryKeyboardNavigation()
            navigation.move(delta: 0, ids: ["same-id"], scope: "original")
            navigation.reconcile(ids: ["same-id"], scope: nextScope, isLoading: true)
            XCTAssertNil(navigation.selectedID, nextScope)
            XCTAssertNil(navigation.focusRequest, nextScope)
        }
    }

    func testFocusRequestCanOnlyBeConsumedOnceByItsIntendedCard() throws {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["a", "b"], scope: "scope")
        let first = try XCTUnwrap(navigation.focusRequest)
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "b", id: first.id))
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "a", id: UUID()))
        XCTAssertEqual(navigation.focusRequest, first)
        navigation.move(delta: 0, ids: ["a", "b"], scope: "scope")
        let second = try XCTUnwrap(navigation.focusRequest)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "a", id: first.id), "An older lazy task must not consume a newer request")
        XCTAssertTrue(navigation.takeFocusRequest(itemID: "a", id: second.id))
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "a", id: second.id), "A lazy remount must not focus again")
        XCTAssertEqual(navigation.selectedID, "a", "Consuming focus does not discard keyboard identity")
    }

    func testRowMovementAndExtremeDeltasStayWithinResults() {
        let navigation = LibraryKeyboardNavigation()
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        navigation.move(delta: 0, ids: ids, scope: "scope")
        navigation.move(delta: 3, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "d")
        navigation.move(delta: 3, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "g")
        navigation.move(delta: Int.max, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "g")
        navigation.move(delta: Int.min, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "a")
        navigation.move(delta: -3, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "a")
        navigation.invalidate()
        navigation.move(delta: -1, ids: ids, scope: "scope")
        XCTAssertEqual(navigation.selectedID, "g")
    }

    func testLeavingResultsDiscardsPendingFocusButPreservesNextMovementOrigin() throws {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["a", "b"], scope: "scope")
        let request = try XCTUnwrap(navigation.focusRequest)
        navigation.invalidatePendingFocus()
        XCTAssertNil(navigation.focusRequest)
        XCTAssertEqual(navigation.selectedID, "a")
        XCTAssertFalse(navigation.takeFocusRequest(itemID: "a", id: request.id))
        navigation.move(delta: 1, ids: ["a", "b"], scope: "scope")
        XCTAssertEqual(navigation.selectedID, "b")
        XCTAssertEqual(navigation.focusRequest?.itemID, "b")
    }

    func testEmptyMovementCannotCreateFocusOrDestroyRefreshIdentity() {
        let navigation = LibraryKeyboardNavigation()
        navigation.move(delta: 0, ids: ["kept"], scope: "scope")
        navigation.reconcile(ids: [], scope: "scope", isLoading: true)
        navigation.move(delta: 1, ids: [], scope: "scope")
        XCTAssertEqual(navigation.selectedID, "kept")
        XCTAssertNil(navigation.focusRequest)
        navigation.move(delta: 1, ids: [], scope: "new scope")
        XCTAssertNil(navigation.selectedID)
        XCTAssertNil(navigation.focusRequest)
    }
}
