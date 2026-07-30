import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import RecorderApp

@MainActor
final class RecorderWorkspaceRenderTests: XCTestCase {
    func testSettingsAccessibilityMarkerReadsInheritedEnabledEnvironment() throws {
        let enabledHost = try MarkerHarnessHost(isEnabled: true)
        defer { enabledHost.close() }
        XCTAssertTrue(try enabledHost.isEnabled("recorder.test.settings-marker"))

        let disabledHost = try MarkerHarnessHost(isEnabled: false)
        defer { disabledHost.close() }
        XCTAssertFalse(try disabledHost.isEnabled("recorder.test.settings-marker"))
    }

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

    func testSidebarVisibilityChangesPreserveRecordingsSelection() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)
        XCTAssertTrue(
            host.containsAccessibilityIdentifier(
                "recorder.destination.recordings"
            )
        )
        let visibleSidebarFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.workspace.sidebar")
        )
        XCTAssertFalse(visibleSidebarFrame.isEmpty)
        let expandedDetailFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.destination.recordings")
        )

        host.setColumnVisibility(.detailOnly)
        try waitUntil(timeout: 1) {
            guard let frame = host.frame(
                forAccessibilityIdentifier: "recorder.destination.recordings"
            ) else {
                return false
            }
            return frame.minX < expandedDetailFrame.minX
        }
        XCTAssertEqual(host.navigationState.selection, .recordings)
        XCTAssertTrue(
            host.containsAccessibilityIdentifier(
                "recorder.destination.recordings"
            )
        )

        let collapsedDetailFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.destination.recordings")
        )
        host.setColumnVisibility(.all)
        try waitUntil(timeout: 1) {
            guard let frame = host.frame(
                forAccessibilityIdentifier: "recorder.destination.recordings"
            ) else {
                return false
            }
            return frame.minX > collapsedDetailFrame.minX
        }
        XCTAssertEqual(host.navigationState.selection, .recordings)
    }

    func testMinimumRecordViewportContainsAllOperationalAnchorsWithoutScrolling() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        let sidebarFrame = try XCTUnwrap(
            host.frame(forAccessibilityIdentifier: "recorder.workspace.sidebar")
        )
        XCTAssertFalse(sidebarFrame.isEmpty)
        let visibleSidebarBounds = host.visibleContentRect.insetBy(dx: -0.5, dy: -0.5)
        XCTAssertTrue(
            visibleSidebarBounds.contains(sidebarFrame),
            "sidebar navigation must be fully visible without scrolling"
        )

        for identifier in RecordDashboardPresentation.operationalProbeIDs {
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

        for identifier in RecordDashboardPresentation.operationalProbeIDs {
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

    func testRecordingsRendersSessionSpecificActions() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)

        XCTAssertTrue(host.containsAccessibilityLabel("Play \(fixture.session.displayName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(fixture.session.displayName)"))
    }

    func testMinimumRecordingsKeepsSessionActionsInsideWindow() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.recordings)

        let rowID = fixture.session.id.lastPathComponent
        for identifier in [
            "recorder.row.play.\(rowID)",
            "recorder.row.open.\(rowID)",
            "recorder.row.edit.\(rowID)",
            "recorder.row.transcribe.\(rowID)",
            "recorder.row.transcript.\(rowID)",
            "recorder.row.trash.\(rowID)",
            "recorder.row.log.\(rowID)"
        ] {
            let frame = try XCTUnwrap(
                host.frame(forAccessibilityIdentifier: identifier),
                "Missing session action: \(identifier)"
            )
            XCTAssertTrue(
                host.windowContentRect.contains(frame),
                "\(identifier) must remain inside the 860×680 window"
            )
        }
    }

    func testSessionActionMarkersUpdateWhenMetadataProjectionRenamesSameSession() throws {
        let fixture = makeFixtureWithOneSession()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.recordings)
        let originalName = fixture.session.displayName
        let renamedName = "Renamed workspace recording"
        XCTAssertTrue(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(originalName)"))

        fixture.model.sessions = [
            RecordingSession(
                id: fixture.session.id,
                folderURL: fixture.session.folderURL,
                recordingURL: fixture.session.recordingURL,
                createdAt: fixture.session.createdAt,
                duration: fixture.session.duration,
                fileSize: fixture.session.fileSize,
                metadata: .init(title: renamedName),
                searchDocument: fixture.session.searchDocument
            )
        ]
        host.render()

        XCTAssertTrue(host.containsAccessibilityLabel("Play \(renamedName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(renamedName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Edit details for \(originalName)"))
    }

    func testTwentyFiveRecordRecordingsCyclesRenderWithoutPendingLeak() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        for _ in 0 ..< 25 {
            host.select(.recordings)
            XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.recordings"))
            host.select(.record)
            XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.record"))
            XCTAssertNil(host.navigationState.pendingDestination)
        }
    }

    func testTwentyFiveNavigationCyclesRenderEveryDestinationWithoutPendingLeak() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
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
        XCTAssertFalse(host.containsAVPlayerView())
    }

    func testSettingsRendersExistingCaptureTeamsVirtualMicAndProviderSections() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }

        host.select(.settings)

        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.destination.settings"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.capture-section"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("capture-mode-picker"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("teams-auto-recording-toggle"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.audio-integration-section"))
        XCTAssertTrue(host.containsAccessibilityIdentifier("recorder.settings.transcription-section"))
    }

    func testMinimumSettingsRendersCaptureAndTeamsControls() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)

        XCTAssertTrue(
            host.containsAccessibilityIdentifier("recorder.destination.settings")
        )
        XCTAssertTrue(host.containsAccessibilityIdentifier("capture-mode-picker"))
        XCTAssertTrue(
            host.containsAccessibilityIdentifier("teams-auto-recording-toggle")
        )
    }

    func testSourceControlGatesRemainDisabledDuringLifecycleWork() throws {
        let fixture = makeLifecycleWorkingFixture()
        defer { fixture.source.resumeRefresh() }
        fixture.model.refreshCaptureApplications()
        try waitUntil(timeout: 1) { fixture.source.refreshStarted }
        XCTAssertTrue(fixture.model.isCaptureLifecycleWorking)

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1_280, height: 800)
        )
        defer { host.close() }
        host.select(.settings)

        XCTAssertFalse(try host.isEnabled("capture-mode-picker"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.capture-application-picker"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.capture-refresh"))
        XCTAssertFalse(try host.isEnabled("recorder.settings.microphone-picker"))
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

    private func makeFixtureWithOneSession() -> SessionFixture {
        let fixture = makeStartupDisabledFixture(
            systemPermission: .granted,
            microphonePermission: .granted
        )
        let folder = URL(
            fileURLWithPath: "/tmp/recorder-render-session-\(UUID().uuidString)",
            isDirectory: true
        )
        let session = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Workspace recording")
        )
        fixture.model.sessions = [session]
        return .init(model: fixture.model, defaults: fixture.defaults, session: session)
    }

    private func makeLifecycleWorkingFixture() -> LifecycleWorkingFixture {
        let suiteName = "RecorderWorkspaceRenderTests.lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let source = PausedRefreshCaptureSource()
        let recorder = RecordingEngine(captureSource: source)
        let model = AppModel(
            defaults: defaults,
            recorder: recorder,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.captureSelection = .init(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.example.capture"
        )
        return .init(model: model, defaults: defaults, source: source)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Timed out waiting for expected lifecycle state")
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
private struct SessionFixture {
    let model: AppModel
    let defaults: UserDefaults
    let session: RecordingSession
}

@MainActor
private struct LifecycleWorkingFixture {
    let model: AppModel
    let defaults: UserDefaults
    let source: PausedRefreshCaptureSource
}

@MainActor
private final class WorkspaceNavigationDriver: ObservableObject {
    @Published var navigation = RecorderNavigationState(selection: .record)
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
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
            ),
            columnVisibility: Binding(
                get: { navigationDriver.columnVisibility },
                set: { navigationDriver.columnVisibility = $0 }
            )
        )
    }
}

