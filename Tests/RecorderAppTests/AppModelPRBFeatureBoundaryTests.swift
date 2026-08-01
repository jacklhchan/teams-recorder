import XCTest
@testable import RecorderApp

/// Contract tests for Task 5's aggregate boundary injection.  These tests are
/// intentionally written before `PRBFeatureBoundaries` and the corresponding
/// `AppModel(featureBoundaries:)` composition API exist.
@MainActor
final class AppModelPRBFeatureBoundaryTests: XCTestCase {
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
