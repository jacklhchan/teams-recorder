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

    private func makeStartupDisabledFixture() -> StartupDisabledFixture {
        let suiteName = "RecorderWorkspaceRenderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return .init(
            model: AppModel(
                defaults: defaults,
                inputDevices: { [] },
                defaultInputDeviceID: { nil },
                performStartupWork: false
            ),
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
        containsAccessibilityIdentifier(identifier, in: hostingView)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func layout() {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private func containsAccessibilityIdentifier(_ identifier: String, in view: NSView) -> Bool {
        if view.accessibilityIdentifier() == identifier { return true }
        return view.subviews.contains { containsAccessibilityIdentifier(identifier, in: $0) }
    }
}
