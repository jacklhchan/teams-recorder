import XCTest
@testable import RecorderApp

@MainActor
final class TeamsAutoMeetingPresentationTests: XCTestCase {
    func testCountdownPresentationShowsRemainingSecondsAndCancel() {
        let presentation = TeamsAutoMeetingPresentation.make(
            state: .startCountdown(secondsRemaining: 3)
        )

        XCTAssertEqual(presentation.title, "Recording starts in 3s")
        XCTAssertEqual(presentation.detail, "Teams meeting detected")
        XCTAssertEqual(presentation.systemImage, "record.circle")
        XCTAssertTrue(presentation.showsCancel)
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
                "Watching Teams meeting windows locally",
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
            let presentation = TeamsAutoMeetingPresentation.make(state: state)

            XCTAssertEqual(presentation.title, expectedTitle)
            XCTAssertEqual(presentation.detail, expectedDetail)
            XCTAssertEqual(presentation.systemImage, expectedImage)
            XCTAssertEqual(presentation.showsCancel, expectedCancel)
        }
    }

    func testSameEpisodeTickCannotRearmConsumedCancelOrReorderPanel() {
        let episode = TeamsAutoMeetingPresentationEpisode()
        var callCount = 0

        let shouldOrderInitialPresentation = episode.present {
            callCount += 1
            episode.consumeCancel()
        }
        episode.consumeCancel()
        let shouldOrderSameEpisodeTick = episode.present {
            callCount += 1
        }
        episode.consumeCancel()

        XCTAssertTrue(shouldOrderInitialPresentation)
        XCTAssertFalse(shouldOrderSameEpisodeTick)
        XCTAssertEqual(callCount, 1)
    }

    func testProgrammaticDismissClearsWithoutConsumingAndNewEpisodeRearms() {
        let episode = TeamsAutoMeetingPresentationEpisode()
        var callCount = 0

        XCTAssertTrue(episode.present {
            callCount += 1
        })
        episode.dismiss()
        episode.consumeCancel()

        XCTAssertEqual(callCount, 0)

        let shouldOrderNewEpisode = episode.present {
            callCount += 1
        }
        episode.consumeCancel()
        episode.consumeCancel()

        XCTAssertTrue(shouldOrderNewEpisode)
        XCTAssertEqual(callCount, 1)
    }

    func testSameEpisodeTickRefreshesCancelOnlyWhileStillArmed() {
        let episode = TeamsAutoMeetingPresentationEpisode()
        var invokedAction = ""

        XCTAssertTrue(episode.present {
            invokedAction = "initial"
        })
        XCTAssertFalse(episode.present {
            invokedAction = "latest"
        })
        episode.consumeCancel()

        XCTAssertEqual(invokedAction, "latest")
    }
}
