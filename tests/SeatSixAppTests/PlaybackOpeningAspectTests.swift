import AppKit
import AVFoundation
import XCTest
import SeatSixCore
import SeatSixPlayback
@testable import SeatSixApp

@MainActor
final class PlaybackOpeningAspectTests: XCTestCase {
    private func item(sources: [[String: Any]] = [], streams: [[String: Any]] = []) throws -> MediaItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "Id": "movie", "Type": "Movie", "MediaSources": sources, "MediaStreams": streams,
            "PrimaryImageAspectRatio": 0.6667
        ])
        return try JSONDecoder().decode(MediaItem.self, from: data)
    }

    func testOpeningHintUsesSelectedVideoEditionAndRejectsMalformedAspects() throws {
        func hint(_ item: MediaItem, _ sourceID: String? = nil) -> CGFloat? {
            item.playbackAspectRatio(for: sourceID) { _ in true }
        }
        let wide = ["Type": "Video", "Width": 720, "Height": 576, "AspectRatio": " 16 : 9 "] as [String: Any]
        let tall = ["Type": "Video", "Width": 1080, "Height": 1920] as [String: Any]
        let sources: [[String: Any]] = [
            ["Id": "wide", "MediaStreams": [["Type": "Audio", "AspectRatio": "1:1"], wide]],
            ["Id": "tall", "MediaStreams": [tall]]
        ]
        let editions = try item(sources: sources, streams: [wide])
        XCTAssertEqual(hint(editions, "wide"), 16.0 / 9)
        XCTAssertEqual(hint(editions, "tall"), 9.0 / 16)
        XCTAssertNil(hint(editions, "unknown"))
        XCTAssertNil(hint(editions))
        XCTAssertEqual(hint(try item(sources: [sources[0]])), 16.0 / 9)
        let fallback: CGFloat = 9.0 / 16
        let examples: [(String, CGFloat)] = [("2.39", 2.39), ("4/3", 4.0 / 3), ("1:0", fallback),
                                             ("2:3:4", fallback), ("NaN", fallback), ("1e999", fallback)]
        for (value, expected) in examples {
            var video = tall
            video["AspectRatio"] = value
            XCTAssertEqual(hint(try item(streams: [video])), expected)
        }
        XCTAssertNil(hint(try item()), "The poster ratio does not describe the video")
    }

    func testUnrepresentableWindowHintFallsBackToVideoDimensionsOrDefault() throws {
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(fileURLWithPath: "/"),
                                          serverID: "server", userID: "user", username: "test")
        let client = MediaServerClient(connection: connection, token: "fixture", deviceID: "fixture")
        for value in ["1e308", "1e-308"] {
            for hasDimensions in [true, false] {
                var stream: [String: Any] = ["Type": "Video", "AspectRatio": value]
                if hasDimensions { stream["Width"] = 1440; stream["Height"] = 1080 }
                let controller = NativePlaybackController(item: try item(streams: [stream]), connection: connection,
                                                          client: client) { _, _ in true }
                let owner = PlaybackWindowController(controller: controller, openingScreen: screen,
                                                     onClosing: { _ in }, onClose: { _ in })
                let window = try XCTUnwrap(owner.window)
                let content = window.contentRect(forFrameRect: window.frame)
                XCTAssertEqual(content.width / content.height, hasDimensions ? 4.0 / 3 : 16.0 / 9, accuracy: 0.01)
                window.delegate = nil
                owner.close()
            }
        }
    }

    func testBothPlayerEnginesResolveOpeningFrameOnceFromTheRenderedVideo() async throws {
        _ = NSApplication.shared
        let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: movie) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=size=192x320:rate=24",
                             "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", movie.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let media = try item(streams: [["Type": "Video", "AspectRatio": "16:9"]])
        let connection = ServerConnection(kind: .emby, name: "test", baseURL: URL(fileURLWithPath: "/"),
                                          serverID: "server", userID: "user", username: "test", libraryIDs: [])
        let client = MediaServerClient(connection: connection, token: "fixture", deviceID: "fixture")
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        for useLocalEngine in [true, false] {
            let controller = NativePlaybackController(item: media, connection: connection, client: client) { _, _ in true }
            let owner = PlaybackWindowController(controller: controller, openingScreen: screen,
                                                 onClosing: { _ in }, onClose: { _ in })
            let window = try XCTUnwrap(owner.window)
            defer { window.delegate = nil; owner.close() }
            func assertFrame(_ aspect: CGFloat, line: UInt = #line) throws {
                let frame = window.frame
                let title = frame.height - window.contentRect(forFrameRect: frame).height
                let expected = try XCTUnwrap(PlaybackWindowGeometry.openingFrame(aspectRatio: aspect,
                                                                                  titleBarHeight: title, screen: screen))
                XCTAssertEqual(frame.width, expected.width, accuracy: 1, line: line)
                XCTAssertEqual(frame.height, expected.height, accuracy: 1, line: line)
                XCTAssertEqual(frame.midX, expected.midX, accuracy: 1, line: line)
                XCTAssertEqual(frame.midY, expected.midY, accuracy: 1, line: line)
                window.contentView?.layoutSubtreeIfNeeded()
                let videoArea = try XCTUnwrap(window.contentView?.bounds, line: line)
                XCTAssertEqual(videoArea.width, videoArea.height * aspect, accuracy: 2, line: line)
                XCTAssertLessThanOrEqual(window.minSize.width, frame.width + 0.5, line: line)
                XCTAssertLessThanOrEqual(window.minSize.height, frame.height + 0.5, line: line)
            }
            func resolveVideo(_ current: NativePlaybackController) async throws {
                if useLocalEngine {
                    let engine = try LocalPlaybackEngine()
                    try await engine.load(url: movie)
                    await current.restorePreferences(engine: engine, mediaSourceID: "fixture")
                } else {
                    current.player.replaceCurrentItem(with: AVPlayerItem(url: movie))
                }
                current.preparing = false
                let deadline = Date().addingTimeInterval(5)
                while current.onOpeningAspectRatio != nil, Date() < deadline {
                    current.sample()
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertNil(current.onOpeningAspectRatio)
            }
            try assertFrame(16.0 / 9)
            try await resolveVideo(controller)
            try assertFrame(192.0 / 320)
            let manual = window.frame.offsetBy(dx: 12, dy: 0)
            window.setFrame(manual, display: false)
            controller.sample()
            XCTAssertEqual(window.frame, manual)
            // Switching episodes preserves the manual frame. An explicit reset
            // while the next decoder is preparing must accept its eventual ratio.
            let next = NativePlaybackController(item: media, connection: connection, client: client) { _, _ in true }
            owner.replaceController(next)
            XCTAssertEqual(window.frame, manual)
            XCTAssertNil(next.onOpeningAspectRatio)
            owner.resetGeometry()
            try assertFrame(16.0 / 9)
            XCTAssertNotNil(next.onOpeningAspectRatio)
            try await resolveVideo(next)
            try assertFrame(192.0 / 320)
            await controller.stop()
            await next.stop()
        }
    }
}
