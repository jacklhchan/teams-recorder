import XCTest
@testable import RecorderApp

@MainActor
final class TeamsAutoMeetingPresentationTests: XCTestCase {
    func testCountdownPresentationShowsRemainingSecondsAndCancel() {
        let presentation = TeamsAutoMeetingPresentation.make(
            state: .startCountdown(secondsRemaining: 3),
            connectionStatus: .inMeeting(muted: false)
        )

        XCTAssertEqual(presentation.title, "Recording starts in 3s")
        XCTAssertEqual(presentation.detail, "Teams meeting detected")
        XCTAssertEqual(presentation.systemImage, "record.circle")
        XCTAssertTrue(presentation.showsCancel)
    }

    func testDisconnectedWaitingPresentationDoesNotClaimMeetingEnded() {
        let presentation = TeamsAutoMeetingPresentation.make(
            state: .waitingForMeeting,
            connectionStatus: .waitingForTeamsAPI
        )

        XCTAssertEqual(presentation.title, "Teams API unavailable")
        XCTAssertEqual(
            presentation.detail,
            "Automatic recording remains armed"
        )
        XCTAssertEqual(
            presentation.systemImage,
            "exclamationmark.triangle.fill"
        )
        XCTAssertFalse(presentation.showsCancel)
    }

    func testEveryAutoMeetingStateHasTheExpectedPresentation() {
        let cases: [(
            TeamsAutoMeetingState,
            String,
            String,
            String,
            Bool
        )] = [
            (
                .disabled,
                "Off",
                "Automatic recording is disabled",
                "circle.dashed",
                false
            ),
            (
                .waitingForMeeting,
                "Waiting for meeting",
                "Automatic recording is armed",
                "clock",
                false
            ),
            (
                .startCountdown(secondsRemaining: 5),
                "Recording starts in 5s",
                "Teams meeting detected",
                "record.circle",
                true
            ),
            (
                .starting,
                "Starting recording",
                "Teams meeting detected",
                "record.circle",
                false
            ),
            (
                .automaticRecording,
                "Recording automatically",
                "Teams meeting in progress",
                "record.circle.fill",
                false
            ),
            (
                .stopCountdown(secondsRemaining: 7),
                "Stopping in 7s",
                "Confirming the meeting has ended",
                "stop.circle",
                false
            ),
            (
                .suppressedUntilMeetingEnd,
                "Cancelled for this meeting",
                "Automatic recording will re-arm after the meeting",
                "xmark.circle",
                false
            ),
            (
                .startBlocked("Microphone permission is required."),
                "Needs permission",
                "Microphone permission is required.",
                "exclamationmark.triangle.fill",
                false
            ),
            (
                .startFailed("Microphone unavailable"),
                "Start failed",
                "Microphone unavailable",
                "exclamationmark.triangle.fill",
                false
            ),
        ]

        for (
            state,
            expectedTitle,
            expectedDetail,
            expectedImage,
            expectedCancel
        ) in cases {
            let presentation = TeamsAutoMeetingPresentation.make(
                state: state,
                connectionStatus: .ready
            )

            XCTAssertEqual(presentation.title, expectedTitle)
            XCTAssertEqual(presentation.detail, expectedDetail)
            XCTAssertEqual(presentation.systemImage, expectedImage)
            XCTAssertEqual(presentation.showsCancel, expectedCancel)
        }
    }

    func testWaitingPresentationReflectsTeamsConnectionProgress() {
        let connecting = TeamsAutoMeetingPresentation.make(
            state: .waitingForMeeting,
            connectionStatus: .connecting
        )
        let awaitingApproval = TeamsAutoMeetingPresentation.make(
            state: .waitingForMeeting,
            connectionStatus: .waitingForPairingApproval
        )
        let failed = TeamsAutoMeetingPresentation.make(
            state: .waitingForMeeting,
            connectionStatus: .failed("Teams connection lost")
        )

        XCTAssertEqual(connecting.title, "Connecting to Teams")
        XCTAssertEqual(connecting.detail, "Automatic recording remains armed")
        XCTAssertEqual(awaitingApproval.title, "Waiting for Teams approval")
        XCTAssertEqual(
            awaitingApproval.detail,
            "Automatic recording remains armed"
        )
        XCTAssertEqual(failed.title, "Teams connection error")
        XCTAssertEqual(failed.detail, "Teams connection lost")
    }

    func testCancelActionIsConsumedOnlyOnceAcrossReentrantTriggers() {
        let action = TeamsAutoMeetingCancelAction()
        var callCount = 0

        action.replace {
            callCount += 1
            action.consume()
        }

        action.consume()
        action.consume()

        XCTAssertEqual(callCount, 1)
    }

    func testProgrammaticClearDoesNotConsumeCancelAction() {
        let action = TeamsAutoMeetingCancelAction()
        var callCount = 0

        action.replace {
            callCount += 1
        }
        action.clear()
        action.consume()

        XCTAssertEqual(callCount, 0)
    }

    func testReplacingCancelActionRearmsConsumeOnceBehavior() {
        let action = TeamsAutoMeetingCancelAction()
        var callCount = 0

        action.replace {
            callCount += 1
        }
        action.consume()
        action.replace {
            callCount += 1
        }
        action.consume()

        XCTAssertEqual(callCount, 2)
    }
}
