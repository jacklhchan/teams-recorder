import XCTest
@testable import RecorderApp

final class TeamsAutoMeetingCoordinatorTests: XCTestCase {
    @MainActor
    func testPendingTimerObservabilityTracksOwnership() {
        let coordinator = TeamsAutoMeetingCoordinator()

        XCTAssertFalse(coordinator.isAutoMeetingEnabled)
        XCTAssertFalse(coordinator.hasPendingTimer)

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        XCTAssertTrue(coordinator.isAutoMeetingEnabled)
        XCTAssertTrue(coordinator.hasPendingTimer)

        coordinator.cancelCountdown()
        XCTAssertFalse(coordinator.hasPendingTimer)
    }

    @MainActor
    func testEnableWaitingCallbackCanSynchronouslySuppressKnownMeeting() {
        let coordinator = TeamsAutoMeetingCoordinator()

        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.onStateChange = { state in
            if state == .waitingForMeeting {
                coordinator.manualRecordingStarted()
            }
        }

        coordinator.setEnabled(true)

        XCTAssertTrue(coordinator.isAutoMeetingEnabled)
        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertFalse(coordinator.hasPendingTimer)
    }

    @MainActor
    func testEnableWaitingCallbackCanSynchronouslyDisableKnownMeeting() {
        let coordinator = TeamsAutoMeetingCoordinator()

        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.onStateChange = { state in
            if state == .waitingForMeeting {
                coordinator.setEnabled(false)
            }
        }

        coordinator.setEnabled(true)

        XCTAssertFalse(coordinator.isAutoMeetingEnabled)
        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertFalse(coordinator.hasPendingTimer)
    }

