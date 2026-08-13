import XCTest
@testable import RecorderApp
@testable import RecorderControl

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testLocalRecorderControlPolicyDefaultsToDisabledAndPersistsEnable() {
        let suiteName = "LocalRecorderControlPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(LocalRecorderControlPolicy(defaults: defaults).isEnabled)
        LocalRecorderControlPolicy(defaults: defaults).setEnabled(true)
        XCTAssertTrue(LocalRecorderControlPolicy(defaults: defaults).isEnabled)
    }

    func testControlServerLifecycleStartsAndStopsExactlyOnce() {
        let suiteName = "AppRuntimeControlPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let policy = LocalRecorderControlPolicy(defaults: defaults)
        let model = AppModel(defaults: defaults, localRecorderControlPolicy: policy, performStartupWork: false)
        let server = AppRuntimeControlServerSpy()
        let runtime = AppRuntime(model: model, controlServerRuntimeFactory: { _ in server })
        defer { runtime.shutdown() }

        XCTAssertEqual(server.startCount, 0)
        XCTAssertEqual(server.stopCount, 0)
        model.setLocalRecorderControlEnabled(true)
        XCTAssertEqual(server.startCount, 1)
        XCTAssertEqual(server.stopCount, 0)
        model.setLocalRecorderControlEnabled(true)
        XCTAssertEqual(server.startCount, 1)
        model.setLocalRecorderControlEnabled(false)
        XCTAssertEqual(server.stopCount, 1)
        model.setLocalRecorderControlEnabled(false)
        XCTAssertEqual(server.stopCount, 1)
    }

    func testDisablingControlPreservesAnActiveRecordingAutoModeSelectedMicAndMute() async throws {
        let suiteName = "AppRuntimeControlPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let policy = LocalRecorderControlPolicy(defaults: defaults)
        policy.setEnabled(true)
        let device = AudioDevice(id: 1, uid: "selected-mic", name: "Selected Mic", manufacturer: "Test", channelCount: 1)
        let recorder = RecordingEngine(
            captureSource: AppRuntimeCaptureSource(),
            writerFactory: { _ in AppRuntimeAudioWriter() },
            mixerBlockFrames: 4
        )
        let model = AppModel(
            defaults: defaults,
            localRecorderControlPolicy: policy,
            recorder: recorder,
            inputDevices: { [device] },
            defaultInputDeviceID: { device.id },
            performStartupWork: false
        )
        model.selectMicrophone(device)
        model.setTeamsAutoMeetingEnabled(true)
        model.setRecorderMicMuted(true)
        _ = try await recorder.start(
            selection: .allSystemAudio,
            microphoneUID: device.uid,
            baseFolder: temporaryFolder()
        )
        let server = AppRuntimeControlServerSpy()
        let runtime = AppRuntime(model: model, controlServerRuntimeFactory: { _ in server })
        XCTAssertTrue(recorder.isRecording)

        model.setLocalRecorderControlEnabled(false)

        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(model.teamsAutoMeetingEnabled)
        XCTAssertTrue(model.localMicMuted)
        XCTAssertEqual(model.selectedMicrophoneUID, device.uid)

        runtime.shutdown()
        _ = await recorder.stop()
    }

    func testRuntimeShutsDownControllerAndPresenterBeforeModelExactlyOnce() {
        let fixture = makeFixture()
        var producerCallbacksWereStillInstalledDuringDismiss = false
        fixture.presenter.onDismiss = {
            producerCallbacksWereStillInstalledDuringDismiss =
                fixture.model.transcriptionFeature.onSuccessfulPublication != nil
                && fixture.model.libraryFeature.onSessionsLoaded != nil
                && fixture.model.meetingIntelligenceFeature.onPublished != nil
        }
        let runtime = AppRuntime(
            model: fixture.model,
            recordingControllerFactory: fixture.presenterFactory
        )

        runtime.shutdown()
        runtime.shutdown()

        XCTAssertEqual(fixture.presenter.dismissCount, 1)
        XCTAssertTrue(producerCallbacksWereStillInstalledDuringDismiss)
        XCTAssertNil(fixture.model.transcriptionFeature.onSuccessfulPublication)
        XCTAssertNil(fixture.model.libraryFeature.onSessionsLoaded)
        XCTAssertNil(fixture.model.meetingIntelligenceFeature.onPublished)
    }

    func testRuntimeExposesInjectedModelAndCreatesOnePresenter() {
        let fixture = makeFixture()

        let runtime = AppRuntime(
            model: fixture.model,
            recordingControllerFactory: fixture.presenterFactory
        )

        XCTAssertTrue(runtime.model === fixture.model)
        XCTAssertEqual(fixture.presenterFactory.makePresenterCount, 1)
        withExtendedLifetime(runtime) {}
    }

    func testRecordingTransitionPresentsTheInjectedModel() async throws {
        let fixture = makeFixture()
        let runtime = AppRuntime(
            model: fixture.model,
            recordingControllerFactory: fixture.presenterFactory
        )

        _ = try await fixture.recorder.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        XCTAssertEqual(fixture.presenter.presentedModels.count, 1)
        XCTAssertTrue(fixture.presenter.presentedModels.first === fixture.model)

        runtime.shutdown()
        _ = await fixture.recorder.stop()
    }

    func testShutdownDismissesPresenterOnce() {
        let fixture = makeFixture()
        let runtime = AppRuntime(
            model: fixture.model,
            recordingControllerFactory: fixture.presenterFactory
        )

        runtime.shutdown()
        runtime.shutdown()

        XCTAssertEqual(fixture.presenter.dismissCount, 1)
    }

    private func makeFixture() -> AppRuntimeFixture {
        let recorder = RecordingEngine(
            captureSource: AppRuntimeCaptureSource(),
            writerFactory: { _ in AppRuntimeAudioWriter() },
            mixerBlockFrames: 4
        )
        let model = AppModel(
            recorder: recorder,
            performStartupWork: false
        )
        let presenter = AppRuntimePresenterSpy()
        let presenterFactory = AppRuntimePresenterFactorySpy(
            presenter: presenter
        )
        return AppRuntimeFixture(
            model: model,
            recorder: recorder,
            presenter: presenter,
            presenterFactory: presenterFactory
        )
    }

    private func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

