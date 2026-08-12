import Foundation

enum RetainableArtifactClass: String, Codable, CaseIterable, Hashable, Sendable {
    case transcriptionLog
    case transcriptionFailureDiagnostic
    case transcriptionBackup
    case legacyRun
}

enum RetentionPolicy: Equatable, Sendable {
    case disabled
    case enabled(eligibleClasses: Set<RetainableArtifactClass>, olderThanDays: Int)
}

extension RetentionPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case eligibleClasses
        case olderThanDays
    }

    private enum Kind: String, Codable {
        case disabled
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .disabled:
            self = .disabled
        case .enabled:
            let classes = try container.decode(Set<RetainableArtifactClass>.self, forKey: .eligibleClasses)
            let days = try container.decode(Int.self, forKey: .olderThanDays)
            guard !classes.isEmpty, days > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .olderThanDays,
                    in: container,
                    debugDescription: "Enabled retention requires an artifact class and positive age."
                )
            }
            self = .enabled(eligibleClasses: classes, olderThanDays: days)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disabled:
            try container.encode(Kind.disabled, forKey: .kind)
        case let .enabled(eligibleClasses, olderThanDays):
            try container.encode(Kind.enabled, forKey: .kind)
            try container.encode(eligibleClasses, forKey: .eligibleClasses)
            try container.encode(olderThanDays, forKey: .olderThanDays)
        }
    }
}

struct RecordingDataLifecyclePolicy: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var ownerOnlyForNewLocalArtifacts: Bool
    var redactGeneratedDiagnostics: Bool
    var retention: RetentionPolicy

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        ownerOnlyForNewLocalArtifacts: Bool = true,
        redactGeneratedDiagnostics: Bool = true,
        retention: RetentionPolicy = .disabled
    ) {
        self.schemaVersion = schemaVersion
        self.ownerOnlyForNewLocalArtifacts = ownerOnlyForNewLocalArtifacts
        self.redactGeneratedDiagnostics = redactGeneratedDiagnostics
        self.retention = retention
    }

    static let safeDefault = RecordingDataLifecyclePolicy()

    var isSupported: Bool {
        schemaVersion == Self.currentSchemaVersion
    }
}

enum RecordingDataLifecyclePolicyStoreError: Error, Equatable {
    case unsupportedPolicy
}

struct RecordingDataLifecyclePolicyStore {
    static let defaultsKey = "recordingDataLifecyclePolicyV1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RecordingDataLifecyclePolicy {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let policy = try? JSONDecoder().decode(RecordingDataLifecyclePolicy.self, from: data),
              policy.isSupported else {
            return .safeDefault
        }
        return policy
    }

    func save(_ policy: RecordingDataLifecyclePolicy) throws {
        guard policy.isSupported else {
            throw RecordingDataLifecyclePolicyStoreError.unsupportedPolicy
        }
        defaults.set(try JSONEncoder().encode(policy), forKey: Self.defaultsKey)
    }
}
