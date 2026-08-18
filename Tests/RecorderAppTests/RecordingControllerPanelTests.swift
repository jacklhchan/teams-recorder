import AppKit
import Combine
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingControllerPanelTests: XCTestCase {
    func testPanelToggleAccessibilityObservationFailsClosedWhenControlCannotBeObserved() {
        let presenter = RecordingControllerPanelPresenter()

        XCTAssertNil(presenter.panelToggleAccessibilityValue)
        presenter.setPresentation(.collapsed)
        XCTAssertNil(presenter.panelToggleAccessibilityValue)

        let fixture = makeFixture()
        presenter.present(model: fixture.model)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(presenter.panelToggleAccessibilityValue)
        presenter.dismiss()
        XCTAssertNil(presenter.panelToggleAccessibilityValue)
    }

    func testRecordingControllerCollapsedShowsOnlyRunningAndEye() throws {
        let host = makeRecordingControllerHost(state: .collapsed)
        defer { host.close() }

        XCTAssertTrue(
            host.contains(RecordingControllerAccessibility.runningID)
        )
        XCTAssertTrue(
            host.contains(RecordingControllerAccessibility.panelToggleID)
        )
        for hidden in [
            RecordingControllerAccessibility.recordingIndicatorID,
            RecordingControllerAccessibility.recordingIndicatorToggleID,
            RecordingControllerAccessibility.statusID,
            RecordingControllerAccessibility.elapsedID,
            RecordingControllerAccessibility.systemWaveformID,
            RecordingControllerAccessibility.microphoneWaveformID,
            RecordingControllerAccessibility.microphoneMuteID,
            RecordingControllerAccessibility.screenStatusID,
            RecordingControllerAccessibility.screenToggleID,
            RecordingControllerAccessibility.stopID,
        ] {
            XCTAssertFalse(host.contains(hidden), hidden)
        }
        XCTAssertEqual(host.frame.size, .init(width: 132, height: 40))
    }

    func testRecordingControllerExpandedRetainsRecordingIndicator() throws {
        let host = makeRecordingControllerHost(state: .expanded)
        defer { host.close() }

        XCTAssertTrue(
            host.contains(RecordingControllerAccessibility.recordingIndicatorID)
        )
        XCTAssertTrue(
            host.contains(RecordingControllerAccessibility.panelToggleID)
        )
    }

    func testRecordingControllerCollapseRoundTripPreservesTopRightAndResetsEpisode() {
        let presenter = RecordingControllerPanelPresenter()
        let fixture = makeFixture()
        let frameProbe = RecordingControllerPanel()
        let expandedOuterSize = frameProbe.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: .init(width: 390, height: 180)
            )
        ).size
        let collapsedOuterSize = frameProbe.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: FloatingPanelLayout.collapsedSize
            )
        ).size
        presenter.setPresentation(.expanded)
        let initial = presenter.panelFrame
        XCTAssertEqual(initial.size, expandedOuterSize)
        let topRight = (initial.maxX, initial.maxY)

        presenter.setPresentation(.collapsed)
        XCTAssertEqual(
            presenter.panelFrame.size,
            collapsedOuterSize
        )
        XCTAssertEqual(presenter.panelFrame.maxX, topRight.0)
        XCTAssertEqual(presenter.panelFrame.maxY, topRight.1)

        presenter.setPresentation(.expanded)
        XCTAssertEqual(
            presenter.panelFrame.size,
            expandedOuterSize
        )
        XCTAssertEqual(presenter.panelFrame.maxX, topRight.0)
        XCTAssertEqual(presenter.panelFrame.maxY, topRight.1)

        presenter.setPresentation(.collapsed)
        presenter.dismiss()
        presenter.present(model: fixture.model)
        defer { presenter.dismiss() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(
            presenter.panelFrame.size,
            expandedOuterSize
        )
        XCTAssertNil(presenter.panelToggleAccessibilityValue)
        frameProbe.orderOut(nil)
    }

    func testRecordingControllerContentSizesUseNativeFrameConversion() {
        let presenter = RecordingControllerPanelPresenter()
        let fixture = makeFixture()
        presenter.present(model: fixture.model)
        defer { presenter.dismiss() }

        let initialTopRight = (presenter.panelFrame.maxX, presenter.panelFrame.maxY)
        XCTAssertEqual(
            presenter.panelContentLayoutRect.size,
            .init(width: 390, height: 180)
        )
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            .init(width: 390, height: 180)
        )

        presenter.setPresentation(.collapsed)
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

        presenter.setPresentation(.expanded)
        XCTAssertEqual(
            presenter.panelContentLayoutRect.size,
            .init(width: 390, height: 180)
        )
        XCTAssertEqual(
            presenter.panelContentBounds.size,
            .init(width: 390, height: 180)
        )
        XCTAssertEqual(presenter.panelFrame.maxX, initialTopRight.0)
        XCTAssertEqual(presenter.panelFrame.maxY, initialTopRight.1)
    }

    func testRecordingFloatingPanelExposesNativeMinimizeButton() {
        let panel = RecordingControllerPanel()
        defer { panel.orderOut(nil) }

        XCTAssertTrue(panel.styleMask.contains(.miniaturizable))
        XCTAssertNotNil(panel.standardWindowButton(.miniaturizeButton))
    }

    func testAccessibilityLabelsAndToggleValuesAreExplicit() {
        XCTAssertEqual(
            RecordingControllerAccessibility.stopLabel,
            "Stop recording"
        )
        XCTAssertEqual(
            RecordingControllerAccessibility.screenCaptureLabel,
            "Capture Teams screen"
        )
        XCTAssertEqual(
            RecordingControllerAccessibility.screenCaptureValue(isOn: true),
            "On"
        )
        XCTAssertEqual(
            RecordingControllerAccessibility.screenCaptureValue(isOn: false),
            "Off"
        )
    }

    func testInputStatusUsesConnectionMuteAndSignalPrecedence() {
        XCTAssertEqual(
            RecordingControllerInputStatus.make(
                level: .init(rms: -12, peak: -3, samples: [0.7]),
                isConnected: true,
                isMuted: false
            ),
            .signal
        )
        XCTAssertEqual(
            RecordingControllerInputStatus.make(
                level: .init(),
                isConnected: true,
                isMuted: false
            ),
            .quiet
        )
        XCTAssertEqual(
            RecordingControllerInputStatus.make(
                level: .init(rms: -12, peak: -3, samples: [0.7]),
                isConnected: true,
                isMuted: true
            ),
            .muted
        )
        XCTAssertEqual(
            RecordingControllerInputStatus.make(
                level: .init(rms: -12, peak: -3, samples: [0.7]),
                isConnected: false,
                isMuted: false
            ),
            .disconnected
        )
    }

    func testEpisodeEmitsOneCommandPerRecordingTransition() {
        var episode = RecordingControllerPanelEpisode()

        XCTAssertEqual(episode.handle(isRecording: false), .none)
        XCTAssertEqual(episode.handle(isRecording: true), .present)
        XCTAssertEqual(episode.handle(isRecording: true), .none)
        XCTAssertEqual(episode.handle(isRecording: false), .dismiss)
        XCTAssertEqual(episode.handle(isRecording: false), .none)
        XCTAssertEqual(episode.handle(isRecording: true), .present)
    }

    func testCoordinatorPresentsOncePerRecordingAndReappearsForNextRecording() {
        let fixture = makeFixture()
        let subject = PassthroughSubject<Bool, Never>()
        let presenter = RecordingControllerPresenterSpy()
        let coordinator = RecordingControllerCoordinator(
            model: fixture.model,
            presenterFactory: RecordingControllerPresenterFactorySpy(
                presenter: presenter
            ),
            isRecordingPublisher: subject.eraseToAnyPublisher()
        )
        defer { coordinator.shutdown() }

        subject.send(false)
        XCTAssertEqual(presenter.presentedModels.count, 0)
        XCTAssertEqual(presenter.dismissCount, 0)

        subject.send(true)
        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)
        XCTAssertTrue(presenter.presentedModels.first === fixture.model)

        subject.send(false)
        subject.send(false)
        XCTAssertEqual(presenter.dismissCount, 1)

        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 2)

        withExtendedLifetime(coordinator) {}
    }

    func testCoordinatorShutdownDismissesOnceAndStopsObservingImmediately() {
        let fixture = makeFixture()
        let subject = PassthroughSubject<Bool, Never>()
        let presenter = RecordingControllerPresenterSpy()
        let coordinator = RecordingControllerCoordinator(
            model: fixture.model,
            presenterFactory: RecordingControllerPresenterFactorySpy(
                presenter: presenter
            ),
            isRecordingPublisher: subject.eraseToAnyPublisher()
        )

        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)

        coordinator.shutdown()
        XCTAssertEqual(presenter.dismissCount, 1)

        coordinator.shutdown()
        XCTAssertEqual(presenter.dismissCount, 1)

        subject.send(false)
        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    private func makeFixture() -> (
        model: AppModel,
        recorder: RecordingEngine
    ) {
        let recorder = RecordingEngine()
        let model = AppModel(
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            virtualMicStateProvider: { .absent }
        )
        return (model, recorder)
    }

    private func makeRecordingControllerHost(
        state: FloatingPanelPresentationState
    ) -> RecordingControllerCollapseRenderHost {
        RecordingControllerCollapseRenderHost(state: state)
    }
}

