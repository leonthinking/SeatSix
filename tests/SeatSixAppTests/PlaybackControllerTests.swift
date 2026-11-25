import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

final class PlaybackControllerTests: XCTestCase {
    @MainActor
    func testBuildSelectsMatchingProfileAndEngineForAutomaticPlayback() throws {
        #if SEATSIX_SYSTEM_PLAYER
        XCTAssertFalse(LocalPlaybackEngine.isAvailable)
        XCTAssertFalse(SettingsPage.availablePages.contains(.subtitles))
        XCTAssertEqual(NativePlaybackController.capability(for: .automatic), .avFoundation)
        XCTAssertThrowsError(try LocalPlaybackEngine()) {
            XCTAssertEqual($0 as? LocalPlaybackError, .unavailable)
        }
        #else
        XCTAssertTrue(LocalPlaybackEngine.isAvailable)
        XCTAssertTrue(SettingsPage.availablePages.contains(.subtitles))
        XCTAssertEqual(NativePlaybackController.capability(for: .automatic), .localDecoder)
        #endif
        XCTAssertEqual(NativePlaybackController.capability(for: .compatible), .avFoundation)
    }

    func testPlaybackStartsOnlyAfterRealAdvanceNotInitialSeekOrPause() {
        var gate = PlaybackStartGate(baseline: 75)
        XCTAssertFalse(gate.observe(seconds: 75, playing: false, seeking: false))
        XCTAssertFalse(gate.observe(seconds: 150, playing: true, seeking: true))
        XCTAssertFalse(gate.observe(seconds: 150, playing: true, seeking: false), "A seek discontinuity must first establish a new baseline")
        XCTAssertFalse(gate.observe(seconds: 150.01, playing: true, seeking: false))
        XCTAssertTrue(gate.observe(seconds: 150.25, playing: true, seeking: false))
    }

    func testPlaybackStartGateRejectsInvalidClocksAndTracksBackwardPause() {
        var gate = PlaybackStartGate(baseline: 90)
        for seconds in [Double.nan, Double.infinity, -1] {
            XCTAssertFalse(gate.observe(seconds: seconds, playing: true, seeking: false))
        }
        XCTAssertEqual(gate.baseline, 90)
        XCTAssertFalse(gate.observe(seconds: 15, playing: false, seeking: false))
        XCTAssertTrue(gate.observe(seconds: 15.1, playing: true, seeking: false))
    }

    @MainActor
    func testSlowWritesCoalesceTwentySeeksAndStopKeepsFinalPosition() async throws {
        let sender = GatedPlaybackSender()
        var acknowledgements: [PlaybackWrite] = []
        var failed = false
        let pump = PlaybackReportPump(send: sender.send, acknowledged: { acknowledgements.append($0) }, failed: { failed = true })
        pump.start(ticks: 0, revision: 1)
        try await waitUntil { sender.received.count == 1 }
        sender.succeed()
        try await waitUntil { pump.outstandingCount == 0 }

        pump.progress(ticks: 100, paused: false, revision: 2)
        try await waitUntil { sender.received.count == 2 }
        for index in 1...20 {
            pump.progress(ticks: Int64(1000 - index), paused: index == 20, revision: index + 2)
            XCTAssertLessThanOrEqual(pump.outstandingCount, 2)
        }
        XCTAssertEqual(sender.received.count, 2, "A delayed sender must not launch one write per seek")
        sender.succeed()
        try await waitUntil { sender.received.count == 3 }
        XCTAssertEqual(sender.received[2].ticks, 980)
        XCTAssertTrue(sender.received[2].paused)

        // A second burst arrives while the coalesced request is still in flight.
        for index in 1...20 { pump.progress(ticks: Int64(index), paused: false, revision: index + 22) }
        let stop = Task { await pump.stop(ticks: 7, revision: 43) }
        try await waitUntil { pump.stopping }
        XCTAssertEqual(pump.outstandingCount, 2)
        sender.succeed()
        try await waitUntil { sender.received.count == 4 }
        XCTAssertEqual(sender.received[3].kind, .stop)
        XCTAssertEqual(sender.received[3].ticks, 7, "Stop must keep the final backward-seek position, not the largest historical position")
        sender.succeed()
        await stop.value

        XCTAssertEqual(sender.received.map(\.kind), [.start, .progress, .progress, .stop])
        XCTAssertEqual(acknowledgements.count, 4)
        XCTAssertFalse(failed)
        XCTAssertTrue(pump.finished)
        XCTAssertEqual(pump.outstandingCount, 0)
    }

    @MainActor
    func testStopCannotOvertakeDelayedStartAndDiscardsUnsentProgress() async throws {
        let sender = GatedPlaybackSender()
        let pump = PlaybackReportPump(send: sender.send, acknowledged: { _ in }, failed: {})
        pump.start(ticks: 70, revision: 1)
        try await waitUntil { sender.received.count == 1 }
        for index in 1...20 { pump.progress(ticks: Int64(index), paused: false, revision: index + 1) }
        let stop = Task { await pump.stop(ticks: 8, revision: 22) }
        try await waitUntil { pump.stopping }
        XCTAssertEqual(sender.received.count, 1)
        sender.succeed()
        try await waitUntil { sender.received.count == 2 }
        XCTAssertEqual(sender.received.map(\.kind), [.start, .stop])
        XCTAssertEqual(sender.received[1].ticks, 8)
        sender.succeed()
        await stop.value
        XCTAssertTrue(pump.finished)
    }

