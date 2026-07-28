import Combine
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingControllerPanelTests: XCTestCase {
    func testEpisodeEmitsOneCommandPerRecordingTransition() {
        var episode = RecordingControllerPanelEpisode()

        XCTAssertEqual(episode.handle(isRecording: false), .none)
        XCTAssertEqual(episode.handle(isRecording: true), .present)
        XCTAssertEqual(episode.handle(isRecording: true), .none)
        XCTAssertEqual(episode.handle(isRecording: false), .dismiss)
        XCTAssertEqual(episode.handle(isRecording: false), .none)
        XCTAssertEqual(episode.handle(isRecording: true), .present)
    }

    func testCoordinatorPresentsOncePerRecordingAndReappearsForNextRecording() {
        let fixture = makeFixture()
        let subject = PassthroughSubject<Bool, Never>()
        let presenter = RecordingControllerPresenterSpy()
        let coordinator = RecordingControllerCoordinator(
            model: fixture.model,
            presenterFactory: RecordingControllerPresenterFactorySpy(
                presenter: presenter
            ),
            isRecordingPublisher: subject.eraseToAnyPublisher()
        )

        subject.send(false)
        XCTAssertEqual(presenter.presentedModels.count, 0)
        XCTAssertEqual(presenter.dismissCount, 0)

        subject.send(true)
        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)
        XCTAssertTrue(presenter.presentedModels.first === fixture.model)

        subject.send(false)
        subject.send(false)
        XCTAssertEqual(presenter.dismissCount, 1)

        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 2)

        withExtendedLifetime(coordinator) {}
    }

    func testCoordinatorDismissesAndStopsObservingOnTeardown() async {
        let fixture = makeFixture()
        let subject = PassthroughSubject<Bool, Never>()
        let presenter = RecordingControllerPresenterSpy()
        var coordinator: RecordingControllerCoordinator? =
            RecordingControllerCoordinator(
                model: fixture.model,
                presenterFactory: RecordingControllerPresenterFactorySpy(
                    presenter: presenter
                ),
                isRecordingPublisher: subject.eraseToAnyPublisher()
            )

        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)

        coordinator = nil
        await Task.yield()
        XCTAssertEqual(presenter.dismissCount, 1)

        subject.send(false)
        subject.send(true)
        XCTAssertEqual(presenter.presentedModels.count, 1)
        _ = coordinator
    }

    private func makeFixture() -> (
        model: AppModel,
        recorder: RecordingEngine
    ) {
        let recorder = RecordingEngine()
        let model = AppModel(
            recorder: recorder,
            performStartupWork: false
        )
        return (model, recorder)
    }
}

@MainActor
private final class RecordingControllerPresenterSpy:
    RecordingControllerPresenting
{
    private(set) var presentedModels: [AppModel] = []
    private(set) var dismissCount = 0

    func present(model: AppModel) {
        presentedModels.append(model)
    }

    func dismiss() {
        dismissCount += 1
    }
}

@MainActor
private struct RecordingControllerPresenterFactorySpy:
    RecordingControllerPresenterFactory
{
    let presenter: RecordingControllerPresenterSpy

    func makePresenter() -> any RecordingControllerPresenting {
        presenter
    }
}