@MainActor
private final class RecordingControllerCollapseRenderHost {
    private let hostingView: NSHostingView<AnyView>
    private let window: NSWindow

    init(state: FloatingPanelPresentationState) {
        let presentation = RecordingControllerPresentation.make(
            snapshot: .init(
                isRecording: true,
                isFinalizing: false,
                startedAt: Date(),
                showsTeamsScreenControl: true,
                screenRequested: false,
                screenStatusText: TeamsScreenStatusText.off,
                screenToggleDisabled: false
            ),
            now: Date()
        )
        hostingView = NSHostingView(
            rootView: AnyView(
                RecordingControllerPanelContent(
                    presentation: presentation,
                    stop: {},
                    toggleMicrophoneMute: {},
                    setScreenRequested: { _ in },
                    systemLevel: .init(),
                    microphoneLevel: .init(),
                    isSystemConnected: true,
                    isMicrophoneConnected: true,
                    isMicrophoneMuted: false,
                    isLocalMicrophoneMuted: false,
                    panelState: state,
                    togglePanel: {}
                )
            )
        )
        let size = state == .collapsed
            ? FloatingPanelLayout.collapsedSize
            : .init(width: 390, height: 180)
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        render()
    }

    var frame: NSRect { hostingView.frame }

    func contains(_ identifier: String) -> Bool {
        view(identifier) != nil || view("\(identifier).marker") != nil
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func view(_ identifier: String) -> NSView? {
        allViews(hostingView).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews
            + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}

@MainActor
private final class RecordingControllerPresenterSpy:
    RecordingControllerPresenting
{
    private(set) var presentedModels: [AppModel] = []
    private(set) var dismissCount = 0

    func present(model: AppModel) {
        presentedModels.append(model)
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private struct RecordingControllerPresenterFactorySpy:
    RecordingControllerPresenterFactory
{
    let presenter: RecordingControllerPresenterSpy

    func makePresenter() -> any RecordingControllerPresenting {
        presenter
    }
}
