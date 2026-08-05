import RecorderControl
@testable import RecorderControlCLI
import XCTest

final class RecorderCLIApplicationTests: XCTestCase {
    func testExistingSocketSendsOnceWithoutLaunching() async {
        let status = makeStatus()
        let client = FakeClient(results: [.success(makeResponse(status: status))])
        let launcher = FakeLauncher()
        let output = OutputRecorder()
        let application = makeApplication(client: client, launcher: launcher, output: output)

        let exitCode = await application.run(arguments: ["start"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(client.requests.map(\.command), [.start])
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testMissingSocketLaunchesOnceRetriesAndSendsOnceWhenReady() async {
        let client = FakeClient(results: [
            .failure(TestError.unavailable),
            .failure(TestError.unavailable),
            .success(makeResponse(status: makeStatus()))
        ])
        let launcher = FakeLauncher()
        let clock = FakeClock()
        let application = makeApplication(client: client, launcher: launcher, clock: clock)

        let exitCode = await application.run(arguments: ["stop"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(client.requests.count, 3)
        XCTAssertEqual(clock.sleeps, [0.1, 0.1])
    }

    func testStartupTimeoutExitsThree() async {
        let client = FakeClient(defaultResult: .failure(TestError.unavailable))
        let launcher = FakeLauncher()
        let clock = FakeClock()
        let output = OutputRecorder()
        let application = makeApplication(
            client: client,
            launcher: launcher,
            clock: clock,
            output: output
        )

        let exitCode = await application.run(arguments: ["status"])

        XCTAssertEqual(exitCode, 3)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(clock.now, 5, accuracy: 0.0001)
        XCTAssertEqual(output.lines, ["error: Recorder app did not become ready within 5 seconds."])
    }

    func testRejectedOperationExitsFourAndPrintsStableError() async {
        let response = RecorderControlResponse(
            protocolVersion: RecorderControlRequest.currentProtocolVersion,
            requestID: "test-request",
            ok: false,
            status: makeStatus(),
            error: RecorderControlErrorPayload(
                code: "operation-in-progress",
                message: "Recording finalization is in progress."
            )
        )
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.success(response)]),
            output: output
        )

        let exitCode = await application.run(arguments: ["start"])

        XCTAssertEqual(exitCode, 4)
        XCTAssertEqual(
            output.lines,
            ["error [operation-in-progress]: Recording finalization is in progress."]
        )
    }

    func testInvalidUsageExitsTwoAndPrintsUsage() async {
        let output = OutputRecorder()
        let application = makeApplication(client: FakeClient(results: []), output: output)

        let exitCode = await application.run(arguments: ["status", "extra"])

        XCTAssertEqual(exitCode, 2)
        XCTAssertEqual(output.lines, [RecorderCLIApplication.usage])
    }

    func testStatusRendersStableHumanLabels() async {
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.success(makeResponse(status: makeStatus()))]),
            output: output
        )

