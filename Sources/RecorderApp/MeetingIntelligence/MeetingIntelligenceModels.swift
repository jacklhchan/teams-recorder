import Foundation

enum MeetingIntelligenceContentOrigin: String, Codable, Equatable, Sendable {
    case generated
    case edited
}

struct MeetingIntelligenceArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let summary: String
    let suggestedTitle: String
    let sourceTranscriptSHA256: String
    let sourceTranscriptByteCount: Int
    let model: String
    let generatedAt: Date
    let intent: MeetingIntelligenceIntent
    let contentOrigin: MeetingIntelligenceContentOrigin
    let editedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case summary
        case suggestedTitle
        case sourceTranscriptSHA256
        case sourceTranscriptByteCount
        case model
        case generatedAt
        case intent
        case contentOrigin
        case editedAt
    }

    init(
        schemaVersion: Int,
        summary: String,
        suggestedTitle: String,
        sourceTranscriptSHA256: String,
        sourceTranscriptByteCount: Int,
        model: String,
        generatedAt: Date,
        intent: MeetingIntelligenceIntent,
        contentOrigin: MeetingIntelligenceContentOrigin,
        editedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.suggestedTitle = suggestedTitle
        self.sourceTranscriptSHA256 = sourceTranscriptSHA256
        self.sourceTranscriptByteCount = sourceTranscriptByteCount
        self.model = model
        self.generatedAt = generatedAt
        self.intent = intent
        self.contentOrigin = contentOrigin
        self.editedAt = editedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported meeting intelligence artifact schema version."
            )
        }

        self.schemaVersion = schemaVersion
        self.summary = try container.decode(String.self, forKey: .summary)
        self.suggestedTitle = try container.decode(String.self, forKey: .suggestedTitle)
        self.sourceTranscriptSHA256 = try container.decode(String.self, forKey: .sourceTranscriptSHA256)
        self.sourceTranscriptByteCount = try container.decode(Int.self, forKey: .sourceTranscriptByteCount)
        self.model = try container.decode(String.self, forKey: .model)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.intent = try container.decode(MeetingIntelligenceIntent.self, forKey: .intent)

        if schemaVersion == 1 {
            self.contentOrigin = .generated
            self.editedAt = nil
        } else {
            let contentOrigin = try container.decode(
                MeetingIntelligenceContentOrigin.self,
                forKey: .contentOrigin
            )
            let editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
            guard MeetingIntelligenceArtifactValidator.isValidProvenance(
                contentOrigin: contentOrigin,
                editedAt: editedAt
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .contentOrigin,
                    in: container,
                    debugDescription: "Invalid meeting intelligence content provenance."
                )
            }
            self.contentOrigin = contentOrigin
            self.editedAt = editedAt
        }
    }
}

enum MeetingIntelligenceIntent: String, Codable, Equatable, Sendable {
    case automatic
    case generate
    case regenerate
    case retryGeneration
}

/// The canonical validation boundary for provider output and persisted artifacts.
enum MeetingIntelligenceArtifactValidator {
    static let maximumSummaryBytes = 48 * 1_024
    static let maximumTitleGraphemes = 120
    static let maximumModelBytes = 512
    static let maximumTranscriptBytes = 4 * 1_024 * 1_024

    static func summary(_ raw: String, maximumBytes: Int = maximumSummaryBytes) -> String? {
        let normalized = raw.precomposedStringWithCanonicalMapping
        guard !containsUnsafeScalar(normalized, allowingNewlineAndTab: true) else { return nil }
        let value = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              !containsUnsafeScalar(value, allowingNewlineAndTab: true) else { return nil }
        return value
    }

    static func title(_ raw: String) -> String? {
        let normalized = raw.precomposedStringWithCanonicalMapping
        guard !containsUnsafeScalar(normalized, allowingNewlineAndTab: false) else { return nil }
        let value = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try! NSRegularExpression(
            pattern: "^(?:\\.|\\.\\.|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?|(meeting|test|manual)-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}(?:[0-9]{2})?)$",
            options: [.caseInsensitive]
        )
        let range = NSRange(value.startIndex..., in: value)
        guard !value.isEmpty, value.count <= maximumTitleGraphemes,
              !value.contains("/"), !value.contains("\\"),
              expression.firstMatch(in: value, range: range) == nil,
              !containsUnsafeScalar(value, allowingNewlineAndTab: false) else { return nil }
        return value
    }

    static func isValid(_ artifact: MeetingIntelligenceArtifact) -> Bool {
        (artifact.schemaVersion == 1 || artifact.schemaVersion == MeetingIntelligenceArtifact.currentSchemaVersion) &&
            summary(artifact.summary) == artifact.summary &&
            title(artifact.suggestedTitle) == artifact.suggestedTitle &&
            isSHA256(artifact.sourceTranscriptSHA256) &&
            (0...maximumTranscriptBytes).contains(artifact.sourceTranscriptByteCount) &&
            isModel(artifact.model) && artifact.generatedAt.timeIntervalSinceReferenceDate.isFinite &&
            isValidProvenance(contentOrigin: artifact.contentOrigin, editedAt: artifact.editedAt)
    }

    static func isValidProvenance(
        contentOrigin: MeetingIntelligenceContentOrigin,
        editedAt: Date?
    ) -> Bool {
        contentOrigin == .generated
            ? editedAt == nil
            : editedAt?.timeIntervalSinceReferenceDate.isFinite == true
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 71, value.hasPrefix("sha256:") else { return false }
        return value.dropFirst(7).unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private static func isModel(_ raw: String) -> Bool {
        let value = raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value == raw && value.utf8.count <= maximumModelBytes &&
            !containsUnsafeScalar(value, allowingNewlineAndTab: false)
    }

    private static func containsUnsafeScalar(_ value: String, allowingNewlineAndTab: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            let scalarValue = scalar.value
            if allowingNewlineAndTab && (scalarValue == 9 || scalarValue == 10) { return false }
            return scalarValue < 32 || (127...159).contains(scalarValue) ||
                scalar.properties.generalCategory == .format ||
                [0x061C, 0x200B, 0x200E, 0x200F, 0xFEFF].contains(scalarValue) ||
                (0x202A...0x202E).contains(scalarValue) || (0x2066...0x2069).contains(scalarValue)
        }
    }
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
    func removeStaged(_ stagedURL: URL, in folder: URL) throws
}

/// Capability-aware artifact staging. The default on-disk store accepts the
/// directory identity captured with metadata so a replacement folder cannot
/// receive even a temporary publication candidate.
protocol MeetingIntelligenceArtifactSecureStoring: MeetingIntelligenceArtifactStoring {
    func stage(
        _ artifact: MeetingIntelligenceArtifact,
        in folder: URL,
        expectedDirectory: MeetingIntelligenceStoreDirectoryIdentity
    ) throws -> URL
}

protocol MeetingIntelligenceStateStoring: Sendable {
    func load(in folder: URL) throws -> MeetingIntelligenceState?
    func save(_ state: MeetingIntelligenceState, in folder: URL) throws
    func remove(in folder: URL) throws
}
