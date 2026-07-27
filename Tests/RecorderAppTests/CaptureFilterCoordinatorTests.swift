import XCTest
@testable import RecorderApp

final class CaptureFilterCoordinatorTests: XCTestCase {
    private let teams = CaptureApplication(
        processID: 42,
        bundleIdentifier: "com.microsoft.teams2",
        name: "Teams"
    )

    func testApplicationToWindowAndBackCoalescesDuplicates() {
        var coordinator = CaptureFilterCoordinator()
        let application = CaptureStreamIntent(filter: .application(teams), cadence: .idle)
        let window = CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 42, windowID: 7)),
            cadence: .enabled
        )

        let first = coordinator.request(application)
        XCTAssertNotNil(first)
        XCTAssertNil(coordinator.request(application))
        let second = coordinator.complete(first!, result: .success(()))
        XCTAssertNil(second)

        let windowUpdate = coordinator.request(window)
        XCTAssertNotNil(windowUpdate)
        XCTAssertNil(coordinator.request(window))
        XCTAssertNil(coordinator.complete(windowUpdate!, result: .success(())))

        let fallback = coordinator.request(application)
        XCTAssertNotNil(fallback)
        XCTAssertNil(coordinator.complete(fallback!, result: .success(())))
    }

    func testNewestRequestWinsOverStaleCompletion() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.request(intent(windowID: 2)))

        let newest = coordinator.complete(first, result: .success(()))
        XCTAssertEqual(newest?.intent, intent(windowID: 2))
        XCTAssertNil(coordinator.complete(first, result: .success(())))
        XCTAssertNil(coordinator.complete(newest!, result: .success(())))
    }

    func testFailureRetriesNewestDesiredIntent() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.request(intent(windowID: 2)))

        let retry = coordinator.complete(first, result: .failure(.streamFailure))
        XCTAssertEqual(retry?.intent, intent(windowID: 2))
        XCTAssertNotEqual(retry?.revision, first.revision)
    }

    func testStopWinsOverEveryPendingCompletion() {
        var coordinator = CaptureFilterCoordinator()
        let update = coordinator.request(intent(windowID: 1))!
        coordinator.stop()
        XCTAssertNil(coordinator.complete(update, result: .success(())))
        XCTAssertNil(coordinator.request(intent(windowID: 2)))
    }

    func testDestroyedWindowFallbackCannotReplaceNewerManualTarget() {
        var coordinator = CaptureFilterCoordinator()
        let original = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.complete(original, result: .success(())))

        let manualTarget = coordinator.request(intent(windowID: 2))!
        let fallback = CaptureStreamIntent(filter: .application(teams), cadence: .idle)
        // A liveness completion captured for window 1 is stale once window 2 is pending.
        XCTAssertNil(coordinator.requestFallback(fallback, matching: original.revision))
        let next = coordinator.complete(manualTarget, result: .success(()))

        XCTAssertNil(next)
    }

    private func intent(windowID: CGWindowID) -> CaptureStreamIntent {
        CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 42, windowID: windowID)),
            cadence: .enabled
        )
    }
}
