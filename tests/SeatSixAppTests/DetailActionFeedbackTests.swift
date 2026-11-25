import Foundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

final class DetailActionFeedbackTests: XCTestCase {
    func testOnlyExplicitAcceptedActionWithAuthoritativeDesiredResultPublishesSuccess() throws {
        let scope = identity(), original = try item(favorite: false)
        var feedback = DetailActionFeedback()
        XCTAssertFalse(feedback.complete(item: try item(favorite: true), scope: scope,
            isBusy: false, error: nil, needsRefresh: false), "An ordinary metadata update is not a user action")
        feedback.begin(itemID: original.id, scope: scope, action: .favorite(true))
        XCTAssertFalse(feedback.complete(item: original, scope: scope, isBusy: true, error: nil, needsRefresh: false))
        XCTAssertNil(feedback.message)
        XCTAssertTrue(feedback.complete(item: try item(favorite: true), scope: scope,
            isBusy: false, error: nil, needsRefresh: false))
        XCTAssertEqual(feedback.message?.text, "已加入收藏")
        let messageID = feedback.message?.id
        XCTAssertFalse(feedback.complete(item: try item(favorite: true), scope: scope,
            isBusy: false, error: nil, needsRefresh: false))
        XCTAssertEqual(feedback.message?.id, messageID, "Repeated metadata must not extend the success timer")
    }

    func testRejectedActionCannotBeConfirmedByLaterUnrelatedBusyCycle() throws {
        let scope = identity(), desired = try item(favorite: true)
        var feedback = DetailActionFeedback()
        feedback.begin(itemID: desired.id, scope: scope, action: .favorite(true))
        XCTAssertFalse(feedback.complete(item: desired, scope: scope, isBusy: false, error: nil, needsRefresh: false))
        XCTAssertFalse(feedback.complete(item: desired, scope: scope, isBusy: true, error: nil, needsRefresh: false))
        XCTAssertFalse(feedback.complete(item: desired, scope: scope, isBusy: false, error: nil, needsRefresh: false))
        XCTAssertNil(feedback.message)
    }

    func testFailureUncertainOrMismatchedServerResultNeverTurnsIntoLaterSuccess() throws {
        let scope = identity(), desired = try item(favorite: true)
        for scenario in 0..<3 {
            var feedback = DetailActionFeedback()
            feedback.begin(itemID: desired.id, scope: scope, action: .favorite(true))
            feedback.complete(item: desired, scope: scope, isBusy: true, error: nil, needsRefresh: true)
            let result = scenario == 2 ? try item(favorite: false) : desired
            XCTAssertFalse(feedback.complete(item: result, scope: scope, isBusy: false,
                error: scenario == 0 ? "Server rejected the operation" : nil, needsRefresh: scenario == 1))
            XCTAssertNil(feedback.message)
            XCTAssertFalse(feedback.complete(item: desired, scope: scope, isBusy: false, error: nil, needsRefresh: false))
            XCTAssertNil(feedback.message, "A failed attempt must not be revived by later reconciliation")
        }
    }

    func testMissingKnownFlagsCannotConfirmFalseFavoriteOrPlayed() throws {
        for action in [DetailActionFeedback.Action.favorite(false), .played(false)] {
            let scope = identity(), missing = try item()
            var feedback = DetailActionFeedback()
            feedback.begin(itemID: missing.id, scope: scope, action: action)
            feedback.complete(item: missing, scope: scope, isBusy: true, error: nil, needsRefresh: false)
            XCTAssertFalse(feedback.complete(item: missing, scope: scope, isBusy: false, error: nil, needsRefresh: false))
            XCTAssertNil(feedback.message)
        }
    }

    func testCrossItemAccountLibraryAndRevisionInvalidatePendingAndVisibleMessages() throws {
        let originalScope = identity(), desired = try item(favorite: true)
        let replacements = [identity(connectionID: UUID()), identity(server: "other-server"),
            identity(user: "other-user"), identity(url: "https://other.invalid"),
            identity(library: "other-library"), identity(revision: UUID())]
        for replacement in replacements {
            var feedback = DetailActionFeedback()
            feedback.begin(itemID: desired.id, scope: originalScope, action: .favorite(true))
            feedback.complete(item: desired, scope: originalScope, isBusy: true, error: nil, needsRefresh: false)
            XCTAssertFalse(feedback.complete(item: desired, scope: replacement, isBusy: false, error: nil, needsRefresh: false))
            XCTAssertFalse(feedback.complete(item: desired, scope: originalScope, isBusy: false, error: nil, needsRefresh: false))
            XCTAssertNil(feedback.message)

            try succeed(&feedback, scope: originalScope, action: .favorite(true))
            XCTAssertNotNil(feedback.message)
            XCTAssertFalse(feedback.complete(item: desired, scope: replacement, isBusy: false, error: nil, needsRefresh: false))
            XCTAssertNil(feedback.message)
        }
        var feedback = DetailActionFeedback()
        try succeed(&feedback, scope: originalScope, action: .favorite(true))
        XCTAssertFalse(feedback.complete(item: try item(id: "other", favorite: true), scope: originalScope,
                                        isBusy: false, error: nil, needsRefresh: false))
        XCTAssertNil(feedback.message)
    }

