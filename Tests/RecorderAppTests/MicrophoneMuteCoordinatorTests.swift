import XCTest
@testable import RecorderApp

final class LocalMicrophoneMuteCoordinatorTests: XCTestCase {
    func testLocalAndNativeMuteRemainIndependentAuthorities() {
        var coordinator = MicrophoneMuteCoordinator()

        XCTAssertEqual(coordinator.setLocalMuted(true), true)
        XCTAssertNil(coordinator.setNativeInputMuted(true))
        XCTAssertNil(coordinator.setLocalMuted(false))
        XCTAssertTrue(coordinator.effectiveMuted)
        XCTAssertEqual(coordinator.setNativeInputMuted(false), false)
        XCTAssertFalse(coordinator.effectiveMuted)
    }

    func testLocalNativeAndTeamsMuteRemainIndependentAuthorities() {
        let gate = MicrophoneMuteGate { _ in }

        gate.setLocalMuted(true)
        gate.setTeamsMuted(false)
        XCTAssertTrue(gate.snapshot.effectiveMuted)

        gate.setLocalMuted(false)
        gate.setNativeInputMuted(true)
        gate.setTeamsMuted(false)
        XCTAssertTrue(gate.snapshot.effectiveMuted)

        gate.setNativeInputMuted(false)
        gate.setTeamsMuted(true)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testClearingTeamsMuteCannotClearLocalOrNativeMute() {
        let gate = MicrophoneMuteGate { _ in }

        gate.setTeamsMuted(true)
        gate.setLocalMuted(true)
        gate.setTeamsMuted(false)
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)

        gate.setLocalMuted(false)
        gate.setNativeInputMuted(true)
        gate.setTeamsMuted(true)
        gate.setTeamsMuted(false)
        XCTAssertTrue(gate.snapshot.nativeInputMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testSnapshotContainsLocalNativeTeamsAndEffectiveMuteState() {
        let snapshot = MicrophoneMuteGate { _ in }.snapshot

        XCTAssertEqual(
            snapshot,
            MicrophoneMuteSnapshot(
                localMuted: false,
                nativeInputMuted: false,
                teamsMuted: false,
                effectiveMuted: false
            )
        )
    }

    func testGateSinkCanReenterStateWithoutDeadlock() {
        let finished = expectation(description: "mute transition finished")
        var gate: MicrophoneMuteGate!
        gate = MicrophoneMuteGate { muted in
            if muted {
                gate.setNativeInputMuted(true)
            }
            finished.fulfill()
        }

        DispatchQueue.global().async {
            gate.setLocalMuted(true)
        }

        wait(for: [finished], timeout: 1)
        XCTAssertTrue(gate.snapshot.localMuted)
        XCTAssertTrue(gate.snapshot.nativeInputMuted)
        XCTAssertTrue(gate.snapshot.effectiveMuted)
    }

    func testGateDrainsOppositeReentrantTransitionAfterOuterSinkReturns() {
        var audioMuted = false
        var sinkCalls: [Bool] = []
        var didReenter = false
        var gate: MicrophoneMuteGate!
        gate = MicrophoneMuteGate { muted in
            sinkCalls.append(muted)
            if muted, !didReenter {
                didReenter = true
                gate.setLocalMuted(false)
            }
            audioMuted = muted
        }

        let snapshot = gate.setLocalMuted(true)

        XCTAssertEqual(sinkCalls, [true, false])
        XCTAssertFalse(audioMuted)
        XCTAssertFalse(snapshot.effectiveMuted)
        XCTAssertFalse(gate.snapshot.effectiveMuted)
    }
}
