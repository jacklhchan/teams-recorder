import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit
import XCTest
@testable import RecorderApp

final class RecordingMediaCoordinatorTests: XCTestCase {
    func testSuccessfulFinishPromotesPartialMP4AndDeletesBackup() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.finalMP4)
        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertEqual(outcome.recoveryState, .none)
        XCTAssertEqual(fixture.files.promotions, [Promotion(fixture.outputs.partialMP4, fixture.outputs.finalMP4)])
        XCTAssertEqual(fixture.files.removed, [fixture.outputs.audioBackup])
    }

    func testNeverEnabledScreenStillProducesFinalMP4() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertTrue(fixture.mux.videoTimes.contains(.zero))
    }

    func testDroppableVideoBackpressureKeepsAudioAndCountsDrop() async throws {
        let fixture = try makeFixture(videoErrors: [MuxedMediaWriterError.videoAppendDropped])
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertGreaterThan(outcome.videoDroppedFrames, 0)
        XCTAssertEqual(fixture.safety.blocks.count, 1)
        XCTAssertEqual(fixture.mux.audioBlocks.count, 1)
    }

    func testClosingBlackFailureFallsBackWithoutPublishingScreenInterval() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(
            criticalVideoErrors: [MuxedMediaWriterError.videoAppendDropped],
            executor: state
        )
        fixture.coordinator.setScreenCaptureRequested(
            true,
            expectedRevision: fixture.revision,
            window: nil
        )
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 9_600))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 4_800, timescale: 48_000),
            revision: fixture.revision
        ))
        state.runAll()

        fixture.coordinator.markScreenSourceUnavailable()
        state.runAll()
        let outcome = try await finish(fixture.coordinator, using: state)

        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertEqual(outcome.recoveryState, .videoLostAudioPreserved)
        XCTAssertTrue(outcome.screenIntervals.isEmpty)
        XCTAssertEqual(fixture.mux.criticalVideoAppendAttempts, 1)
    }

    func testMuxFailureLatchesOnceAndContinuesSafetyAudio() async throws {
        let fixture = try makeFixture(audioErrors: [TestError.mux, TestError.second])
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        fixture.coordinator.enqueueAudio(audioBlock(start: 480, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(fixture.safety.blocks.count, 2)
        XCTAssertEqual(fixture.mux.audioAppendAttempts, 1)
        XCTAssertEqual(outcome.recoveryState, .videoLostAudioPreserved)
    }

    func testFailedMuxPromotesBackupToRecordingM4A() async throws {
        let fixture = try makeFixture(audioErrors: [TestError.mux])
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertEqual(outcome.recoveryState, .videoLostAudioPreserved)
        XCTAssertEqual(fixture.files.promotions, [Promotion(fixture.outputs.audioBackup, fixture.outputs.recoveredM4A)])
    }

    func testFailedMuxRetainsPartialMP4AsRecoveryArtifact() async throws {
        let fixture = try makeFixture(audioErrors: [TestError.mux])
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        _ = try await fixture.coordinator.finish()

        XCTAssertFalse(fixture.files.removed.contains(fixture.outputs.partialMP4))
    }

    func testSafetyFailureIsReportedWithoutDeletingValidMP4() async throws {
        let fixture = try makeFixture(safetyCloseError: TestError.safety)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.finalMP4)
        XCTAssertNotNil(outcome.safetyCleanupDiagnostic)
        XCTAssertEqual(fixture.files.promotions, [Promotion(fixture.outputs.partialMP4, fixture.outputs.finalMP4)])
    }

    func testVideoIngressHoldsAtMostTwoPendingFrames() throws {
        let fixture = try makeFixture()
        for value in 0..<20 {
            fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: CMTimeValue(value), timescale: 48_000)))
        }
        XCTAssertLessThanOrEqual(fixture.coordinator.pendingVideoOwnershipCount, 2)
    }

    func testProducerFloodSchedulesOneDrainAndRetainsAtMostTwoPixelBuffers() throws {
        let executor = ManualExecutor()
        let fixture = try makeFixture(executor: executor)
        for value in 0..<100 {
            fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: CMTimeValue(value), timescale: 48_000)))
        }
        XCTAssertEqual(fixture.coordinator.scheduledVideoDrainCount, 1)
        XCTAssertLessThanOrEqual(fixture.coordinator.pendingVideoOwnershipCount, 2)
        XCTAssertLessThanOrEqual(fixture.coordinator.peakVideoOwnershipCount, 2)
        executor.runAll()
    }

    func testTemporaryMuxAudioBackpressureDoesNotTriggerFallback() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state, muxPendingAudio: true)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        state.runAll()

        XCTAssertTrue(fixture.mux.audioBlocks.isEmpty)
        XCTAssertEqual(fixture.mux.pendingAudio.count, 1)

        let outcome = try await finish(fixture.coordinator, using: state)

        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertEqual(fixture.mux.finishCalls, 1)
        XCTAssertEqual(fixture.mux.pendingAudio.count, 0)
        XCTAssertEqual(fixture.mux.audioBlocks.map(\.presentationTime), [.zero])
    }

    func testIdleFramesKeepAStaticScreenIntervalAlive() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 1))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 1, frames: 60_000))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 60_000, timescale: 48_000),
            revision: fixture.revision,
            status: .idle
        ))
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 60_001, frames: 60_000))
        state.runAll()

        let outcome = try await finish(fixture.coordinator, using: state)

        XCTAssertFalse(events.kinds.contains(.sourceStalled))
        XCTAssertEqual(outcome.screenIntervals.count, 1)
        XCTAssertGreaterThan(outcome.screenIntervals[0].endSeconds, 2)
    }

    func testStaticScreenWithoutFurtherCallbacksRemainsOpenUntilFinish() async throws {
        let state = ManualExecutor()
        let eventExecutor = ManualExecutor()
        let fixture = try makeFixture(executor: state, eventExecutor: eventExecutor)
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.setScreenCaptureRequested(
            true,
            expectedRevision: fixture.revision,
            window: nil
        )
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 4_800, timescale: 48_000),
            revision: fixture.revision
        ))
        state.runAll()
        for start in stride(from: Int64(480), to: 480_000, by: 480) {
            fixture.coordinator.enqueueAudio(audioBlock(start: start, frames: 480))
            state.runAll()
        }

        let outcome = try await finish(fixture.coordinator, using: state)
        eventExecutor.runAll()

        XCTAssertFalse(events.kinds.contains(.sourceStalled))
        XCTAssertEqual(fixture.mux.videoTimes.count, 3)
        XCTAssertEqual(fixture.mux.videoTimes[1], CMTime(value: 4_800, timescale: 48_000))
        XCTAssertEqual(fixture.mux.videoTimes.last, CMTime(value: 479_999, timescale: 48_000))
        XCTAssertEqual(outcome.screenIntervals.count, 1)
        XCTAssertEqual(outcome.screenIntervals[0].startSeconds, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(
            outcome.screenIntervals[0].endSeconds,
            Double(479_999) / 48_000,
            accuracy: 0.000_001
        )
    }

    func testCachedIdleFrameOpensScreenIntervalWhenMailboxEvictsCompleteFrame() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 4_800))
        state.runAll()

        fixture.coordinator.enqueueVideo(try videoFrame(
            time: .zero,
            revision: fixture.revision,
            status: .complete
        ))
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 1, timescale: 48_000),
            revision: fixture.revision,
            status: .idle
        ))
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 2, timescale: 48_000),
            revision: fixture.revision,
            status: .idle
        ))
        state.runAll()

        let outcome = try await finish(fixture.coordinator, using: state)

        XCTAssertEqual(outcome.videoDroppedFrames, 1)
        XCTAssertEqual(outcome.screenIntervals.count, 1)
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 1, timescale: 48_000)))
    }

    func testVideoEventsCarrySourceSessionAndRecordingEpoch() async throws {
        let fixture = try makeFixture(muxSetupError: TestError.mux)
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        _ = try await fixture.coordinator.finish()

        XCTAssertFalse(events.events.isEmpty)
        XCTAssertTrue(events.events.allSatisfy { $0.sourceSessionID == fixture.sessionID && $0.recordingEpoch == 42 })
    }

    func testClearedEventHandlerReceivesNoDelayedEvents() async throws {
        let fixture = try makeFixture(videoErrors: [MuxedMediaWriterError.videoAppendDropped])
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        let noHandler: (@Sendable (RecordingVideoEvent) -> Void)? = nil
        fixture.coordinator.setVideoEventHandler(noHandler)

        XCTAssertTrue(events.events.isEmpty)
    }

    func testFinishDrainsQueuedAudioBeforeClosingWriters() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        fixture.coordinator.enqueueAudio(audioBlock(start: 480, frames: 480))

        _ = try await fixture.coordinator.finish()

        XCTAssertEqual(fixture.safety.blocks.count, 2)
        XCTAssertEqual(fixture.mux.audioBlocks.count, 2)
    }

    func testSafetyWritePrecedesMuxAppendAndRepeatedFinishSharesResult() async throws {
        let trace = Trace()
        let fixture = try makeFixture(trace: trace)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        let first = Task { try await fixture.coordinator.finish() }
        let second = Task { try await fixture.coordinator.finish() }
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(fixture.mux.finishCalls, 1)
        XCTAssertEqual(trace.values.prefix(2), ["safety", "mux-audio"])
    }

    func testPostFinishIngressIsIgnored() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        _ = try await fixture.coordinator.finish()
        fixture.coordinator.enqueueAudio(audioBlock(start: 480, frames: 480))

        XCTAssertEqual(fixture.safety.blocks.count, 1)
    }

    func testFinishAdmissionBarrierRejectsLaterAudioControlAndVideo() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()
        _ = try await finish(fixture.coordinator, using: state)
        let audioCount = fixture.safety.blocks.count
        let videoCount = fixture.mux.videoTimes.count

        fixture.coordinator.enqueueAudio(audioBlock(start: 480, frames: 480))
        fixture.coordinator.setScreenCaptureRequested(false, expectedRevision: nil, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 480, timescale: 48_000), revision: fixture.revision))
        state.runAll()

        XCTAssertEqual(fixture.safety.blocks.count, audioCount)
        XCTAssertEqual(fixture.mux.videoTimes.count, videoCount)
        XCTAssertEqual(state.activeCount, 0)
        XCTAssertLessThanOrEqual(state.peakActiveCount, 1)
    }

    func testPromotionAndSafetyFailuresAreReturnedAsAggregate() async throws {
        let fixture = try makeFixture(audioErrors: [TestError.mux], safetyCloseError: TestError.safety)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        do {
            _ = try await fixture.coordinator.finish()
            XCTFail("Expected aggregate finalization failure")
        } catch let error as RecordingMediaFinalizationError {
            guard case .aggregate = error else { return XCTFail("Expected aggregate") }
        }
    }

    func testExistingDestinationPromotionFallsBackWithoutClaimingMP4() async throws {
        let fixture = try makeFixture()
        fixture.files.mp4PromotionError = TestError.destinationAlreadyExists
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
        XCTAssertFalse(fixture.files.promotions.contains(Promotion(fixture.outputs.partialMP4, fixture.outputs.finalMP4)))
    }

    func testCrossDevicePromotionFallsBackWithoutCopyingMP4() async throws {
        let fixture = try makeFixture()
        fixture.files.mp4PromotionError = TestError.crossDevice
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.mediaKind, .audio)
        XCTAssertEqual(fixture.files.promotions, [Promotion(fixture.outputs.audioBackup, fixture.outputs.recoveredM4A)])
    }

    func testSymlinkPromotionSourceFallsBackWithoutClaimingFinalMP4() async throws {
        let fixture = try makeFixture()
        fixture.files.mp4PromotionError = TestError.symlink
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
    }

    func testPostRenameValidationFailureFallsBackWithoutClaimingFinalMP4() async throws {
        let fixture = try makeFixture()
        fixture.files.failFinalMP4Validation = true
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
        XCTAssertTrue(fixture.files.promotions.contains(Promotion(fixture.outputs.finalMP4, fixture.outputs.partialMP4)))
    }

    func testMuxSetupFailureStillRecordsSafetyAndFallsBack() async throws {
        let fixture = try makeFixture(muxSetupError: TestError.mux)
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
        XCTAssertEqual(fixture.safety.blocks.count, 1)
        XCTAssertTrue(events.kinds.contains { if case .muxFailed = $0 { return true }; return false })
    }

    func testEarlyVideoIsReplayedWhenAudioAnchorArrives() async throws {
        let fixture = try makeFixture()
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 4_800, timescale: 48_000), revision: fixture.revision))
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 9_600))

        _ = try await fixture.coordinator.finish()

        XCTAssertGreaterThanOrEqual(fixture.mux.videoTimes.count, 2)
    }

    func testRevisionReplacementDropsOldFramesAndKeepsSessionIdentity() async throws {
        let fixture = try makeFixture()
        let next = CaptureFilterRevision(sessionGeneration: 7, revision: 4)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 9_600))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 4_800, timescale: 48_000), revision: fixture.revision))
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: next, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 9_600, timescale: 48_000), revision: fixture.revision))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 14_400, timescale: 48_000), revision: next))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(outcome.capturedWindow, nil)
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 14_400, timescale: 48_000)))
    }

    func testUnavailableSourceClosesThenMatchingFrameRecovers() async throws {
        let fixture = try makeFixture()
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 9_600))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 4_800, timescale: 48_000), revision: fixture.revision))
        fixture.coordinator.markScreenSourceUnavailable()
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 9_600, timescale: 48_000), revision: fixture.revision))

        _ = try await fixture.coordinator.finish()

        XCTAssertTrue(events.kinds.contains(.sourceStalled))
        XCTAssertTrue(events.kinds.contains(.sourceRecovered))
    }

    func testDroppedRecoveryFrameDoesNotEmitSourceRecovered() async throws {
        let state = ManualExecutor()
        let eventExecutor = ManualExecutor()
        let fixture = try makeFixture(executor: state, eventExecutor: eventExecutor)
        let events = EventCollector()
        fixture.coordinator.setVideoEventHandler { events.append($0) }
        fixture.coordinator.setScreenCaptureRequested(
            true,
            expectedRevision: fixture.revision,
            window: nil
        )
        state.runAll()
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 9_600))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 4_800, timescale: 48_000),
            revision: fixture.revision
        ))
        state.runAll()
        fixture.coordinator.markScreenSourceUnavailable()
        state.runAll()

        fixture.mux.videoErrors = [MuxedMediaWriterError.videoAppendDropped]
        fixture.coordinator.enqueueVideo(try videoFrame(
            time: CMTime(value: 14_400, timescale: 48_000),
            revision: fixture.revision
        ))
        state.runAll()
        _ = try await finish(fixture.coordinator, using: state)
        eventExecutor.runAll()

        XCTAssertTrue(events.kinds.contains(.sourceStalled))
        XCTAssertFalse(events.kinds.contains(.sourceRecovered))
    }

    func testEscapedOutputURLsAreRejectedBeforeWriterFactories() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/recording-media-coordinator-tests")
        let outputs = RecordingOutputURLs(
            folder: folder,
            partialMP4: folder.appendingPathComponent("../escaped.mp4"),
            finalMP4: folder.appendingPathComponent("recording.mp4"),
            audioBackup: folder.appendingPathComponent("recording.audio-backup.m4a"),
            recoveredM4A: folder.appendingPathComponent("recording.m4a")
        )
        XCTAssertThrowsError(try RecordingMediaCoordinator(
            outputs: outputs,
            sourceSessionID: UUID(),
            recordingEpoch: 1,
            activeFilterRevision: CaptureFilterRevision(sessionGeneration: 1, revision: 1),
            safetyWriterFactory: { _ in XCTFail("factory must not run"); return FakeSafety(closeError: nil, trace: nil) },
            muxWriterFactory: { _ in FakeMux(audioErrors: [], videoErrors: [], trace: nil) },
            fileOperations: FakeFiles(),
            blackFrameFactory: { try self.blackBuffer() }
        )) { XCTAssertEqual($0 as? RecordingMediaFinalizationError, .invalidOutputURLs) }
    }

    func testProductionNoReplacePromotionRejectsExistingAndSymlinkPaths() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording-media-posix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("recording.partial.mp4")
        let destination = folder.appendingPathComponent("recording.mp4")
        try Data([1, 2, 3]).write(to: source)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        let operations = ProductionRecordingMediaFileOperations()

        try operations.promoteNoReplace(source, to: destination)

        let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(before, after)
        try Data([4]).write(to: source)
        XCTAssertThrowsError(try operations.promoteNoReplace(source, to: destination))

        let symlinkSource = folder.appendingPathComponent("symlink-source.mp4")
        let symlinkDestination = folder.appendingPathComponent("symlink-destination.mp4")
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: destination)
        XCTAssertThrowsError(try operations.promoteNoReplace(symlinkSource, to: symlinkDestination))
        try FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: destination)
        XCTAssertThrowsError(try operations.promoteNoReplace(source, to: symlinkDestination))
    }

    func testProductionPromotionRollbackPreservesInodeAndRestoresSource() throws {
        let folder = try makePOSIXFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("recording.partial.mp4")
        let destination = folder.appendingPathComponent("recording.mp4")
        try Data([1, 2, 3]).write(to: source)
        let sourceInode = try inode(of: source)
        let operations = ProductionRecordingMediaFileOperations()
        try operations.promoteNoReplace(source, to: destination)
        XCTAssertEqual(try inode(of: destination), sourceInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try operations.rollbackOwnedPromotion(destination, to: source)
        XCTAssertEqual(try inode(of: source), sourceInode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testProductionPromotionReportsExactTypedPOSIXFailures() throws {
        let folder = try makePOSIXFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("recording.partial.mp4")
        let destination = folder.appendingPathComponent("recording.mp4")
        try Data([1]).write(to: source)
        try Data([2]).write(to: destination)
        let operations = ProductionRecordingMediaFileOperations()
        XCTAssertThrowsError(try operations.promoteNoReplace(source, to: destination)) {
            XCTAssertEqual($0 as? RecordingMediaFileError, .destinationAlreadyExists(destination))
        }

        let symlinkSource = folder.appendingPathComponent("symlink-source.mp4")
        let symlinkDestination = folder.appendingPathComponent("symlink-destination.mp4")
        try FileManager.default.createSymbolicLink(at: symlinkSource, withDestinationURL: source)
        XCTAssertThrowsError(try operations.promoteNoReplace(symlinkSource, to: symlinkDestination)) {
            XCTAssertEqual($0 as? RecordingMediaFileError, .sourceIsNotRegular(symlinkSource))
        }
        try FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: source)
        XCTAssertThrowsError(try operations.promoteNoReplace(source, to: symlinkDestination)) {
            XCTAssertEqual($0 as? RecordingMediaFileError, .destinationAlreadyExists(symlinkDestination))
        }
    }

    func testProductionPromotionRejectsDifferentParentAndInjectedEXDEV() throws {
        let folder = try makePOSIXFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("recording.partial.mp4")
        try Data([1]).write(to: source)
        let differentParent = other.appendingPathComponent("recording.mp4")
        let operations = ProductionRecordingMediaFileOperations()
        XCTAssertThrowsError(try operations.promoteNoReplace(source, to: differentParent)) {
            XCTAssertEqual($0 as? RecordingMediaFileError, .parentMismatch(source: source, destination: differentParent))
        }
        let destination = folder.appendingPathComponent("recording.mp4")
        let exdev = ProductionRecordingMediaFileOperations(exclusiveRename: { _, _ in (-1, EXDEV) })
        XCTAssertThrowsError(try exdev.promoteNoReplace(source, to: destination)) {
            XCTAssertEqual($0 as? RecordingMediaFileError, .crossDevice(source: source, destination: destination))
        }
    }

    func testPostRenameValidationRollbackLeavesPartialAndPromotesBackup() async throws {
        let fixture = try makeFixture()
        fixture.files.failFinalMP4Validation = true
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        _ = try await fixture.coordinator.finish()
        XCTAssertFalse(fixture.files.present.contains(fixture.outputs.finalMP4))
        XCTAssertTrue(fixture.files.present.contains(fixture.outputs.partialMP4))
        XCTAssertTrue(fixture.files.present.contains(fixture.outputs.recoveredM4A))
    }

    func testRollbackFailureDoesNotPromoteBackupWhileInvalidFinalExists() async throws {
        let fixture = try makeFixture()
        fixture.files.failFinalMP4Validation = true
        fixture.files.rollbackError = TestError.safety
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        do {
            _ = try await fixture.coordinator.finish()
            XCTFail("Expected aggregate finalization failure")
        } catch let error as RecordingMediaFinalizationError {
            guard case .aggregate = error else { return XCTFail("Expected aggregate") }
        }
        XCTAssertTrue(fixture.files.present.contains(fixture.outputs.finalMP4))
        XCTAssertFalse(fixture.files.present.contains(fixture.outputs.recoveredM4A))
    }

    func testMuxSetupFailureWritesSafetyThenEmitsOnceAndClosesOnce() async throws {
        let trace = Trace()
        let events = ManualExecutor()
        let fixture = try makeFixture(trace: trace, eventExecutor: events, muxSetupError: TestError.mux)
        let collector = EventCollector()
        fixture.coordinator.setVideoEventHandler { collector.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        let outcome = try await fixture.coordinator.finish()
        events.runAll()
        XCTAssertEqual(outcome.finalURL, fixture.outputs.recoveredM4A)
        XCTAssertEqual(fixture.safety.closeCalls, 1)
        XCTAssertEqual(trace.values.prefix(2), ["safety", "safety-close"])
        XCTAssertEqual(collector.events.count, 1)
        guard case .muxFailed = collector.events[0].kind else { return XCTFail("Expected mux failure") }
    }

    func testEarlyVideoDoesNotAnchorBeforeTenFrames() throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        for value in 0..<9 {
            fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: CMTimeValue(value * 1_000), timescale: 48_000), revision: fixture.revision))
            state.runAll()
        }
        XCTAssertEqual(fixture.mux.videoTimes, [.zero])
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 1)
    }

    func testTenthEarlyVideoDropsZeroRealFrameButAppendsThresholdFrame() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state, muxEnforcesVideoCadence: true)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        for value in 0..<10 {
            fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: CMTimeValue(value * 1_000), timescale: 48_000), revision: fixture.revision))
            state.runAll()
        }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 48_000))
        state.runAll()
        let outcome = try await finish(fixture.coordinator, using: state)
        XCTAssertEqual(fixture.mux.videoTimes.filter { $0 == .zero }.count, 1)
        XCTAssertEqual(fixture.mux.videoDropCount, 1)
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 9_000, timescale: 48_000)))
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 0)
        XCTAssertEqual(
            try XCTUnwrap(outcome.screenIntervals.first).startSeconds,
            Double(9_000) / 48_000,
            accuracy: 0.000_001
        )
        XCTAssertEqual(outcome.recoveryState, .none)
    }

    func testOneSecondEarlyVideoSpanEstablishesAnchor() throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 48_000, timescale: 48_000), revision: fixture.revision))
        state.runAll()
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 48_000, timescale: 48_000)))
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 0)
    }

    func testAudioAnchorReplaysHeldEarlyFrameWithoutThirdOwnedBuffer() throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 1)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 240, timescale: 48_000), revision: fixture.revision))
        state.runAll()
        XCTAssertLessThanOrEqual(fixture.coordinator.peakVideoOwnershipCount, 2)
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 0)
        XCTAssertTrue(fixture.mux.videoTimes.contains(.zero))
    }

    func testReplayReservationAllowsOnlyOneMailboxSlotUntilLocalReplayReturns() throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        state.runAll()
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()

        let first = try videoFrame(time: CMTime(value: 240, timescale: 48_000), revision: fixture.revision)
        let second = try videoFrame(time: CMTime(value: 480, timescale: 48_000), revision: fixture.revision)
        fixture.coordinator.replayInterleavingHook = {
            fixture.coordinator.enqueueVideo(first)
            fixture.coordinator.enqueueVideo(second)
            XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 2)
            XCTAssertLessThanOrEqual(fixture.coordinator.peakVideoOwnershipCount, 2)
        }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 960))
        state.runAll()

        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 0)
        XCTAssertLessThanOrEqual(fixture.coordinator.peakVideoOwnershipCount, 2)
        XCTAssertFalse(fixture.mux.videoTimes.contains(CMTime(value: 240, timescale: 48_000)))
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 480, timescale: 48_000)))
    }

    func testSynchronousStateExecutorDoesNotDeadlockAndFinishKeepsAcceptedOrder() async throws {
        let trace = Trace()
        let fixture = try makeFixture(trace: trace, synchronousExecutor: true)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 480, timescale: 48_000), revision: fixture.revision))

        let outcome = try await fixture.coordinator.finish()

        XCTAssertEqual(fixture.safety.blocks.count, 1)
        XCTAssertEqual(fixture.mux.audioBlocks.count, 1)
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 480, timescale: 48_000)))
        XCTAssertEqual(trace.values.prefix(2), ["safety", "mux-audio"])
        XCTAssertEqual(outcome.recoveryState, .none)
    }

    func testFinishReleasesHeldEarlyFrame() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        fixture.coordinator.enqueueVideo(try videoFrame(time: .zero, revision: fixture.revision))
        state.runAll()
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 1)
        _ = try await finish(fixture.coordinator, using: state)
        XCTAssertEqual(fixture.coordinator.pendingVideoOwnershipCount, 0)
    }

    func testQueuedEventIsDiscardedWhenHandlerClearsBeforeEventExecutorRuns() throws {
        let state = ManualExecutor()
        let events = ManualExecutor()
        let fixture = try makeFixture(executor: state, eventExecutor: events, muxSetupError: TestError.mux)
        let collector = EventCollector()
        fixture.coordinator.setVideoEventHandler { collector.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        state.runAll()
        fixture.coordinator.setVideoEventHandler(nil)
        events.runAll()
        XCTAssertTrue(collector.events.isEmpty)
    }

    func testKnownEventHasExactIdentityAfterManualEventDelivery() throws {
        let state = ManualExecutor()
        let events = ManualExecutor()
        let fixture = try makeFixture(executor: state, eventExecutor: events, muxSetupError: TestError.mux)
        let collector = EventCollector()
        fixture.coordinator.setVideoEventHandler { collector.append($0) }
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 480))
        state.runAll()
        events.runAll()
        XCTAssertFalse(collector.events.isEmpty)
        XCTAssertEqual(collector.events.count, 1)
        guard let event = collector.events.first else { return XCTFail("Expected one event") }
        XCTAssertEqual(event.sourceSessionID, fixture.sessionID)
        XCTAssertEqual(event.recordingEpoch, 42)
        guard case .muxFailed = event.kind else { return XCTFail("Expected mux failure") }
    }

    func testRevisionSwitchPreservesIntentAndIntervalsWithoutSecondZeroBlack() async throws {
        let state = ManualExecutor()
        let fixture = try makeFixture(executor: state)
        let next = CaptureFilterRevision(sessionGeneration: 7, revision: 4)
        fixture.coordinator.enqueueAudio(audioBlock(start: 0, frames: 24_000))
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: fixture.revision, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 4_800, timescale: 48_000), revision: fixture.revision))
        state.runAll()
        fixture.coordinator.setScreenCaptureRequested(true, expectedRevision: next, window: nil)
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 9_600, timescale: 48_000), revision: fixture.revision))
        fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: 14_400, timescale: 48_000), revision: next))
        state.runAll()
        let outcome = try await finish(fixture.coordinator, using: state)
        XCTAssertEqual(fixture.mux.videoTimes.filter { $0 == .zero }.count, 1)
        XCTAssertFalse(fixture.mux.videoTimes.contains(CMTime(value: 9_600, timescale: 48_000)))
        XCTAssertTrue(fixture.mux.videoTimes.contains(CMTime(value: 14_400, timescale: 48_000)))
        XCTAssertEqual(outcome.screenIntervals.count, 2)
    }

    func testFloodConsumesDropsBeforeDrainCompletes() throws {
        let state = ManualExecutor()
        let events = ManualExecutor()
        let fixture = try makeFixture(executor: state, eventExecutor: events)
        let collector = EventCollector()
        fixture.coordinator.setVideoEventHandler { collector.append($0) }
        for value in 0..<50 {
            fixture.coordinator.enqueueVideo(try videoFrame(time: CMTime(value: CMTimeValue(value), timescale: 48_000)))
        }
        state.runAll()
        events.runAll()
        XCTAssertEqual(fixture.coordinator.peakActiveVideoDrainCount, 1)
        XCTAssertEqual(fixture.coordinator.activeVideoDrainCount, 0)
        XCTAssertGreaterThan(fixture.mux.videoTimes.count, 0)
        XCTAssertFalse(collector.events.isEmpty)
        XCTAssertTrue(collector.events.contains { if case .droppedFrames = $0.kind { return true }; return false })
    }

    private func makeFixture(
        audioErrors: [Error] = [],
        videoErrors: [Error] = [],
        criticalVideoErrors: [Error] = [],
        safetyCloseError: Error? = nil,
        trace: Trace? = nil,
        executor: ManualExecutor? = nil,
        synchronousExecutor: Bool = false,
        eventExecutor: ManualExecutor? = nil,
        muxPendingAudio: Bool = false,
        muxEnforcesVideoCadence: Bool = false,
        muxSetupError: Error? = nil
    ) throws -> Fixture {
        let folder = URL(fileURLWithPath: "/private/tmp/recording-media-coordinator-tests")
        let outputs = RecordingOutputURLs(folder: folder)
        let revision = CaptureFilterRevision(sessionGeneration: 7, revision: 3)
        let safety = FakeSafety(closeError: safetyCloseError, trace: trace)
        let mux = FakeMux(
            audioErrors: audioErrors,
            videoErrors: videoErrors,
            criticalVideoErrors: criticalVideoErrors,
            trace: trace,
            holdsAudioUntilFinish: muxPendingAudio,
            enforcesVideoCadence: muxEnforcesVideoCadence
        )
        let files = FakeFiles(present: [outputs.partialMP4, outputs.audioBackup])
        let sessionID = UUID()
        let coordinator = try RecordingMediaCoordinator(
            outputs: outputs,
            sourceSessionID: sessionID,
            recordingEpoch: 42,
            activeFilterRevision: revision,
            safetyWriterFactory: { _ in safety },
            muxWriterFactory: { _ in if let muxSetupError { throw muxSetupError }; return mux },
            fileOperations: files,
            blackFrameFactory: { try self.blackBuffer() },
            stateEnqueue: synchronousExecutor ? { work in work() } : executor.map { executor in { work in executor.enqueue(work) } },
            eventEnqueue: eventExecutor.map { executor in { work in executor.enqueue(work) } }
        )
        return Fixture(coordinator: coordinator, outputs: outputs, revision: revision, sessionID: sessionID, safety: safety, mux: mux, files: files)
    }

    private func audioBlock(start: Int64, frames: Int) -> MixedAudioBlock {
        MixedAudioBlock(startFrame: start, left: Array(repeating: 0.1, count: frames), right: Array(repeating: 0.1, count: frames))
    }

    private func videoFrame(
        time: CMTime,
        revision: CaptureFilterRevision = CaptureFilterRevision(sessionGeneration: 7, revision: 3),
        status: SCFrameStatus = .complete
    ) throws -> ScreenVideoFrame {
        ScreenVideoFrame(pixelBuffer: try blackBuffer(), sourcePTS: time, status: status, filterRevision: revision)
    }

    private func blackBuffer() throws -> CVPixelBuffer {
        try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
    }

    private func makePOSIXFolder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recording-media-posix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func inode(of url: URL) throws -> NSNumber {
        guard let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber else {
            throw TestError.invalidMedia
        }
        return inode
    }

    private func finish(
        _ coordinator: RecordingMediaCoordinator,
        using executor: ManualExecutor
    ) async throws -> RecordingMediaOutcome {
        let completion = FinishCompletion()
        Task.detached {
            do { completion.complete(.success(try await coordinator.finish())) }
            catch { completion.complete(.failure(error)) }
        }
        while completion.result == nil {
            executor.runAll()
            await Task.yield()
        }
        return try completion.result!.get()
    }

}

