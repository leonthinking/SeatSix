import XCTest
@testable import SeatSixProbe

@MainActor
final class SubtitleSettingsProbeTests: XCTestCase {
    func testDelaySamplesProveBothDirectionsWithoutSeekingPastMedia() throws {
        for (original, duration) in [(0.0, 100.0), (40, 100), (98, 100), (-20, 14), (.nan, 100)] {
            let sample = try XCTUnwrap(SubtitleSettingsProbe.delaySample(original: original, duration: duration))
            XCTAssertGreaterThanOrEqual(sample.early, 0)
            XCTAssertLessThan(sample.late, duration - 1)
            let cue = sample.cueStart...sample.cueEnd
            XCTAssertFalse(cue.contains(sample.early))
            XCTAssertFalse(cue.contains(sample.late))
            // Positive mpv delay displays the earlier subtitle time; negative
            // delay displays a cue before its original timestamp.
            XCTAssertTrue(cue.contains(sample.early - (-sample.amount)))
            XCTAssertTrue(cue.contains(sample.late - sample.amount))
            XCTAssertLessThanOrEqual(sample.amount, 30)
        }
    }

    func testDelaySamplesRejectUnknownOrTooShortDuration() {
        for duration in [0.0, -1, 13.99, .nan, .infinity] {
            XCTAssertNil(SubtitleSettingsProbe.delaySample(original: 20, duration: duration))
        }
    }

    func testArtificialSubtitleTimestampsRoundAcrossSecondBoundary() {
        XCTAssertEqual(SubtitleSettingsProbe.srtTimestamp(0), "00:00:00,000")
        XCTAssertEqual(SubtitleSettingsProbe.srtTimestamp(59.9996), "00:01:00,000")
        XCTAssertEqual(SubtitleSettingsProbe.srtTimestamp(3661.234), "01:01:01,234")
        XCTAssertEqual(SubtitleSettingsProbe.srtTimestamp(.nan), "00:00:00,000")
        XCTAssertEqual(SubtitleSettingsProbe.srtTimestamp(-5), "00:00:00,000")
    }

    func testBitmapEvidenceDoesNotClaimTextStyleSupport() {
        XCTAssertTrue(SubtitleSettingsProbe.isBitmap(codec: "HDMV_PGS_SUBTITLE"))
        XCTAssertTrue(SubtitleSettingsProbe.isBitmap(codec: "dvd_subtitle"))
        XCTAssertFalse(SubtitleSettingsProbe.isBitmap(codec: "ass"))
        XCTAssertFalse(SubtitleSettingsProbe.isBitmap(codec: "subrip"))
        XCTAssertFalse(SubtitleSettingsProbe.isBitmap(codec: nil))
        let bitmap = embedded(kind: "bitmap", delay: true, fontApplicable: false, textPassed: nil)
        XCTAssertTrue(passed([bitmap]))
        XCTAssertFalse(passed([embedded(kind: "bitmap", delay: true, fontApplicable: true, textPassed: true)]))
        XCTAssertFalse(passed([embedded(kind: "bitmap", delay: false, fontApplicable: false, textPassed: nil)]))
    }

    func testDelayEvidenceAcceptsChangedAndHiddenCuesOnlyWithExactReset() {
        XCTAssertEqual(SubtitleSettingsProbe.delayEvidence(clean: "video", original: "cue A", delayed: "video", restored: "cue A"), "cue_hidden")
        XCTAssertEqual(SubtitleSettingsProbe.delayEvidence(clean: "video", original: "cue A", delayed: "cue B", restored: "cue A"), "cue_changed")
        XCTAssertNil(SubtitleSettingsProbe.delayEvidence(clean: "video", original: "cue A", delayed: "cue A", restored: "cue A"))
        XCTAssertNil(SubtitleSettingsProbe.delayEvidence(clean: "video", original: "cue A", delayed: "cue B", restored: "other frame"))
        XCTAssertNil(SubtitleSettingsProbe.delayEvidence(clean: "video", original: "video", delayed: "cue B", restored: "video"))
    }

    func testAStaticCueOrPropertyAcknowledgmentDoesNotStopDelayScan() {
        XCTAssertFalse(SubtitleSettingsProbe.hasDelayEvidence(["delayVerified": true]))
        XCTAssertFalse(SubtitleSettingsProbe.hasDelayEvidence(["delayVerified": true, "delayEvidence": "property_acknowledged"]))
        XCTAssertFalse(SubtitleSettingsProbe.hasDelayEvidence(["delayVerified": false, "delayEvidence": "cue_changed"]))
        XCTAssertTrue(SubtitleSettingsProbe.hasDelayEvidence(["delayVerified": true, "delayEvidence": "cue_changed"]))
        XCTAssertTrue(SubtitleSettingsProbe.hasDelayEvidence(["delayVerified": true, "delayEvidence": "cue_hidden"]))
    }

    func testSummaryRequiresActualRenderingAndEveryIndependentPresentationProbe() {
        let text = embedded(kind: "text", delay: true, fontApplicable: true, textPassed: true)
        XCTAssertTrue(passed([text]))
        XCTAssertFalse(passed([]))
        XCTAssertFalse(passed([["selected": true]]))
        XCTAssertFalse(passed([embedded(kind: "text", delay: true, fontApplicable: true, textPassed: false)]))
        XCTAssertFalse(passed([embedded(kind: "text", delay: true, fontApplicable: true, textPassed: nil)]))
        XCTAssertFalse(SubtitleSettingsProbe.presentationPassed(embedded: [text], externalText: ["passed": false], artificialDelay: ["passed": true]))
        XCTAssertFalse(SubtitleSettingsProbe.presentationPassed(embedded: [text], externalText: ["passed": true], artificialDelay: ["passed": false]))
        var missingRender = text
        missingRender["renderVerified"] = false
        XCTAssertFalse(passed([missingRender]))
    }

    private func embedded(kind: String, delay: Bool, fontApplicable: Bool, textPassed: Bool?) -> [String: Any] {
        var presentation: [String: Any] = ["kind": kind, "delayVerified": delay,
                                           "fontSizeApplicable": fontApplicable, "pausedPositionPreserved": true,
                                           "delayEvidence": "cue_hidden"]
        if let textPassed { presentation["textRendering"] = ["passed": textPassed] }
        return ["renderVerified": true, "presentation": presentation]
    }

    private func passed(_ embedded: [[String: Any]]) -> Bool {
        SubtitleSettingsProbe.presentationPassed(embedded: embedded, externalText: ["passed": true], artificialDelay: ["passed": true])
    }
}
