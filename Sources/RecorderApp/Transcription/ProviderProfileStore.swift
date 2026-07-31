import Foundation

protocol ProviderProfileStoring: Sendable {
    func load() throws -> OpenAICompatibleProviderProfile?
    func save(_ profile: OpenAICompatibleProviderProfile) throws
}

protocol ProviderPresetProfileStoring: ProviderProfileStoring {
    func loadProfile(for kind: AIProviderKind) throws -> OpenAICompatibleProviderProfile?
    func activeProviderKind() throws -> AIProviderKind
    func setActiveProviderKind(_ kind: AIProviderKind) throws
    func hasAnyProfile() throws -> Bool
}

private struct ProviderProfileEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 2
    let schemaVersion: Int
    let activeProviderKind: AIProviderKind
    let genericProfile: OpenAICompatibleProviderProfile?
    let hktProfile: OpenAICompatibleProviderProfile?
}

final class OpenAICompatibleProviderProfileStore: ProviderPresetProfileStoring, @unchecked Sendable {
    // Keep the old key: a legacy v1 value is migrated in place to the envelope.
    static let key = "openAICompatibleProvider.activeProfile.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock {
            guard let envelope = try loadEnvelopeMigratingLegacy() else { return nil }
            return envelope.profile(for: envelope.activeProviderKind)
        }
    }

    func loadProfile(for kind: AIProviderKind) throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock { try loadEnvelopeMigratingLegacy()?.profile(for: kind) }
    }

    func activeProviderKind() throws -> AIProviderKind {
        try lock.withLock { try loadEnvelopeMigratingLegacy()?.activeProviderKind ?? .openAICompatible }
    }

    func hasAnyProfile() throws -> Bool {
        try lock.withLock {
            guard let envelope = try loadEnvelopeMigratingLegacy() else { return false }
            return envelope.genericProfile != nil || envelope.hktProfile != nil
        }
    }

    func setActiveProviderKind(_ kind: AIProviderKind) throws {
        try lock.withLock {
            let existing = try loadEnvelopeMigratingLegacy()
            let envelope = try validatedEnvelope(.init(schemaVersion: ProviderProfileEnvelope.currentSchemaVersion, activeProviderKind: kind, genericProfile: existing?.genericProfile, hktProfile: existing?.hktProfile))
            try saveEnvelope(envelope)
        }
    }

    func save(_ profile: OpenAICompatibleProviderProfile) throws {
        try save(profile, makingActive: true)
    }

    func save(_ profile: OpenAICompatibleProviderProfile, makingActive: Bool) throws {
        try lock.withLock {
            let profile = try OpenAICompatibleProviderProfile.validatedPersisted(profile)
            let existing = try loadEnvelopeMigratingLegacy()
            let generic = profile.providerKind == .openAICompatible ? profile : existing?.genericProfile
            let hkt = profile.providerKind == .hktGenAI ? profile : existing?.hktProfile
            let active = makingActive ? profile.providerKind : (existing?.activeProviderKind ?? .openAICompatible)
            try saveEnvelope(try validatedEnvelope(.init(schemaVersion: ProviderProfileEnvelope.currentSchemaVersion, activeProviderKind: active, genericProfile: generic, hktProfile: hkt)))
        }
    }

    private func loadEnvelopeMigratingLegacy() throws -> ProviderProfileEnvelope? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        if let envelope = try? JSONDecoder().decode(ProviderProfileEnvelope.self, from: data) {
            return try validatedEnvelope(envelope)
        }
        let legacy = try JSONDecoder().decode(OpenAICompatibleProviderProfile.self, from: data)
        let generic = try OpenAICompatibleProviderProfile.validatedPersisted(legacy)
        guard generic.providerKind == .openAICompatible else { throw ProviderProfileValidationError.invalidProviderConfiguration }
        let envelope = try validatedEnvelope(.init(schemaVersion: ProviderProfileEnvelope.currentSchemaVersion, activeProviderKind: .openAICompatible, genericProfile: generic, hktProfile: nil))
        try saveEnvelope(envelope)
        return envelope
    }

    private func validatedEnvelope(_ envelope: ProviderProfileEnvelope) throws -> ProviderProfileEnvelope {
        guard envelope.schemaVersion == ProviderProfileEnvelope.currentSchemaVersion else { throw ProviderProfileValidationError.unsupportedSchemaVersion(envelope.schemaVersion) }
        let generic = try envelope.genericProfile.map(OpenAICompatibleProviderProfile.validatedPersisted)
        let hkt = try envelope.hktProfile.map(OpenAICompatibleProviderProfile.validatedPersisted)
        guard generic?.providerKind != .hktGenAI, hkt?.providerKind != .openAICompatible else { throw ProviderProfileValidationError.invalidProviderConfiguration }
        return .init(schemaVersion: ProviderProfileEnvelope.currentSchemaVersion, activeProviderKind: envelope.activeProviderKind, genericProfile: generic, hktProfile: hkt)
    }

    private func saveEnvelope(_ envelope: ProviderProfileEnvelope) throws {
        defaults.set(try JSONEncoder().encode(envelope), forKey: Self.key)
    }
}

private extension ProviderProfileEnvelope {
    func profile(for kind: AIProviderKind) -> OpenAICompatibleProviderProfile? {
        switch kind { case .openAICompatible: genericProfile; case .hktGenAI: hktProfile }
    }
}
