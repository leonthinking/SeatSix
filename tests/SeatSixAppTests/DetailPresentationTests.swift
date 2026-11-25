import SwiftUI
import XCTest
@testable import SeatSixApp

@MainActor
final class DetailPresentationTests: XCTestCase {
    private let bounds = CGRect(x: 192, y: 0, width: 1415, height: 978)
    private let card = CGRect(x: 232, y: 300, width: 160, height: 240)
    private let context = "library|movies|query=|sort=name"

    func testDuplicateMediaControlsHaveDistinctStableSourceKeys() {
        let hero = DetailSourceKey(kind: "hero-detail", itemID: "movie")
        let rail = DetailSourceKey(kind: "home-rail", itemID: "movie")
        XCTAssertNotEqual(hero.id, rail.id)
        XCTAssertEqual(hero.id, DetailSourceKey(kind: "hero-detail", itemID: "movie").id)
        XCTAssertNotEqual(DetailSourceKey(kind: "a|b", itemID: "c").id,
                          DetailSourceKey(kind: "a", itemID: "b|c").id)
    }

    func testMotionUsesVisibleSourceDirectionAndFallsBackForMissingOrOffscreenOrigins() {
        let leading = DetailTransitionMotion(sourceFrame: card, bounds: bounds, reduceMotion: false)
        let trailing = DetailTransitionMotion(sourceFrame: CGRect(x: 1400, y: 700, width: 100, height: 200),
                                              bounds: bounds, reduceMotion: false)
        XCTAssertLessThan(leading.offset.width, 0)
        XCTAssertGreaterThan(trailing.offset.width, 0)
        XCTAssertLessThan(leading.offset.height, 0)
        XCTAssertGreaterThan(trailing.offset.height, 0)
        for motion in [leading, trailing] {
            XCTAssertLessThanOrEqual(abs(motion.offset.width), 20)
            XCTAssertLessThanOrEqual(abs(motion.offset.height), 20)
            XCTAssertGreaterThan(motion.scale, 0.95)
            XCTAssertLessThan(motion.scale, 1)
            XCTAssertLessThanOrEqual(motion.duration, 0.25)
        }
        for source in [nil, CGRect.zero, CGRect(x: 0, y: -500, width: 100, height: 100),
                       CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)] {
            let fallback = DetailTransitionMotion(sourceFrame: source, bounds: bounds, reduceMotion: false)
            XCTAssertEqual(fallback.offset, CGSize.zero)
            XCTAssertEqual(fallback.scale, 1)
            XCTAssertLessThanOrEqual(fallback.duration, 0.15)
        }
        let reduced = DetailTransitionMotion(sourceFrame: card, bounds: bounds, reduceMotion: true)
        XCTAssertEqual(reduced.offset, .zero)
        XCTAssertEqual(reduced.scale, 1)
        XCTAssertEqual(reduced.duration, 0)
        XCTAssertNil(reduced.animation)
    }

    func testSameDetailMetadataRefreshDoesNotReplayOrReplaceItsReturnSource() {
        let presentation = DetailPresentation(), scope = identity()
        let original = open(presentation, item: "movie", source: "hero", scope: scope)
        XCTAssertTrue(presentation.finish(generation: original))
        let refresh = presentation.prepareOpen(itemID: "movie", from: "movie", sourceID: "refresh",
            scope: scope, context: context, sourceFrame: card, bounds: bounds, reduceMotion: false)
        XCTAssertEqual(refresh, original)
        XCTAssertFalse(presentation.isTransitioning)
        back(presentation, from: "movie", to: nil, scope: scope, frames: ["hero": card])
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "hero")
    }

    func testRapidNestedBackUsesModelTargetAndRejectsOldCompletions() {
        let presentation = DetailPresentation(), scope = identity()
        let first = open(presentation, item: "series", source: "library-card", scope: scope)
        let episode = open(presentation, item: "episode", from: "series", source: "episode-row", scope: scope)
        XCTAssertNotEqual(first, episode)
        XCTAssertFalse(presentation.finish(generation: first))
        XCTAssertTrue(presentation.isTransitioning)

        let returned = back(presentation, from: "episode", to: "series", scope: scope,
                            frames: ["episode-row": card])
        XCTAssertFalse(presentation.finish(generation: episode))
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "episode-row")
        XCTAssertEqual(presentation.returnFocusRequest?.detailID, "series")
        XCTAssertFalse(consume(presentation, source: "episode-row", scope: scope, detailID: "series", visible: false))
        XCTAssertTrue(consume(presentation, source: "episode-row", scope: scope, detailID: "series"))
        XCTAssertFalse(consume(presentation, source: "episode-row", scope: scope, detailID: "series"))
        XCTAssertTrue(presentation.finish(generation: returned))

        back(presentation, from: "series", to: nil, scope: scope, frames: ["library-card": card])
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "library-card")
        XCTAssertNil(presentation.returnFocusRequest?.detailID)
    }

    func testNewOpenDuringBackCancelsPendingReturnFocusAndOldAnimation() {
        let presentation = DetailPresentation(), scope = identity()
        open(presentation, item: "first", source: "first-card", scope: scope)
        let returning = back(presentation, from: "first", to: nil, scope: scope, frames: ["first-card": card])
        XCTAssertNotNil(presentation.returnFocusRequest)
        let next = open(presentation, item: "second", source: "second-card", scope: scope)
        XCTAssertNil(presentation.returnFocusRequest)
        XCTAssertFalse(presentation.finish(generation: returning))
        XCTAssertTrue(presentation.isTransitioning)
        XCTAssertTrue(presentation.finish(generation: next))
        back(presentation, from: "second", to: nil, scope: scope, frames: ["second-card": card])
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "second-card")
    }

    func testEveryIdentityFieldAndRouteChangeInvalidateVisualsAndFocusEvenForSameMedia() {
        let original = identity()
        let replacements = [identity(connectionID: UUID()), identity(server: "other-server"),
            identity(user: "other-user"), identity(url: "https://other.invalid"),
            identity(library: "other-library"), identity(revision: UUID())]
        for replacement in replacements + [original] {
            let presentation = DetailPresentation()
            open(presentation, item: "movie", source: "card", scope: original)
            let returning = back(presentation, from: "movie", to: nil, scope: original, frames: ["card": card])
            presentation.synchronize(scope: replacement, context: replacement == original ? "home" : context,
                                     detailID: nil, bounds: bounds, reduceMotion: false)
            XCTAssertNil(presentation.returnFocusRequest)
            XCTAssertFalse(presentation.isTransitioning)
            XCTAssertFalse(presentation.finish(generation: returning))
            back(presentation, from: "movie", to: nil, scope: replacement, frames: ["card": card])
            XCTAssertNil(presentation.returnFocusRequest, "Invalidation cannot resurrect the old control by matching item ID")
        }
    }

    func testResizeCancelsOldAnimationButKeepsCurrentVisitReturnProvenance() {
        let presentation = DetailPresentation(), scope = identity()
        let entering = open(presentation, item: "movie", source: "card", scope: scope)
        let resized = CGRect(x: 250, y: 0, width: 1000, height: 820)
        presentation.synchronize(scope: scope, context: context, detailID: "movie", bounds: resized, reduceMotion: false)
        XCTAssertFalse(presentation.isTransitioning)
        XCTAssertFalse(presentation.finish(generation: entering))
        presentation.prepareBack(from: "movie", to: nil, scope: scope, context: context,
            sourceFrames: ["card": card], bounds: resized, reduceMotion: false, now: 10)
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "card")
    }

    func testReduceMotionChangeImmediatelySettlesAndInvalidatesOldCompletion() {
        let presentation = DetailPresentation(), scope = identity()
        let entering = open(presentation, item: "movie", source: "card", scope: scope)
        presentation.synchronize(scope: scope, context: context, detailID: "movie", bounds: bounds, reduceMotion: true)
        XCTAssertFalse(presentation.isTransitioning)
        XCTAssertEqual(presentation.motion.offset, .zero)
        XCTAssertEqual(presentation.motion.scale, 1)
        XCTAssertNil(presentation.motion.animation)
        XCTAssertFalse(presentation.finish(generation: entering))
        presentation.prepareBack(from: "movie", to: nil, scope: scope, context: context,
            sourceFrames: ["card": card], bounds: bounds, reduceMotion: true, now: 10)
        XCTAssertFalse(presentation.isTransitioning)
        XCTAssertEqual(presentation.returnFocusRequest?.sourceID, "card", "Reduced motion must not discard keyboard provenance")
    }

    func testFocusRequiresCurrentVisibleSourceAndExpiresOrCancelsWithNewUserIntent() {
        let presentation = DetailPresentation(), scope = identity()
        open(presentation, item: "movie", source: "card", scope: scope)
        back(presentation, from: "movie", to: nil, scope: scope, frames: ["card": card])
        XCTAssertFalse(consume(presentation, source: "other-card", scope: scope))
        XCTAssertFalse(consume(presentation, source: "card", scope: identity(user: "other")))
        XCTAssertFalse(consume(presentation, source: "card", scope: scope, detailID: "other-detail"))
        XCTAssertFalse(consume(presentation, source: "card", scope: scope, visible: false))
        XCTAssertFalse(presentation.consumeReturnFocus(sourceID: "card", scope: scope, context: context,
            detailID: nil, isVisible: true, frame: CGRect(x: 0, y: -1000, width: 100, height: 100), viewport: bounds, now: 10.2))
        XCTAssertFalse(presentation.consumeReturnFocus(sourceID: "card", scope: scope, context: "other-route",
            detailID: nil, isVisible: true, frame: card, viewport: bounds, now: 10.2))
        XCTAssertNotNil(presentation.returnFocusRequest)
        XCTAssertFalse(consume(presentation, source: "card", scope: scope, now: 12))
        XCTAssertNil(presentation.returnFocusRequest)

        open(presentation, item: "movie", source: "card", scope: scope)
        back(presentation, from: "movie", to: nil, scope: scope, frames: ["card": card])
        presentation.cancelReturnFocus()
        XCTAssertFalse(consume(presentation, source: "card", scope: scope))
    }

    func testMouseOriginAndUnknownNavigationDoNotInventKeyboardFocus() {
        let presentation = DetailPresentation(), scope = identity()
        presentation.prepareOpen(itemID: "movie", from: nil, sourceID: "card", scope: scope, context: context,
            sourceFrame: card, bounds: bounds, reduceMotion: false, restoreFocus: false)
        back(presentation, from: "movie", to: nil, scope: scope, frames: ["card": card])
        XCTAssertNil(presentation.returnFocusRequest)

        open(presentation, item: "movie", source: "card", scope: scope)
        presentation.synchronize(scope: scope, context: context, detailID: "external", bounds: bounds, reduceMotion: false)
        back(presentation, from: "external", to: nil, scope: scope, frames: ["card": card])
        XCTAssertNil(presentation.returnFocusRequest)
    }

    @discardableResult
    private func open(_ value: DetailPresentation, item: String, from: String? = nil,
                      source: String, scope: HomeArtworkScope) -> UUID {
        value.prepareOpen(itemID: item, from: from, sourceID: source, scope: scope, context: context,
                          sourceFrame: card, bounds: bounds, reduceMotion: false)
    }

    @discardableResult
    private func back(_ value: DetailPresentation, from: String, to: String?, scope: HomeArtworkScope,
                      frames: [String: CGRect]) -> UUID {
        value.prepareBack(from: from, to: to, scope: scope, context: context,
                          sourceFrames: frames, bounds: bounds, reduceMotion: false, now: 10)
    }

    private func consume(_ value: DetailPresentation, source: String, scope: HomeArtworkScope,
                         detailID: String? = nil, visible: Bool = true, now: TimeInterval = 10.2) -> Bool {
        value.consumeReturnFocus(sourceID: source, scope: scope, context: context, detailID: detailID,
                                 isVisible: visible, frame: card, viewport: bounds, now: now)
    }

    private func identity(connectionID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                          server: String = "server", user: String = "user", url: String = "https://fixture.invalid",
                          library: String = "movies", revision: UUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!) -> HomeArtworkScope {
        HomeArtworkScope(connectionID: connectionID, serverID: server, userID: user,
                         baseURL: url, libraryID: library, posterRevision: revision)
    }
}
