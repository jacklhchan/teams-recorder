import Foundation

struct MeetingIntelligenceArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let summary: String
    let suggestedTitle: String
    let sourceTranscriptSHA256: String
    let sourceTranscriptByteCount: Int
    let model: String
    let generatedAt: Date
    let intent: MeetingIntelligenceIntent
}

enum MeetingIntelligenceIntent: String, Codable, Equatable, Sendable {
    case automatic
    case generate
    case regenerate
    case retryGeneration
}

enum MeetingIntelligenceStatePhase: String, Codable, Equatable, Sendable {
    case checkingAvailability
    case generating
    case completed
    case failed
    case cancelled
    case interrupted
}

struct MeetingIntelligenceState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let phase: MeetingIntelligenceStatePhase
    let message: String
    let sourceTranscriptSHA256: String?
    let startedAt: Date
    let finishedAt: Date?
}

protocol MeetingIntelligenceArtifactStoring: Sendable {
    func load(in folder: URL) throws -> MeetingIntelligenceArtifact?
    func stage(_ artifact: MeetingIntelligenceArtifact, in folder: URL) throws -> URL
    func promoteStaged(_ stagedURL: URL, in folder: URL) throws
}

protocol MeetingIntelligenceStateStoring: Sendable {
    func load(in folder: URL) throws -> MeetingIntelligenceState?
    func save(_ state: MeetingIntelligenceState, in folder: URL) throws
    func remove(in folder: URL) throws
}