private struct Fixture {
    let coordinator: RecordingMediaCoordinator
    let outputs: RecordingOutputURLs
    let revision: CaptureFilterRevision
    let sessionID: UUID
    let safety: FakeSafety
    let mux: FakeMux
    let files: FakeFiles
}

private struct Promotion: Equatable {
    let source: URL
    let destination: URL
    init(_ source: URL, _ destination: URL) {
        self.source = source
        self.destination = destination
    }
}

private enum TestError: Error { case mux, second, safety, destinationAlreadyExists, crossDevice, symlink, invalidMedia }

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
}

private final class FakeSafety: MixedAudioWriting {
    var blocks: [MixedAudioBlock] = []
    let closeError: Error?
    let trace: Trace?
    private(set) var closeCalls = 0
    init(closeError: Error?, trace: Trace?) { self.closeError = closeError; self.trace = trace }
    func write(_ block: MixedAudioBlock) throws { blocks.append(block); trace?.append("safety") }
    func close() throws {
        closeCalls += 1
        trace?.append("safety-close")
        if let closeError { throw closeError }
    }
}

private final class FakeMux: MuxedMediaWriting {
    var audioBlocks: [TimedMixedAudioBlock] = []
    var pendingAudio: [TimedMixedAudioBlock] = []
    var audioAppendAttempts = 0
    var videoTimes: [CMTime] = []
    var audioErrors: [Error]
    var videoErrors: [Error]
    var criticalVideoErrors: [Error]
    var finishCalls = 0
    private(set) var videoDropCount = 0
    private(set) var criticalVideoAppendAttempts = 0
    let trace: Trace?
    let holdsAudioUntilFinish: Bool
    let enforcesVideoCadence: Bool
    private var lastAcceptedVideoTime: CMTime?
    init(
        audioErrors: [Error],
        videoErrors: [Error],
        criticalVideoErrors: [Error] = [],
        trace: Trace?,
        holdsAudioUntilFinish: Bool = false,
        enforcesVideoCadence: Bool = false
    ) {
        self.audioErrors = audioErrors
        self.videoErrors = videoErrors
        self.criticalVideoErrors = criticalVideoErrors
        self.trace = trace
        self.holdsAudioUntilFinish = holdsAudioUntilFinish
        self.enforcesVideoCadence = enforcesVideoCadence
    }
    func appendAudio(_ block: TimedMixedAudioBlock) throws {
        audioAppendAttempts += 1
        if !audioErrors.isEmpty { throw audioErrors.removeFirst() }
        if holdsAudioUntilFinish {
            pendingAudio.append(block)
        } else {
            audioBlocks.append(block)
        }
        trace?.append("mux-audio")
    }
    func appendVideo(_: CVPixelBuffer, at time: CMTime) throws {
        if !videoErrors.isEmpty { throw videoErrors.removeFirst() }
        if enforcesVideoCadence,
           let previous = lastAcceptedVideoTime,
           CMTimeCompare(CMTimeSubtract(time, previous), CMTime(value: 4_800, timescale: 48_000)) < 0 {
            videoDropCount += 1
            throw MuxedMediaWriterError.videoAppendDropped
        }
        videoTimes.append(time)
        lastAcceptedVideoTime = time
    }
    func appendCriticalVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) throws {
        criticalVideoAppendAttempts += 1
        if !criticalVideoErrors.isEmpty {
            let error = criticalVideoErrors.removeFirst()
            if error as? MuxedMediaWriterError == .videoAppendDropped {
                throw MuxedMediaWriterError.criticalVideoAppendFailed
            }
            throw error
        }
        try appendVideo(pixelBuffer, at: time)
    }
    func finish(at _: CMTime) async throws {
        finishCalls += 1
        audioBlocks.append(contentsOf: pendingAudio)
        pendingAudio.removeAll()
    }
}

