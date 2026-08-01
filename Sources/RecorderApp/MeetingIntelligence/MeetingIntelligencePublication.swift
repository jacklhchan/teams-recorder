import Foundation

/// The durable semantic outcomes that can require one targeted Library refresh.
/// An artifact generation and its automatic-title decision are deliberately one
/// outcome so a protected title never produces a second, ambiguous callback.
enum MeetingIntelligencePublicationKind: Hashable, Sendable {
    case artifactAndAutomaticTitle
    case explicitSuggestedTitle
}

enum MeetingIntelligenceTitleOutcome: Equatable, Sendable {
    case applied
    case preserved
    case warning(String)
    case explicitApplied
}

/// Value identity for a durable Meeting Intelligence outcome. The workspace
/// fence is captured by the producer at command admission; this coordinator
/// never owns mutable workspace selection state.
struct MeetingIntelligencePublicationIdentity: Hashable, Sendable {
    let coordinatorInstanceID: UUID
    let sessionID: RecordingSession.ID
    let normalizedSessionFolder: URL
    let generation: UInt64
    let attemptID: UUID
    let transcriptRevision: TranscriptDocumentRevision
    let workspaceFence: WorkspacePublicationFence
    let kind: MeetingIntelligencePublicationKind
}

struct MeetingIntelligencePublished: Sendable {
    let identity: MeetingIntelligencePublicationIdentity
    let canonicalSession: RecordingSession
    let artifact: MeetingIntelligenceArtifact?
    let titleOutcome: MeetingIntelligenceTitleOutcome
}

/// A test seam for the interval after a successful durable write but before
/// observer delivery. Production delivery is immediate. In particular, a
/// cancellation that arrives in this interval cannot erase the already-durable
/// semantic publication.
protocol MeetingIntelligencePublicationDeliveryScheduling: Sendable {
    func awaitDeliveryAdmission() async
}

struct ImmediateMeetingIntelligencePublicationDeliveryScheduler: MeetingIntelligencePublicationDeliveryScheduling {
    func awaitDeliveryAdmission() async {}
}