@MainActor
private struct MarkerHarnessRoot: View {
    let isEnabled: Bool

    var body: some View {
        Color.clear
            .frame(width: 20, height: 20)
            .background(
                RecorderSettingsAccessibilityMarker(
                    identifier: "recorder.test.settings-marker"
                )
            )
            .disabled(!isEnabled)
    }
}

@MainActor
private final class MarkerHarnessHost {
    private let hostingView: NSHostingView<MarkerHarnessRoot>
    private let window: NSWindow

    init(isEnabled: Bool) throws {
        hostingView = NSHostingView(rootView: MarkerHarnessRoot(isEnabled: isEnabled))
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        hostingView.frame = frame
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func isEnabled(_ identifier: String) throws -> Bool {
        guard let marker = findMarker(in: hostingView, identifier: identifier) else {
            throw WorkspaceHostError.missingAccessibilityElement(identifier)
        }
        return marker.isAccessibilityEnabled()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func findMarker(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let marker = findMarker(in: subview, identifier: identifier) {
                return marker
            }
        }
        return nil
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

    func containsAccessibilityLabel(_ label: String) -> Bool {
        view(withAccessibilityLabel: label) != nil
    }

    func isEnabled(_ identifier: String) throws -> Bool {
        if let view = view(forAccessibilityIdentifier: identifier) {
            return view.isAccessibilityEnabled()
        }
        guard let element = accessibilityElement(forAccessibilityIdentifier: identifier) else {
            throw WorkspaceHostError.missingAccessibilityElement(identifier)
        }
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString("accessibilityEnabled")),
              let isEnabled = object.value(forKey: "accessibilityEnabled") as? Bool else {
            throw WorkspaceHostError.missingAccessibilityElement(identifier)
        }
        return isEnabled
    }

    var navigationState: RecorderNavigationState {
        navigationDriver.navigation
    }

    var visibleContentRect: CGRect {
        hostingView.accessibilityFrame()
    }

    var windowContentRect: CGRect {
        let contentRect = window.contentLayoutRect
        return CGRect(
            origin: window.convertPoint(toScreen: contentRect.origin),
            size: contentRect.size
        )
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

    func render() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        layout()
    }

    func setColumnVisibility(_ visibility: NavigationSplitViewVisibility) {
        navigationDriver.columnVisibility = visibility
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        layout()
    }

    func containsAVPlayerView() -> Bool {
        containsAVPlayerView(in: hostingView)
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

    private func containsAVPlayerView(in view: NSView) -> Bool {
        if view is AVPlayerView { return true }
        return view.subviews.contains(where: containsAVPlayerView(in:))
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
                if let found = find(in: accessibilityChildren(of: child)) {
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

    private func accessibilityChildren(of element: Any) -> [Any] {
        if let view = element as? NSView {
            return view.accessibilityChildren() ?? []
        }
        if let object = element as? NSObject {
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else {
                return []
            }
            return object.value(forKey: "accessibilityChildren") as? [Any] ?? []
        }
        return []
    }

    private func view(
        withAccessibilityLabel label: String,
        in root: NSView? = nil
    ) -> NSView? {
        let candidate = root ?? hostingView
        if candidate.accessibilityLabel() == label { return candidate }
        for subview in candidate.subviews {
            if let found = view(withAccessibilityLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

}

private enum WorkspaceHostError: Error {
    case missingAccessibilityElement(String)
}

@MainActor
private final class PausedRefreshCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: 0)
    private(set) var refreshStarted = false
    private var refreshContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] {
        refreshStarted = true
        await withCheckedContinuation { refreshContinuation = $0 }
        return []
    }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}
    func updateVideoTarget(_: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        .init(sessionGeneration: 0, revision: 0)
    }
    func start(
        selection _: ResolvedCaptureSelection,
        microphoneUID _: String?,
        onAudio _: @escaping (AudioFrameBlock) -> Void,
        onVideo _: @escaping (ScreenVideoFrame) -> Void,
        onEvent _: @escaping (CaptureEvent) -> Void
    ) async throws {}
    func stop() async {}

    func resumeRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }
}
