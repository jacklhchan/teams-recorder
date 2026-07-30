import CoreMedia
import CoreVideo
import XCTest
@testable import RecorderApp

@MainActor
final class RecordingEngineStateTests: XCTestCase {
    // Coordinator-path regression matrix. Every test emits a real frame or event.
    func testNewRecordingRequestsPartialMP4AndAudioBackupURLs() async throws {
        let (engine, coordinator, _) = coordinatorEngine()
        let folder = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        XCTAssertEqual(coordinator.outputs, RecordingOutputURLs(folder: folder))
        XCTAssertEqual(coordinator.pixelFormat, kCVPixelFormatType_32BGRA)
        _ = await engine.stop()
    }

    func testEveryNewRecordingResetsScreenIntentToOff() async throws {
        let (engine, _, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 1)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        assertAwaitingFrames(engine.meetingScreenCaptureState, identity: source.windows[0].identity)
        _ = await engine.stop()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        _ = await engine.stop()
    }

    func testVideoCallbackNeverUsesMixedAudioWriterPath() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(video: try videoFrame(seconds: 0))
        XCTAssertEqual(coordinator.videoFrames.count, 1)
        XCTAssertTrue(coordinator.audioBlocks.isEmpty)
        _ = await engine.stop()
    }

    func testVideoIngressRejectsMonitoringAndStaleRecordingEpochFrames() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        try await engine.startMonitoring(selection: .allSystemAudio, microphoneUID: nil)
        source.emit(video: try videoFrame(seconds: 0))
        XCTAssertTrue(coordinator.videoFrames.isEmpty)
        await engine.stopMonitoring()
        try await engine.startMonitoring(selection: .allSystemAudio, microphoneUID: nil)
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(video: try videoFrame(seconds: 1))
        source.emitOldVideo(0, frame: try videoFrame(seconds: 2))
        XCTAssertEqual(coordinator.videoFrames.count, 1)
        _ = await engine.stop()
    }

    func testVideoIngressForwardsWithoutMainActorHop() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await source.emitVideoOnBackground(try videoFrame(seconds: 0))
        XCTAssertEqual(coordinator.videoFrames.count, 1)
        XCTAssertEqual(coordinator.enqueueVideoOnMainActor, [false])
        _ = await engine.stop()
    }

    func testEnableScreenUpdatesFilterWithoutRestartingSourceOrWriter() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 11)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        let session = engine.continuitySnapshot
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(coordinator.finishCount, 0)
        XCTAssertEqual(source.videoTargets.last, source.windows[0].identity)
        XCTAssertEqual(coordinator.screenRequests.last?.requested, true)
        XCTAssertEqual(engine.continuitySnapshot.recordingEpoch, session.recordingEpoch)
        _ = await engine.stop()
    }

    func testSuccessfulFilterUpdateWaitsForAcceptedFrameBeforeCapturing() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 13)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let revision = try XCTUnwrap(source.videoRevisions.last)

        assertAwaitingFrames(engine.meetingScreenCaptureState, identity: source.windows[0].identity)
        coordinator.emitCurrent(
            .sourceRecovered,
            filterRevision: revision,
            acceptedFrameRevision: revision
        )
        await settle()

        assertScreenState(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity,
            capturing: true
        )
        _ = await engine.stop()
    }

    func testDisableScreenKeepsAudioAndReturnsToApplicationFilter() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 12)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        await engine.setScreenCaptureRequested(false)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertNil(source.videoTargets.last!)
        XCTAssertEqual(coordinator.screenRequests.last?.requested, false)
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        _ = await engine.stop()
    }

    func testWindowReplacementPreservesSessionEpochAndMute() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 21)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        let before = engine.continuitySnapshot
        engine.toggleMicMute()
        source.windows = [teamsWindow(id: 22)]
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        XCTAssertEqual(engine.continuitySnapshot.recordingEpoch, before.recordingEpoch)
        XCTAssertTrue(engine.micMuted)
        XCTAssertEqual(source.videoTargets.last!, source.windows[0].identity)
        XCTAssertEqual(coordinator.finishCount, 0)
        _ = await engine.stop()
    }

    func testScreenFailureDoesNotDisconnectSystemOrMicrophone() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(event: .screenCaptureFailed)
        await settle()
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(coordinator.screenUnavailableCount, 1)
        XCTAssertEqual(engine.meetingScreenCaptureState, .failed("Screen frame capture unavailable"))
        let result = await engine.stop()
        XCTAssertEqual(result?.health.videoFilterFailures, 1)
    }

    func testScreenTargetLostClosesIntervalAndShowsWaitingWithoutDisconnectingAudio() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 30)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)

        source.emit(event: .screenTargetLost(try XCTUnwrap(source.videoRevisions.last)))
        await settle()

        XCTAssertEqual(coordinator.screenUnavailableCount, 1)
        assertTargetLost(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertFalse(coordinator.audioBlocks.isEmpty)
        _ = await engine.stop()
    }

    func testAutomaticTargetLossKeepsReconnectingAcrossEmptyRefresh() async throws {
        let (engine, _, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 37)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let revision = try XCTUnwrap(source.videoRevisions.last)
        source.emit(event: .screenTargetLost(revision))
        await settle()

        source.windows = []
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )

        assertTargetLost(engine.meetingScreenCaptureState, identity: teamsWindow(id: 37).identity)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        _ = await engine.stop()
    }

    func testUnavailableScreenFrameClosesIntervalAndShowsWaitingWithoutDisconnectingAudio() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 31)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)

        source.emit(event: .screenFrameUnavailable(try XCTUnwrap(source.videoRevisions.last)))
        await settle()

        XCTAssertEqual(coordinator.screenUnavailableCount, 1)
        assertFrameUnavailable(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        _ = await engine.stop()
    }

    func testStaleTargetLostFromOldRevisionCannotDemoteReplacement() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 35)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let oldRevision = try XCTUnwrap(source.videoRevisions.last)

        source.windows = [teamsWindow(id: 36)]
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        source.emit(event: .screenTargetLost(oldRevision))
        await settle()

        XCTAssertEqual(coordinator.screenUnavailableCount, 0)
        assertAwaitingFrames(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        XCTAssertNil(engine.captureStatus)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        _ = await engine.stop()
    }

    func testOldTargetLossAfterFallbackCannotOverrideAmbiguousWaiting() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 40)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let oldRevision = try XCTUnwrap(source.videoRevisions.last)

        source.windows = [
            teamsWindow(id: 41),
            teamsWindow(id: 42)
        ]
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        guard case let .waiting(candidates) = engine.meetingScreenCaptureState else {
            return XCTFail("Expected ambiguous waiting state")
        }
        XCTAssertEqual(candidates.count, 2)

        source.emit(event: .screenTargetLost(oldRevision))
        await settle()

        XCTAssertEqual(engine.meetingScreenCaptureState, .waiting(candidates))
        XCTAssertEqual(coordinator.screenUnavailableCount, 0)
        XCTAssertNil(engine.captureStatus)
        _ = await engine.stop()
    }

    func testUnavailableScreenFrameFromDisabledCaptureIsIgnored() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 32)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let oldRevision = try XCTUnwrap(source.videoRevisions.last)

        await engine.setScreenCaptureRequested(false)
        source.emit(event: .screenFrameUnavailable(oldRevision))
        await settle()

        XCTAssertEqual(coordinator.screenUnavailableCount, 0)
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        XCTAssertNil(engine.captureStatus)
        _ = await engine.stop()
    }

    func testUnavailableScreenFrameFromOldWindowRevisionIsIgnored() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 33)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let oldRevision = try XCTUnwrap(source.videoRevisions.last)

        source.windows = [teamsWindow(id: 34)]
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        source.emit(event: .screenFrameUnavailable(oldRevision))
        await settle()

        XCTAssertEqual(coordinator.screenUnavailableCount, 0)
        assertAwaitingFrames(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        XCTAssertNil(engine.captureStatus)
        _ = await engine.stop()
    }

    func testScreenCaptureFailureRemainsFailedWhenCoordinatorThenStalls() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())

        source.emit(event: .screenCaptureFailed)
        await settle()
        coordinator.emitCurrent(.sourceStalled)
        await settle()

        XCTAssertEqual(engine.meetingScreenCaptureState, .failed("Screen frame capture unavailable"))
        let result = await engine.stop()
        XCTAssertEqual(result?.health.videoFilterFailures, 1)
    }

    func testVideoStallShowsWaitingWithoutDisconnectingAudio() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 31)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        coordinator.emitCurrent(
            .sourceStalled,
            filterRevision: try XCTUnwrap(source.videoRevisions.last)
        )
        await settle()
        assertFrameUnavailable(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        XCTAssertTrue(engine.isSystemCaptureConnected)
        _ = await engine.stop()
    }

    func testRecoveredVideoReturnsToCapturingState() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 32)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        let revision = try XCTUnwrap(source.videoRevisions.last)
        coordinator.emitCurrent(.sourceStalled, filterRevision: revision)
        coordinator.emitCurrent(
            .sourceRecovered,
            filterRevision: revision,
            acceptedFrameRevision: revision
        )
        await settle()
        assertScreenState(engine.meetingScreenCaptureState, identity: source.windows[0].identity, capturing: true)
        _ = await engine.stop()
    }

    func testStaleRecoveryFromOldRevisionCannotCaptureReplacement() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 38)]
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await engine.setScreenCaptureRequested(true)
        let oldRevision = try XCTUnwrap(source.videoRevisions.last)

        source.windows = [teamsWindow(id: 39)]
        await engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        coordinator.emitCurrent(
            .sourceRecovered,
            filterRevision: oldRevision,
            acceptedFrameRevision: oldRevision
        )
        await settle()

        assertAwaitingFrames(
            engine.meetingScreenCaptureState,
            identity: source.windows[0].identity
        )
        _ = await engine.stop()
    }

    func testMuxFailureShowsScreenFailureWhileSafetyAudioContinues() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        coordinator.emitCurrent(.muxFailed("mux"))
        await settle()
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        await settle()
        XCTAssertEqual(engine.meetingScreenCaptureState, .failed("mux"))
        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(coordinator.audioBlocks.isEmpty)
        _ = await engine.stop()
    }

    func testMuxFallbackEventAndOutcomeFailureAreCountedOnce() async throws {
        let (engine, coordinator, _) = coordinatorEngine()
        coordinator.outcome = .init(
            finalURL: URL(fileURLWithPath: "/tmp/recording.m4a"), mediaKind: .audio,
            screenIntervals: [], capturedWindow: nil, recoveryState: .videoLostAudioPreserved,
            videoDroppedFrames: 0, videoFailureDescription: "mux unavailable", safetyCleanupDiagnostic: nil
        )
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        coordinator.emitCurrent(.muxFailed("mux unavailable"))
        await settle()

        let result = await engine.stop()
        XCTAssertEqual(result?.health.muxFallbackEvents, 1)
        XCTAssertEqual(result?.warning, "mux unavailable")
    }

    func testDelayedVideoEventFromPriorEpochCannotChangeNewRecordingState() async throws {
        let source = FakeCaptureSource()
        let first = FakeMediaCoordinator()
        let second = FakeMediaCoordinator()
        var coordinators = [first, second]
        let engine = RecordingEngine(captureSource: source, coordinatorFactory: { outputs, id, epoch, revision, format in
            let coordinator = coordinators.removeFirst()
            coordinator.configure(outputs: outputs, sourceSessionID: id, epoch: epoch, revision: revision, pixelFormat: format)
            return coordinator
        }, mixerBlockFrames: 4)
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        _ = await engine.stop()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        first.emitCurrent(.muxFailed("old"))
        await settle()
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        _ = await engine.stop()
    }

    func testStopDrainsCallbacksFlushesMixerThenFinalizesCoordinator() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        coordinator.blockVideoEnqueue = true
        let frame = try videoFrame(seconds: 0)
        let emission = Task.detached { [source] in
            await source.emitVideoOnBackground(frame)
        }
        await coordinator.waitForVideoEnqueueStart()
        let stop = Task { await engine.stop() }
        await waitUntil { source.stopCount == 1 }
        XCTAssertEqual(coordinator.finishCount, 0)
        coordinator.releaseBlockedVideoEnqueue()
        _ = await emission.value
        _ = await stop.value
        XCTAssertEqual(coordinator.finishCount, 1)
        XCTAssertFalse(coordinator.videoFrames.isEmpty)
        XCTAssertEqual(coordinator.handlerInstallCount, 2)
        let finalVideoIndex = try XCTUnwrap(coordinator.events.lastIndex(of: "video"))
        let finishIndex = try XCTUnwrap(coordinator.events.firstIndex(of: "finish"))
        let handlerClearIndex = try XCTUnwrap(coordinator.events.firstIndex(of: "handler-clear"))
        XCTAssertLessThan(finalVideoIndex, finishIndex)
        XCTAssertLessThan(finishIndex, handlerClearIndex)
        XCTAssertEqual(coordinator.events.last, "handler-clear")
    }

    func testStaleEnableCompletionAfterStopCannotEnableScreenForNewSession() async throws {
        let source = FakeCaptureSource()
        let first = FakeMediaCoordinator()
        let second = FakeMediaCoordinator()
        var coordinators = [first, second]
        let engine = RecordingEngine(captureSource: source, coordinatorFactory: { outputs, id, epoch, revision, format in
            let coordinator = coordinators.removeFirst()
            coordinator.configure(outputs: outputs, sourceSessionID: id, epoch: epoch, revision: revision, pixelFormat: format)
            return coordinator
        }, mixerBlockFrames: 4)
        source.windows = [teamsWindow(id: 71)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        source.pauseVideoTargetUpdates = true
        async let enable: Void = engine.setScreenCaptureRequested(true)
        await waitUntil { source.videoTargets.count == 1 }
        _ = await engine.stop()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.completeNextVideoTarget()
        await enable
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        XCTAssertTrue(second.screenRequests.isEmpty)
        _ = await engine.stop()
    }

    func testStaleDisableFailureAfterNewSessionCannotReplaceOffState() async throws {
        let source = FakeCaptureSource()
        let first = FakeMediaCoordinator()
        let second = FakeMediaCoordinator()
        var coordinators = [first, second]
        let engine = RecordingEngine(captureSource: source, coordinatorFactory: { outputs, id, epoch, revision, format in
            let coordinator = coordinators.removeFirst()
            coordinator.configure(outputs: outputs, sourceSessionID: id, epoch: epoch, revision: revision, pixelFormat: format)
            return coordinator
        }, mixerBlockFrames: 4)
        source.windows = [teamsWindow(id: 72)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        source.pauseVideoTargetUpdates = true
        async let disable: Void = engine.setScreenCaptureRequested(false)
        await waitUntil { source.videoTargets.count == 2 }
        _ = await engine.stop()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.failNextVideoTarget(TestError.failed)
        await disable
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        XCTAssertTrue(second.screenRequests.isEmpty)
        _ = await engine.stop()
    }

    func testStaleWindowRefreshCompletionCannotApplyOldWindowRevision() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        source.windows = [teamsWindow(id: 73)]
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        await engine.refreshTeamsWindows(selectedTeamsProcessID: teamsProcessID, meetingActive: true, manualOverride: nil)
        await engine.setScreenCaptureRequested(true)
        source.pauseVideoTargetUpdates = true
        source.windows = [teamsWindow(id: 74)]
        async let refresh: Void = engine.refreshTeamsWindows(
            selectedTeamsProcessID: teamsProcessID,
            meetingActive: true,
            manualOverride: nil
        )
        await waitUntil { source.videoTargets.count == 2 }
        async let disable: Void = engine.setScreenCaptureRequested(false)
        await waitUntil { source.videoTargets.count == 3 }
        source.completeNextVideoTarget()
        source.completeNextVideoTarget()
        await refresh
        await disable
        XCTAssertEqual(engine.meetingScreenCaptureState, .off)
        XCTAssertEqual(coordinator.screenRequests.filter(\.requested).count, 1)
        _ = await engine.stop()
    }

    func testFallbackResultReturnsRecordingM4AAndRecoveryState() async throws {
        let (engine, coordinator, _) = coordinatorEngine()
        coordinator.outcome = .init(finalURL: URL(fileURLWithPath: "/tmp/recording.m4a"), mediaKind: .audio, screenIntervals: [], capturedWindow: nil, recoveryState: .videoLostAudioPreserved, videoDroppedFrames: 0, videoFailureDescription: nil, safetyCleanupDiagnostic: nil)
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        let result = await engine.stop()
        XCTAssertEqual(result?.recordingURL.lastPathComponent, "recording.m4a")
        XCTAssertEqual(result?.recoveryState, .videoLostAudioPreserved)
    }

    func testInvalidVideoTimestampIsCountedOnlyForActiveRecording() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(video: try videoFrame(seconds: 0, valid: false))
        source.emit(video: try videoFrame(seconds: 1))
        let result = await engine.stop()
        XCTAssertEqual(coordinator.videoFrames.count, 1)
        XCTAssertEqual(result?.health.videoInvalidTimestamps, 1)
    }

    func testOutcomeDroppedFramesMergeWithoutDuplicatingEventCount() async throws {
        let (engine, coordinator, _) = coordinatorEngine()
        coordinator.outcome = .init(
            finalURL: URL(fileURLWithPath: "/tmp/recording.mp4"), mediaKind: .video,
            screenIntervals: [], capturedWindow: nil, recoveryState: .none,
            videoDroppedFrames: 3, videoFailureDescription: nil, safetyCleanupDiagnostic: nil
        )
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        coordinator.emitCurrent(.droppedFrames(3))
        await settle()
        let result = await engine.stop()
        XCTAssertEqual(result?.health.videoDroppedFrames, 3)
    }

    func testCumulativeDroppedFrameEventsAreNotAddedTogether() async throws {
        let (engine, coordinator, _) = coordinatorEngine()
        coordinator.outcome = .init(
            finalURL: URL(fileURLWithPath: "/tmp/recording.mp4"), mediaKind: .video,
            screenIntervals: [], capturedWindow: nil, recoveryState: .none,
            videoDroppedFrames: 3, videoFailureDescription: nil, safetyCleanupDiagnostic: nil
        )
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        coordinator.emitCurrent(.droppedFrames(1))
        coordinator.emitCurrent(.droppedFrames(2))
        coordinator.emitCurrent(.droppedFrames(3))
        await settle()

        let result = await engine.stop()
        XCTAssertEqual(result?.health.videoDroppedFrames, 3)
    }

    func testCoordinatorFactoryTakesPrecedenceOverLegacyWriterFactory() async throws {
        let source = FakeCaptureSource()
        let coordinator = FakeMediaCoordinator()
        let writer = FakeWriter()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            coordinatorFactory: { outputs, sessionID, epoch, revision, pixelFormat in
                coordinator.configure(outputs: outputs, sourceSessionID: sessionID, epoch: epoch, revision: revision, pixelFormat: pixelFormat)
                return coordinator
            },
            mixerBlockFrames: 4
        )
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        await settle()
        XCTAssertFalse(coordinator.audioBlocks.isEmpty)
        XCTAssertTrue(writer.blocks.isEmpty)
        _ = await engine.stop()
    }

    func testTerminalSourceEventFinalizesCoordinatorExactlyOnce() async throws {
        let (engine, coordinator, source) = coordinatorEngine()
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        source.emit(event: .streamStoppedBySystem)
        await waitUntil { !engine.isRecording }
        XCTAssertEqual(coordinator.finishCount, 1)
        XCTAssertEqual(coordinator.events.filter { $0 == "finish" }.count, 1)
    }

    func testCoordinatorCreationFailureStopsSourceAndLeavesNoLiveRecording() async throws {
        let source = FakeCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            coordinatorFactory: { _, _, _, _, _ in throw TestError.failed },
            mixerBlockFrames: 4
        )
        do {
            _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
            XCTFail("Expected coordinator creation failure")
        } catch {
            XCTAssertEqual(source.stopCount, 1)
            XCTAssertFalse(engine.isRecording)
            XCTAssertFalse(engine.isMonitoring)
        }
    }
    func testRecordingMetadataPersistsIntervalsAndWindowIdentity() async throws {
        let source = FakeCaptureSource()
        let coordinator = FakeMediaCoordinator()
        let interval = RecordedScreenInterval(startSeconds: 1, endSeconds: 2)
        let window = RecordedTeamsWindowIdentity(processID: 7, windowID: 9, title: "Teams call")
        coordinator.outcome = RecordingMediaOutcome(
            finalURL: URL(fileURLWithPath: "/tmp/recording.mp4"), mediaKind: .video,
            screenIntervals: [interval], capturedWindow: window, recoveryState: .none,
            videoDroppedFrames: 2, videoFailureDescription: nil, safetyCleanupDiagnostic: nil
        )
        var written: RecordingSessionMetadata?
        let engine = RecordingEngine(
            captureSource: source,
            coordinatorFactory: { _, _, _, _, _ in coordinator },
            metadataWriter: { metadata, _ in written = metadata },
            mixerBlockFrames: 4
        )
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        let result = await engine.stop()

        XCTAssertEqual(written?.mediaKind, .video)
        XCTAssertEqual(written?.screenIntervals, [interval])
        XCTAssertEqual(written?.capturedTeamsWindow, window)
        XCTAssertEqual(result?.health.videoDroppedFrames, 2)
    }

    func testMetadataFailurePreservesFinalRecordingResult() async throws {
        let source = FakeCaptureSource()
        let coordinator = FakeMediaCoordinator()
        let finalURL = URL(fileURLWithPath: "/tmp/final.mp4")
        coordinator.outcome = RecordingMediaOutcome(finalURL: finalURL, mediaKind: .video, screenIntervals: [], capturedWindow: nil, recoveryState: .none, videoDroppedFrames: 0, videoFailureDescription: nil, safetyCleanupDiagnostic: nil)
        let engine = RecordingEngine(captureSource: source, coordinatorFactory: { _, _, _, _, _ in coordinator }, metadataWriter: { _, _ in throw TestError.failed }, mixerBlockFrames: 4)
        _ = try await engine.start(selection: .allSystemAudio, microphoneUID: nil, baseFolder: temporaryFolder())
        let result = await engine.stop()

        XCTAssertEqual(result?.recordingURL, finalURL)
        XCTAssertEqual(result?.health.metadataWriteFailures, 1)
        XCTAssertNotNil(result?.warning)
    }
    func testScreenFailureDoesNotDisconnectSystemAudio() async throws {
        let source = FakeCaptureSource()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in FakeWriter() },
            mixerBlockFrames: 4
        )
        try await engine.startMonitoring(selection: .allSystemAudio, microphoneUID: nil)

        source.emit(event: .screenCaptureFailed)
        await settle()

        XCTAssertTrue(engine.isMonitoring)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertEqual(engine.captureStatus, .warning("Screen frame capture unavailable"))
    }

    func testMonitoringPublishesOnlyMicrophoneBeforeRecordingStarts() async throws {
        let source = FakeCaptureSource()
        let publisher = FakeVirtualMicPublisher()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in FakeWriter() },
            mixerBlockFrames: 4,
            virtualMicPublisher: publisher
        )

        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "AirPods-UID"
        )
        source.emit(try block(.system, frame: 0, samples: [0.9, 0.8]))
        source.emit(try block(.microphone, frame: 0, samples: [0.3, -0.2]))
        await settle()

        XCTAssertFalse(engine.isRecording)
        XCTAssertEqual(publisher.startCount, 1)
        XCTAssertEqual(engine.virtualMicPublisherState, .ready)
        XCTAssertEqual(publisher.publishedLeft, [[0.3, -0.2]])
        XCTAssertEqual(publisher.publishedRight, [[0.3, -0.2]])

        await engine.stopMonitoring()
        XCTAssertEqual(publisher.stopCount, 1)
        XCTAssertEqual(engine.virtualMicPublisherState, .stopped)
    }

    func testPublisherWriteFailureBecomesObservableDuringMonitoring() async throws {
        let source = FakeCaptureSource()
        let publisher = FakeVirtualMicPublisher()
        publisher.becomeUnavailableOnPublish = true
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in FakeWriter() },
            mixerBlockFrames: 4,
            virtualMicPublisher: publisher
        )

        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "AirPods-UID"
        )
        source.emit(try block(.microphone, frame: 0, samples: [0.3, -0.2]))
        await settle()

        XCTAssertEqual(engine.virtualMicPublisherState, .unavailable)
    }

    func testPendingMuteStateUpdateCannotOverwriteStoppedPublisherState() async throws {
        let source = FakeCaptureSource()
        let publisher = FakeVirtualMicPublisher()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in FakeWriter() },
            mixerBlockFrames: 4,
            virtualMicPublisher: publisher
        )
        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "AirPods-UID"
        )

        engine.applyInputMuteToAudioPaths(true)
        await engine.stopMonitoring()
        await settle()

        XCTAssertEqual(engine.virtualMicPublisherState, .stopped)
    }

    func testImmediateMuteGateSilencesRecordingBeforeDisplayNotification() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let publisher = FakeVirtualMicPublisher()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4,
            virtualMicPublisher: publisher
        )
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: "AirPods-UID",
            baseFolder: temporaryFolder()
        )

        engine.applyInputMuteToAudioPaths(true)
        XCTAssertFalse(engine.micMuted)
        XCTAssertEqual(publisher.muteCalls, [true])

        source.emit(try block(.system, frame: 0, samples: [0, 0, 0, 0]))
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertTrue(writer.blocks[0].left.allSatisfy { $0 == 0 })
        XCTAssertTrue(writer.blocks[0].right.allSatisfy { $0 == 0 })

        engine.updateMicMuteDisplay(true)
        XCTAssertTrue(engine.micMuted)
        _ = await engine.stop()
    }

    func testStartDoesNotRequireBlackHoleDevice() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)

        let folder = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )

        XCTAssertEqual(source.startedSelection, .allSystemAudio)
        XCTAssertEqual(source.startedMicrophoneUID, "BuiltInMicrophone")
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSelectedAppDisconnectKeepsRecordingActive() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .applicationDisconnected("Teams"))
        await settle()
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(engine.isSystemCaptureConnected)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(try XCTUnwrap(writer.blocks.first?.left.first), 0.48, accuracy: 0.001)
    }

    func testReconnectUpdatesActiveSourceWithoutRecreatingWriterOrMicrophone() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        let folder = try await engine.start(
            selection: .application(original),
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(original.name))
        await settle()

        try await engine.reconnect(selection: .application(restarted))

        XCTAssertEqual(source.reconnectedSelection, .application(restarted))
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 0)
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(engine.isMonitoring)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(engine.outputFolder, folder)
        XCTAssertEqual(writer.closeCount, 0)
    }

    func testReconnectPreservesCompleteRecordingContinuityContract() async throws {
        let source = FakeCaptureSource()
        let factory = FakeWriterFactory()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: factory.makeWriter,
            mixerBlockFrames: 4
        )
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let restarted = CaptureApplication(
            processID: 99,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        let baseFolder = temporaryFolder()
        let folder = try await engine.start(
            selection: .application(original),
            microphoneUID: "AirPods-UID",
            baseFolder: baseFolder
        )
        engine.toggleMicMute()
        source.emit(event: .applicationDisconnected(original.name))
        await settle()
        let before = engine.continuitySnapshot

        try await engine.reconnect(selection: .application(restarted))
        let after = engine.continuitySnapshot
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertEqual(factory.createCount, 1)
        XCTAssertEqual(factory.requestedURLs, [folder.appendingPathComponent("recording.m4a")])
        XCTAssertEqual(before, after)
        XCTAssertEqual(source.streamIdentityAtStart, source.streamIdentityAtReconnect)
        XCTAssertEqual(source.filterUpdateCount, 1)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 0)
        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(engine.micMuted)
        XCTAssertTrue(factory.writers[0].blocks.allSatisfy { $0.left.allSatisfy { $0 == 0 } })
    }

    func testReconnectRejectsCrossBundleTarget() async throws {
        let source = FakeCaptureSource()
        let engine = makeEngine(source: source, writer: FakeWriter())
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let other = CaptureApplication(
            processID: 99,
            bundleIdentifier: "com.apple.Music",
            name: "Music"
        )
        _ = try await engine.start(
            selection: .application(original),
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(original.name))
        await settle()

        await XCTAssertThrowsErrorAsync(
            try await engine.reconnect(selection: .application(other))
        )

        XCTAssertEqual(source.reconnectCount, 0)
        XCTAssertFalse(engine.isSystemCaptureConnected)
    }

    func testReconnectRequiresDisconnectedSelectedApplicationSession() async throws {
        let source = FakeCaptureSource()
        let engine = makeEngine(source: source, writer: FakeWriter())
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        _ = try await engine.start(
            selection: .application(application),
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        await XCTAssertThrowsErrorAsync(
            try await engine.reconnect(selection: .application(application))
        )

        XCTAssertEqual(source.reconnectCount, 0)
        XCTAssertTrue(engine.isSystemCaptureConnected)
    }

    func testFailedReconnectKeepsRecordingMicrophoneAndDisconnectedSystemAudio() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        _ = try await engine.start(
            selection: .application(application),
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(application.name))
        await settle()
        source.reconnectError = CaptureSourceError.selectedApplicationUnavailable

        do {
            try await engine.reconnect(selection: .application(application))
            XCTFail("Expected reconnect failure")
        } catch {
            XCTAssertEqual(error as? CaptureSourceError, .selectedApplicationUnavailable)
        }
        source.emit(try block(.microphone, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(engine.isRecording)
        XCTAssertTrue(engine.isMonitoring)
        XCTAssertFalse(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 0)
        XCTAssertEqual(writer.closeCount, 0)
        XCTAssertEqual(writer.blocks.count, 1)
    }

    func testConcurrentReconnectRequestsCoalesceToOneSourceOperation() async throws {
        let source = FakeCaptureSource()
        source.pauseReconnect = true
        let engine = makeEngine(source: source, writer: FakeWriter())
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        _ = try await engine.start(
            selection: .application(application),
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(application.name))
        await settle()

        async let first: Void = engine.reconnect(selection: .application(application))
        await waitUntil { source.reconnectCount == 1 }
        async let second: Void = engine.reconnect(selection: .application(application))
        await settle()

        XCTAssertEqual(source.reconnectCount, 1)
        source.resumeAllReconnects()
        try await first
        try await second
        XCTAssertEqual(source.reconnectCount, 1)
    }

    func testDifferentReconnectTargetsDoNotCoalesce() async throws {
        let source = FakeCaptureSource()
        source.pauseReconnect = true
        let engine = makeEngine(source: source, writer: FakeWriter())
        let original = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let firstTarget = CaptureApplication(
            processID: 99,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        let secondTarget = CaptureApplication(
            processID: 100,
            bundleIdentifier: original.bundleIdentifier,
            name: original.name
        )
        _ = try await engine.start(
            selection: .application(original),
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(original.name))
        await settle()

        let first = Task { @MainActor in
            try await engine.reconnect(selection: .application(firstTarget))
        }
        await waitUntil { source.reconnectCount == 1 }
        await XCTAssertThrowsErrorAsync(
            try await engine.reconnect(selection: .application(secondTarget))
        )

        XCTAssertEqual(source.reconnectCount, 1)
        source.resumeReconnect()
        try await first.value
    }

    func testStopWinsOverLateSuccessfulReconnect() async throws {
        let source = FakeCaptureSource()
        source.pauseReconnect = true
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        _ = try await engine.start(
            selection: .application(application),
            microphoneUID: "BuiltInMicrophone",
            baseFolder: temporaryFolder()
        )
        source.emit(event: .applicationDisconnected(application.name))
        await settle()

        let reconnect = Task { @MainActor in
            try await engine.reconnect(selection: .application(application))
        }
        await waitUntil { source.reconnectCount == 1 }
        let stop = Task { @MainActor in await engine.stop() }
        await waitUntil { source.stopCount == 1 }
        source.resumeReconnect()
        _ = await stop.value

        do {
            try await reconnect.value
            XCTFail("Stopped recording must reject a late reconnect completion")
        } catch {
            XCTAssertEqual(error as? CaptureSourceError, .streamStartCancelled)
        }
        XCTAssertFalse(engine.isRecording)
        XCTAssertFalse(engine.isMonitoring)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testMicrophoneDisconnectKeepsSystemRecordingActive() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .microphoneDisconnected)
        await settle()
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(engine.isRecording)
        XCTAssertFalse(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(try XCTUnwrap(writer.blocks.first?.left.first), 0.48, accuracy: 0.001)
    }

    func testStopFlushesMixerAndClosesWriterOnce() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [0.5, 0.5, 0.5, 0.5]))
        source.emit(try block(.microphone, frame: 0, samples: [0.5, 0.5, 0.5, 0.5]))

        let result = await engine.stop()
        let second = await engine.stop()

        XCTAssertNotNil(result)
        XCTAssertNil(second)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(writer.closeCount, 1)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(writer.events, ["write", "close"])
    }

    func testConversionFailureAppearsInHealthReport() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .conversionFailed(.system))
        let result = await engine.stop()

        XCTAssertEqual(result?.health.conversionFailures, 1)
        XCTAssertTrue(result?.health.summary.contains("conversion failures") == true)
    }

    func testTerminalCaptureFailureAppearsInCompletedHealthReport() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let completion = RecordingResultCapture()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4,
            onRecordingStopped: { completion.store($0) }
        )
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(event: .streamFailed)
        await waitUntil { completion.value != nil }

        XCTAssertEqual(completion.value?.health.streamFailures, 1)
        XCTAssertFalse(engine.isRecording)
    }

    func testTimelineDiscontinuityIsReportedWithoutPaddingElapsedDuration() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        source.emit(try block(.system, frame: 48_000 * 3_600, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 48_000 * 3_600, samples: [0, 0, 0, 0]))
        await settle()
        let result = await engine.stop()

        XCTAssertEqual(writer.blocks.count, 2)
        XCTAssertEqual(writer.physicalFrameCount, 8)
        XCTAssertEqual(result?.health.timelineDiscontinuities, 1)
    }

    func testStopBoundsOneHourSparseSourceGap() async throws {
        let futureFrame: Int64 = 48_000 * 3_600
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        source.emit(try block(
            .system,
            frame: futureFrame,
            samples: Array(repeating: 1, count: 8)
        ))

        let result = await engine.stop()

        XCTAssertEqual(writer.blocks.map(\.startFrame), [0, futureFrame, futureFrame + 4])
        XCTAssertEqual(writer.physicalFrameCount, 12)
        XCTAssertEqual(result?.health.timelineDiscontinuities, 1)
    }

    func testStopWritesExactPartialTail() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1]))

        _ = await engine.stop()

        XCTAssertEqual(writer.blocks.map(\.left.count), [3])
        XCTAssertEqual(writer.physicalFrameCount, 3)
    }

    func testWriterOpenFailureRollsBackSourceAndEmptyFolder() async throws {
        let source = FakeCaptureSource()
        let attemptedURL = URLBox()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: { url in
                attemptedURL.value = url
                throw FakeFailure.writerOpen
            },
            mixerBlockFrames: 4
        )
        let baseFolder = temporaryFolder()
        try FileManager.default.createDirectory(
            at: baseFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: baseFolder) }

        do {
            _ = try await engine.start(
                selection: .allSystemAudio,
                microphoneUID: nil,
                baseFolder: baseFolder
            )
            XCTFail("Expected writer open failure")
        } catch {
            XCTAssertTrue(error is RecordingEngineError)
        }

        let attemptedFolder = try XCTUnwrap(attemptedURL.value?.deletingLastPathComponent())
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertFalse(engine.isMonitoring)
        XCTAssertFalse(engine.isRecording)
        let result = await engine.stop()
        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attemptedFolder.path))
    }

    func testConcurrentSameMonitoringRequestCoalescesOneSourceStart() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let engine = makeEngine(source: source, writer: FakeWriter())

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await settle()
        source.resumeAllStarts()
        try await first
        try await second

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.maximumConcurrentStarts, 1)
        XCTAssertTrue(engine.isMonitoring)
    }

    func testDifferentMonitoringRequestWaitsThenRestarts() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let engine = makeEngine(source: source, writer: FakeWriter())
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .application(teams),
            microphoneUID: "mic-b"
        )
        await settle()
        source.resumeNextStart()
        await waitUntil { source.startCount == 2 }
        source.resumeNextStart()
        try await first
        try await second

        XCTAssertEqual(source.startedSelections, [.allSystemAudio, .application(teams)])
        XCTAssertEqual(source.maximumConcurrentStarts, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertTrue(engine.isMonitoring)
    }

    func testFailedMonitoringRequestCannotPolluteNewSession() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        source.startErrors[1] = CaptureSourceError.streamFailure
        let engine = makeEngine(source: source, writer: FakeWriter())
        let teams = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )

        async let first: Void = engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: "mic-a"
        )
        await waitUntil { source.startCount == 1 }
        async let second: Void = engine.startMonitoring(
            selection: .application(teams),
            microphoneUID: "mic-b"
        )
        source.resumeNextStart()
        await waitUntil { source.startCount == 2 }
        source.resumeNextStart()

        do {
            try await first
            XCTFail("Expected first monitoring request to fail")
        } catch {}
        try await second

        XCTAssertTrue(engine.isMonitoring)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertNil(engine.captureStatus)
    }

    func testConcurrentRecordingStartsCreateOneWriter() async throws {
        let source = FakeCaptureSource()
        source.pauseStarts = true
        let factory = FakeWriterFactory()
        let engine = RecordingEngine(
            captureSource: source,
            writerFactory: factory.makeWriter,
            mixerBlockFrames: 4
        )
        let baseFolder = temporaryFolder()

        async let first = engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: baseFolder
        )
        await waitUntil { source.startCount == 1 }
        async let second = engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: baseFolder
        )
        await settle()
        source.resumeAllStarts()
        let folders = try await [first, second]

        XCTAssertEqual(factory.createCount, 1)
        XCTAssertEqual(Set(folders).count, 1)
        _ = await engine.stop()
    }

    func testTerminalEventDuringRecordingFinalizesOnce() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        source.emit(event: .streamStoppedBySystem)
        await settle()

        await waitUntil { !engine.isRecording }
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertTrue(engine.isSystemCaptureConnected)
        XCTAssertTrue(engine.isMicrophoneCaptureConnected)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testMonitorOnlyTerminalEventAllowsSameSelectionRestart() async throws {
        let source = FakeCaptureSource()
        let engine = makeEngine(source: source, writer: FakeWriter())
        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: nil
        )

        source.emit(event: .streamFailed)
        await settle()
        XCTAssertFalse(engine.isMonitoring)

        try await engine.startMonitoring(
            selection: .allSystemAudio,
            microphoneUID: nil
        )

        XCTAssertEqual(source.startCount, 2)
        XCTAssertTrue(engine.isMonitoring)
    }

    func testConnectionSnapshotCarriesSourceIdentityAndClearsAfterStop() async throws {
        let source = FakeCaptureSource()
        let engine = makeEngine(source: source, writer: FakeWriter())
        let application = CaptureApplication(
            processID: 42,
            bundleIdentifier: "com.microsoft.teams2",
            name: "Microsoft Teams"
        )
        let selection = ResolvedCaptureSelection.application(application)

        try await engine.startMonitoring(
            selection: selection,
            microphoneUID: "BuiltInMicrophone"
        )
        let activeSnapshot = engine.captureConnectionSnapshot
        let sourceSessionID = try XCTUnwrap(activeSnapshot.sourceSessionID)

        XCTAssertEqual(activeSnapshot.activeSelection, selection)
        XCTAssertTrue(activeSnapshot.isMonitoring)
        XCTAssertTrue(activeSnapshot.isSystemCaptureConnected)

        source.emit(event: .applicationDisconnected(application.name))
        await settle()

        XCTAssertEqual(
            engine.captureConnectionSnapshot,
            CaptureConnectionSnapshot(
                sourceSessionID: sourceSessionID,
                activeSelection: selection,
                isMonitoring: true,
                isSystemCaptureConnected: false
            )
        )

        await engine.stopMonitoring()

        XCTAssertEqual(engine.captureConnectionSnapshot, .idle)
    }

    func testNoAudioStopDoesNotWritePhantomBlock() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        _ = await engine.stop()

        XCTAssertTrue(writer.blocks.isEmpty)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testConcurrentStopsCloseWriterOnlyOnce() async throws {
        let source = FakeCaptureSource()
        source.pauseStop = true
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        async let first = engine.stop()
        await waitUntil { source.stopCount == 1 }
        async let second = engine.stop()
        let secondResult = await second
        source.resumeStop()
        let firstResult = await first
        let results = [firstResult, secondResult]

        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testCallbackBarrierFlushesAcceptedFrameAndDropsOldSession() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )

        source.emit(try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        source.emit(try block(.microphone, frame: 0, samples: [0, 0, 0, 0]))
        let result = await engine.stop()
        source.emit(try block(.system, frame: 4, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertNotNil(result)
        XCTAssertEqual(writer.blocks.count, 1)
        XCTAssertEqual(writer.closeCount, 1)
    }

    func testOldSessionCallbackCannotWriteToNewSessionWriter() async throws {
        let source = FakeCaptureSource()
        let writer = FakeWriter()
        let engine = makeEngine(source: source, writer: writer)
        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        _ = await engine.stop()
        writer.resetBlocks()

        _ = try await engine.start(
            selection: .allSystemAudio,
            microphoneUID: nil,
            baseFolder: temporaryFolder()
        )
        source.emitFromSession(0, try block(.system, frame: 0, samples: [1, 1, 1, 1]))
        await settle()

        XCTAssertTrue(writer.blocks.isEmpty)
        _ = await engine.stop()
    }

    private func temporaryFolder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeEngine(source: FakeCaptureSource, writer: FakeWriter) -> RecordingEngine {
        RecordingEngine(
            captureSource: source,
            writerFactory: { _ in writer },
            mixerBlockFrames: 4
        )
    }

    private func coordinatorEngine() -> (RecordingEngine, FakeMediaCoordinator, FakeCaptureSource) {
        let source = FakeCaptureSource()
        let coordinator = FakeMediaCoordinator()
        let engine = RecordingEngine(captureSource: source, coordinatorFactory: { outputs, sessionID, epoch, revision, pixelFormat in
            coordinator.configure(outputs: outputs, sourceSessionID: sessionID, epoch: epoch, revision: revision, pixelFormat: pixelFormat)
            return coordinator
        }, mixerBlockFrames: 4)
        return (engine, coordinator, source)
    }

    private func teamsWindow(id: UInt32) -> TeamsWindowSnapshot {
        TeamsWindowSnapshot(
            identity: TeamsWindowIdentity(processID: teamsProcessID, windowID: id),
            title: "Teams meeting \(id)",
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isOnScreen: true,
            layer: 0
        )
    }

    private var teamsProcessID: pid_t { 3016 }

    private func assertScreenState(
        _ state: MeetingScreenCaptureState,
        identity: TeamsWindowIdentity,
        capturing: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch state {
        case let .capturing(descriptor) where capturing:
            XCTAssertEqual(descriptor.identity, identity, file: file, line: line)
        case let .waiting(descriptors) where !capturing:
            XCTAssertEqual(descriptors.map(\.identity), [identity], file: file, line: line)
        default:
            XCTFail("Unexpected screen state: \(state)", file: file, line: line)
        }
    }

    private func assertFrameUnavailable(
        _ state: MeetingScreenCaptureState,
        identity: TeamsWindowIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .frameUnavailable(descriptor) = state else {
            return XCTFail("Unexpected screen state: \(state)", file: file, line: line)
        }
        XCTAssertEqual(descriptor.identity, identity, file: file, line: line)
    }

    private func assertAwaitingFrames(
        _ state: MeetingScreenCaptureState,
        identity: TeamsWindowIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .awaitingFrames(descriptor) = state else {
            return XCTFail("Unexpected screen state: \(state)", file: file, line: line)
        }
        XCTAssertEqual(descriptor.identity, identity, file: file, line: line)
    }

    private func assertTargetLost(
        _ state: MeetingScreenCaptureState,
        identity: TeamsWindowIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .targetLost(descriptor) = state else {
            return XCTFail("Unexpected screen state: \(state)", file: file, line: line)
        }
        XCTAssertEqual(descriptor?.identity, identity, file: file, line: line)
    }

    private func videoFrame(seconds: Int64, valid: Bool = true) throws -> ScreenVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &buffer
        ), kCVReturnSuccess)
        return ScreenVideoFrame(
            pixelBuffer: try XCTUnwrap(buffer),
            sourcePTS: valid ? CMTime(value: seconds, timescale: 1) : .invalid,
            status: .complete,
            filterRevision: CaptureFilterRevision(sessionGeneration: 1, revision: 1)
        )
    }

    private func block(_ source: AudioSourceKind, frame: Int64, samples: [Float]) throws -> AudioFrameBlock {
        try AudioFrameBlock.stereo(source: source, startFrame: frame, left: samples, right: samples)
    }

    private func settle() async {
        await Task.yield()
        await Task.yield()
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }
}