    func testNewActionClearsOldMessageAndOldTimerCannotDismissNewSuccess() throws {
        let scope = identity()
        var feedback = DetailActionFeedback()
        try succeed(&feedback, scope: scope, action: .favorite(true))
        let previous = try XCTUnwrap(feedback.message?.id)
        feedback.begin(itemID: "movie", scope: scope, action: .played(true))
        XCTAssertNil(feedback.message)
        let desired = try item(played: true)
        feedback.complete(item: desired, scope: scope, isBusy: true, error: nil, needsRefresh: false)
        XCTAssertTrue(feedback.complete(item: desired, scope: scope, isBusy: false, error: nil, needsRefresh: false))
        let current = try XCTUnwrap(feedback.message?.id)
        XCTAssertNotEqual(current, previous)
        XCTAssertFalse(feedback.dismiss(messageID: previous))
        XCTAssertEqual(feedback.message?.id, current)
        XCTAssertTrue(feedback.dismiss(messageID: current))
        XCTAssertNil(feedback.message)
    }

    func testAllActionsPublishSpecificConfirmedMessagesAndInvalidationClearsEverything() throws {
        let scope = identity()
        for (action, text) in [(DetailActionFeedback.Action.favorite(true), "已加入收藏"),
                               (.favorite(false), "已取消收藏"), (.played(true), "已标记为已看"),
                               (.played(false), "已标记为未看")] {
            var feedback = DetailActionFeedback()
            try succeed(&feedback, scope: scope, action: action)
            XCTAssertEqual(feedback.message?.text, text)
            feedback.invalidate()
            XCTAssertNil(feedback.message)
            XCTAssertFalse(feedback.complete(item: try item(played: false, favorite: false), scope: scope,
                                             isBusy: false, error: nil, needsRefresh: false))
        }
    }

    func testMissingScopeNeverPublishesSuccess() throws {
        let desired = try item(favorite: true)
        var feedback = DetailActionFeedback()
        feedback.begin(itemID: desired.id, scope: nil, action: .favorite(true))
        feedback.complete(item: desired, scope: nil, isBusy: true, error: nil, needsRefresh: false)
        XCTAssertFalse(feedback.complete(item: desired, scope: nil, isBusy: false, error: nil, needsRefresh: false))
        XCTAssertNil(feedback.message)
        try succeed(&feedback, scope: identity(), action: .favorite(true))
        XCTAssertFalse(feedback.complete(item: desired, scope: nil, isBusy: false, error: nil, needsRefresh: false))
        XCTAssertNil(feedback.message)
    }

    private func succeed(_ feedback: inout DetailActionFeedback, scope: HomeArtworkScope,
                         action: DetailActionFeedback.Action) throws {
        let result: MediaItem
        switch action {
        case .favorite(let value): result = try item(favorite: value)
        case .played(let value): result = try item(played: value)
        }
        feedback.begin(itemID: result.id, scope: scope, action: action)
        feedback.complete(item: result, scope: scope, isBusy: true, error: nil, needsRefresh: false)
        XCTAssertTrue(feedback.complete(item: result, scope: scope, isBusy: false, error: nil, needsRefresh: false))
    }

    private func item(id: String = "movie", played: Bool? = nil, favorite: Bool? = nil) throws -> MediaItem {
        var state: [String: Any] = [:]
        if let played { state["Played"] = played }
        if let favorite { state["IsFavorite"] = favorite }
        let data = try JSONSerialization.data(withJSONObject: ["Id": id, "Name": "Synthetic movie", "Type": "Movie", "UserData": state])
        return try JSONDecoder().decode(MediaItem.self, from: data)
    }

    private func identity(connectionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                          server: String = "server", user: String = "user", url: String = "https://fixture.invalid",
                          library: String = "movies", revision: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!) -> HomeArtworkScope {
        HomeArtworkScope(connectionID: connectionID, serverID: server, userID: user,
                         baseURL: url, libraryID: library, posterRevision: revision)
    }
}
