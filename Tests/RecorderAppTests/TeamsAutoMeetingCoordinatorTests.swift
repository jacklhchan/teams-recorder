import XCTest
@testable import RecorderApp

final class TeamsAutoMeetingCoordinatorTests: XCTestCase {
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
            await ticker.fire()
            await settleAsyncWork()
            XCTAssertEqual(
                coordinator.state,
                .startCountdown(secondsRemaining: expected)
            )
        }
        await ticker.fire()
        await settleAsyncWork()

        XCTAssertEqual(coordinator.state, .starting)
        XCTAssertEqual(commands, [.startRecording])
        XCTAssertTrue(states.contains(.startCountdown(secondsRemaining: 5)))
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
    func testFalseDuringStartCountdownCancelsWithoutStarting() async {
        let ticker = ManualAutoMeetingTicker()
        let coordinator = makeCoordinator(ticker: ticker)
        var commands: [TeamsAutoMeetingCommand] = []
        coordinator.onCommand = { commands.append($0) }

        coordinator.setEnabled(true)
        coordinator.handleMeetingState(isInMeeting: true)
        coordinator.handleMeetingState(isInMeeting: false)
        await fire(ticker, count: 5)

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
            await ticker.fire()
            await settleAsyncWork()
        }
        coordinator.automaticStartSucceeded()
        coordinator.handleMeetingState(isInMeeting: false)
        XCTAssertEqual(coordinator.state, .stopCountdown(secondsRemaining: 10))

        await ticker.fire()
        await settleAsyncWork()
        coordinator.handleMeetingState(isInMeeting: true)

        XCTAssertEqual(coordinator.state, .automaticRecording)
        XCTAssertEqual(commands, [.startRecording])
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
        await fire(ticker, count: 10)
        await fire(ticker, count: 2)

        XCTAssertEqual(commands, [.startRecording, .stopRecording])
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
        await fire(ticker, count: 5)

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
        await fire(ticker, count: 5)

        XCTAssertEqual(coordinator.state, .disabled)
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
            await ticker.fire()
            await settleAsyncWork()
        }
    }

    private func settleAsyncWork() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private actor ManualAutoMeetingTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var pendingTicks = 0

    func waitForTick() async {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        await withCheckedContinuation { continuations.append($0) }
    }

    func fire() {
        if continuations.isEmpty {
            pendingTicks += 1
        } else {
            continuations.removeFirst().resume()
        }
    }
}
