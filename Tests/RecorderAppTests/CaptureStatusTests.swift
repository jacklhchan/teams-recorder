import CoreMedia
import XCTest
@testable import RecorderApp

final class CaptureStatusTests: XCTestCase {
    func testDeniedSystemAudioPermissionBlocksStart() {
        let state = CaptureReadiness.evaluate(
            permission: .denied,
            selection: .init(mode: .allSystemAudio),
            resolvedSelection: .allSystemAudio,
            microphoneAvailable: true
        )

        XCTAssertEqual(
            state,
            .blocked("Screen & System Audio Recording permission is required.")
        )
    }

    func testDisconnectedSelectedAppShowsReconnectWithoutChangingMode() {
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )
        let state = CaptureReadiness.evaluate(
            permission: .granted,
            selection: selection,
            resolvedSelection: .disconnected("com.microsoft.teams2"),
            microphoneAvailable: true
        )

        XCTAssertEqual(state, .reconnectRequired)
        XCTAssertEqual(selection.mode, .selectedApplication)
        XCTAssertEqual(selection.selectedBundleIdentifier, "com.microsoft.teams2")
    }

    func testSelectedAppWithoutBundleIDIsBlockedInsteadOfCapturingAllAudio() {
        XCTAssertEqual(
            CaptureReadiness.evaluate(
                permission: .granted,
                selection: .init(mode: .selectedApplication),
                resolvedSelection: .disconnected(""),
                microphoneAvailable: true
            ),
            .blocked("Choose an application to capture.")
        )
    }

    func testMissingMicrophoneBlocksStart() {
        XCTAssertEqual(
            CaptureReadiness.evaluate(
                permission: .granted,
                selection: .init(mode: .allSystemAudio),
                resolvedSelection: .allSystemAudio,
                microphoneAvailable: false
            ),
            .blocked("Microphone permission and an available microphone are required.")
        )
    }

    func testPermissionAndDisconnectedStatesExposeActions() {
        XCTAssertEqual(
            CaptureStatusRowMapper.row(for: .denied),
            .init(
                title: "Screen & System Audio Recording",
                message: "Permission denied. Open System Settings, then restart or retry.",
                action: .openSettings
            )
        )
        XCTAssertEqual(
            CaptureStatusRowMapper.row(for: .reconnectRequired),
            .init(
                title: "System Audio",
                message: "App audio disconnected",
                action: .reconnect
            )
        )
    }

    func testCaptureSelectionPersistenceRoundTripUsesOnlyApprovedKeys() {
        let defaults = UserDefaults(suiteName: "CaptureStatusTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let persistence = CaptureSelectionPersistence(defaults: defaults)
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )

        persistence.save(selection: selection, microphoneUID: "BuiltInMicrophoneDevice")

        XCTAssertEqual(persistence.loadSelection(), selection)
        XCTAssertEqual(persistence.loadMicrophoneUID(), "BuiltInMicrophoneDevice")
        XCTAssertEqual(
            Set(defaults.dictionaryRepresentation().keys).intersection(CaptureSelectionPersistence.keys),
            Set(CaptureSelectionPersistence.keys)
        )
    }

    @MainActor
    func testRuntimeDisconnectLatchesReconnectAcrossRefreshWithoutMicrophoneReadiness() {
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: "com.microsoft.teams2"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let sourceSessionID = UUID()
        let disconnected = CaptureConnectionProjection.observeSystemConnection(
            current: .connected,
            snapshot: CaptureConnectionSnapshot(
                sourceSessionID: sourceSessionID,
                activeSelection: .application(restarted),
                isMonitoring: true,
                isSystemCaptureConnected: false
            ),
            selection: selection
        )

        XCTAssertEqual(
            disconnected,
            .selectedApplicationDisconnected(
                sourceSessionID: sourceSessionID,
                bundleIdentifier: "com.microsoft.teams2"
            )
        )
        XCTAssertEqual(
            CaptureConnectionProjection.resolveAfterRefresh(
                selection: selection,
                applications: [restarted],
                connectionState: disconnected
            ),
            .disconnected("com.microsoft.teams2")
        )
        XCTAssertTrue(
            CaptureConnectionProjection.canReconnect(
                systemPermission: .granted,
                selection: selection,
                connectionState: disconnected,
                connectionSnapshot: CaptureConnectionSnapshot(
                    sourceSessionID: sourceSessionID,
                    activeSelection: .application(restarted),
                    isMonitoring: true,
                    isSystemCaptureConnected: false
                ),
                isLifecycleWorking: false
            )
        )
    }

    func testTerminalOrDisconnectedProjectionRecoversForHealthyMatchingMonitoringSession() {
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: application.bundleIdentifier
        )
        let healthySessionID = UUID()
        let healthySnapshot = CaptureConnectionSnapshot(
            sourceSessionID: healthySessionID,
            activeSelection: .application(application),
            isMonitoring: true,
            isSystemCaptureConnected: true
        )

        XCTAssertEqual(
            CaptureConnectionProjection.observeSystemConnection(
                current: .terminal,
                snapshot: healthySnapshot,
                selection: selection
            ),
            .connected
        )
        XCTAssertEqual(
            CaptureConnectionProjection.observeSystemConnection(
                current: .selectedApplicationDisconnected(
                    sourceSessionID: UUID(),
                    bundleIdentifier: application.bundleIdentifier
                ),
                snapshot: healthySnapshot,
                selection: selection
            ),
            .connected
        )
    }

    func testStoppedDisconnectLatchAllowsIdleRefreshRecoveryWhenAppReappears() {
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: application.bundleIdentifier,
            name: application.name
        )
        let selection = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: application.bundleIdentifier
        )
        let disconnected = CaptureConnectionProjection.observeSystemConnection(
            current: .connected,
            snapshot: CaptureConnectionSnapshot(
                sourceSessionID: UUID(),
                activeSelection: .application(application),
                isMonitoring: true,
                isSystemCaptureConnected: false
            ),
            selection: selection
        )
        let idle = CaptureConnectionProjection.observeSystemConnection(
            current: disconnected,
            snapshot: .idle,
            selection: selection
        )

        XCTAssertEqual(idle, .connected)
        XCTAssertEqual(
            CaptureConnectionProjection.resolveAfterRefresh(
                selection: selection,
                applications: [],
                connectionState: idle
            ),
            .disconnected(application.bundleIdentifier)
        )
        let recovered = CaptureConnectionProjection.resolveAfterRefresh(
            selection: selection,
            applications: [restarted],
            connectionState: idle
        )
        XCTAssertEqual(recovered, .application(restarted))
        XCTAssertEqual(
            CaptureReadiness.evaluate(
                permission: .granted,
                selection: selection,
                resolvedSelection: recovered,
                microphoneAvailable: true
            ),
            .ready
        )
    }

    func testConnectionProjectionAttributesDisconnectToActiveSourceNotUIIntent() {
        let applicationA = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.example.A",
            name: "Application A"
        )
        let applicationB = CaptureApplication(
            processID: 99,
            bundleIdentifier: "com.example.B",
            name: "Application B"
        )
        let intentB = CaptureSelection(
            mode: .selectedApplication,
            selectedBundleIdentifier: applicationB.bundleIdentifier
        )
        let sessionA = UUID()
        let sessionB = UUID()

        XCTAssertEqual(
            CaptureConnectionProjection.observeSystemConnection(
                current: .connected,
                snapshot: CaptureConnectionSnapshot(
                    sourceSessionID: sessionA,
                    activeSelection: .application(applicationA),
                    isMonitoring: true,
                    isSystemCaptureConnected: false
                ),
                selection: intentB
            ),
            .connected
        )
        XCTAssertEqual(
            CaptureConnectionProjection.observeSystemConnection(
                current: .terminal,
                snapshot: CaptureConnectionSnapshot(
                    sourceSessionID: sessionB,
                    activeSelection: .application(applicationB),
                    isMonitoring: true,
                    isSystemCaptureConnected: true
                ),
                selection: intentB
            ),
            .connected
        )
        XCTAssertEqual(
            CaptureConnectionProjection.observeSystemConnection(
                current: .connected,
                snapshot: CaptureConnectionSnapshot(
                    sourceSessionID: sessionB,
                    activeSelection: .application(applicationB),
                    isMonitoring: true,
                    isSystemCaptureConnected: false
                ),
                selection: intentB
            ),
            .selectedApplicationDisconnected(
                sourceSessionID: sessionB,
                bundleIdentifier: applicationB.bundleIdentifier
            )
        )
    }

    @MainActor
    func testUnavailableMicrophoneIntentSurvivesRefreshAndRestoresWhenDeviceReturns() {
        let suiteName = "CaptureStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = CaptureSelectionPersistence(defaults: defaults)
        persistence.saveMicrophoneUID("AirPods-UID")
        var availableDevices: [AudioDevice] = []
        let model = AppModel(
            defaults: defaults,
            inputDevices: { availableDevices },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )

        model.refreshDevices()

        XCTAssertEqual(model.selectedMicrophoneUID, "AirPods-UID")
        XCTAssertNil(model.selectedMicDevice)
        XCTAssertEqual(persistence.loadMicrophoneUID(), "AirPods-UID")

        availableDevices = [
            AudioDevice(
                id: 7,
                uid: "AirPods-UID",
                name: "AirPods",
                manufacturer: "Apple",
                channelCount: 1
            )
        ]
        model.refreshDevices()

        XCTAssertEqual(model.selectedMicDevice?.uid, "AirPods-UID")
        XCTAssertEqual(persistence.loadMicrophoneUID(), "AirPods-UID")
    }

    func testScreenPermissionStatusIncludesRestartAndRetryGuidance() {
        XCTAssertEqual(
            CaptureStatusRowMapper.row(for: .denied).message,
            "Permission denied. Open System Settings, then restart or retry."
        )
    }

    func testLifecycleGateRejectsOverlapAndStaleCompletionCannotClearStop() throws {
        var gate = CaptureLifecycleGate()
        let refresh = try XCTUnwrap(gate.begin(.refresh))

        XCTAssertNil(gate.begin(.start))
        let stop = try XCTUnwrap(gate.cancelAndBeginStop())
        XCTAssertNil(gate.cancelAndBeginStop())
        XCTAssertFalse(gate.finish(refresh))
        XCTAssertTrue(gate.isWorking)
        XCTAssertTrue(gate.accepts(stop))

        XCTAssertTrue(gate.finish(stop))
        XCTAssertFalse(gate.isWorking)
    }

    @MainActor
    func testDoubleStopCoalescesUntilRealFinalizationAndKeepsSavedStatus() async throws {
        let source = PausedStopCaptureSource()
        let writer = AppModelStopWriter()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4
        )
        let suiteName = "CaptureStatusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: defaults,
            recorder: engine,
            inputDevices: { [] },
            defaultInputDeviceID: { nil },
            performStartupWork: false
        )
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        model.startOrStop()
        await waitUntil { source.stopCount == 1 }
        model.startOrStop()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(source.stopCount, 1)
        XCTAssertTrue(model.isCaptureLifecycleWorking)
        XCTAssertNotEqual(model.statusMessage, "No active recording.")

        source.resumeStop()
        await waitUntil { !model.isCaptureLifecycleWorking }

        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(writer.closeCount, 1)
        XCTAssertTrue(model.statusMessage.hasPrefix("Recording saved:"))
    }

    func testDisconnectedCaptureMapsToWarning() {
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .applicationDisconnected("Teams")),
            .warning("App audio disconnected")
        )
    }

    func testAudioDeviceCarriesStableUID() {
        let device = AudioDevice(
            id: 1,
            uid: "BuiltInMicrophoneDevice",
            name: "MacBook Microphone",
            manufacturer: "Apple",
            channelCount: 1
        )

        XCTAssertEqual(device.uid, "BuiltInMicrophoneDevice")
    }

    func testPTSConvertsToFortyEightKStartFrameUsingRoundTowardZero() {
        let pts = CMTime(value: 1_001, timescale: 1_000)

        XCTAssertEqual(SampleBufferConverter.startFrame(for: pts), 48_048)
    }

    func testPersistentConverterNormalizesMonoPCMToStereoAtFortyEightK() throws {
        let packet = OwnedAudioPacket(
            pcm: OwnedPCMBuffer(sampleRate: 48_000, channels: [[0.25, -0.5]]),
            presentationTime: CMTime(value: 2, timescale: 1)
        )
        let converter = PersistentAudioResampler(source: .microphone)

        let block = try XCTUnwrap(converter.process(packet))

        XCTAssertEqual(block.startFrame, 96_000)
        XCTAssertEqual(block.left, [0.25, -0.5])
        XCTAssertEqual(block.right, [0.25, -0.5])
    }

    func testLateBufferFromStoppedGenerationIsDiscarded() {
        let gate = CaptureSessionGate()
        let stream = NSObject()
        let token = gate.activate(streamIdentity: ObjectIdentifier(stream))

        XCTAssertTrue(gate.accepts(token, streamIdentity: ObjectIdentifier(stream)))
        gate.deactivate(token)

        XCTAssertFalse(gate.accepts(token, streamIdentity: ObjectIdentifier(stream)))
    }

    func testSelectedAppResolutionRequiresCurrentPID() {
        let selected = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: selected.bundleIdentifier,
            name: selected.name
        )

        XCTAssertNil(
            CaptureProcessResolver.currentApplication(
                for: .application(selected),
                availableApplications: [restarted]
            )
        )
    }

    func testMicrophoneUIDResolverRequiresExactAVFoundationMatch() throws {
        XCTAssertEqual(
            try MicrophoneDeviceResolver.resolve(
                coreAudioUID: "AirPods-UID",
                availableCaptureDeviceUIDs: ["BuiltIn-UID", "AirPods-UID"]
            ),
            "AirPods-UID"
        )
        XCTAssertThrowsError(
            try MicrophoneDeviceResolver.resolve(
                coreAudioUID: "AirPods-UID",
                availableCaptureDeviceUIDs: ["BuiltIn-UID"]
            )
        )
    }

    func testSystemDefaultMicrophoneMayRemainNilButEmptyUIDFails() throws {
        XCTAssertNil(try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(coreAudioUID: nil))
        XCTAssertThrowsError(
            try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(coreAudioUID: "")
        )
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.volatileDomainNames.first(where: { $0.hasPrefix("CaptureStatusTests.") })
            ?? "CaptureStatusTests"
    }

    private func temporaryFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

private final class PausedStopCaptureSource: CaptureSourceProtocol {
    private(set) var stopCount = 0
    private var stopContinuation: CheckedContinuation<Void, Never>?

    func refreshContent() async throws -> [CaptureApplication] { [] }

    func reconnect(selection: ResolvedCaptureSelection) async throws {}

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {}

    func stop() async {
        stopCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }
}

private final class AppModelStopWriter: MixedAudioWriting {
    private(set) var closeCount = 0

    func write(_ block: MixedAudioBlock) throws {}

    func close() throws {
        closeCount += 1
    }
}