@MainActor
private struct AppRuntimeFixture {
    let model: AppModel
    let recorder: RecordingEngine
    let presenter: AppRuntimePresenterSpy
    let presenterFactory: AppRuntimePresenterFactorySpy
}

@MainActor
private final class AppRuntimePresenterSpy: RecordingControllerPresenting {
    private(set) var presentedModels: [AppModel] = []
    private(set) var dismissCount = 0
    var onDismiss: (() -> Void)?

    func present(model: AppModel) {
        presentedModels.append(model)
    }

    func dismiss() {
        dismissCount += 1
        onDismiss?()
    }
}

@MainActor
private final class AppRuntimePresenterFactorySpy:
    RecordingControllerPresenterFactory
{
    let presenter: AppRuntimePresenterSpy
    private(set) var makePresenterCount = 0

    init(presenter: AppRuntimePresenterSpy) {
        self.presenter = presenter
    }

    func makePresenter() -> any RecordingControllerPresenting {
        makePresenterCount += 1
        return presenter
    }
}

private final class AppRuntimeCaptureSource: CaptureSourceProtocol {
    let screenVideoFormat = ScreenVideoFormat(
        width: 1_600,
        height: 900,
        pixelFormat: 0
    )

    func refreshContent() async throws -> [CaptureApplication] { [] }
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { [] }
    func reconnect(selection _: ResolvedCaptureSelection) async throws {}

    func updateVideoTarget(
        _ target: TeamsWindowIdentity?
    ) async throws -> CaptureFilterRevision {
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
}

private final class AppRuntimeAudioWriter: MixedAudioWriting {
    func write(_: MixedAudioBlock) throws {}
    func close() throws {}
}

@MainActor
private final class AppRuntimeControlServerSpy: RecorderControlServerRunning {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}
