import RecorderControl
@testable import RecorderControlCLI
import XCTest

final class RecorderCLIApplicationTests: XCTestCase {
    func testDisabledControlExitsThreeWithoutSendingOrLaunching() async {
        let client = FakeClient(results: [])
        let launcher = FakeLauncher()
        let output = OutputRecorder()
        let application = RecorderCLIApplication(
            client: client,
            launcher: launcher,
            clock: FakeClock(),
            isControlEnabled: { false },
            writeLine: output.write
        )

        let exitCode = await application.run(arguments: ["status", "--json"])

        XCTAssertEqual(exitCode, 3)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(output.lines, ["error [control_disabled]: Local recorder control is disabled in Settings."])
    }

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
            .failure(POSIXError(.ENOENT)),
            .failure(POSIXError(.ENOENT)),
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
        let client = FakeClient(defaultResult: .failure(POSIXError(.ENOENT)))
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

    func testMalformedTransportResponseExitsThreeWithoutLaunching() async {
        let launcher = FakeLauncher()
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.failure(RecorderControlSocketError.malformedFrame)]),
            launcher: launcher,
            output: output
        )

        let exitCode = await application.run(arguments: ["status"])

        XCTAssertEqual(exitCode, 3)
        XCTAssertEqual(launcher.launchCount, 0)
        XCTAssertEqual(
            output.lines,
            ["error: Recorder control transport failed: malformed response."]
        )
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
        XCTAssertTrue(output.lines.contains("Auto meeting countdown seconds: 5"))
        XCTAssertTrue(output.lines.contains("Recorder mic muted: no"))
        XCTAssertTrue(output.lines.contains("Virtual Mic publisher: unavailable"))
        XCTAssertFalse(
            output.lines.contains { $0.hasPrefix("Teams mic state:") }
        )
        XCTAssertTrue(output.lines.contains("Active recording storage: inactive"))
        XCTAssertTrue(output.lines.contains("Operation status: idle"))
        XCTAssertTrue(output.lines.contains("Output storage: configured"))
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
        XCTAssertTrue(output.lines[0].hasPrefix("{\"activeRecordingStorageState\":"))
        XCTAssertEqual(
            try? JSONDecoder().decode(
                RecorderControlStatus.self,
                from: Data(output.lines[0].utf8)
            ),
            makeStatus()
        )
    }

    func testHumanStatusUsesUnknownForLegacyMissingPublisherState() async {
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.success(makeResponse(status: makeStatus(
                virtualMicPublisherState: nil
            )))]),
            output: output
        )

        let exitCode = await application.run(arguments: ["status"])

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.lines.contains("Virtual Mic publisher: unknown"))
    }

    func testWatchJSONEmitsFirstAndOnlyLaterChangedStatuses() async {
        let first = makeStatus(operationStatusCode: "idle")
        let changed = makeStatus(operationStatusCode: "recording")
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

    func testCancellationWhileSendIsInFlightOverridesRejectedResponse() async {
        let started = expectation(description: "send started")
        let client = InFlightClient(started: started)
        let output = OutputRecorder()
        let application = RecorderCLIApplication(
            client: client,
            launcher: FakeLauncher(),
            clock: FakeClock(),
            writeLine: output.write
        )
        let task = Task {
            await application.run(arguments: ["start"])
        }

        await fulfillment(of: [started])
        task.cancel()
        await client.resume(
            with: RecorderControlResponse(
                protocolVersion: RecorderControlRequest.currentProtocolVersion,
                requestID: "test-request",
                ok: false,
                status: makeStatus(),
                error: RecorderControlErrorPayload(
                    code: "operation-in-progress",
                    message: "Recording finalization is in progress."
                )
            )
        )

        let exitCode = await task.value
        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(output.lines.isEmpty)
    }

    func testStatusNeverRendersSensitiveLegacyFields() async throws {
        let sensitive = "/Users/private/meeting mic-secret-uid provider=https://private.example prompt=secret token=abc"
        let status = makeStatus(
            selectedMicrophoneName: "Studio Mic",
            operationStatusCode: "attention"
        )
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [
                .success(makeResponse(status: status)),
                .success(makeResponse(status: status))
            ]),
            output: output
        )

        _ = await application.run(arguments: ["status"])
        _ = await application.run(arguments: ["status", "--json"])

        let rendered = output.lines.joined(separator: "\n")
        XCTAssertFalse(rendered.contains(sensitive))
        XCTAssertFalse(rendered.contains("/Users/private/meeting"))
        XCTAssertFalse(rendered.contains("mic-secret-uid"))
        XCTAssertFalse(rendered.contains("private.example"))
    }

    func testUnexpectedFallbackErrorRendersFixedSafeMessage() async {
        let output = OutputRecorder()
        let application = makeApplication(
            client: FakeClient(results: [.failure(SecretError())]),
            output: output
        )

        let exitCode = await application.run(arguments: ["status"])

        XCTAssertEqual(exitCode, 3)
        XCTAssertEqual(output.lines, ["error: Recorder control transport failed: unexpected transport error."])
        XCTAssertFalse(output.lines.joined().contains(SecretError().localizedDescription))
    }

    func testUnknownServerErrorNeverRendersPayloadSecretsForStatusOrWatch() async {
        let rejected = RecorderControlResponse(
            protocolVersion: 1, requestID: "x", ok: false, status: nil,
            error: .init(code: "token=abc", message: "/Users/private/meeting prompt=secret")
        )
        let output = OutputRecorder()
        let application = makeApplication(client: FakeClient(results: [.success(rejected), .success(rejected)]), output: output)

        let statusExitCode = await application.run(arguments: ["status"])
        let watchExitCode = await application.run(arguments: ["watch"])
        XCTAssertEqual(statusExitCode, 4)
        XCTAssertEqual(watchExitCode, 4)
        XCTAssertEqual(output.lines, ["error [control_failed]: Recorder control request failed.", "error [control_failed]: Recorder control request failed."])
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
        guard let defaultResult else { throw POSIXError(.ENOENT) }
        return try defaultResult.get()
    }
}

