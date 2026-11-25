import XCTest
import SeatSixCore
@testable import SeatSixApp

@MainActor
final class PlaybackVolumeControllerTests: XCTestCase {
    func testInitialMutedVolumeDoesNotSaveAndUnmuteRestoresListeningLevel() async throws {
        let controller = try makeController()
        var changes: [PlaybackVolumeState] = []
        controller.onVolumeChange = { changes.append($0) }
        controller.applyInitialVolume(.init(volume: 0, isMuted: true, volumeBeforeMute: 0.28))
        XCTAssertEqual(controller.volume, 0)
        XCTAssertEqual(Double(controller.player.volume), 0.28, accuracy: 0.0001)
        XCTAssertTrue(controller.player.isMuted)
        XCTAssertTrue(changes.isEmpty)
        controller.toggleMute()
        XCTAssertEqual(controller.volume, 0.28, accuracy: 0.0001)
        XCTAssertEqual(Double(controller.player.volume), 0.28, accuracy: 0.0001)
        XCTAssertFalse(controller.player.isMuted)
        XCTAssertEqual(changes.count, 1)
        controller.toggleMute()
        XCTAssertEqual(changes.last?.volume, 0)
        XCTAssertEqual(try XCTUnwrap(changes.last?.volumeBeforeMute), 0.28, accuracy: 0.0001)
        await controller.stop()
        controller.setVolume(0.8)
        XCTAssertEqual(changes.count, 2, "Stopped controllers must not overwrite a newer session's volume")
    }

    func testCompatibilitySystemControlsReportActualVolumeAndMuteState() async throws {
        let controller = try makeController()
        var changes: [PlaybackVolumeState] = []
        controller.onVolumeChange = { changes.append($0) }
        controller.applyInitialVolume(.init(volume: 0.4, isMuted: false, volumeBeforeMute: 0.4))
        // Let initial KVO assignments finish while the controller is preparing.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(changes.isEmpty)
        controller.preparing = false
        controller.player.volume = 0.23
        controller.player.isMuted = true
        for _ in 0..<10 { await Task.yield() }
        let muted = try XCTUnwrap(changes.last)
        XCTAssertEqual(muted.volume, 0.23, accuracy: 0.0001)
        XCTAssertTrue(muted.isMuted)
        XCTAssertEqual(muted.volumeBeforeMute, 0.23, accuracy: 0.0001)
        XCTAssertEqual(controller.volume, 0)
        let next = try makeController()
        next.inheritContinuationVolume(from: controller)
        XCTAssertEqual(next.volume, 0)
        XCTAssertTrue(next.player.isMuted)
        next.toggleMute()
        XCTAssertEqual(next.volume, 0.23, accuracy: 0.0001)
        await controller.stop()
        let count = changes.count
        controller.player.volume = 0.9
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(changes.count, count)
        await next.stop()
    }

    func testSavedLocalMuteCanBeUnmutedUsingCompatibilitySystemControl() async throws {
        let local = try makeController()
        local.setVolume(0.35)
        local.toggleMute()
        let saved = local.volumeState
        XCTAssertEqual(saved.volume, 0)
        XCTAssertTrue(saved.isMuted)
        XCTAssertEqual(saved.volumeBeforeMute, 0.35, accuracy: 0.0001)

        let compatibility = try makeController()
        var changes: [PlaybackVolumeState] = []
        compatibility.onVolumeChange = { changes.append($0) }
        compatibility.applyInitialVolume(saved)
        XCTAssertEqual(compatibility.volume, 0, "The restored session remains silent until explicitly unmuted")
        XCTAssertTrue(compatibility.player.isMuted)
        XCTAssertEqual(Double(compatibility.player.volume), 0.35, accuracy: 0.0001)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(changes.isEmpty)
        compatibility.preparing = false
        // This is the system AVPlayerView action, which does not change volume.
        compatibility.player.isMuted = false
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(compatibility.volume, 0.35, accuracy: 0.0001)
        XCTAssertEqual(compatibility.volumeState.volume, 0.35, accuracy: 0.0001)
        XCTAssertFalse(compatibility.volumeState.isMuted)
        XCTAssertEqual(try XCTUnwrap(changes.last).volume, 0.35, accuracy: 0.0001)
        XCTAssertFalse(try XCTUnwrap(changes.last).isMuted)
        await local.stop()
        await compatibility.stop()
    }

    func testCompatibilityVolumeChangeImmediatelyBeforeStopIsNotLost() async throws {
        let controller = try makeController()
        var changes: [PlaybackVolumeState] = []
        controller.onVolumeChange = { changes.append($0) }
        controller.applyInitialVolume(.init(volume: 0.4, isMuted: false, volumeBeforeMute: 0.4))
        controller.preparing = false
        // No suspension between the system control mutation and stop: queued KVO
        // work cannot be relied on to publish the final listening level.
        controller.player.volume = 0.25
        await controller.stop()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(try XCTUnwrap(changes.last).volume, 0.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(changes.last).volumeBeforeMute, 0.25, accuracy: 0.0001)
        XCTAssertFalse(try XCTUnwrap(changes.last).isMuted)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(changes.count, 1)
    }

    func testStopDuringPreparationDoesNotSaveUnchangedInitialDefaults() async throws {
        for initial in [PlaybackVolumeState(), .init(volume: 0, isMuted: true, volumeBeforeMute: 0.35)] {
            let controller = try makeController()
            var changes: [PlaybackVolumeState] = []
            controller.onVolumeChange = { changes.append($0) }
            controller.applyInitialVolume(initial)
            await controller.stop()
            XCTAssertTrue(changes.isEmpty)
        }
    }

    private func makeController() throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Test","Type":"Movie"}"#.utf8))
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        return NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test")) { _, _ in true }
    }
}
