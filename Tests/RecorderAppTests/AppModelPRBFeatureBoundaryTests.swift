@preconcurrency import AVFoundation
import XCTest
@testable import RecorderApp

/// Contract tests for Task 5's aggregate boundary injection.  These tests are
/// intentionally written before `PRBFeatureBoundaries` and the corresponding
/// `AppModel(featureBoundaries:)` composition API exist.
@MainActor
final class AppModelPRBFeatureBoundaryTests: XCTestCase {
    func testShutdownIsIdempotentAndCapturedBridgeCallbackCannotMutateFeaturesAfterward() throws {
        let repository = makeProviderRepository()
        let baseline = AppModel(
            providerRepository: repository,
            performStartupWork: false
        )
        let playbackCoordinator = ShutdownPlaybackCoordinator()
        let playback = PlaybackFeatureModel(coordinator: playbackCoordinator)
        let boundaries = PRBFeatureBoundaries(
            library: baseline.libraryFeature,
            transcription: baseline.transcriptionFeature,
            meetingIntelligence: baseline.meetingIntelligenceFeature,
            playback: playback
        )
        let model = AppModel(
            providerRepository: repository,
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
        let repository = makeProviderRepository()
        let supplied = defaultFeatureBoundaries(repository: repository)

        let model = AppModel(
            providerRepository: repository,
            performStartupWork: false,
            featureBoundaries: supplied
        )

        XCTAssertTrue(model.libraryFeature === supplied.library)
        XCTAssertTrue(model.transcriptionFeature === supplied.transcription)
        XCTAssertTrue(model.meetingIntelligenceFeature === supplied.meetingIntelligence)
        XCTAssertTrue(model.playbackFeature === supplied.playback)
    }

    func testAggregateInjectionDoesNotInvokeFallbackBoundaryFactory() {
        let repository = makeProviderRepository()
        let supplied = defaultFeatureBoundaries(repository: repository)
        var fallbackInvocations = 0

        let model = AppModel(
            providerRepository: repository,
            performStartupWork: false,
            featureBoundaries: supplied,
            defaultFeatureBoundariesFactory: {
                fallbackInvocations += 1
                return self.defaultFeatureBoundaries(repository: repository)
            }
        )

        XCTAssertEqual(fallbackInvocations, 0)
        XCTAssertTrue(model.libraryFeature === supplied.library)
        XCTAssertTrue(model.transcriptionFeature === supplied.transcription)
        XCTAssertTrue(model.meetingIntelligenceFeature === supplied.meetingIntelligence)
        XCTAssertTrue(model.playbackFeature === supplied.playback)
    }

    func testInjectedAggregateRequiresMeetingIntelligenceToMatchTranscriptionSource() {
        let supplied = defaultFeatureBoundaries(repository: makeProviderRepository())

        XCTAssertTrue(supplied.hasCompatiblePublicationSources)
        XCTAssertEqual(
            supplied.meetingIntelligence.expectedTranscriptionPublicationSourceID,
            supplied.transcription.publicationSourceID
        )

        let independentlyConstructed = defaultFeatureBoundaries(repository: makeProviderRepository())
        let mismatched = PRBFeatureBoundaries(
            library: supplied.library,
            transcription: supplied.transcription,
            meetingIntelligence: independentlyConstructed.meetingIntelligence,
            playback: supplied.playback
        )
        XCTAssertFalse(mismatched.hasCompatiblePublicationSources)
    }

    func testAggregateCompatibilityRejectsFeatureBoundariesWithDifferentMutationGates() {
        let libraryBoundary = defaultFeatureBoundaries(repository: makeProviderRepository())
        let asrAndMeetingIntelligenceBoundary = defaultFeatureBoundaries(repository: makeProviderRepository())

        let mismatched = PRBFeatureBoundaries(
            library: libraryBoundary.library,
            transcription: asrAndMeetingIntelligenceBoundary.transcription,
            meetingIntelligence:
                asrAndMeetingIntelligenceBoundary.meetingIntelligence,
            playback: libraryBoundary.playback
        )

        XCTAssertTrue(mismatched.hasCompatiblePublicationSources)
        XCTAssertFalse(mismatched.hasCompatibleMutationGates)
        XCTAssertFalse(mismatched.isCompatible)
    }

    func testDefaultBoundaryConstructionBuildsOneConsistentFeatureSet() {
        let repository = makeProviderRepository()
        let model = AppModel(providerRepository: repository, performStartupWork: false)
        defer { model.shutdown() }

        let boundaries = PRBFeatureBoundaries(
            library: model.libraryFeature,
            transcription: model.transcriptionFeature,
            meetingIntelligence: model.meetingIntelligenceFeature,
            playback: model.playbackFeature
        )

        // PR B has one shared mutation gate for Library, ASR, and MI.  The
        // AppModel compatibility bridge must retain the Library gate rather
        // than constructing a parallel mutable artifact path.
        XCTAssertTrue(model.libraryFeature.mutationGate === model.transcriptMutationGate)
        XCTAssertTrue(boundaries.hasCompatibleMutationGates)
        XCTAssertTrue(boundaries.isCompatible)

        // Meeting intelligence must only accept publications from the single
        // retained transcription boundary, never from an independently made
        // default coordinator.
        XCTAssertEqual(
            model.meetingIntelligenceFeature.expectedTranscriptionPublicationSourceID,
            model.transcriptionFeature.publicationSourceID
        )
        XCTAssertTrue(boundaries.isCompatible(with: repository.compositionIdentity))
        XCTAssertEqual(
            model.aiProviderSettingsModel.providerRepositoryIdentity,
            repository.compositionIdentity
        )
    }

    func testCompatibilityRejectsSplitProviderRepositoriesEvenWhenOtherIdentitiesAreInspected() {
        let transcriptionRepository = makeProviderRepository()
        let meetingIntelligenceRepository = makeProviderRepository()
        let transcriptionBoundary = defaultFeatureBoundaries(
            repository: transcriptionRepository
        )
        let meetingIntelligenceBoundary = defaultFeatureBoundaries(
            repository: meetingIntelligenceRepository
        )
        let mismatched = PRBFeatureBoundaries(
            library: transcriptionBoundary.library,
            transcription: transcriptionBoundary.transcription,
            meetingIntelligence: meetingIntelligenceBoundary.meetingIntelligence,
            playback: transcriptionBoundary.playback
        )

        XCTAssertFalse(mismatched.hasCompatibleProviderRepositories)
        XCTAssertFalse(mismatched.isCompatible(with: transcriptionRepository.compositionIdentity))
    }

    func testCompatibilityRejectsSplitSettingsRepositoryAndSharedPredicateCatchesEveryBoundaryGraph() {
        let repository = makeProviderRepository()
        let settingsRepository = makeProviderRepository()
        let compatible = defaultFeatureBoundaries(repository: repository)
        let splitGateBoundary = defaultFeatureBoundaries(repository: repository)
        let splitGate = PRBFeatureBoundaries(
            library: splitGateBoundary.library,
            transcription: compatible.transcription,
            meetingIntelligence: compatible.meetingIntelligence,
            playback: compatible.playback
        )

        XCTAssertTrue(compatible.hasCompatibleProviderRepositories)
        XCTAssertTrue(compatible.isCompatible(with: repository.compositionIdentity))
        XCTAssertFalse(compatible.isCompatible(with: settingsRepository.compositionIdentity))
        XCTAssertFalse(splitGate.isCompatible(with: repository.compositionIdentity))
    }

    private func defaultFeatureBoundaries(
        repository: any OpenAICompatibleProviderManaging
    ) -> PRBFeatureBoundaries {
        // Build a real baseline set rather than mocks.  The aggregate under
        // test must preserve these exact objects when it is injected.
        let baseline = AppModel(
            providerRepository: repository,
            performStartupWork: false
        )
        return .init(
            library: baseline.libraryFeature,
            transcription: baseline.transcriptionFeature,
            meetingIntelligence: baseline.meetingIntelligenceFeature,
            playback: baseline.playbackFeature
        )
    }

    private func makeProviderRepository() -> RecordingProviderRepository {
        let profile = try! OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "asr",
            llmModel: "llm",
            language: "en",
            prompt: ""
        )
        return RecordingProviderRepository(profile: profile)
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
