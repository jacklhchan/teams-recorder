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

    func testWindowReplacementPublishesOnlyReplacementAfterFirstCompletion() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.request(intent(windowID: 2)))

        let replacement = coordinator.complete(first, result: .success(()))

        XCTAssertEqual(replacement?.intent, intent(windowID: 2))
        XCTAssertNotEqual(replacement?.revision, first.revision)
    }

    func testWindowToApplicationFallbackHasIdleCadence() {
        var coordinator = CaptureFilterCoordinator()
        let window = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.complete(window, result: .success(())))
        let application = CaptureStreamIntent(filter: .application(teams), cadence: .idle)

        let fallback = coordinator.request(application)

        XCTAssertEqual(fallback?.intent, application)
        XCTAssertEqual(fallback?.intent.cadence.framesPerSecond, 1)
    }

    func testFailedFilterOrConfigurationUpdateDoesNotCommitFailedIntent() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        let retry = coordinator.complete(first, result: .failure(.streamFailure))

        XCTAssertNil(retry)
        XCTAssertNil(coordinator.complete(first, result: .success(())))
    }

    func testFailedUpdateOnlyContinuesWhenNewerDesiredIntentExists() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        XCTAssertNil(coordinator.request(intent(windowID: 2)))

        let next = coordinator.complete(first, result: .failure(.streamFailure))

        XCTAssertEqual(next?.intent, intent(windowID: 2))
    }

    func testSameFailedIntentRemainsTerminalUntilNewerIntentArrives() {
        var coordinator = CaptureFilterCoordinator()
        let failed = coordinator.request(intent(windowID: 1))!

        XCTAssertNil(coordinator.complete(failed, result: .failure(.streamFailure)))
        XCTAssertTrue(coordinator.hasTerminalFailure(for: intent(windowID: 1)))
        XCTAssertNil(coordinator.request(intent(windowID: 1)))

        let newer = coordinator.request(intent(windowID: 2))
        XCTAssertFalse(coordinator.hasTerminalFailure(for: intent(windowID: 2)))
        XCTAssertEqual(newer?.intent, intent(windowID: 2))
    }

    func testInterleavedToggleReconnectAndEnableLeavesNewestEnabledIntent() {
        var coordinator = CaptureFilterCoordinator()
        let disabled = CaptureStreamIntent(filter: .application(teams), cadence: .idle)
        let reconnect = CaptureStreamIntent(
            filter: .application(CaptureApplication(
                processID: 43,
                bundleIdentifier: teams.bundleIdentifier,
                name: teams.name
            )),
            cadence: .idle
        )
        let enabled = intent(windowID: 3)
        let first = coordinator.request(disabled)!
        XCTAssertNil(coordinator.request(reconnect))
        XCTAssertNil(coordinator.request(enabled))

        let newest = coordinator.complete(first, result: .success(()))

        XCTAssertEqual(newest?.intent, enabled)
        XCTAssertEqual(newest?.intent.cadence.framesPerSecond, 10)
    }

    func testReconnectUsesSameCoordinatorAndCannotBypassPendingManualTarget() {
        var coordinator = CaptureFilterCoordinator()
        let first = coordinator.request(intent(windowID: 1))!
        let reconnect = CaptureStreamIntent(filter: .application(teams), cadence: .idle)
        XCTAssertNil(coordinator.request(reconnect))
        XCTAssertNil(coordinator.request(intent(windowID: 2)))

        let next = coordinator.complete(first, result: .success(()))

        XCTAssertEqual(next?.intent, intent(windowID: 2))
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

    func testWaiterSupersededByNewerDesiredIntentIsCancelledExactlyOnce() {
        var registry = CaptureFilterWaiterRegistry()
        let waiter = UUID()
        let replacement = UUID()

        XCTAssertTrue(registry.register(waiter, for: intent(windowID: 2)).isEmpty)
        XCTAssertEqual(
            registry.supersedeWaiters(except: intent(windowID: 3)),
            [.resume(waiter, .failure(.streamStartCancelled))]
        )
        XCTAssertTrue(registry.register(replacement, for: intent(windowID: 3)).isEmpty)
        XCTAssertEqual(
            registry.resolveWaiters(for: intent(windowID: 3), result: .success(revision(3))),
            [.resume(replacement, .success(revision(3)))]
        )
        XCTAssertTrue(registry.drain(error: .streamStartCancelled).isEmpty)
    }

    func testCancellationBeforeRegistrationIsObservedAndDoesNotRetainWaiter() {
        var registry = CaptureFilterWaiterRegistry()
        let waiter = UUID()

        registry.prepare(waiter)
        XCTAssertTrue(registry.cancel(waiter).isEmpty)
        XCTAssertEqual(
            registry.register(waiter, for: intent(windowID: 2)),
            [.resume(waiter, .failure(.streamStartCancelled))]
        )
        XCTAssertTrue(registry.drain(error: .streamStartCancelled).isEmpty)
    }

    func testCancellationCommitAndStopProduceOneOutcomeAndLateCompletionIsIgnored() {
        var registry = CaptureFilterWaiterRegistry()
        let cancelled = UUID()
        let committed = UUID()
        let stopped = UUID()

        XCTAssertTrue(registry.register(cancelled, for: intent(windowID: 2)).isEmpty)
        XCTAssertEqual(registry.cancel(cancelled), [.resume(cancelled, .failure(.streamStartCancelled))])
        XCTAssertTrue(registry.register(committed, for: intent(windowID: 3)).isEmpty)
        XCTAssertEqual(
            registry.resolveWaiters(for: intent(windowID: 3), result: .success(revision(3))),
            [.resume(committed, .success(revision(3)))]
        )
        XCTAssertTrue(registry.register(stopped, for: intent(windowID: 4)).isEmpty)
        XCTAssertEqual(
            registry.drain(error: .streamStartCancelled),
            [.resume(stopped, .failure(.streamStartCancelled))]
        )
        XCTAssertTrue(registry.drain(error: .streamStartCancelled).isEmpty)
        XCTAssertTrue(
            registry.resolveWaiters(for: intent(windowID: 4), result: .success(revision(4))).isEmpty
        )
    }

    func testNormalStopRegistryDrainResumesOnceAndLateCompletionDoesNothing() {
        assertStopDrainIsSingleOutcome()
    }

    func testDelegateStopRegistryDrainResumesOnceAndLateCompletionDoesNothing() {
        assertStopDrainIsSingleOutcome()
    }

    private func intent(windowID: CGWindowID) -> CaptureStreamIntent {
        CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 42, windowID: windowID)),
            cadence: .enabled
        )
    }

    private func revision(_ value: UInt64) -> CaptureFilterRevision {
        CaptureFilterRevision(sessionGeneration: 1, revision: value)
    }

    private func assertStopDrainIsSingleOutcome() {
        var registry = CaptureFilterWaiterRegistry()
        let waiter = UUID()
        let intent = intent(windowID: 5)

        XCTAssertTrue(registry.register(waiter, for: intent).isEmpty)
        XCTAssertEqual(
            registry.drain(error: .streamStartCancelled),
            [.resume(waiter, .failure(.streamStartCancelled))]
        )
        XCTAssertTrue(registry.drain(error: .streamStartCancelled).isEmpty)
        XCTAssertTrue(registry.resolveWaiters(for: intent, result: .success(revision(5))).isEmpty)
    }
}
