@preconcurrency import AVFoundation
import XCTest
@testable import RecorderApp

/// Contract tests for Task 5's aggregate boundary injection.  These tests are
/// intentionally written before `PRBFeatureBoundaries` and the corresponding
/// `AppModel(featureBoundaries:)` composition API exist.
@MainActor
final class AppModelPRBFeatureBoundaryTests: XCTestCase {
    func testShutdownIsIdempotentAndCapturedBridgeCallbackCannotMutateFeaturesAfterward() throws {
        let baseline = AppModel(performStartupWork: false)
        let playbackCoordinator = ShutdownPlaybackCoordinator()
        let playback = PlaybackFeatureModel(coordinator: playbackCoordinator)
        let boundaries = PRBFeatureBoundaries(
            library: baseline.libraryFeature,
            transcription: baseline.transcriptionFeature,
            meetingIntelligence: baseline.meetingIntelligenceFeature,
            playback: playback
        )
        let model = AppModel(
            performStartupWork: false,
            featureBoundaries: boundaries
        )
        let capturedCallback = try XCTUnwrap(
            model.libraryFeature.onSessionsLoaded,
            "The production bridge must register the Library load callback."
        )
        let lateSessionID = FileManager.default.temporaryDirectory
            .appendingPathComponent("shutdown-late-session", isDirectory: true)
        let lateStates: [RecordingSession.ID: TranscriptionState] = [
            lateSessionID: .init(
                phase: .completed,
                message: "Must not cross teardown",
                startedAt: .distantPast,
                finishedAt: .distantPast
            )
        ]
        let librarySnapshot = model.libraryFeature.snapshot
        let meetingSnapshot = model.meetingIntelligenceFeature.snapshot
        playbackCoordinator.onStop = {
            capturedCallback(.init(
                sessions: [],
                transcriptionStates: lateStates
            ))
        }

        model.shutdown()
        model.shutdown()

        XCTAssertEqual(playbackCoordinator.stopCount, 1)
        XCTAssertNil(model.transcriptionFeature.onSuccessfulPublication)
        XCTAssertNil(model.libraryFeature.onSessionsLoaded)
        XCTAssertNil(model.libraryFeature.onTranscriptPublicationCommitted)
        XCTAssertNil(model.libraryFeature.onTranscriptEdited)
        XCTAssertNil(model.libraryFeature.onMetadataSaved)
        XCTAssertNil(model.libraryFeature.onImportedAudioReady)
        XCTAssertNil(model.libraryFeature.onSessionRemoved)
        XCTAssertNil(model.meetingIntelligenceFeature.onPublished)
        XCTAssertNil(model.aiProviderSettingsModel.onProviderSettingsSaved)
        XCTAssertNil(
            model.transcriptionFeature.presentation
                .transcriptionStatesBySessionID[lateSessionID]
        )
        XCTAssertEqual(model.libraryFeature.snapshot, librarySnapshot)
        XCTAssertEqual(model.meetingIntelligenceFeature.snapshot, meetingSnapshot)
    }

    func testAggregateInjectionRetainsExactlyTheFourProvidedFeatureInstances() {
        let supplied = defaultFeatureBoundaries()

        let model = AppModel(
            performStartupWork: false,
            featureBoundaries: supplied
        )

        XCTAssertTrue(model.libraryFeature === supplied.library)
        XCTAssertTrue(model.transcriptionFeature === supplied.transcription)
        XCTAssertTrue(model.meetingIntelligenceFeature === supplied.meetingIntelligence)
        XCTAssertTrue(model.playbackFeature === supplied.playback)
    }

    func testAggregateInjectionDoesNotInvokeFallbackBoundaryFactory() {
        let supplied = defaultFeatureBoundaries()
        var fallbackInvocations = 0

        let model = AppModel(
            performStartupWork: false,
            featureBoundaries: supplied,
            defaultFeatureBoundariesFactory: {
                fallbackInvocations += 1
                return self.defaultFeatureBoundaries()
            }
        )

        XCTAssertEqual(fallbackInvocations, 0)
        XCTAssertTrue(model.libraryFeature === supplied.library)
        XCTAssertTrue(model.transcriptionFeature === supplied.transcription)
        XCTAssertTrue(model.meetingIntelligenceFeature === supplied.meetingIntelligence)
        XCTAssertTrue(model.playbackFeature === supplied.playback)
    }

    func testInjectedAggregateRequiresMeetingIntelligenceToMatchTranscriptionSource() {
        let supplied = defaultFeatureBoundaries()

        XCTAssertTrue(supplied.hasCompatiblePublicationSources)
        XCTAssertEqual(
            supplied.meetingIntelligence.expectedTranscriptionPublicationSourceID,
            supplied.transcription.publicationSourceID
        )

        let independentlyConstructed = defaultFeatureBoundaries()
        let mismatched = PRBFeatureBoundaries(
            library: supplied.library,
            transcription: supplied.transcription,
            meetingIntelligence: independentlyConstructed.meetingIntelligence,
            playback: supplied.playback
        )
        XCTAssertFalse(mismatched.hasCompatiblePublicationSources)
    }

    func testDefaultBoundaryConstructionBuildsOneConsistentFeatureSet() {
        let model = AppModel(performStartupWork: false)
        defer { model.shutdown() }

        // PR B has one shared mutation gate for Library, ASR, and MI.  The
        // AppModel compatibility bridge must retain the Library gate rather
        // than constructing a parallel mutable artifact path.
        XCTAssertTrue(model.libraryFeature.mutationGate === model.transcriptMutationGate)

        // Meeting intelligence must only accept publications from the single
        // retained transcription boundary, never from an independently made
        // default coordinator.
        XCTAssertEqual(
            model.meetingIntelligenceFeature.expectedTranscriptionPublicationSourceID,
            model.transcriptionFeature.publicationSourceID
        )
    }

    private func defaultFeatureBoundaries() -> PRBFeatureBoundaries {
        // Build a real baseline set rather than mocks.  The aggregate under
        // test must preserve these exact objects when it is injected.
        let baseline = AppModel(performStartupWork: false)
        return .init(
            library: baseline.libraryFeature,
            transcription: baseline.transcriptionFeature,
            meetingIntelligence: baseline.meetingIntelligenceFeature,
            playback: baseline.playbackFeature
        )
    }

}

@MainActor
private final class ShutdownPlaybackCoordinator: PlaybackCoordinating {
    let player = AVPlayer()
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onStop: (() -> Void)?
    private(set) var stopCount = 0

    func load(_: RecordingSession) async throws {}
    func play() {}
    func pause() {}
    func seek(to _: TimeInterval) async {}
    func stop() {
        stopCount += 1
        onStop?()
    }
}
