import Foundation
import XCTest
@testable import RecorderApp

final class RecordingControllerPresentationTests: XCTestCase {
    func testHiddenWhenRecordingIsInactive() {
        let presentation = makePresentation(
            isRecording: false,
            startedAt: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertFalse(presentation.isVisible)
    }

    func testActiveRecordingShowsRecordingStateAndEnablesStop() {
        let presentation = makePresentation(
            isRecording: true,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(presentation.title, "Recording")
        XCTAssertFalse(presentation.stopDisabled)
    }

    func testFinalizingShowsFinalizingStateAndDisablesStop() {
        let presentation = makePresentation(
            isRecording: true,
            isFinalizing: true,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.title, "Finalizing")
        XCTAssertTrue(presentation.stopDisabled)
    }

    func testElapsedTimeUsesWholeNonNegativeHoursMinutesAndSeconds() {
        XCTAssertEqual(
            makePresentation(
                isRecording: true,
                startedAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 100)
            ).elapsedText,
            "00:00:00"
        )
        XCTAssertEqual(
            makePresentation(
                isRecording: true,
                startedAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 3_761.9)
            ).elapsedText,
            "01:01:01"
        )
        XCTAssertEqual(
            makePresentation(
                isRecording: true,
                startedAt: Date(timeIntervalSince1970: 200),
                now: Date(timeIntervalSince1970: 100)
            ).elapsedText,
            "00:00:00"
        )
    }

    func testNonTeamsSourceShowsUnavailableAndDisablesScreenToggle() {
        let presentation = makePresentation(
            isRecording: true,
            showsTeamsScreenControl: false,
            screenStatusText: TeamsScreenStatusText.capturing,
            screenToggleDisabled: false
        )

        XCTAssertEqual(
            presentation.screenStatusText,
            "Teams screen unavailable"
        )
        XCTAssertEqual(presentation.screenTone, .warning)
        XCTAssertTrue(presentation.screenToggleDisabled)
    }

    func testTeamsScreenStatusesMapToExpectedTones() {
        let cases: [(String, RecordingControllerTone)] = [
            (TeamsScreenStatusText.off, .neutral),
            (TeamsScreenStatusText.ready, .ready),
            (TeamsScreenStatusText.capturing, .recording),
            (TeamsScreenStatusText.waiting, .warning),
            (TeamsScreenStatusText.awaitingFrames, .warning),
            (TeamsScreenStatusText.framesUnavailable, .warning),
            (TeamsScreenStatusText.reconnecting, .warning),
            (TeamsScreenStatusText.unavailable, .warning)
        ]

        for (status, expectedTone) in cases {
            let presentation = makePresentation(
                isRecording: true,
                screenStatusText: status
            )

            XCTAssertEqual(
                presentation.screenStatusText,
                status,
                "Unexpected status projection for \(status)"
            )
            XCTAssertEqual(
                presentation.screenTone,
                expectedTone,
                "Unexpected tone for \(status)"
            )
        }
    }

    func testRequestedUnavailableScreenCaptureCanStillBeTurnedOff() {
        let presentation = makePresentation(
            isRecording: true,
            screenRequested: true,
            screenStatusText: TeamsScreenStatusText.unavailable,
            screenToggleDisabled: false
        )

        XCTAssertTrue(presentation.screenRequested)
        XCTAssertFalse(presentation.screenToggleDisabled)
    }

    func testLifecycleGateExposesOnlyTheActiveOperation() {
        var gate = CaptureLifecycleGate()
        XCTAssertNil(gate.activeOperation)

        let token = gate.begin(.start)
        XCTAssertEqual(gate.activeOperation, .start)

        if let token {
            XCTAssertTrue(gate.finish(token))
        }
        XCTAssertNil(gate.activeOperation)
    }

    private func makePresentation(
        isRecording: Bool = false,
        isFinalizing: Bool = false,
        startedAt: Date? = nil,
        showsTeamsScreenControl: Bool = true,
        screenRequested: Bool = false,
        screenStatusText: String = TeamsScreenStatusText.off,
        screenToggleDisabled: Bool = false,
        now: Date = Date(timeIntervalSince1970: 0)
    ) -> RecordingControllerPresentation {
        RecordingControllerPresentation.make(
            snapshot: RecordingControllerSnapshot(
                isRecording: isRecording,
                isFinalizing: isFinalizing,
                startedAt: startedAt,
                showsTeamsScreenControl: showsTeamsScreenControl,
                screenRequested: screenRequested,
                screenStatusText: screenStatusText,
                screenToggleDisabled: screenToggleDisabled
            ),
            now: now
        )
    }
}