    @MainActor
    func testMeetingStartCountsDownFiveTicksAndEmitsOneStart() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            tick: { await ticker.waitForTick() }
        )
        var states: [TeamsAutoMeetingState] = []
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { states.append($0) }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 5))

        for expected in [4, 3, 2, 1] {
            await ticker.fireAndWaitForAcknowledgement()
            XCTAssertEqual(
                coordinator.state,
                .startCountdown(secondsRemaining: expected)
            )
        }
        await ticker.fireAndWaitForAcknowledgement()

        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(commands, [.startRecording])
        XCTAssertTrue(states.contains(.startCountdown(secondsRemaining: 5)))
    }

    @MainActor
    func testStartingStateCallbackCanSynchronouslyCancelBeforeStartCommand() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { state in
            if state == .starting {
                coordinator.handleMeetingState(isInMeeting: false)
            }
        }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()

        XCTAssertEqual(coordinator.state, .waitingForMeeting)
        XCTAssertEqual(commands, [.cancelAutomaticStart])
    }

    @MainActor
    func testInitialStartCountdownCallbackCanSynchronouslyCancelTimer() {
        let coordinator = TeamsAutoMeetingCoordinator()
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { state in
            if state == .startCountdown(secondsRemaining: 5) {
                coordinator.cancelCountdown()
            }
        }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertFalse(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testInitialStartCountdownCallbackCanSynchronouslyDisableTimer() {
        let coordinator = TeamsAutoMeetingCoordinator()
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { state in
            if state == .startCountdown(secondsRemaining: 5) {
                coordinator.setEnabled(false)
            }
        }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertFalse(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testInitialStartCountdownCallbackCanSynchronouslyInvalidateTimer() {
        let coordinator = TeamsAutoMeetingCoordinator()
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { state in
            if state == .startCountdown(secondsRemaining: 5) {
                coordinator.invalidate()
            }
        }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertFalse(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testRepeatedTrueDoesNotRestartStartCountdown() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker)
        XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 4))

        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 4)

        XCTAssertEqual(coordinator.state, .starting)
    }

    @MainActor
    func testCancelCountdownSuppressesUntilMeetingEnds() {
        let coordinator = TeamsAutoMeetingCoordinator()
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.cancelCountdown()
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertEqual(commands, [])

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
    }

    @MainActor
    func testManualRecordingStartedSuppressesRepeatedTrueUntilFalse() {
        let coordinator = TeamsAutoMeetingCoordinator()
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.manualRecordingStarted()
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.manualRecordingStarted()
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertEqual(commands, [])

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
    }

    @MainActor
    func testExternalStopOfAutomaticRecordingSuppressesRepeatedTrueUntilFalse() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartSucceeded()

        coordinator.suppressUntilMeetingEnd()
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertEqual(commands, [.startRecording])

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
    }

    @MainActor
    func testExternalStopDuringMeetingEndDebounceSuppressesTransientTrue() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartSucceeded()
        coordinator.handleMeetingState(isInMeeting: false)
        await fire(ticker, count: 3)

        coordinator.suppressUntilMeetingEnd()
        coordinator.handleMeetingState(isInMeeting: true)

        guard coordinator.state == .suppressedUntilMeetingEnd else {
            return XCTFail("Rejoin did not preserve external-stop suppression")
        }
        XCTAssertFalse(coordinator.hasPendingTimer)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker)
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertEqual(commands, [.startRecording])

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.handleMeetingState(isInMeeting: true)
        XCTAssertEqual(
            coordinator.state,
            .startCountdown(secondsRemaining: 5)
        )
        XCTAssertTrue(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [.startRecording])
        await fire(ticker)
        XCTAssertEqual(
            coordinator.state,
            .startCountdown(secondsRemaining: 4)
        )
        XCTAssertEqual(commands, [.startRecording])
    }

    @MainActor
    func testFalseDuringStartCountdownCancelsWithoutStarting() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.handleMeetingState(isInMeeting: false)
        await fire(ticker)

        XCTAssertEqual(coordinator.state, .waitingForMeeting)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testFalseDuringStartingCancelsAutomaticStart() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.handleMeetingState(isInMeeting: false)

        XCTAssertEqual(coordinator.state, .waitingForMeeting)
        XCTAssertEqual(commands, [.startRecording, .cancelAutomaticStart])
    }

    @MainActor
    func testAutomaticReadinessBlockageStaysBlockedUntilFalse() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartBlocked("Microphone unavailable")
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .startBlocked("Microphone unavailable"))

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
    }

    @MainActor
    func testAutomaticStartFailureStaysFailedUntilFalse() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartFailed("Writer failed")
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .startFailed("Writer failed"))

        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .waitingForMeeting)
    }

    @MainActor
    func testTrueDuringStopDebounceCancelsAutomaticStop() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }
        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        for _ in 0..<5 {
            await ticker.fireAndWaitForAcknowledgement()
        }
        coordinator.automaticStartSucceeded()
        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .stopCountdown(secondsRemaining: 10))

        await ticker.fireAndWaitForAcknowledgement()
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .automaticRecording)
        XCTAssertEqual(commands, [.startRecording])
    }

    @MainActor
    func testInitialStopCountdownCallbackCanSynchronouslyCancelTimer() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        coordinator.automaticStartSucceeded()
        coordinator.onStateChange = { state in
            if state == .stopCountdown(secondsRemaining: 10) {
                coordinator.handleMeetingState(isInMeeting: true)
            }
        }

        coordinator.handleMeetingState(isInMeeting: false)

        XCTAssertEqual(coordinator.state, .automaticRecording)
        XCTAssertFalse(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [.startRecording])
    }

    @MainActor
    func testDisableCancelCommandCallbackCanSynchronouslyReenable() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { command in
            commands.append(command)
            if command == .cancelAutomaticStart {
                coordinator.setEnabled(true)
            }
        }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        coordinator.setEnabled(false)

        XCTAssertTrue(coordinator.isAutoMeetingEnabled)
        XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 1))
        XCTAssertTrue(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [.startRecording, .cancelAutomaticStart])
    }

    @MainActor
    func testDisableTransferCommandCallbackCanSynchronouslyReenable() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { command in
            commands.append(command)
            if command == .transferRecordingToManual {
                coordinator.setEnabled(true)
            }
        }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        coordinator.automaticStartSucceeded()
        coordinator.setEnabled(false)

        XCTAssertTrue(coordinator.isAutoMeetingEnabled)
        XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 1))
        XCTAssertTrue(coordinator.hasPendingTimer)
        XCTAssertEqual(
            commands,
            [.startRecording, .transferRecordingToManual]
        )
    }

    @MainActor
    func testFalseDuringStartingCommandCallbackCanSynchronouslyRestoreMeeting() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { command in
            commands.append(command)
            if command == .cancelAutomaticStart {
                coordinator.handleMeetingState(isInMeeting: true)
            }
        }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        coordinator.handleMeetingState(isInMeeting: false)

        XCTAssertEqual(coordinator.state, .startCountdown(secondsRemaining: 1))
        XCTAssertTrue(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [.startRecording, .cancelAutomaticStart])
    }

    @MainActor
    func testSuppressStartingCommandCallbackCanSynchronouslyEndMeeting() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = TeamsAutoMeetingCoordinator(
            startCountdownSeconds: 1,
            tick: { await ticker.waitForTick() }
        )
        var handledMeetingEnd = false
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { command in
            commands.append(command)
            if command == .cancelAutomaticStart, !handledMeetingEnd {
                handledMeetingEnd = true
                coordinator.handleMeetingState(isInMeeting: false)
            }
        }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await ticker.fireAndWaitForAcknowledgement()
        coordinator.suppressUntilMeetingEnd()

        XCTAssertEqual(coordinator.state, .waitingForMeeting)
        XCTAssertFalse(coordinator.hasPendingTimer)
        XCTAssertEqual(commands, [.startRecording, .cancelAutomaticStart])
    }

    @MainActor
    func testTenFalseTicksEmitExactlyOneStop() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartSucceeded()
        coordinator.handleMeetingState(isInMeeting: false)

        for expected in stride(from: 9, through: 1, by: -1) {
            await fire(ticker)
            XCTAssertEqual(
                coordinator.state,
                .stopCountdown(secondsRemaining: expected)
            )
            XCTAssertEqual(commands, [.startRecording])
        }

        await fire(ticker)
        XCTAssertEqual(commands, [.startRecording, .stopRecording])
    }

    @MainActor
    func testTrueAfterCommittedStopWaitsForCompletionThenStartsOnce() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartSucceeded()
        coordinator.handleMeetingState(isInMeeting: false)
        await fire(ticker, count: 10)

        XCTAssertEqual(commands, [.startRecording, .stopRecording])
        XCTAssertFalse(coordinator.hasPendingTimer)
        coordinator.handleMeetingState(isInMeeting: true)
        guard coordinator.state == .stopCountdown(secondsRemaining: 1) else {
            return XCTFail("Committed stop was revived before completion")
        }

        coordinator.automaticStopCompleted()
        coordinator.automaticStopCompleted()
        coordinator.handleMeetingState(isInMeeting: true)
        XCTAssertEqual(
            coordinator.state,
            .startCountdown(secondsRemaining: 5)
        )
        XCTAssertTrue(coordinator.hasPendingTimer)

        await fire(ticker, count: 5)

        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(
            commands,
            [.startRecording, .stopRecording, .startRecording]
        )
    }

    @MainActor
    func testDisablingAutomaticRecordingTransfersToManual() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        await fire(ticker, count: 5)
        coordinator.automaticStartSucceeded()
        coordinator.setEnabled(false)

        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertEqual(commands, [.startRecording, .transferRecordingToManual])
    }

    @MainActor
    func testStaleTicksAfterCancelDoNotChangeStateOrEmitCommands() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.cancelCountdown()
        await fire(ticker)

        XCTAssertEqual(coordinator.state, .suppressedUntilMeetingEnd)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testStaleTicksAfterDisableDoNotChangeStateOrEmitCommands() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.setEnabled(false)
        await fire(ticker)

        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    func testStaleTicksAfterInvalidateDoNotChangeStateOrEmitCommands() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var observedStates: [TeamsAutoMeetingState] = []
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onStateChange = { observedStates.append($0) }
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.invalidate()
        let statesAtInvalidation = observedStates
        await fire(ticker)

        XCTAssertEqual(coordinator.state, .disabled)
        XCTAssertEqual(observedStates, statesAtInvalidation)
        XCTAssertEqual(commands, [])
    }

    @MainActor
    private func makeCoordinator(
        ticker: ManualAutoMeetingTicker
    ) -> TeamsAutoMeetingCoordinator {
        TeamsAutoMeetingCoordinator(tick: { await ticker.waitForTick() })
    }

    @MainActor
    private func fire(
        _ ticker: ManualAutoMeetingTicker,
        count: Int = 1
    ) async {
        for _ in 0..<count {
            await ticker.fireAndWaitForAcknowledgement()
        }
    }
}

private actor ManualAutoMeetingTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0
    private var deliveredTicks = 0
    private var acknowledgedTicks = 0
    private var acknowledgementContinuations:
        [(tick: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
        } else {
            await withCheckedContinuation { continuations.append($0) }
        }

        acknowledgedTicks += 1
        let ready = acknowledgementContinuations.filter {
            $0.tick <= acknowledgedTicks
        }
        acknowledgementContinuations.removeAll {
            $0.tick <= acknowledgedTicks
        }
        ready.forEach { $0.continuation.resume() }
    }

    func fireAndWaitForAcknowledgement() async {
        deliveredTicks += 1
        let tick = deliveredTicks
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }

        if acknowledgedTicks < tick {
            await withCheckedContinuation {
                acknowledgementContinuations.append(
                    (tick: tick, continuation: $0)
                )
            }
        }
    }

}
