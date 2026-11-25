import AppKit
import XCTest
@testable import SeatSixPlayback

@MainActor
final class LocalChapterTests: XCTestCase {
    func testEmbeddedChaptersUpdateWhenMediaChangesAndClearOnShutdown() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = directory.appendingPathComponent("chapter.txt")
        try """
        ;FFMETADATA1
        [CHAPTER]
        TIMEBASE=1/1000
        START=0
        END=1000
        title=Opening
        [CHAPTER]
        TIMEBASE=1/1000
        START=1000
        END=2000
        title=Finale
        """.write(to: metadata, atomically: true, encoding: .utf8)
        let chaptered = directory.appendingPathComponent("chaptered.mp4")
        let plain = directory.appendingPathComponent("plain.mp4")
        try makeMedia(["-f","lavfi","-i","testsrc2=size=160x90:rate=24","-i",metadata.path,
                       "-t","2","-c:v","libx264","-map","0:v","-map_metadata","1","-map_chapters","1",chaptered.path])
        try makeMedia(["-i",chaptered.path,"-map","0:v","-c:v","copy","-map_chapters","-1",plain.path])
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        try await engine.load(url: chaptered)
        XCTAssertEqual(engine.snapshot.chapters.map(\.start), [0, 1])
        XCTAssertEqual(engine.snapshot.chapters.map(\.title), ["Opening", "Finale"])
        XCTAssertGreaterThan(try engine.thumbnailImage().size.width, 0)
        try await engine.load(url: plain)
        XCTAssertTrue(engine.snapshot.chapters.isEmpty)
        try await engine.load(url: chaptered)
        XCTAssertEqual(engine.snapshot.chapters.count, 2)
        engine.shutdown()
        XCTAssertTrue(engine.snapshot.chapters.isEmpty)
        XCTAssertThrowsError(try engine.thumbnailImage())
    }

    private func makeMedia(_ args: [String]) throws {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        command.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error"] + args
        try command.run()
        command.waitUntilExit()
        XCTAssertEqual(command.terminationStatus, 0)
    }
}

