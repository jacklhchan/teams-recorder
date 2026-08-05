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
        let model = AppModel(
            defaults: UserDefaults(suiteName: suiteName)!,
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
