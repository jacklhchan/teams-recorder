import Foundation

@MainActor
final class AppRuntime {
    let model: AppModel
    private let recordingController: RecordingControllerCoordinator

    init(
        model: AppModel? = nil,
        recordingControllerFactory:
            (any RecordingControllerPresenterFactory)? = nil
    ) {
        let model = model ?? AppModel()
        self.model = model
        recordingController = RecordingControllerCoordinator(
            model: model,
            presenterFactory: recordingControllerFactory
                ?? RecordingControllerPanelPresenterFactory()
        )
    }

    func shutdown() {
        recordingController.shutdown()
        model.shutdown()
    }
}
