import Foundation

@MainActor
protocol RecorderControlServerRunning: AnyObject {
    func start() throws
    func stop()
}

@MainActor
final class AppRuntime {
    let model: AppModel
    private let recordingController: RecordingControllerCoordinator
    private let controlServerRuntime: any RecorderControlServerRunning
    private var isControlServerRunning = false

    init(
        model: AppModel? = nil,
        recordingControllerFactory:
            (any RecordingControllerPresenterFactory)? = nil,
        controlServerRuntimeFactory:
            ((AppModel) -> any RecorderControlServerRunning)? = nil
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
        model.localRecorderControlPolicy.onChange = { [weak self] _ in
            self?.reconcileControlServer()
        }
        reconcileControlServer()
    }

    func shutdown() {
        model.localRecorderControlPolicy.onChange = nil
        stopControlServerIfNeeded()
        recordingController.shutdown()
        model.shutdown()
    }

    private func reconcileControlServer() {
        if model.localRecorderControlPolicy.isEnabled {
            guard !isControlServerRunning else { return }
            do {
                try controlServerRuntime.start()
                isControlServerRunning = true
            } catch {}
        } else {
            stopControlServerIfNeeded()
        }
    }

    private func stopControlServerIfNeeded() {
        guard isControlServerRunning else { return }
        controlServerRuntime.stop()
        isControlServerRunning = false
    }
}
