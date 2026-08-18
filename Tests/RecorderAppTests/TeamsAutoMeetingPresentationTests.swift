import AppKit
import XCTest
@testable import RecorderApp

@MainActor
final class TeamsAutoMeetingPresentationTests: XCTestCase {
    func testCountdownCollapsePersistsWithinEpisodeAndResetsForNext() throws {
        let presenter = TeamsAutoMeetingCountdownPanelController()
        presenter.present(seconds: 5, cancel: {})
        defer { presenter.dismiss() }

        let panel = try XCTUnwrap(
            NSApp.windows.first {
                $0.title == "Teams Window Auto Recording" && $0.isVisible
            }
        )
        render(panel: panel)
        XCTAssertTrue(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.secondsID))

        try click(
            panel: panel,
            identifier: TeamsAutoMeetingCountdownAccessibility.panelToggleID
        )
        XCTAssertTrue(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.runningID))
        XCTAssertFalse(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.secondsID))

        presenter.present(seconds: 4, cancel: {})
        render(panel: panel)
        XCTAssertTrue(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.runningID))
        XCTAssertFalse(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.secondsID))

        presenter.dismiss()
        presenter.present(seconds: 3, cancel: {})
        render(panel: panel)
        XCTAssertTrue(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.secondsID))
        XCTAssertTrue(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.cancelID))
        XCTAssertFalse(contains(panel: panel, identifier: TeamsAutoMeetingCountdownAccessibility.runningID))
    }

    func testCountdownContentSizesUseNativeFrameConversion() throws {
        let presenter = TeamsAutoMeetingCountdownPanelController()
        presenter.present(seconds: 5, cancel: {})
        defer { presenter.dismiss() }

        let panel = try XCTUnwrap(
            NSApp.windows.first {
                $0.title == "Teams Window Auto Recording" && $0.isVisible
            }
        )
        let initialTopRight = (presenter.panelFrame.maxX, presenter.panelFrame.maxY)
        XCTAssertEqual(
            presenter.panelContentLayoutRect.size,
            .init(width: 360, height: 94)
        )
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            .init(width: 360, height: 94)
        )

        try click(
            panel: panel,
            identifier: TeamsAutoMeetingCountdownAccessibility.panelToggleID
        )
        XCTAssertEqual(
            presenter.panelContentLayoutRect.size,
            FloatingPanelLayout.collapsedSize
        )
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            FloatingPanelLayout.collapsedSize
        )
        XCTAssertEqual(presenter.panelFrame.maxX, initialTopRight.0)
        XCTAssertEqual(presenter.panelFrame.maxY, initialTopRight.1)

        presenter.present(seconds: 4, cancel: {})
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            FloatingPanelLayout.collapsedSize
        )

        presenter.dismiss()
        presenter.present(seconds: 3, cancel: {})
        XCTAssertEqual(
            presenter.panelContentLayoutRect.size,
            .init(width: 360, height: 94)
        )
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            .init(width: 360, height: 94)
        )
    }

    func testAutoMeetingFloatingPanelExposesNativeMinimizeButton() {
        let presenter = TeamsAutoMeetingCountdownPanelController()
        presenter.present(seconds: 5, cancel: {})
        defer { presenter.dismiss() }

        let panel = NSApp.windows.first {
            $0.title == "Teams Window Auto Recording"
        }
        XCTAssertTrue(panel?.styleMask.contains(.miniaturizable) == true)
        XCTAssertNotNil(panel?.standardWindowButton(.miniaturizeButton))
    }

    func testCountdownPresentationShowsRemainingSecondsAndCancel() {
        let presentation = TeamsAutoMeetingPresentation.make(
            state: .startCountdown(secondsRemaining: 3)
        )

        XCTAssertEqual(presentation.title, "Recording starts in 3s")
        XCTAssertEqual(presentation.detail, "Teams meeting detected")
        XCTAssertEqual(presentation.systemImage, "record.circle")
        XCTAssertTrue(presentation.showsCancel)
    }

    func testSuppressedPresentationExposesRearmNowOnly() {
        XCTAssertTrue(
            TeamsAutoMeetingPresentation.make(
                state: .suppressedUntilMeetingEnd
            ).showsRearmNow
        )
        XCTAssertFalse(
            TeamsAutoMeetingPresentation.make(
                state: .startBlocked("Microphone permission is required.")
            ).showsRearmNow
        )
        XCTAssertFalse(
            TeamsAutoMeetingPresentation.make(
                state: .startFailed("Microphone unavailable")
            ).showsRearmNow
        )
        XCTAssertFalse(
            TeamsAutoMeetingPresentation.make(
                state: .waitingForMeeting
            ).showsRearmNow
        )
    }

    func testEveryAutoMeetingStateHasTheExpectedPresentation() {
        let cases: [(
            TeamsAutoMeetingState,
            String,
            String,
            String,
            Bool,
            Bool
        )] = [
            (
                .disabled,
                "Off",
                "Automatic recording is disabled",
                "circle.dashed",
                false,
                false
            ),
            (
                .waitingForMeeting,
                "Waiting for meeting",
                "Watching Teams meeting windows locally",
                "clock",
                false,
                false
            ),
            (
                .startCountdown(secondsRemaining: 5),
                "Recording starts in 5s",
                "Teams meeting detected",
                "record.circle",
                true,
                false
            ),
            (
                .starting,
                "Starting recording",
                "Teams meeting detected",
                "record.circle",
                false,
                false
            ),
            (
                .automaticRecording,
                "Recording automatically",
                "Teams meeting in progress",
                "record.circle.fill",
                false,
                false
            ),
            (
                .stopCountdown(secondsRemaining: 7),
                "Stopping in 7s",
                "Confirming the meeting has ended",
                "stop.circle",
                false,
                false
            ),
            (
                .suppressedUntilMeetingEnd,
                "Cancelled for this meeting",
                "Automatic recording will re-arm after the meeting",
                "xmark.circle",
                false,
                true
            ),
            (
                .startBlocked("Microphone permission is required."),
                "Needs permission",
                "Microphone permission is required.",
                "exclamationmark.triangle.fill",
                false,
                false
            ),
            (
                .startFailed("Microphone unavailable"),
                "Start failed",
                "Microphone unavailable",
                "exclamationmark.triangle.fill",
                false,
                false
            ),
        ]

        for (
            state,
            expectedTitle,
            expectedDetail,
            expectedImage,
            expectedCancel,
            expectedRearmNow
        ) in cases {
            let presentation = TeamsAutoMeetingPresentation.make(state: state)

            XCTAssertEqual(presentation.title, expectedTitle)
            XCTAssertEqual(presentation.detail, expectedDetail)
            XCTAssertEqual(presentation.systemImage, expectedImage)
            XCTAssertEqual(presentation.showsCancel, expectedCancel)
            XCTAssertEqual(presentation.showsRearmNow, expectedRearmNow)
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

    private func click(panel: NSWindow, identifier: String) throws {
        render(panel: panel)
        let marker = try XCTUnwrap(
            allViews(in: panel.contentView).first {
                $0.accessibilityIdentifier() == "\(identifier).marker"
            },
            "missing marker for \(identifier)"
        )
        let location = marker.convert(
            .init(x: marker.bounds.midX, y: marker.bounds.midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type,
                    location: location,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0
                ),
                "missing \(type) event"
            )
            panel.sendEvent(event)
        }
        render(panel: panel)
    }

    private func render(panel: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        panel.layoutIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    private func allViews(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        let children = view.subviews
            + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap { allViews(in: $0) }
    }

    private func contains(panel: NSWindow, identifier: String) -> Bool {
        allViews(in: panel.contentView).contains {
            $0.accessibilityIdentifier() == identifier
                || $0.accessibilityIdentifier() == "\(identifier).marker"
        }
    }
}