private final class RecordingResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RecordingResult?

    var value: RecordingResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: RecordingResult?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class FakeCaptureSource: CaptureSourceProtocol, @unchecked Sendable {
    let screenVideoFormat = ScreenVideoFormat(width: 1_600, height: 900, pixelFormat: kCVPixelFormatType_32BGRA)
    private let streamIdentity = UUID()
    private let callbackLock = NSLock()
    private var onAudio: ((AudioFrameBlock) -> Void)?
    private var onEvent: ((CaptureEvent) -> Void)?
    private var onVideo: ((ScreenVideoFrame) -> Void)?
    private var audioHandlers: [(AudioFrameBlock) -> Void] = []
    private var videoHandlers: [(ScreenVideoFrame) -> Void] = []
    private(set) var startedSelection: ResolvedCaptureSelection?
    private(set) var startedMicrophoneUID: String?
    private(set) var stopCount = 0
    private(set) var startCount = 0
    private(set) var activeStarts = 0
    private(set) var maximumConcurrentStarts = 0
    private(set) var startedSelections: [ResolvedCaptureSelection] = []
    private(set) var reconnectedSelection: ResolvedCaptureSelection?
    private(set) var reconnectCount = 0
    private(set) var filterUpdateCount = 0
    private(set) var videoTargets: [TeamsWindowIdentity?] = []
    private(set) var videoRevisions: [CaptureFilterRevision] = []
    private(set) var streamIdentityAtStart: UUID?
    private(set) var streamIdentityAtReconnect: UUID?
    var pauseStarts = false
    var pauseReconnect = false
    var startErrors: [Int: Error] = [:]
    var reconnectError: Error?
    var pauseStop = false
    var pauseVideoTargetUpdates = false
    var windows: [TeamsWindowSnapshot] = []
    var videoTargetErrors: [Int: Error] = [:]
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var reconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var videoTargetContinuations: [CheckedContinuation<CaptureFilterRevision, Error>] = []

    func refreshContent() async throws -> [CaptureApplication] { [] }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] { windows }

    func updateVideoTarget(_ target: TeamsWindowIdentity?) async throws -> CaptureFilterRevision {
        videoTargets.append(target)
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: UInt64(videoTargets.count))
        videoRevisions.append(revision)
        if pauseVideoTargetUpdates {
            return try await withCheckedThrowingContinuation { continuation in
                videoTargetContinuations.append(continuation)
            }
        }
        if let error = videoTargetErrors[videoTargets.count] { throw error }
        return revision
    }

    func reconnect(selection: ResolvedCaptureSelection) async throws {
        reconnectCount += 1
        if pauseReconnect {
            await withCheckedContinuation { continuation in
                reconnectContinuations.append(continuation)
            }
        }
        if let reconnectError { throw reconnectError }
        filterUpdateCount += 1
        streamIdentityAtReconnect = streamIdentity
        reconnectedSelection = selection
    }

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onVideo: @escaping (ScreenVideoFrame) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws {
        startCount += 1
        let thisStart = startCount
        activeStarts += 1
        maximumConcurrentStarts = max(maximumConcurrentStarts, activeStarts)
        startedSelections.append(selection)
        defer { activeStarts -= 1 }
        if pauseStarts {
            await withCheckedContinuation { continuation in
                startContinuations.append(continuation)
            }
        }
        if let error = startErrors[thisStart] {
            throw error
        }
        startedSelection = selection
        startedMicrophoneUID = microphoneUID
        streamIdentityAtStart = streamIdentity
        storeHandlers(audio: onAudio, video: onVideo, event: onEvent)
    }

    func stop() async {
        stopCount += 1
        guard pauseStop else { return }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func emit(_ block: AudioFrameBlock) {
        callbackLock.lock()
        let handler = onAudio
        callbackLock.unlock()
        handler?(block)
    }

    func emit(event: CaptureEvent) {
        callbackLock.lock()
        let handler = onEvent
        callbackLock.unlock()
        handler?(event)
    }

    func emit(video: ScreenVideoFrame) {
        callbackLock.lock()
        let handler = onVideo
        callbackLock.unlock()
        handler?(video)
    }

    func emitVideoOnBackground(_ frame: ScreenVideoFrame) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                emit(video: frame)
                continuation.resume()
            }
        }
    }

    func emitOldVideo(_ index: Int, frame: ScreenVideoFrame) {
        callbackLock.lock()
        let handler = videoHandlers[index]
        callbackLock.unlock()
        handler(frame)
    }

    func emitFromSession(_ index: Int, _ block: AudioFrameBlock) {
        callbackLock.lock()
        let handler = audioHandlers[index]
        callbackLock.unlock()
        handler(block)
    }

    func resumeStop() {
        let continuation = stopContinuation
        stopContinuation = nil
        continuation?.resume()
    }

    func resumeNextStart() {
        guard !startContinuations.isEmpty else { return }
        startContinuations.removeFirst().resume()
    }

    func resumeAllStarts() {
        pauseStarts = false
        let continuations = startContinuations
        startContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func resumeReconnect() {
        guard !reconnectContinuations.isEmpty else { return }
        reconnectContinuations.removeFirst().resume()
    }

    func resumeAllReconnects() {
        let continuations = reconnectContinuations
        reconnectContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func completeNextVideoTarget() {
        guard !videoTargetContinuations.isEmpty else { return }
        let continuation = videoTargetContinuations.removeFirst()
        let revision = videoRevisions[videoRevisions.count - videoTargetContinuations.count - 1]
        continuation.resume(returning: revision)
    }

    func failNextVideoTarget(_ error: Error) {
        guard !videoTargetContinuations.isEmpty else { return }
        videoTargetContinuations.removeFirst().resume(throwing: error)
    }

    private func storeHandlers(
        audio: @escaping (AudioFrameBlock) -> Void,
        video: @escaping (ScreenVideoFrame) -> Void,
        event: @escaping (CaptureEvent) -> Void
    ) {
        callbackLock.lock()
        onAudio = audio
        onVideo = video
        onEvent = event
        audioHandlers.append(audio)
        videoHandlers.append(video)
        callbackLock.unlock()
    }
}

private final class FakeWriter: MixedAudioWriting {
    private(set) var blocks: [MixedAudioBlock] = []
    private(set) var closeCount = 0
    private(set) var events: [String] = []

    var physicalFrameCount: Int {
        blocks.reduce(0) { $0 + $1.left.count }
    }

    func write(_ block: MixedAudioBlock) throws {
        blocks.append(block)
        events.append("write")
    }

    func close() throws {
        closeCount += 1
        events.append("close")
    }

    func resetBlocks() {
        blocks.removeAll()
    }
}

private enum TestError: Error { case failed }

private final class FakeMediaCoordinator: RecordingMediaCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private let videoEnqueueStarted = DispatchSemaphore(value: 0)
    private var blockedVideoEnqueue: DispatchSemaphore?
    var blockVideoEnqueue = false
    var outputs: RecordingOutputURLs?
    private(set) var sourceSessionID: UUID?
    private(set) var epoch: UInt64?
    private(set) var revision: CaptureFilterRevision?
    private(set) var pixelFormat: OSType?
    var outcome = RecordingMediaOutcome(
        finalURL: URL(fileURLWithPath: "/tmp/recording.mp4"), mediaKind: .video,
        screenIntervals: [], capturedWindow: nil, recoveryState: .none,
        videoDroppedFrames: 0, videoFailureDescription: nil, safetyCleanupDiagnostic: nil
    )
    private(set) var audioBlocks: [MixedAudioBlock] = []
    private(set) var finishCount = 0
    private(set) var videoFrames: [ScreenVideoFrame] = []
    private(set) var enqueueVideoOnMainActor: [Bool] = []
    private(set) var screenUnavailableCount = 0
    private(set) var screenRequests: [(requested: Bool, revision: CaptureFilterRevision?, window: RecordedTeamsWindowIdentity?)] = []
    private(set) var events: [String] = []
    private(set) var handlerInstallCount = 0
    private var handler: (@Sendable (RecordingVideoEvent) -> Void)?

    func configure(outputs: RecordingOutputURLs, sourceSessionID: UUID, epoch: UInt64, revision: CaptureFilterRevision, pixelFormat: OSType) {
        self.outputs = outputs
        self.sourceSessionID = sourceSessionID
        self.epoch = epoch
        self.revision = revision
        self.pixelFormat = pixelFormat
    }

    func setVideoEventHandler(_ handler: (@Sendable (RecordingVideoEvent) -> Void)?) {
        self.handler = handler
        handlerInstallCount += 1
        events.append(handler == nil ? "handler-clear" : "handler-install")
    }

    func enqueueAudio(_ block: MixedAudioBlock) {
        lock.lock()
        audioBlocks.append(block)
        events.append("audio")
        lock.unlock()
    }

    func enqueueVideo(_ frame: ScreenVideoFrame) {
        lock.lock()
        videoFrames.append(frame)
        enqueueVideoOnMainActor.append(Thread.isMainThread)
        events.append("video")
        let shouldBlock = blockVideoEnqueue
        let semaphore = shouldBlock ? DispatchSemaphore(value: 0) : nil
        blockedVideoEnqueue = semaphore
        lock.unlock()
        videoEnqueueStarted.signal()
        guard shouldBlock else { return }
        semaphore?.wait()
    }

    func waitForVideoEnqueueStart() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.videoEnqueueStarted.wait()
                continuation.resume()
            }
        }
    }

    func releaseBlockedVideoEnqueue() {
        lock.lock()
        let semaphore = blockedVideoEnqueue
        blockedVideoEnqueue = nil
        lock.unlock()
        semaphore?.signal()
    }
    func setScreenCaptureRequested(_ requested: Bool, expectedRevision: CaptureFilterRevision?, window: RecordedTeamsWindowIdentity?) {
        screenRequests.append((requested, expectedRevision, window))
    }
    func markScreenSourceUnavailable() { screenUnavailableCount += 1 }
    func finish() async throws -> RecordingMediaOutcome { finishCount += 1; events.append("finish"); return outcome }
    func emitCurrent(
        _ kind: RecordingVideoEventKind,
        filterRevision: CaptureFilterRevision? = nil,
        acceptedFrameRevision: CaptureFilterRevision? = nil
    ) {
        guard let sourceSessionID, let epoch else { return }
        handler?(RecordingVideoEvent(
            sourceSessionID: sourceSessionID,
            recordingEpoch: epoch,
            kind: kind,
            filterRevision: filterRevision,
            acceptedFrameRevision: acceptedFrameRevision
        ))
    }
}

private final class FakeWriterFactory {
    private(set) var createCount = 0
    private(set) var writers: [FakeWriter] = []
    private(set) var requestedURLs: [URL] = []

    func makeWriter(url: URL) throws -> MixedAudioWriting {
        createCount += 1
        requestedURLs.append(url)
        let writer = FakeWriter()
        writers.append(writer)
        return writer
    }
}

private final class FakeVirtualMicPublisher: VirtualMicPublishing {
    private(set) var state: VirtualMicPublisherState = .stopped
    var becomeUnavailableOnPublish = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var muteCalls: [Bool] = []
    private(set) var publishedLeft: [[Float]] = []
    private(set) var publishedRight: [[Float]] = []

    func start() {
        startCount += 1
        state = .ready
    }

    func publishMicrophone(left: [Float], right: [Float]) {
        publishedLeft.append(left)
        publishedRight.append(right)
        if becomeUnavailableOnPublish {
            state = .unavailable
        }
    }

    func setMuted(_ muted: Bool) {
        muteCalls.append(muted)
    }

    func stop() {
        stopCount += 1
        state = .stopped
    }
}

private final class URLBox {
    var value: URL?
}

private enum FakeFailure: Error {
    case writerOpen
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
