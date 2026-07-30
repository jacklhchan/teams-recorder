import AppKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecorderWorkspaceRenderTests: XCTestCase {
    func testNavigationShellStartsOnRecordAndCanRenderBaselineDestinations() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
            )
        defer { host.close() }

        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.record"))
        host.select(.recordings)
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.recordings"))
        host.select(.settings)
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.settings"))
    }

    func testMinimumRecordViewportContainsAllOperationalAnchorsWithoutScrolling() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        for identifier in operationalProbeIDs {
            let frame = try XCTUnwrap(host.frame(forAccessibilityIdentifier: identifier))
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(
                host.visibleContentRect.contains(frame),
                "\(identifier) must be fully visible without scrolling"
            )
        }
    }

    func testWideRecordViewportContainsAllOperationalAnchorsWithoutScrolling() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1280, height: 800)
        )
        defer { host.close() }

        for identifier in operationalProbeIDs {
            XCTAssertTrue(
                host.visibleContentRect.contains(
                    try XCTUnwrap(host.frame(forAccessibilityIdentifier: identifier))
                )
            )
        }
    }

    func testBlockingCaptureStateShowsVisibleSettingsRecoveryDeepLink() throws {
        let fixture = makeStartupDisabledFixture(systemPermission: .denied)
        try assertVisibleSettingsRecoveryDeepLink(for: fixture)
    }

    func testRestrictedSystemPermissionShowsVisibleSettingsRecoveryDeepLink() throws {
        let fixture = makeStartupDisabledFixture(systemPermission: .restricted)
        try assertVisibleSettingsRecoveryDeepLink(for: fixture)
    }

    func testRestrictedMicrophonePermissionShowsVisibleSettingsRecoveryDeepLink() throws {
        let fixture = makeStartupDisabledFixture(
            systemPermission: .granted,
            microphonePermission: .restricted
        )
        try assertVisibleSettingsRecoveryDeepLink(for: fixture)
    }

    private func assertVisibleSettingsRecoveryDeepLink(
        for fixture: StartupDisabledFixture
    ) throws {
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        XCTAssertTrue(
            host.visibleContentRect.contains(
                try XCTUnwrap(
                    host.frame(forAccessibilityIdentifier: "recorder.probe.capture-recovery")
                )
            )
        )
        XCTAssertTrue(host.click(atAccessibilityFrame: "recorder.probe.capture-recovery"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.capture-section"))
    }

    private var operationalProbeIDs: [String] {
        [
            "record-state",
            "elapsed-time",
            RecorderActionID.startStop,
            RecorderActionID.muteMic,
            "system-meter",
            "microphone-meter",
            "capture-health"
        ]
    }

    private func makeStartupDisabledFixture(
        systemPermission: CapturePermissionState = .notDetermined,
        microphonePermission: CapturePermissionState = .granted
    ) -> StartupDisabledFixture {
        let suiteName = "RecorderWorkspaceRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = systemPermission
        model.microphonePermission = microphonePermission
        return .init(
            model: model,
            defaults: defaults
        )
    }

    private func makeWorkspaceHost(model: AppModel, size: CGSize) throws -> WorkspaceHost {
        try WorkspaceHost(model: model, size: size)
    }
}

@MainActor
private struct StartupDisabledFixture {
    let model: AppModel
    let defaults: UserDefaults
}

@MainActor
private final class WorkspaceNavigationDriver: ObservableObject {
    @Published var navigation = RecorderNavigationState(selection: .record)
}

@MainActor
private struct WorkspaceHostRoot: View {
    @ObservedObject var navigationDriver: WorkspaceNavigationDriver
    let model: AppModel

    var body: some View {
        RecorderWorkspaceContent(
            model: model,
            navigation: Binding(
                get: { navigationDriver.navigation },
                set: { navigationDriver.navigation = $0 }
            )
        )
    }
}

@MainActor
private final class WorkspaceHost {
    private let navigationDriver = WorkspaceNavigationDriver()
    private let hostingView: NSHostingView<WorkspaceHostRoot>
    private let window: NSWindow

    init(model: AppModel, size: CGSize) throws {
        hostingView = NSHostingView(
            rootView: WorkspaceHostRoot(
                navigationDriver: navigationDriver,
                model: model
            )
        )
        let frame = NSRect(origin: .zero, size: size)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        layout()
    }

    func select(_ destination: RecorderDestination) {
        navigationDriver.navigation.select(destination, hasUnsavedChanges: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
    }

    func containsAccessibilityIdentifier(_ identifier: String) -> Bool {
        view(forAccessibilityIdentifier: identifier) != nil
            || accessibilityElement(forAccessibilityIdentifier: identifier) != nil
    }

    var visibleContentRect: CGRect {
        hostingView.accessibilityFrame()
    }

    func frame(forAccessibilityIdentifier identifier: String) -> CGRect? {
        if let element = accessibilityElement(forAccessibilityIdentifier: identifier) {
            return element.accessibilityFrame()
        }
        return view(forAccessibilityIdentifier: identifier)?.accessibilityFrame()
    }

    @discardableResult
    func click(atAccessibilityFrame identifier: String) -> Bool {
        guard let frame = frame(forAccessibilityIdentifier: identifier) else {
            return false
        }
        let location = window.convertPoint(fromScreen: .init(
            x: frame.midX,
            y: frame.midY
        ))
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }
        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
        return true
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func layout() {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func view(forAccessibilityIdentifier identifier: String, in root: NSView? = nil) -> NSView? {
        let candidate = root ?? hostingView
        if candidate.accessibilityIdentifier() == identifier { return candidate }
        for subview in candidate.subviews {
            if let found = self.view(forAccessibilityIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func accessibilityElement(
        forAccessibilityIdentifier identifier: String
    ) -> (any NSAccessibilityElementProtocol)? {
        func find(in children: [Any]) -> (any NSAccessibilityElementProtocol)? {
            for child in children {
                if let element = child as? any NSAccessibilityElementProtocol,
                   element.accessibilityIdentifier?() == identifier {
                    return element
                }
                if let view = child as? NSView,
                   let found = find(in: view.accessibilityChildren() ?? []) {
                    return found
                }
            }
            return nil
        }
        if hostingView.accessibilityIdentifier() == identifier {
            return hostingView
        }
        return find(in: hostingView.accessibilityChildren() ?? [])
    }

}