        let exitCode = await application.run(arguments: ["status"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(output.lines.first, "App: running (1.2.3)")
        XCTAssertTrue(output.lines.contains("Recording: idle"))
        XCTAssertTrue(output.lines.contains("Recorder mic muted: no"))
        XCTAssertEqual(output.lines.last, "Output folder: /tmp/Recordings")
    }

    func testJSONStatusUsesSortedKeysAndEncodesStatusDirectly() async {
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.success(makeResponse(status: makeStatus()))]),
            output: output
        )

        let exitCode = await application.run(arguments: ["status", "--json"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(output.lines.count, 1)
        XCTAssertTrue(output.lines[0].hasPrefix("{\"appRunning\":"))
        XCTAssertEqual(
            try? JSONDecoder().decode(
                RecorderControlStatus.self,
                from: Data(output.lines[0].utf8)
            ),
            makeStatus()
        )
    }

    func testWatchJSONEmitsFirstAndOnlyLaterChangedStatuses() async {
        let first = makeStatus(statusMessage: "Ready")
        let changed = makeStatus(statusMessage: "Recording")
        let client = FakeClient(results: [
            .success(makeResponse(status: first)),
            .success(makeResponse(status: first)),
            .success(makeResponse(status: changed))
        ])
        let clock = FakeClock(cancelAfterSleeps: 2)
        let output = OutputRecorder()
        let application = makeApplication(
            client: client,
            clock: clock,
            output: output
        )

        let exitCode = await application.run(arguments: ["watch", "--json"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(output.lines.count, 2)
        XCTAssertEqual(
            try? output.lines.map {
                try JSONDecoder().decode(RecorderControlStatus.self, from: Data($0.utf8))
            },
            [first, changed]
        )
    }

    private func makeApplication(
        client: FakeClient,
        launcher: FakeLauncher = FakeLauncher(),
        clock: FakeClock = FakeClock(),
        output: OutputRecorder = OutputRecorder()
    ) -> RecorderCLIApplication {
        RecorderCLIApplication(
            client: client,
            launcher: launcher,
            clock: clock,
            writeLine: output.write
        )
    }
}

private enum TestError: Error {
    case unavailable
}

private final class FakeClient: RecorderCLIClient {
    struct Request {
        let command: RecorderControlCommand
        let argument: String?
    }

    private var results: [Result<RecorderControlResponse, Error>]
    private let defaultResult: Result<RecorderControlResponse, Error>?
    private(set) var requests: [Request] = []

    init(
        results: [Result<RecorderControlResponse, Error>] = [],
        defaultResult: Result<RecorderControlResponse, Error>? = nil
    ) {
        self.results = results
        self.defaultResult = defaultResult
    }

    func send(command: RecorderControlCommand, argument: String?) async throws -> RecorderControlResponse {
        requests.append(Request(command: command, argument: argument))
        if !results.isEmpty {
            return try results.removeFirst().get()
        }
        guard let defaultResult else { throw TestError.unavailable }
        return try defaultResult.get()
    }
}

private final class FakeLauncher: RecorderAppLaunching {
    private(set) var launchCount = 0

    func launchInBackground() throws {
        launchCount += 1
    }
}

private final class FakeClock: RecorderCLIClock {
    private(set) var now: TimeInterval = 0
    private(set) var sleeps: [TimeInterval] = []
    private let cancelAfterSleeps: Int?

    init(cancelAfterSleeps: Int? = nil) {
        self.cancelAfterSleeps = cancelAfterSleeps
    }

    func sleep(for interval: TimeInterval) async throws {
        if sleeps.count == cancelAfterSleeps {
            throw CancellationError()
        }
        sleeps.append(interval)
        now += interval
    }
}

private final class OutputRecorder {
    private(set) var lines: [String] = []

    func write(_ line: String) {
        lines.append(line)
    }
}

private func makeResponse(status: RecorderControlStatus) -> RecorderControlResponse {
    RecorderControlResponse(
        protocolVersion: RecorderControlRequest.currentProtocolVersion,
        requestID: "test-request",
        ok: true,
        status: status,
        error: nil
    )
}

private func makeStatus(statusMessage: String = "Ready") -> RecorderControlStatus {
    RecorderControlStatus(
        appRunning: true,
        appVersion: "1.2.3",
        recordingState: "idle",
        lifecycleOperation: "idle",
        recordingOwnership: nil,
        elapsedSeconds: nil,
        activeRecordingFolder: nil,
        statusMessage: statusMessage,
        autoModeEnabled: false,
        autoMeetingState: "idle",
        meetingDetectionState: "not-in-meeting",
        selectedMicrophoneName: "Studio Mic",
        selectedMicrophoneUID: "mic-1",
        localMicMuted: false,
        nativeInputMicMuted: false,
        teamsMicState: "unknown",
        effectiveMicMuted: false,
        virtualMicState: "ready",
        systemAudioPermission: "granted",
        microphonePermission: "granted",
        outputFolder: "/tmp/Recordings"
    )
}
