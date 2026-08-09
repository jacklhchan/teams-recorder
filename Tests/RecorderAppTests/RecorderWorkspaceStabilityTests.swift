import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecorderWorkspaceStabilityTests: XCTestCase {
    func testOneHundredCleanNavigationCyclesDoNotLeakPendingRoute() throws {
        try requireStabilityRun()
        var state = RecorderNavigationState(selection: .record)

        for _ in 0 ..< 100 {
            state.select(.recordings, hasUnsavedChanges: false)
            state.select(.settings, hasUnsavedChanges: false)
            state.select(.record, hasUnsavedChanges: false)
            XCTAssertNil(state.pendingDestination)
        }
    }

    func testTwentyFiveRecordRecordingsCyclesRenderWithoutPendingLeak() throws {
        try requireStabilityRun()
        let fixture = makeModel()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let host = try WorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        for _ in 0 ..< 25 {
            host.select(.recordings)
            XCTAssertTrue(
                host.containsAccessibilityIdentifier(
                    "recorder.destination.recordings"
                )
            )
            host.select(.record)
            XCTAssertTrue(
                host.containsAccessibilityIdentifier(
                    "recorder.destination.record"
                )
            )
            XCTAssertNil(host.navigationState.pendingDestination)
        }
    }

    func testTwentyFiveNavigationCyclesRenderEveryDestination() throws {
        try requireStabilityRun()
        let fixture = makeModel()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let host = try WorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        for _ in 0 ..< 25 {
            for destination in RecorderDestination.allCases {
                host.select(destination)
                XCTAssertTrue(
                    host.containsAccessibilityIdentifier(
                        "recorder.destination.\(destination.rawValue)"
                    )
                )
                XCTAssertNil(host.navigationState.pendingDestination)
            }
        }
    }

    func testTwentyFiveContentViewCyclesRetainPresenterPair() async throws {
        try requireStabilityRun()
        let fixture = makeModel()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let countdownFactory = StabilityCountdownPresenterFactory()
        let playbackFactory = StabilityPlaybackPresenterFactory()
        let navigationDriver = StabilityNavigationDriver()
        let hostingView = NSHostingView(
            rootView: ContentView(
                model: fixture.model,
                autoMeetingPanelFactory: countdownFactory,
                playbackWindowPresenterFactory: playbackFactory,
                navigationOverride: Binding(
                    get: { navigationDriver.navigation },
                    set: { navigationDriver.navigation = $0 }
                )
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: 800
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        await Task.yield()
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        for _ in 0 ..< 25 {
            for destination in RecorderDestination.allCases {
                navigationDriver.navigation.select(
                    destination,
                    hasUnsavedChanges: false
                )
                fixture.model.objectWillChange.send()
                try? await Task.sleep(for: .milliseconds(10))
                window.layoutIfNeeded()
                hostingView.layoutSubtreeIfNeeded()
                XCTAssertTrue(
                    containsAccessibilityIdentifier(
                        "recorder.destination.\(destination.rawValue)",
                        in: hostingView
                    )
                )
            }
        }

        XCTAssertEqual(countdownFactory.makeCount, 1)
        XCTAssertEqual(playbackFactory.makeCount, 1)
    }

    private func requireStabilityRun() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RECORDER_STABILITY"]
                == "1",
            "Workspace stress tests run only in main stability CI."
        )
    }

    private func makeModel() -> (
        model: AppModel,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName =
            "RecorderWorkspaceStabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = .notDetermined
        model.microphonePermission = .granted
        return (model, defaults, suiteName)
    }

    private func containsAccessibilityIdentifier(
        _ identifier: String,
        in view: NSView
    ) -> Bool {
        if view.accessibilityIdentifier() == identifier {
            return true
        }
        return view.subviews.contains {
            containsAccessibilityIdentifier(identifier, in: $0)
        }
    }
}

@MainActor
private final class StabilityNavigationDriver: ObservableObject {
    @Published var navigation = RecorderNavigationState(selection: .record)
}

@MainActor
private final class StabilityCountdownPresenterFactory:
    TeamsAutoMeetingCountdownPresenterFactory
{
    private(set) var makeCount = 0

    func makePresenter() -> any TeamsAutoMeetingCountdownPresenting {
        makeCount += 1
        return StabilityCountdownPresenter()
    }
}

@MainActor
private final class StabilityCountdownPresenter:
    TeamsAutoMeetingCountdownPresenting
{
    func present(
        seconds _: Int,
        cancel _: @escaping @MainActor () -> Void
    ) {}

    func dismiss() {}
}

@MainActor
private final class StabilityPlaybackPresenterFactory:
    PlaybackWindowPresenterFactory
{
    private(set) var makeCount = 0

    func makePresenter() -> any PlaybackWindowPresenting {
        makeCount += 1
        return StabilityPlaybackPresenter()
    }
}

@MainActor
private final class StabilityPlaybackPresenter: PlaybackWindowPresenting {
    func present(
        presentation _: PlaybackPresentationModel,
        togglePlayback _: @escaping @MainActor () -> Void,
        stopPlayback _: @escaping @MainActor () -> Void,
        seekPlayback _: @escaping @MainActor (TimeInterval) -> Void
    ) {}

    func dismiss() {}
}
