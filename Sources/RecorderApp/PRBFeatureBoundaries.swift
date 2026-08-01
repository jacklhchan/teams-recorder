import Foundation

/// The PR B compatibility aggregate. Until the next composition phase moves
/// construction out of `AppModel`, it retains exactly this one set of feature
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

    /// All durable per-session mutations must serialize through the same gate.
    /// This is separate from the ASR publication-source check: a correctly
    /// wired event stream with split gates can still race transcript, metadata
    /// and meeting-intelligence artifact writes.
    var hasCompatibleMutationGates: Bool {
        library.mutationGate === transcription.mutationGate
            && library.mutationGate === meetingIntelligence.mutationGate
    }

    /// Settings is intentionally outside this four-feature aggregate, but
    /// ASR and meeting intelligence must still retain the same mutable
    /// provider repository before Settings identity is compared at the
    /// composition root.
    var hasCompatibleProviderRepositories: Bool {
        transcription.providerRepositoryIdentity
            == meetingIntelligence.providerRepositoryIdentity
    }

    var isCompatible: Bool {
        hasCompatiblePublicationSources
            && hasCompatibleMutationGates
            && hasCompatibleProviderRepositories
    }

    /// The single aggregate compatibility predicate used by both aggregate
    /// and individual injection paths after all retained boundaries exist.
    func isCompatible(with settingsRepositoryIdentity: ObjectIdentifier) -> Bool {
        isCompatible
            && transcription.providerRepositoryIdentity == settingsRepositoryIdentity
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
