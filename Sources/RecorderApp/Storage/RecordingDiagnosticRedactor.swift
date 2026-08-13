import Foundation

enum RecordingDiagnosticEvent: String, Codable, Sendable {
    case transcriptionSucceeded = "transcription_succeeded"
    case transcriptionFailure = "transcription_failure"
    case meetingIntelligenceFailure = "meeting_intelligence_failure"
    case storageFailure = "storage_failure"
}

enum RecordingDiagnosticComponent: String, Codable, Sendable {
    case transcription
    case meetingIntelligence = "meeting_intelligence"
    case storage
}

enum RecordingDiagnosticStage: String, Codable, Sendable {
    case preparation
    case upload
    case publication
}

enum RecordingDiagnosticOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case skipped
}

enum RecordingDiagnosticErrorCode: String, Codable, Sendable {
    case unknown
    case providerHTTPFailure = "provider_http_failure"
    case providerTransportFailure = "provider_transport_failure"
    case publicationFailure = "publication_failure"
    case invalidArtifact = "invalid_artifact"
}

enum RecordingDiagnosticArtifactClass: String, Codable, Sendable {
    case transcriptionLog = "transcription_log"
    case transcriptionFailureDiagnostic = "transcription_failure_diagnostic"
    case meetingIntelligenceState = "meeting_intelligence_state"
}

struct RecordingDiagnosticEventInput: Sendable {
    let event: RecordingDiagnosticEvent
    let component: RecordingDiagnosticComponent
    let stage: RecordingDiagnosticStage
    let outcome: RecordingDiagnosticOutcome
    let errorCode: RecordingDiagnosticErrorCode
    let httpStatus: Int?
    let attemptCount: Int
    let timestamp: Date
    let artifactClass: RecordingDiagnosticArtifactClass
    let byteCount: Int
}

struct SafeRecordingDiagnostic: Encodable, Equatable, Sendable {
    static let schemaVersion = 1
    static let maximumAttemptCount = 1_000
    static let maximumByteCount = 64 * 1_024 * 1_024

    let event: RecordingDiagnosticEvent
    let schemaVersion: Int
    let component: RecordingDiagnosticComponent
    let stage: RecordingDiagnosticStage
    let outcome: RecordingDiagnosticOutcome
    let errorCode: RecordingDiagnosticErrorCode
    let httpStatus: Int?
    let attemptCount: Int
    let timestamp: String
    let artifactClass: RecordingDiagnosticArtifactClass
    let byteCount: Int

    private init(
        event: RecordingDiagnosticEvent,
        schemaVersion: Int,
        component: RecordingDiagnosticComponent,
        stage: RecordingDiagnosticStage,
        outcome: RecordingDiagnosticOutcome,
        errorCode: RecordingDiagnosticErrorCode,
        httpStatus: Int?,
        attemptCount: Int,
        timestamp: String,
        artifactClass: RecordingDiagnosticArtifactClass,
        byteCount: Int
    ) {
        self.event = event
        self.schemaVersion = schemaVersion
        self.component = component
        self.stage = stage
        self.outcome = outcome
        self.errorCode = errorCode
        self.httpStatus = httpStatus
        self.attemptCount = attemptCount
        self.timestamp = timestamp
        self.artifactClass = artifactClass
        self.byteCount = byteCount
    }

    fileprivate static func make(
        event: RecordingDiagnosticEvent,
        component: RecordingDiagnosticComponent,
        stage: RecordingDiagnosticStage,
        outcome: RecordingDiagnosticOutcome,
        errorCode: RecordingDiagnosticErrorCode,
        httpStatus: Int?,
        attemptCount: Int,
        timestamp: Date,
        artifactClass: RecordingDiagnosticArtifactClass,
        byteCount: Int
    ) -> SafeRecordingDiagnostic {
        .init(
            event: event,
            schemaVersion: schemaVersion,
            component: component,
            stage: stage,
            outcome: outcome,
            errorCode: errorCode,
            httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
            attemptCount: min(max(0, attemptCount), maximumAttemptCount),
            timestamp: ISO8601DateFormatter().string(from: timestamp),
            artifactClass: artifactClass,
            byteCount: min(max(0, byteCount), maximumByteCount)
        )
    }
}

enum RecordingDiagnosticRedactor {
    static func redact(_ input: RecordingDiagnosticEventInput) -> SafeRecordingDiagnostic {
        .make(
            event: input.event,
            component: input.component,
            stage: input.stage,
            outcome: input.outcome,
            errorCode: input.errorCode,
            httpStatus: input.httpStatus,
            attemptCount: input.attemptCount,
            timestamp: input.timestamp,
            artifactClass: input.artifactClass,
            byteCount: input.byteCount
        )
    }
}
