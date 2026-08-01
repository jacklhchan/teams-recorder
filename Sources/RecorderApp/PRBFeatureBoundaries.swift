import Foundation

/// The PR B compatibility aggregate.  Until PR C moves construction to
/// `AppCoordinator`, `AppModel` retains exactly this one set of feature
/// boundaries without copying their mutable state.
@MainActor
struct PRBFeatureBoundaries {
    let library: LibraryFeatureModel
    let transcription: TranscriptionFeatureModel
    let meetingIntelligence: MeetingIntelligenceFeatureModel
    let playback: PlaybackFeatureModel

    init(
        library: LibraryFeatureModel,
        transcription: TranscriptionFeatureModel,
        meetingIntelligence: MeetingIntelligenceFeatureModel,
        playback: PlaybackFeatureModel
    ) {
        self.library = library
        self.transcription = transcription
        self.meetingIntelligence = meetingIntelligence
        self.playback = playback
    }

    var hasCompatiblePublicationSources: Bool {
        Self.arePublicationSourcesCompatible(
            transcriptionSourceID: transcription.publicationSourceID,
            meetingIntelligenceExpectedSourceID:
                meetingIntelligence.expectedTranscriptionPublicationSourceID
        )
    }

    static func arePublicationSourcesCompatible(
        transcriptionSourceID: UUID,
        meetingIntelligenceExpectedSourceID: UUID
    ) -> Bool {
        transcriptionSourceID == meetingIntelligenceExpectedSourceID
    }
}

/// An internal test seam for validating that aggregate injection suppresses
/// fallback construction.  Production callers rely on the normal default
/// construction path; the factory is deliberately zero-argument so it cannot
/// become another state or dependency ownership surface.
typealias PRBFeatureBoundariesFactory = @MainActor () -> PRBFeatureBoundaries