    @MainActor
    func testUncertainWriteDropsPendingEventsAndNeverWritesAgain() async throws {
        let sender = GatedPlaybackSender()
        var failureCount = 0
        let pump = PlaybackReportPump(send: sender.send, acknowledged: { _ in }, failed: { failureCount += 1 })
        pump.start(ticks: 0, revision: 1)
        try await waitUntil { sender.received.count == 1 }
        for index in 1...20 { pump.progress(ticks: Int64(index), paused: false, revision: index + 1) }
        let stop = Task { await pump.stop(ticks: 4, revision: 22) }
        try await waitUntil { pump.stopping }
        sender.fail()
        await stop.value
        pump.progress(ticks: 900, paused: false, revision: 23)
        pump.start(ticks: 900, revision: 24)
        await pump.stop(ticks: 900, revision: 25)
        XCTAssertEqual(sender.received.count, 1)
        XCTAssertEqual(failureCount, 1)
        XCTAssertTrue(pump.uncertain)
        XCTAssertEqual(pump.outstandingCount, 0)
    }

    @MainActor
    func testFailedLocalSaveNeverClaimsProgressIsSafelyStored() throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!, serverID: "server", userID: "user", username: "name")
        let client = MediaServerClient(connection: connection, token: "", deviceID: "test")
        var writes: [(Int64, Bool)] = []
        var saveSucceeds = false
        let controller = NativePlaybackController(item: item, connection: connection, client: client) { ticks, confirmed in
            writes.append((ticks, confirmed)); return saveSucceeds
        }
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.requestedMode, .automatic)
        XCTAssertFalse(controller.persistSnapshot(ticks: 50, confirmed: false))
        XCTAssertTrue(controller.syncMessage.contains("本机进度保存失败"))
        controller.markUncertain()
        XCTAssertTrue(controller.syncMessage.contains("本机进度保存失败"))
        XCTAssertFalse(controller.syncMessage.contains("仅保存在本机"))
        saveSucceeds = true
        XCTAssertTrue(controller.persistSnapshot(ticks: 75, confirmed: false))
        controller.markUncertain()
        XCTAssertTrue(controller.syncMessage.contains("仅保存在本机"))
        XCTAssertEqual(writes.map(\.0), [50, 75])
    }

    @MainActor
    func testFailedFinalSnapshotCanBeRetriedAfterDiskRecoversWithoutServerReplay() async throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"episode","Name":"Test","Type":"Episode"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!, serverID: "server", userID: "user", username: "name")
        var writes: [(Int64, Bool)] = []
        var succeeds = false
        let controller = NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test")) { ticks, confirmed in
            writes.append((ticks, confirmed)); return succeeds
        }
        // Final position can be less than an earlier snapshot after a backward seek.
        XCTAssertFalse(controller.persistSnapshot(ticks: 900_000_000, confirmed: false))
        XCTAssertFalse(controller.persistSnapshot(ticks: 750_000_000, confirmed: false))
        controller.markUncertain()
        await controller.stop()
        XCTAssertFalse(controller.recoverProgressForEpisodeSwitch())
        XCTAssertTrue(controller.episodeProgressAtRisk)
        succeeds = true
        XCTAssertTrue(controller.recoverProgressForEpisodeSwitch())
        XCTAssertFalse(controller.episodeProgressAtRisk)
        XCTAssertEqual(writes.map(\.0), [900_000_000, 750_000_000, 750_000_000, 750_000_000])
        XCTAssertTrue(writes.allSatisfy { !$0.1 }, "A local retry must keep the server record unconfirmed")
        XCTAssertTrue(controller.syncMessage.contains("仅保存在本机"))
        XCTAssertTrue(controller.recoverProgressForEpisodeSwitch())
        XCTAssertEqual(writes.count, 4, "A durable snapshot is not repeatedly written")
    }

    @MainActor
    func testQueuedEOFCannotCancelAnAcceptedManualSelection() async throws {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"episode","Name":"Test","Type":"Episode"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "Test", baseURL: URL(string: "https://example.test")!, serverID: "server", userID: "user", username: "name")
        let controller = NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test")) { _, _ in true }
        let selection = controller.beginEpisodeSwitch()
        await controller.completeNaturally()
        XCTAssertTrue(controller.isEpisodeSwitchCurrent(selection))
        XCTAssertTrue(controller.isActive, "Queued EOF leaves teardown to the accepted selection")
        await controller.stop(forEpisodeSwitch: selection)
        XCTAssertTrue(controller.isEpisodeSwitchCurrent(selection))
        XCTAssertFalse(controller.isActive)
        await controller.stop()
        XCTAssertFalse(controller.isEpisodeSwitchCurrent(selection), "An explicit close/stop must still cancel it")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("A controlled playback write did not arrive")
    }
}

@MainActor
private final class GatedPlaybackSender {
    private(set) var received: [PlaybackWrite] = []
    private var waiting: CheckedContinuation<Void, Error>?

    func send(_ write: PlaybackWrite) async throws {
        XCTAssertNil(waiting, "Only one network write may be active")
        received.append(write)
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func succeed() { let continuation = waiting; waiting = nil; continuation?.resume() }
    func fail() { let continuation = waiting; waiting = nil; continuation?.resume(throwing: URLError(.timedOut)) }
}
