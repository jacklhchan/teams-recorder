import XCTest
@testable import RecorderApp

@MainActor
final class RecordingSessionCoordinatorTests: XCTestCase {
    func testLifecycleOperationsHaveOneSerializedOwner() {
        let coordinator = RecordingSessionCoordinator()

        let start = coordinator.begin(.start)

        XCTAssertNotNil(start)
        XCTAssertTrue(coordinator.isWorking)
        XCTAssertNil(coordinator.begin(.refresh))
        XCTAssertEqual(coordinator.activeOperation, .start)
        XCTAssertTrue(coordinator.accepts(start!))

        let stop = coordinator.cancelAndBeginStop()

        XCTAssertNotNil(stop)
        XCTAssertFalse(coordinator.accepts(start!))
        XCTAssertEqual(coordinator.activeOperation, .stop)
        XCTAssertFalse(coordinator.finish(start!))
        XCTAssertTrue(coordinator.finish(stop!))
        XCTAssertFalse(coordinator.isWorking)
        XCTAssertNil(coordinator.activeOperation)
    }

    func testCoordinatorOwnsRecordingAttemptAndTeamsOwnershipState() {
        let coordinator = RecordingSessionCoordinator()
        let token = coordinator.begin(.start)!
        let attempt = RecordingStartAttempt(
            id: UUID(),
            ownership: .teamsAutomatic,
            lifecycleToken: token
        )

        coordinator.pendingAttempt = attempt
        coordinator.ownership = .teamsAutomatic
        coordinator.automaticStopIntentToken = token
        coordinator.independentlyFinalizedAttempts.insert(attempt.id)

        XCTAssertEqual(coordinator.pendingAttempt, attempt)
        XCTAssertEqual(coordinator.ownership, .teamsAutomatic)
        XCTAssertEqual(coordinator.automaticStopIntentToken, token)
        XCTAssertTrue(
            coordinator.independentlyFinalizedAttempts.contains(
                attempt.id
            )
        )
    }
}
