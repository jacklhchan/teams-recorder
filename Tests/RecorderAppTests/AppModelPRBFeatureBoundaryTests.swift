@preconcurrency import AVFoundation
import XCTest
@testable import RecorderApp

/// Contract tests for Task 5's aggregate boundary injection.  These tests are
/// intentionally written before `PRBFeatureBoundaries` and the corresponding
/// `AppModel(featureBoundaries:)` composition API exist.
@MainActor
final class AppModelPRBFeatureBoundaryTests: XCTestCase {
    func testDefaultBoundaryFactoryReceivesExactPrivacyPolicyAndBlocksInjectedFeatures() throws {
        let suiteName = "AppModelPRBFeatureBoundaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let policy = PrivacyModePolicy(defaults: defaults)
        policy.setEnabled(true)
        let repository = makeProviderRepository()
        let gate = RecordingSessionMutationGate()
        let service = BoundaryTranscriptionService()
        let generator = BoundaryMeetingIntelligenceGenerator()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let session = RecordingSession(
            id: root,
            folderURL: root,
            recordingURL: root.appendingPathComponent("recording.m4a"),
            createdAt: .distantPast,
            duration: 1,
            fileSize: 1,
            metadata: .init()
        )
        try Data().write(to: session.recordingURL)
        try "transcript".write(
            to: TranscriptDocumentStore.editableURL(in: root),
            atomically: true,
            encoding: .utf8
        )
        var capturedAdmissionIdentity: ObjectIdentifier?

        let model = AppModel(
            defaults: defaults,
            privacyModePolicy: policy,
            providerRepository: repository,
            performStartupWork: false,
            defaultFeatureBoundariesFactory: { admission in
                capturedAdmissionIdentity = ObjectIdentifier(admission as AnyObject)
                let transcription = TranscriptionFeatureModel(
                    coordinator: .init(
                        providerRepository: repository,
                        audioPreparer: BoundaryAudioPreparer(),
                        service: service,
                        mutationGate: gate
                    ),
                    thirdPartyProcessingAdmission: admission
                )
                let artifacts = MeetingIntelligenceArtifactStore(mutationGate: gate)
                let meeting = MeetingIntelligenceFeatureModel(coordinator: .init(
                    providerRepository: repository,
                    expectedPublicationSourceID: transcription.publicationSourceID,
                    mutationGate: gate,
                    availabilityChecker: BoundaryMeetingIntelligenceAvailability(),
                    generator: generator,
                    publisher: MeetingIntelligencePublisher(
                        mutationGate: gate,
                        artifactStore: artifacts
                    ),
                    artifactStore: artifacts,
                    stateStore: MeetingIntelligenceStateStore(mutationGate: gate),
                    thirdPartyProcessingAdmission: admission
                ))
                return PRBFeatureBoundaries(
                    library: LibraryFeatureModel(
                        sessionLoader: { _ in [] },
                        sessionReloader: { $0 },
                        searchDocumentLoader: { _ in .empty },
                        recovery: { _ in },
                        trashHandler: { _ in false },
                        mutationGate: gate
                    ),
                    transcription: transcription,
                    meetingIntelligence: meeting,
                    playback: PlaybackFeatureModel(coordinator: ShutdownPlaybackCoordinator())
                )
            }
        )
        defer { model.shutdown() }

        model.transcriptionFeature.start(session: session, providerIsConfigured: true)
        model.meetingIntelligenceFeature.generate(for: session)

        XCTAssertEqual(capturedAdmissionIdentity, ObjectIdentifier(policy))
        XCTAssertEqual(service.requests, 0)
        XCTAssertEqual(generator.requests, 0)
    }
    func testShutdownIsIdempotentAndCapturedBridgeCallbackCannotMutateFeaturesAfterward() throws {
        let repository = makeProviderRepository()
        let policy = makePrivacyModePolicy()
        let baseline = AppModel(
            privacyModePolicy: policy,
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
            privacyModePolicy: policy,
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
        let policy = makePrivacyModePolicy()
        let supplied = defaultFeatureBoundaries(repository: repository, privacyModePolicy: policy)

        let model = AppModel(
            privacyModePolicy: policy,
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
        let policy = makePrivacyModePolicy()
        let supplied = defaultFeatureBoundaries(repository: repository, privacyModePolicy: policy)
        var fallbackInvocations = 0

        let model = AppModel(
            privacyModePolicy: policy,
            providerRepository: repository,
            performStartupWork: false,
            featureBoundaries: supplied,
            defaultFeatureBoundariesFactory: { admission in
                fallbackInvocations += 1
                XCTAssertEqual(ObjectIdentifier(admission as AnyObject), ObjectIdentifier(policy))
                return self.defaultFeatureBoundaries(
                    repository: repository,
                    privacyModePolicy: policy
                )
            }
        )

        XCTAssertEqual(fallbackInvocations, 0)
        XCTAssertTrue(model.libraryFeature === supplied.library)
        XCTAssertTrue(model.transcriptionFeature === supplied.transcription)
        XCTAssertTrue(model.meetingIntelligenceFeature === supplied.meetingIntelligence)
        XCTAssertTrue(model.playbackFeature === supplied.playback)
    }

    func testInjectedAggregateRequiresMeetingIntelligenceToMatchTranscriptionSource() {
        let policy = makePrivacyModePolicy()
        let supplied = defaultFeatureBoundaries(
            repository: makeProviderRepository(),
            privacyModePolicy: policy
        )

        XCTAssertTrue(supplied.hasCompatiblePublicationSources)
        XCTAssertEqual(
            supplied.meetingIntelligence.expectedTranscriptionPublicationSourceID,
            supplied.transcription.publicationSourceID
        )

        let independentlyConstructed = defaultFeatureBoundaries(
            repository: makeProviderRepository(),
            privacyModePolicy: policy
        )
        let mismatched = PRBFeatureBoundaries(
            library: supplied.library,
            transcription: supplied.transcription,
            meetingIntelligence: independentlyConstructed.meetingIntelligence,
            playback: supplied.playback
        )
        XCTAssertFalse(mismatched.hasCompatiblePublicationSources)
    }

    func testAggregateCompatibilityRejectsFeatureBoundariesWithDifferentMutationGates() {
        let policy = makePrivacyModePolicy()
        let libraryBoundary = defaultFeatureBoundaries(
            repository: makeProviderRepository(),
            privacyModePolicy: policy
        )
        let asrAndMeetingIntelligenceBoundary = defaultFeatureBoundaries(
            repository: makeProviderRepository(),
            privacyModePolicy: policy
        )

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
        let policy = makePrivacyModePolicy()
        let transcriptionBoundary = defaultFeatureBoundaries(
            repository: transcriptionRepository,
            privacyModePolicy: policy
        )
        let meetingIntelligenceBoundary = defaultFeatureBoundaries(
            repository: meetingIntelligenceRepository,
            privacyModePolicy: policy
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
        let policy = makePrivacyModePolicy()
        let compatible = defaultFeatureBoundaries(
            repository: repository,
            privacyModePolicy: policy
        )
        let splitGateBoundary = defaultFeatureBoundaries(
            repository: repository,
            privacyModePolicy: policy
        )
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
        repository: any OpenAICompatibleProviderManaging,
        privacyModePolicy: PrivacyModePolicy
    ) -> PRBFeatureBoundaries {
        // Build a real baseline set rather than mocks.  The aggregate under
        // test must preserve these exact objects when it is injected.
        let baseline = AppModel(
            privacyModePolicy: privacyModePolicy,
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

    private func makePrivacyModePolicy() -> PrivacyModePolicy {
        PrivacyModePolicy(
            defaults: UserDefaults(
                suiteName: "AppModelPRBFeatureBoundaryTests.Policy.\(UUID().uuidString)"
            )!
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

private struct BoundaryAudioPreparer: TranscriptionAudioPreparing {
    func prepare(for session: RecordingSession) async throws -> PreparedTranscriptionAudio {
        .init(audioURL: session.recordingURL, cleanupURL: nil)
    }
    func cleanup(_: PreparedTranscriptionAudio) {}
}

private final class BoundaryTranscriptionService: TranscriptionServicing, @unchecked Sendable {
    private(set) var requests = 0
    func transcribe(
        _: TranscriptionServiceRequest,
        onProgress _: @escaping @Sendable (TranscriptionServiceProgress) -> Void
    ) async throws -> TranscriptionServiceResult {
        requests += 1
        throw CancellationError()
    }
}

private final class BoundaryMeetingIntelligenceGenerator: MeetingIntelligenceGenerating, @unchecked Sendable {
    private(set) var requests = 0
    func generate(
        transcript _: TranscriptDocumentSnapshot,
        snapshot _: OpenAICompatibleProviderSnapshot,
        onProgress _: @escaping @Sendable (MeetingIntelligenceProgress) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent {
        requests += 1
        return .init(title: "Title", summary: "Summary")
    }
}

private struct BoundaryMeetingIntelligenceAvailability: MeetingIntelligenceAvailabilityChecking {
    func availability(for _: OpenAICompatibleProviderSnapshot) async -> MeetingIntelligenceAvailability {
        .confirmed
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
