import AppKit
import AVFoundation
import XCTest
import SeatSixCore
@testable import SeatSixApp

/// Compatibility playback has native AVPlayer controls that can change state while
/// a skip seek is pending. The seek completion must not override that newer intent.
@MainActor
final class SeriesSkipCompatibilityTests: XCTestCase {
    @MainActor
    private final class SuspendedSeek {
        let started = XCTestExpectation(description: "Seek callback installed")
        private(set) var requestedSeconds: Double?
        private var result: Bool?
        private var completion: CheckedContinuation<Bool, Never>?

        func seek(_ player: AVPlayer, seconds: Double) async -> Bool {
            requestedSeconds = seconds
            return await withCheckedContinuation { continuation in
                if let result { continuation.resume(returning: result) }
                else { completion = continuation }
                started.fulfill()
            }
        }

        func finish(_ succeeded: Bool) {
            guard result == nil else { return }
            result = succeeded
            let waiting = completion
            completion = nil
            waiting?.resume(returning: succeeded)
        }
    }

    private func controller(seek: SuspendedSeek) throws -> NativePlaybackController {
        let item = try JSONDecoder().decode(MediaItem.self, from: Data(
            "{\"Id\":\"e1\",\"Name\":\"Test\",\"Type\":\"Episode\",\"SeriesId\":\"show\"}".utf8))
        let connection = ServerConnection(kind: .emby, name: "test",
            baseURL: URL(string: "https://example.test")!, serverID: "s", userID: "u", username: "test")
        let owner = NativePlaybackController(item: item, connection: connection,
            client: MediaServerClient(connection: connection, token: "", deviceID: "test"),
            compatibilitySeek: { player, seconds in await seek.seek(player, seconds: seconds) },
            save: { _, _ in true })
        owner.preparing = false
        return owner
    }

    func testSupersededNativeSeekDoesNotFailStopOrCompletePlayback() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        // AVPlayer returns false when a newer native scrub supersedes this seek.
        pending.finish(false)
        await work.value
        await Task.yield()
        XCTAssertEqual(pending.requestedSeconds, 11.5)
        XCTAssertTrue(owner.isActive)
        XCTAssertNil(owner.errorMessage)
        XCTAssertNil(owner.seriesSkipMessage)
        XCTAssertFalse(owner.canAutomaticallyContinue)
        XCTAssertEqual(completions, 0)
        await owner.stop()
    }

    func testNativePauseDuringSeekRemainsPausedAfterSuccessfulSeek() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await prepare(owner.player, url: movie)
        owner.player.playImmediately(atRate: 1)
        XCTAssertEqual(owner.player.rate, 1)
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        owner.player.pause()
        pending.finish(true)
        await work.value
        XCTAssertEqual(owner.player.rate, 0, "Completing a skip must not undo a native pause")
        XCTAssertEqual(owner.seriesSkipMessage, "已跳过片尾")
        XCTAssertTrue(owner.isActive)
        await owner.stop()
    }

    func testNativeRateChangeDuringSeekIsPreserved() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await prepare(owner.player, url: movie)
        owner.player.playImmediately(atRate: 1)
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        owner.player.playImmediately(atRate: 1.5)
        XCTAssertEqual(owner.player.rate, 1.5)
        pending.finish(true)
        await work.value
        XCTAssertEqual(owner.player.rate, 1.5, "Completing a skip must not reset native playback speed")
        XCTAssertEqual(owner.seriesSkipMessage, "已跳过片尾")
        await owner.stop()
    }

    func testCloseWhileSeekPendingCannotResumeOrPublishLateSuccess() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await prepare(owner.player, url: movie)
        owner.player.playImmediately(atRate: 1)
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        await owner.stop()
        pending.finish(true)
        await work.value
        XCTAssertFalse(owner.isActive)
        XCTAssertNil(owner.player.currentItem)
        XCTAssertEqual(owner.player.rate, 0)
        XCTAssertNil(owner.seriesSkipMessage)
        XCTAssertNil(owner.errorMessage)
        XCTAssertEqual(completions, 0)
    }

    func testManualEpisodeSelectionWhileSeekPendingOwnsTransition() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await prepare(owner.player, url: movie)
        owner.player.playImmediately(atRate: 1)
        var completions = 0
        owner.onNaturalCompletion = { _ in completions += 1 }
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        let selection = owner.beginEpisodeSwitch()
        owner.player.pause()
        pending.finish(true)
        await work.value
        XCTAssertTrue(owner.isEpisodeSwitchCurrent(selection))
        XCTAssertTrue(owner.switchingEpisode)
        XCTAssertEqual(owner.player.rate, 0)
        XCTAssertNil(owner.seriesSkipMessage)
        XCTAssertNil(owner.errorMessage)
        XCTAssertFalse(owner.canAutomaticallyContinue)
        XCTAssertEqual(completions, 0)
        await owner.stop(forEpisodeSwitch: selection)
    }

    func testCancelledSkipDoesNotOverrideNativePause() async throws {
        let pending = SuspendedSeek()
        let owner = try controller(seek: pending)
        let (directory, movie) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await prepare(owner.player, url: movie)
        owner.player.playImmediately(atRate: 1)
        let work = Task { await owner.performOutroSkip(to: 11.5) }
        try await waitForSeek(pending)
        work.cancel()
        owner.player.pause()
        pending.finish(true)
        await work.value
        XCTAssertEqual(owner.player.rate, 0)
        XCTAssertNil(owner.seriesSkipMessage)
        XCTAssertNil(owner.errorMessage)
        XCTAssertTrue(owner.isActive)
        await owner.stop()
    }

    func testFinishingBeforeSeekStartsDoesNotStrandPendingWork() async {
        let pending = SuspendedSeek()
        pending.finish(false)
        let returned = expectation(description: "Seek completed with the earlier result")
        Task {
            let result = await pending.seek(AVPlayer(), seconds: 11.5)
            XCTAssertFalse(result)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
    }

    private func waitForSeek(_ seek: SuspendedSeek) async throws {
        let status = await XCTWaiter.fulfillment(of: [seek.started], timeout: 5)
        guard status == .completed else {
            seek.finish(false)
            throw NSError(domain: "SeriesSkipCompatibilityTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the seek callback"])
        }
    }

    private func prepare(_ player: AVPlayer, url: URL) async throws {
        _ = NSApplication.shared
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let deadline = Date().addingTimeInterval(5)
        while item.status == .unknown, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item.status, .readyToPlay, "The local MP4 must be ready so rate assertions exercise AVPlayer")
        if let error = item.error { throw error }
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("compatibility.mp4")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
            "color=c=navy:size=320x180:rate=24", "-t", "12", "-c:v", "libx264",
            "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-movflags", "+faststart", movie.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            throw NSError(domain: "SeriesSkipCompatibilityTests", code: 1)
        }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SeriesSkipCompatibilityTests", code: 2)
        }
        return (directory, movie)
    }
}
