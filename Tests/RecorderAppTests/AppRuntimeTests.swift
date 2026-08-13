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

    func testDisabledRuntimeDoesNotStartControlServerAndEnableStartsIt() {
        let suiteName = "AppRuntimeControlPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let policy = LocalRecorderControlPolicy(defaults: defaults)
        let model = AppModel(defaults: defaults, localRecorderControlPolicy: policy, performStartupWork: false)
        let socketPath = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString).sock").path
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let server = RecorderControlServerRuntime(model: model, serverFactory: { handler in
            RecorderControlSocketServer(socketPath: socketPath, handler: handler)
        })
        let runtime = AppRuntime(model: model, controlServerRuntimeFactory: { _ in server })
        defer { runtime.shutdown() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        model.setLocalRecorderControlEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        model.setLocalRecorderControlEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testDisablingControlStopsServerWithoutChangingModelState() {
        let suiteName = "AppRuntimeControlPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let policy = LocalRecorderControlPolicy(defaults: defaults)
        policy.setEnabled(true)
        let model = AppModel(defaults: defaults, localRecorderControlPolicy: policy, performStartupWork: false)
        model.setTeamsAutoMeetingEnabled(true)
        model.setRecorderMicMuted(true)
        let socketPath = FileManager.default.temporaryDirectory.appendingPathComponent("control-\(UUID().uuidString).sock").path
        defer { try? FileManager.default.removeItem(atPath: socketPath) }
        let server = RecorderControlServerRuntime(model: model, serverFactory: { handler in
            RecorderControlSocketServer(socketPath: socketPath, handler: handler)
        })
        let runtime = AppRuntime(model: model, controlServerRuntimeFactory: { _ in server })
        defer { runtime.shutdown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        model.setLocalRecorderControlEnabled(false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(model.teamsAutoMeetingEnabled)
        XCTAssertTrue(model.localMicMuted)
        XCTAssertFalse(model.recorder.isRecording)
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