private final class FakeFiles: RecordingMediaFileOperating {
    var promotions: [Promotion] = []
    var removed: [URL] = []
    var mp4PromotionError: Error?
    var failFinalMP4Validation = false
    var rollbackError: Error?
    private(set) var present: Set<URL>
    init(present: Set<URL> = []) { self.present = present }
    func promoteNoReplace(_ source: URL, to destination: URL) throws {
        if destination.pathExtension == "mp4", let mp4PromotionError { throw mp4PromotionError }
        guard present.contains(source) else { throw TestError.invalidMedia }
        guard !present.contains(destination) else { throw TestError.destinationAlreadyExists }
        promotions.append(Promotion(source, destination))
        present.remove(source)
        present.insert(destination)
    }
    func remove(_ url: URL) throws { removed.append(url); present.remove(url) }
    func rollbackOwnedPromotion(_ destination: URL, to source: URL) throws {
        if let rollbackError { throw rollbackError }
        guard present.contains(destination), !present.contains(source) else { throw TestError.invalidMedia }
        promotions.append(Promotion(destination, source))
        present.remove(destination)
        present.insert(source)
    }
    func validateMP4(_ url: URL) async throws {
        if failFinalMP4Validation, url.lastPathComponent == "recording.mp4" { throw TestError.invalidMedia }
    }
    func validateM4A(_: URL) throws {}
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [RecordingVideoEvent] = []
    var kinds: [RecordingVideoEventKind] { lock.lock(); defer { lock.unlock() }; return events.map(\.kind) }
    func append(_ event: RecordingVideoEvent) { lock.lock(); events.append(event); lock.unlock() }
}

private final class ManualExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []
    private var active = 0
    private var maximumActive = 0
    var queuedCount: Int { lock.lock(); defer { lock.unlock() }; return jobs.count }
    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }
    var peakActiveCount: Int { lock.lock(); defer { lock.unlock() }; return maximumActive }
    func enqueue(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }
    func runAll() {
        while true {
            lock.lock()
            guard !jobs.isEmpty else { lock.unlock(); return }
            let job = jobs.removeFirst()
            active += 1
            maximumActive = max(maximumActive, active)
            lock.unlock()
            job()
            lock.lock()
            active -= 1
            lock.unlock()
        }
    }
}

private final class FinishCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<RecordingMediaOutcome, Error>?
    var result: Result<RecordingMediaOutcome, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func complete(_ value: Result<RecordingMediaOutcome, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
