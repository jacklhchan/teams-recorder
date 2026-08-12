import Foundation

enum RecordingDiagnosticEvent: String, Codable, Sendable {
    case transcriptionFailure
    case meetingIntelligenceFailure
    case storageFailure
}

enum RecordingDiagnosticComponent: String, Codable, Sendable {
    case transcription
    case meetingIntelligence
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
    case providerHTTPFailure
    case providerTransportFailure
    case publicationFailure
    case invalidArtifact
}

enum RecordingDiagnosticArtifactClass: String, Codable, Sendable {
    case transcriptionLog
    case transcriptionFailureDiagnostic
    case meetingIntelligenceState
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

struct SafeRecordingDiagnostic: Codable, Equatable, Sendable {
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
}

enum RecordingDiagnosticRedactor {
    static func redact(_ input: RecordingDiagnosticEventInput) -> SafeRecordingDiagnostic {
        .init(
            event: input.event,
            schemaVersion: SafeRecordingDiagnostic.schemaVersion,
            component: input.component,
            stage: input.stage,
            outcome: input.outcome,
            errorCode: input.errorCode,
            httpStatus: input.httpStatus.flatMap { (100...599).contains($0) ? $0 : nil },
            attemptCount: min(max(0, input.attemptCount), SafeRecordingDiagnostic.maximumAttemptCount),
            timestamp: ISO8601DateFormatter().string(from: input.timestamp),
            artifactClass: input.artifactClass,
            byteCount: min(max(0, input.byteCount), SafeRecordingDiagnostic.maximumByteCount)
        )
    }
}
