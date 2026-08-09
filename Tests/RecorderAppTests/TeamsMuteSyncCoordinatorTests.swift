import Foundation
import XCTest
@testable import RecorderApp

@MainActor
final class TeamsMuteSyncCoordinatorTests: XCTestCase {
    func testMuteIsLocalFirstAndTeamsFailureLeavesRecorderMuted() async {
        let gate = MicrophoneMuteGate { _ in }
        let controller = TeamsMuteControllerFake(
            setResult: .unknown(.confirmationFailed),
            localMuteSnapshot: { gate.snapshot.localMuted }
        )
        let coordinator = TeamsMuteSyncCoordinator(
            controller: controller,
            microphoneMuteGate: gate
        )

        let result = await coordinator.setMuted(true, processID: 42)

        XCTAssertEqual(result, .unknown(.confirmationFailed))
        XCTAssertEqual(controller.localMuteValuesAtSet, [true])
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testUnmuteCallsTeamsFirstAndClearsLocalOnlyAfterConfirmation() async {
        let gate = MicrophoneMuteGate(localMuted: true) { _ in }
        let controller = TeamsMuteControllerFake(
            setResult: .unmuted,
            localMuteSnapshot: { gate.snapshot.localMuted }
        )
        let coordinator = TeamsMuteSyncCoordinator(
            controller: controller,
            microphoneMuteGate: gate
        )

        let result = await coordinator.setMuted(false, processID: 42)

        XCTAssertEqual(result, .unmuted)
        XCTAssertEqual(controller.localMuteValuesAtSet, [true])
        XCTAssertFalse(gate.snapshot.localMuted)
        XCTAssertFalse(gate.snapshot.effectiveMuted)
    }

    func testUnmuteUnknownLeavesRecorderLocalMuteSet() async {
        let gate = MicrophoneMuteGate(localMuted: true) { _ in }
        let controller = TeamsMuteControllerFake(
            setResult: .unknown(.confirmationFailed),
            localMuteSnapshot: { gate.snapshot.localMuted }
        )
        let coordinator = TeamsMuteSyncCoordinator(
            controller: controller,
            microphoneMuteGate: gate
        )

        let result = await coordinator.setMuted(false, processID: 42)

        XCTAssertEqual(result, .unknown(.confirmationFailed))
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testManualPollingAppliesKnownTeamsStatesAndPreservesUnknown() async {
        let ticker = TeamsMuteManualTicker()
        let gate = MicrophoneMuteGate { _ in }
        let controller = TeamsMuteControllerFake(
            readResults: [.muted, .unknown(.controlNotFound), .unmuted]
        )
        let coordinator = TeamsMuteSyncCoordinator(
            controller: controller,
            microphoneMuteGate: gate,
            tick: { await ticker.tick() }
        )

        coordinator.updatePolling(
            isPanelActive: false,
            isRecording: true,
            processID: 42
        )
        XCTAssertFalse(coordinator.hasPollingTask)

        coordinator.updatePolling(
            isPanelActive: true,
            isRecording: true,
            processID: 42
        )
        XCTAssertTrue(coordinator.hasPollingTask)

        await ticker.advance()
        await waitUntil { coordinator.state == .muted }
        XCTAssertTrue(gate.snapshot.teamsMuted)

        await ticker.advance()
        await waitUntil {
            coordinator.state == .unknown(.controlNotFound)
        }
        XCTAssertTrue(gate.snapshot.teamsMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)

        gate.setLocalMuted(true)
        gate.setNativeInputMuted(true)
        await ticker.advance()
        await waitUntil { coordinator.state == .unmuted }
        XCTAssertFalse(gate.snapshot.teamsMuted)
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.nativeInputMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)

        coordinator.stopPolling()
        XCTAssertFalse(coordinator.hasPollingTask)
    }

    func testResetInvalidatesInFlightActionsWithoutChangingSafeMuteState() async {
        let gate = MicrophoneMuteGate(localMuted: true) { _ in }
        gate.setTeamsMuted(true)
        let controller = TeamsMuteSuspendingControllerFake()
        let coordinator = TeamsMuteSyncCoordinator(
            controller: controller,
            microphoneMuteGate: gate
        )

        let unmuteTask = Task {
            await coordinator.setMuted(false, processID: 42)
        }
        await controller.waitForPendingAction()
        coordinator.resetTeamsSource()
        await controller.completeNext(with: .unmuted)

        let unmuteResult = await unmuteTask.value
        XCTAssertEqual(unmuteResult, .unknown(.inactive))
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertFalse(gate.snapshot.teamsMuted)
        XCTAssertEqual(coordinator.state, .unknown(.inactive))

        let muteTask = Task {
            await coordinator.setMuted(true, processID: 42)
        }
        await controller.waitForPendingAction()
        coordinator.resetTeamsSource()
        await controller.completeNext(with: .muted)

        let muteResult = await muteTask.value
        XCTAssertEqual(muteResult, .unknown(.inactive))
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertFalse(gate.snapshot.teamsMuted)
        XCTAssertEqual(coordinator.state, .unknown(.inactive))
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

private final class TeamsMuteControllerFake: TeamsMuteControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var readResults: [TeamsMicMuteState]
    private let setResult: TeamsMicMuteState
    private let localMuteSnapshot: @Sendable () -> Bool
    private var storedLocalMuteValuesAtSet: [Bool] = []

    init(
        readResults: [TeamsMicMuteState] = [],
        setResult: TeamsMicMuteState = .unmuted,
        localMuteSnapshot: @escaping @Sendable () -> Bool = { false }
    ) {
        self.readResults = readResults
        self.setResult = setResult
        self.localMuteSnapshot = localMuteSnapshot
    }

    var localMuteValuesAtSet: [Bool] {
        lock.withLock { storedLocalMuteValuesAtSet }
    }

    func readState(processID _: pid_t) async -> TeamsMicMuteState {
        lock.withLock {
            guard !readResults.isEmpty else { return .unknown(.inactive) }
            return readResults.removeFirst()
        }
    }

    func setMuted(
        _ muted: Bool,
        processID _: pid_t
    ) async -> TeamsMicMuteState {
        lock.withLock {
            storedLocalMuteValuesAtSet.append(localMuteSnapshot())
        }
        return setResult
    }

    @MainActor
    func requestPermission() {}
}

private actor TeamsMuteManualTicker {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func tick() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func advance() async {
        while continuations.isEmpty {
            await Task.yield()
        }
        continuations.removeFirst().resume()
    }
}

private actor TeamsMuteSuspendingControllerFake: TeamsMuteControlling {
    private var pendingActions: [CheckedContinuation<TeamsMicMuteState, Never>] = []

    func readState(processID _: pid_t) async -> TeamsMicMuteState {
        .unknown(.inactive)
    }

    func setMuted(
        _: Bool,
        processID _: pid_t
    ) async -> TeamsMicMuteState {
        await withCheckedContinuation { continuation in
            pendingActions.append(continuation)
        }
    }

    func waitForPendingAction() async {
        while pendingActions.isEmpty {
            await Task.yield()
        }
    }

    func completeNext(with result: TeamsMicMuteState) {
        pendingActions.removeFirst().resume(returning: result)
    }

    @MainActor
    func requestPermission() {}
}