private final class FakeLauncher: RecorderAppLaunching {
    private(set) var launchCount = 0

    func launchInBackground() async throws {
        launchCount += 1
    }
}

private actor InFlightClient: RecorderCLIClient {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<RecorderControlResponse, Never>?

    init(started: XCTestExpectation) {
        self.started = started
    }

    func send(
        command: RecorderControlCommand,
        argument: String?
    ) async throws -> RecorderControlResponse {
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(with response: RecorderControlResponse) {
        continuation?.resume(returning: response)
        continuation = nil
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

private func makeStatus(
    selectedMicrophoneName: String? = "Studio Mic",
    operationStatusCode: String = "idle",
    virtualMicPublisherState: String? = "unavailable"
) -> RecorderControlStatus {
    RecorderControlStatus(
        appRunning: true,
        appVersion: "1.2.3",
        recordingState: "idle",
        lifecycleOperation: "idle",
        recordingOwnership: nil,
        elapsedSeconds: nil,
        activeRecordingStorageState: "inactive",
        operationStatusCode: operationStatusCode,
        autoModeEnabled: false,
        autoMeetingState: "startCountdown",
        autoMeetingCountdownSeconds: 5,
        meetingDetectionState: "not-in-meeting",
        selectedMicrophoneName: selectedMicrophoneName,
        localMicMuted: false,
        nativeInputMicMuted: false,
        teamsMicState: "notMonitored",
        effectiveMicMuted: false,
        virtualMicState: "ready",
        virtualMicPublisherState: virtualMicPublisherState,
        systemAudioPermission: "granted",
        microphonePermission: "granted",
        outputStorageState: "configured"
    )
}

private struct SecretError: LocalizedError {
    var errorDescription: String? { "transport secret /Users/private/meeting token=abc" }
}
