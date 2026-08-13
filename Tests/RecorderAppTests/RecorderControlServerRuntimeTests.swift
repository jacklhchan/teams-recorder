import Foundation
import XCTest
@testable import RecorderApp
@testable import RecorderControl

@MainActor
final class RecorderControlServerRuntimeTests: XCTestCase {
    func testAppRuntimeServesOneStatusRequestAndRemovesSocketOnShutdown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lmr-runtime-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("control.sock").path
        let outputFolder = directory.appendingPathComponent("recordings", isDirectory: true)
        let suiteName = "RecorderControlServerRuntimeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: LocalRecorderControlPolicy.defaultsKey)
        let model = AppModel(
            defaults: defaults,
            performStartupWork: false,
            initialOutputFolder: outputFolder
        )
        let controlRuntime = RecorderControlServerRuntime(
            model: model,
            serverFactory: { handler in
                RecorderControlSocketServer(
                    socketPath: socketPath,
                    handler: handler
                )
            }
        )
        let runtime = AppRuntime(
            model: model,
            recordingControllerFactory: ControlRuntimePresenterFactory(),
            controlServerRuntimeFactory: { _ in controlRuntime }
        )
        defer { runtime.shutdown() }

        let response = try await RecorderControlSocketClient().send(
            .init(requestID: "runtime-status", command: .status),
            to: socketPath,
            timeout: 1
        )

        XCTAssertEqual(response.requestID, "runtime-status")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.status?.outputFolder, outputFolder.path)

        runtime.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStoppedRuntimeRejectsCapturedHandlerWithoutTouchingModel() async throws {
        let suiteName = "RecorderControlServerRuntimeTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
            performStartupWork: false
        )
        model.setTeamsAutoMeetingEnabled(true)
        var capturedHandler: RecorderControlSocketServer.Handler?
        let runtime = RecorderControlServerRuntime(
            model: model,
            serverFactory: { handler in
                capturedHandler = handler
                return RecorderControlSocketServer(
                    socketPath: FileManager.default.temporaryDirectory
                        .appendingPathComponent("unused-\(UUID().uuidString.prefix(8)).sock").path,
                    handler: handler
                )
            }
        )
        try runtime.start()
        runtime.stop()

        let response = await capturedHandler?(.init(
            requestID: "after-stop",
            command: .setAuto,
            argument: "off"
        ))

        XCTAssertEqual(response?.error?.code, "server_stopped")
        XCTAssertTrue(model.teamsAutoMeetingEnabled)
    }
}

@MainActor
private struct ControlRuntimePresenterFactory: RecordingControllerPresenterFactory {
    func makePresenter() -> any RecordingControllerPresenting {
        ControlRuntimePresenter()
    }
}

@MainActor
private final class ControlRuntimePresenter: RecordingControllerPresenting {
    func present(model _: AppModel) {}
    func dismiss() {}
}
