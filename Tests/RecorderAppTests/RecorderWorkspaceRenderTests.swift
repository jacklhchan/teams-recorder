import AppKit
import Combine
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

    func testMinimumWindowRendersRecordStatusAndPrimaryAction() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        for identifier in [
            "recorder.workspace.sidebar",
            "record-state",
            "elapsed-time",
            RecorderActionID.startStop,
            "system-meter",
            "microphone-meter",
            "capture-health"
        ] {
            XCTAssertTrue(
                host.containsAccessibilityIdentifier(identifier),
                "Missing minimum-window control: \(identifier)"
            )
        }
    }

    func testWideWindowRendersEveryDestinationOnce() throws {
        let fixture = makeStartupDisabledFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 1280, height: 800)
        )
        defer { host.close() }

        for destination in RecorderDestination.allCases {
            host.select(destination)
            XCTAssertTrue(
                host.containsAccessibilityIdentifier(
                    "recorder.destination.\(destination.rawValue)"
                )
            )
        }
    }

    func testUnavailableCapturePermissionsExposeSettingsRecovery() throws {
        let cases: [
            (CapturePermissionState, CapturePermissionState)
        ] = [
            (CapturePermissionState.denied, .granted),
            (.restricted, .granted),
            (.granted, .restricted)
        ]
        for (systemPermission, microphonePermission) in cases {
            try assertVisibleSettingsRecoveryDeepLink(
                for: makeStartupDisabledFixture(
                    systemPermission: systemPermission,
                    microphonePermission: microphonePermission
                )
            )
        }
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

        fixture.model.seedLibrarySessionsForTesting([
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
        ])
        host.render()

        XCTAssertTrue(host.containsAccessibilityLabel("Play \(renamedName)"))
        XCTAssertTrue(host.containsAccessibilityLabel("Edit details for \(renamedName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Play \(originalName)"))
        XCTAssertFalse(host.containsAccessibilityLabel("Edit details for \(originalName)"))
    }

    func testTranscriptDetailActionProjectionUsesResolvedSessionForOpenDetail() {
        let folder = URL(fileURLWithPath: "/tmp/transcript-detail-action-\(UUID().uuidString)")
        let opened = RecordingSession(
            id: folder,
            folderURL: folder,
            recordingURL: folder.appendingPathComponent("recording.m4a"),
            createdAt: .now,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Original recording title", isFavorite: false)
        )
        let resolved = RecordingSession(
            id: opened.id,
            folderURL: opened.folderURL,
            recordingURL: opened.recordingURL,
            createdAt: opened.createdAt,
            duration: opened.duration,
            fileSize: opened.fileSize,
            metadata: .init(title: "Generated meeting title", isFavorite: true)
        )
        let visibleSessions: [RecordingSession] = []
        let allSessions = [resolved]
        XCTAssertTrue(visibleSessions.isEmpty)

        let current = TranscriptDetailActionProjection.current(
            opened: opened,
            allSessions: allSessions
        )

        XCTAssertEqual(current.id, opened.id)
        XCTAssertEqual(current.displayName, "Generated meeting title")
        XCTAssertTrue(current.isFavorite)
    }

    func testRecordingsSheetObservesMeetingIntelligenceFeatureSnapshotWithoutAppModelRelay() async throws {
        let fixture = try RecordingsMeetingIntelligenceRenderFixture()
        defer { fixture.remove() }
        fixture.feature.reload(sessions: [fixture.session])
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)

        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }
        host.select(.recordings)

        XCTAssertTrue(
            host.click(
                atAccessibilityFrame: "recorder.row.transcript.\(fixture.session.id.lastPathComponent)"
            ),
            "The actual RecordingsLibraryView transcript route must open its detail sheet."
        )
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier("recorder.transcript.detail.root")
        }
        XCTAssertTrue(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceGenerate))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle))
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))

        var appModelChanges = 0
        let appModelChange = fixture.model.objectWillChange.sink { _ in
            appModelChanges += 1
        }
        defer { appModelChange.cancel() }

        fixture.feature.generate(for: fixture.session)
        await fulfillment(of: [fixture.generatorEntered], timeout: 1)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceCancel)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceStatus)
        }

        await fixture.generationGate.release()
        await fulfillment(of: [fixture.generatorFinished, fixture.published], timeout: 1)
        await fixture.coordinator.waitUntilIdleForTesting(sessionID: fixture.session.id)
        try waitUntil(timeout: 1) {
            host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSummary)
                && host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceSuggestedTitle)
        }

        XCTAssertTrue(host.containsAccessibilityLabel("Generated title"))
        XCTAssertFalse(host.containsAccessibilityIdentifier(RecorderActionID.meetingIntelligenceCancel))
        XCTAssertEqual(
            appModelChanges,
            0,
            "The open production sheet must refresh from MeetingIntelligenceFeatureModel, not AppModel.objectWillChange."
        )
        XCTAssertFalse(host.containsView(named: "AVPlayerView"))
        XCTAssertFalse(host.containsView(named: "RecordingPlaybackView"))
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

    func testMinimumSettingsKeepsReadyTeamsStatusInsideWindow() throws {
        let fixture = makeReadyTeamsFixture()
        let host = try makeWorkspaceHost(
            model: fixture.model,
            size: .init(width: 860, height: 680)
        )
        defer { host.close() }

        host.select(.settings)

        let frame = try XCTUnwrap(
            host.frame(
                forAccessibilityIdentifier: "teams-mute-sync-status"
            ),
            "Missing Teams mute-sync status"
        )
        XCTAssertTrue(
            host.windowContentRect.contains(frame),
            "Ready Teams status must remain inside the 860×680 window: \(frame)"
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
        fixture.model.seedLibrarySessionsForTesting([session])
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

    private func makeReadyTeamsFixture() -> StartupDisabledFixture {
        let suiteName =
            "RecorderWorkspaceRenderTests.ready-teams.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let client = RenderTeamsMuteSyncClient()
        let model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            teamsMuteSyncClient: client,
            teamsIntegrationScheduler: { operation in operation() }
        )
        model.systemAudioPermission = .notDetermined
        model.microphonePermission = .granted
        model.installTeamsMuteSync()
        client.emit(.status(.ready))
        return .init(model: model, defaults: defaults)
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

/// This fixture deliberately mounts the production workspace and opens the
/// production `RecordingsLibraryView` sheet. The local feature fakes only
/// control asynchronous MI work; they do not replace the view under test.
@MainActor
private final class RecordingsMeetingIntelligenceRenderFixture {
    let workspace: URL
    let session: RecordingSession
    let model: AppModel
    let coordinator: MeetingIntelligenceJobCoordinator
    let feature: MeetingIntelligenceFeatureModel
    let generationGate = RenderMeetingIntelligenceGenerationGate()
    let generatorEntered = XCTestExpectation(description: "recordings MI generation entered")
    let generatorFinished = XCTestExpectation(description: "recordings MI generation finished")
    let published = XCTestExpectation(description: "recordings MI typed publication")

    init() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recordings-mi-render-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let folder = workspace.appendingPathComponent("recordings-mi-session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recordingURL = folder.appendingPathComponent("recording.m4a")
        try Data().write(to: recordingURL)
        let transcriptURL = TranscriptDocumentStore.editableURL(in: folder)
        let transcriptData = Data("Production recordings transcript".utf8)
        try transcriptData.write(to: transcriptURL)
        session = .init(
            id: RecordingLibraryURLIdentity.normalized(folder),
            folderURL: folder,
            recordingURL: recordingURL,
            createdAt: .distantPast,
            duration: 12,
            fileSize: 0,
            metadata: .init(title: "Production recordings session")
        )

        let transcript = TranscriptDocumentSnapshot(
            url: transcriptURL,
            data: transcriptData,
            revision: .init(
                sha256: "sha256:" + String(repeating: "c", count: 64),
                byteCount: transcriptData.count
            )
        )
        let generator = RenderMeetingIntelligenceGenerator(
            entered: generatorEntered,
            finished: generatorFinished,
            gate: generationGate
        )
        coordinator = .init(
            providerRepository: RenderMeetingIntelligenceRepository(),
            expectedPublicationSourceID: UUID(),
            transcriptReader: RenderMeetingIntelligenceTranscriptReader(snapshot: transcript),
            availabilityChecker: RenderMeetingIntelligenceAvailability(),
            generator: generator,
            publisher: RenderMeetingIntelligencePublisher(published: published),
            artifactStore: RenderMeetingIntelligenceArtifactStore(),
            stateStore: RenderMeetingIntelligenceStateStore()
        )
        feature = .init(coordinator: coordinator)
        let defaultsName = "RecorderWorkspaceRenderTests.mi.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        model = AppModel(
            defaults: defaults,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false,
            initialOutputFolder: workspace,
            meetingIntelligenceFeature: feature
        )
        model.systemAudioPermission = .granted
        model.microphonePermission = .granted
        model.seedLibrarySessionsForTesting([session])
        // Deliberately detach AppModel's compatibility callback. The durable
        // publisher expectation below still proves publication occurred, while
        // the open production sheet can only update through its observed
        // MeetingIntelligenceFeatureModel snapshot.
        feature.onPublished = { _ in }
    }

    func remove() {
        feature.shutdown()
        try? FileManager.default.removeItem(at: workspace)
    }
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
final class WorkspaceHost {
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

    func containsView(named className: String) -> Bool {
        renderedRoots.flatMap { allViews(startingAt: $0) }.contains {
            String(describing: type(of: $0)).contains(className)
        }
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

    private func layout() {
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    private var renderedRoots: [NSView] {
        // The transcript detail is an AppKit sheet owned by this host window.
        // Do not search every application window: playback lifecycle tests can
        // leave unrelated `AVPlayerView` windows alive in the same process.
        let windows = [window] + window.sheets
        var seen = Set<ObjectIdentifier>()
        return windows.compactMap(\.contentView).filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    private func view(forAccessibilityIdentifier identifier: String) -> NSView? {
        renderedRoots.lazy.compactMap {
            self.findView(forAccessibilityIdentifier: identifier, in: $0)
        }.first
    }

    private func findView(
        forAccessibilityIdentifier identifier: String,
        in candidate: NSView
    ) -> NSView? {
        if candidate.accessibilityIdentifier() == identifier { return candidate }
        for subview in candidate.subviews {
            if let found = findView(forAccessibilityIdentifier: identifier, in: subview) {
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
                if let found = find(in: accessibilityChildren(of: child)) {
                    return found
                }
            }
            return nil
        }
        for root in renderedRoots {
            if root.accessibilityIdentifier() == identifier {
                return root
            }
            if let found = find(in: root.accessibilityChildren() ?? []) {
                return found
            }
        }
        return nil
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

    private func view(withAccessibilityLabel label: String) -> NSView? {
        renderedRoots.lazy.compactMap {
            self.findView(withAccessibilityLabel: label, in: $0)
        }.first
    }

    private func findView(
        withAccessibilityLabel label: String,
        in candidate: NSView
    ) -> NSView? {
        if candidate.accessibilityLabel() == label { return candidate }
        for subview in candidate.subviews {
            if let found = findView(withAccessibilityLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

    private func allViews(startingAt view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(startingAt: $0) }
    }

}

private enum WorkspaceHostError: Error {
    case missingAccessibilityElement(String)
}

private final class RenderTeamsMuteSyncClient: TeamsMuteSyncing {
    private var onEvent: ((TeamsMuteSyncEvent) -> Void)?

    func start(onEvent: @escaping (TeamsMuteSyncEvent) -> Void) {
        self.onEvent = onEvent
    }

    func stop() {
        onEvent = nil
    }

    func reconnect() {}

    func requestPairing() {}

    func emit(_ event: TeamsMuteSyncEvent) {
        onEvent?(event)
    }
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

private final class RenderMeetingIntelligenceRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private let value = try! OpenAICompatibleProviderSnapshot.validated(
        profile: .validated(
            baseURLText: "http://127.0.0.1:8080",
            asrModel: "asr",
            llmModel: "llm",
            language: "en",
            prompt: ""
        ),
        apiKey: nil
    )

    func loadProfile() throws -> OpenAICompatibleProviderProfile? { value.profile }
    func setActiveProviderKind(_: AIProviderKind) throws {}
    func save(profile _: OpenAICompatibleProviderProfile, replacementAPIKey _: String?) throws {}
    func snapshot() throws -> OpenAICompatibleProviderSnapshot { value }
    func snapshot(overriding _: OpenAICompatibleProviderProfile) throws -> OpenAICompatibleProviderSnapshot { value }
    func hasAPIKey() throws -> Bool { false }
    func removeAPIKey() throws {}
    func migrateLegacyIfNeeded(settingsURL _: URL) throws -> LegacyProviderMigrationOutcome { .notFound }
}

private struct RenderMeetingIntelligenceAvailability: MeetingIntelligenceAvailabilityChecking {
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability { .confirmed }
}

private actor RenderMeetingIntelligenceGenerationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RenderMeetingIntelligenceGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private let entered: XCTestExpectation
    private let finished: XCTestExpectation
    private let gate: RenderMeetingIntelligenceGenerationGate

    init(
        entered: XCTestExpectation,
        finished: XCTestExpectation,
        gate: RenderMeetingIntelligenceGenerationGate
    ) {
        self.entered = entered
        self.finished = finished
        self.gate = gate
    }

    func generate(
        transcript _: TranscriptDocumentSnapshot,
        snapshot _: OpenAICompatibleProviderSnapshot,
        onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        entered.fulfill()
        await gate.wait()
        finished.fulfill()
        return .init(title: "Generated title", summary: "Generated summary")
    }
}

private final class RenderMeetingIntelligenceTranscriptReader: TranscriptDocumentReading, @unchecked Sendable {
    let snapshot: TranscriptDocumentSnapshot

    init(snapshot: TranscriptDocumentSnapshot) {
        self.snapshot = snapshot
    }

    func readCanonical(
        in _: URL,
        allowLegacy _: Bool
    ) throws -> TranscriptDocumentSnapshot {
        snapshot
    }
}

private struct RenderMeetingIntelligencePublisher: MeetingIntelligencePublishing {
    let published: XCTestExpectation

    func publish(
        _ request: MeetingIntelligencePublicationRequest
    ) async throws -> MeetingIntelligencePublicationOutcome {
        published.fulfill()
        return .init(
            artifact: .init(
                schemaVersion: 1,
                summary: "Generated summary",
                suggestedTitle: "Generated title",
                sourceTranscriptSHA256: request.sourceRevision.sha256,
                sourceTranscriptByteCount: request.sourceRevision.byteCount,
                model: request.snapshot.profile.llmModel,
                generatedAt: .distantPast,
                intent: request.intent
            ),
            titleOutcome: .applied
        )
    }
}

private final class RenderMeetingIntelligenceArtifactStore: MeetingIntelligenceArtifactStoring, @unchecked Sendable {
    func load(in _: URL) throws -> MeetingIntelligenceArtifact? { nil }
    func stage(_: MeetingIntelligenceArtifact, in _: URL) throws -> URL { URL(fileURLWithPath: "/tmp/render-mi-stage") }
    func promoteStaged(_: URL, in _: URL) throws {}
    func removeStaged(_: URL, in _: URL) throws {}
}

private final class RenderMeetingIntelligenceStateStore: MeetingIntelligenceStateStoring, @unchecked Sendable {
    func load(in _: URL) throws -> MeetingIntelligenceState? { nil }
    func save(_: MeetingIntelligenceState, in _: URL) throws {}
    func remove(in _: URL) throws {}
}
