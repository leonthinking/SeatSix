import AppKit
import XCTest
import SeatSixPlayback
@testable import SeatSixProbe

@MainActor
final class PlaybackExperienceProbeTests: XCTestCase {
    func testRemainingDurationBudgetIncludesEveryWarmupAndLongAcceptedSample() {
        let rates = PlaybackExperienceProbe.testedRates
        XCTAssertEqual(PlaybackExperienceProbe.requiredRemainingSeconds(for: rates), 80)
        for index in rates.indices {
            let remaining = Array(rates[index...])
            let worstPlayback = remaining.reduce(0, +) * (8 + 6)
            XCTAssertGreaterThan(PlaybackExperienceProbe.requiredRemainingSeconds(for: remaining), worstPlayback + 5)
        }
    }

    func testRateEvidenceRequiresMeasuredClockAndAudioOutputNotOnlyAcknowledgedProperty() {
        var evidence = measurement(rate: 2)
        XCTAssertTrue(evidence.passed)
        evidence.mediaAdvancedSeconds = evidence.wallSeconds
        XCTAssertFalse(evidence.passed, "A speed property of 2 with real-time playback is insufficient")
        evidence = measurement(rate: 2); evidence.audioAdvancedSeconds = 0
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 1); evidence.audioOutputPresent = false
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 1); evidence.pitchCorrectionEnabled = false
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 0.5); evidence.renderedFrames = 0
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 0.5); evidence.nonBlackPixelCount = 0
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 1.5); evidence.pausePreserved = false
        XCTAssertFalse(evidence.passed)
        evidence = measurement(rate: 1.5); evidence.seekPreserved = false
        XCTAssertFalse(evidence.passed)
    }

    func testRateEvidenceRejectsMissingCasesDuplicatesInvalidTimeAndLongStalls() {
        let complete = PlaybackExperienceProbe.testedRates.map(measurement(rate:))
        XCTAssertTrue(PlaybackExperienceProbe.measurementsPassed(complete))
        XCTAssertFalse(PlaybackExperienceProbe.measurementsPassed([]))
        XCTAssertFalse(PlaybackExperienceProbe.measurementsPassed(Array(complete.dropLast())))
        XCTAssertFalse(PlaybackExperienceProbe.measurementsPassed(complete + [complete[0]]))
        for value in [0, 1.9, 6.1, Double.nan, .infinity] {
            var evidence = measurement(rate: 1)
            evidence.wallSeconds = value
            XCTAssertFalse(evidence.passed)
        }
        var mismatched = measurement(rate: 1)
        mismatched.actualRate = 1.5
        XCTAssertFalse(mismatched.passed)
    }

    func testSyntheticActualClockProbeAtAllFourRates() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("motion.mkv")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "40", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", movie.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try runFixtureProcess(process)
        XCTAssertEqual(process.terminationStatus, 0)
        let engine = try LocalPlaybackEngine()
        defer { engine.shutdown() }
        engine.setVolume(0)
        try await engine.load(url: movie, startSeconds: 1)
        var results: [PlaybackExperienceProbe.RateMeasurement] = []
        for rate in PlaybackExperienceProbe.testedRates {
            let evidence = try await PlaybackExperienceProbe.measure(engine, rate: rate)
            XCTAssertTrue(evidence.passed, "Rate evidence: \(evidence.report)")
            results.append(evidence)
        }
        XCTAssertTrue(PlaybackExperienceProbe.measurementsPassed(results))
    }

    private func measurement(rate: Double) -> PlaybackExperienceProbe.RateMeasurement {
        .init(requestedRate: rate, actualRate: rate, wallSeconds: 2.5,
              mediaAdvancedSeconds: rate * 2.5, audioAdvancedSeconds: rate * 2.5,
              renderedFrames: 30, nonBlackPixelCount: 1000, audioOutputPresent: true,
              pitchCorrectionEnabled: true, pausePreserved: true, seekPreserved: true)
    }

    private func runFixtureProcess(_ process: Process) throws {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 30) == .success else {
            process.terminate()
            throw LocalPlaybackError.timeout
        }
    }
}
