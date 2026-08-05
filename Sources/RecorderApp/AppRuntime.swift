import Foundation

@MainActor
final class AppRuntime {
    let model: AppModel
    private let recordingController: RecordingControllerCoordinator
    private let controlServerRuntime: RecorderControlServerRuntime

    init(
        model: AppModel? = nil,
        recordingControllerFactory:
            (any RecordingControllerPresenterFactory)? = nil,
        controlServerRuntimeFactory:
            ((AppModel) -> RecorderControlServerRuntime)? = nil
    ) {
        let model = model ?? AppModel()
        self.model = model
        recordingController = RecordingControllerCoordinator(
            model: model,
            presenterFactory: recordingControllerFactory
                ?? RecordingControllerPanelPresenterFactory()
        )
        controlServerRuntime = controlServerRuntimeFactory?(model)
            ?? RecorderControlServerRuntime(
                model: model,
                bundleIdentifier: Bundle.main.bundleIdentifier
                    ?? "local.meeting.recorder"
            )
        try? controlServerRuntime.start()
    }

    func shutdown() {
        controlServerRuntime.stop()
        recordingController.shutdown()
        model.shutdown()
    }
}
