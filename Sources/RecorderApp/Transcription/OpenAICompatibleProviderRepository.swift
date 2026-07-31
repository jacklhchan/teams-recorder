import Foundation

protocol OpenAICompatibleProviderManaging: AnyObject {
    func loadProfile() throws -> OpenAICompatibleProviderProfile?
    func save(
        profile: OpenAICompatibleProviderProfile,
        replacementAPIKey: String?
    ) throws
    func snapshot() throws -> OpenAICompatibleProviderSnapshot
    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot
    func hasAPIKey() throws -> Bool
    func removeAPIKey() throws
    func migrateLegacyIfNeeded(
        settingsURL: URL
    ) throws -> LegacyProviderMigrationOutcome
}

struct OpenAICompatibleProviderSnapshot: Codable, Equatable, Sendable {
    let providerKind: AIProviderKind
    let authentication: ProviderAuthentication
    let profile: OpenAICompatibleProviderProfile
    let apiKey: String?

    init(
        providerKind: AIProviderKind? = nil,
        authentication: ProviderAuthentication? = nil,
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) {
        let kind = providerKind ?? profile.providerKind
        self.providerKind = kind
        self.authentication = authentication ?? .forProviderKind(kind)
        self.profile = profile
        self.apiKey = apiKey
    }
}

enum OpenAICompatibleProviderCredential {
    // Do not change the generic identity: it is the already-shipped credential.
    static let service = "local.meeting.recorder.openai-compatible-provider"
    static let account = "active-profile-api-key.v1"
    static let hktService = "local.meeting.recorder.hkt-genai-provider"
    static let hktAccount = "group-api-key.v1"

    static func identity(for kind: AIProviderKind) -> (service: String, account: String) {
        switch kind {
        case .openAICompatible: (service, account)
        case .hktGenAI: (hktService, hktAccount)
        }
    }
}

enum ProviderRepositoryError: LocalizedError, Equatable {
    case missingProfile
    case invalidAPIKeyEncoding
    case legacyCredentialMismatch
    case migrationVerificationFailed
    case migrationRollbackFailed
    case unsupportedProviderPreset

    var errorDescription: String? {
        switch self {
        case .missingProfile:
            "Configure an AI provider before starting transcription."
        case .invalidAPIKeyEncoding:
            "The saved provider API key is invalid."
        case .legacyCredentialMismatch:
            "The saved provider key differs from the legacy local key."
        case .migrationVerificationFailed:
            "Provider credential migration could not be verified."
        case .migrationRollbackFailed:
            "Provider credential migration could not be rolled back."
        case .unsupportedProviderPreset:
            "This provider preset is not supported by the current profile store."
        }
    }
}

enum LegacyProviderMigrationOutcome: Equatable {
    case notFound
    case alreadyConfigured
    case migrated
}

final class OpenAICompatibleProviderRepository: OpenAICompatibleProviderManaging, @unchecked Sendable {
    private let profiles: any ProviderProfileStoring
    private let secureStore: any SecureValueStoring
    private let lock = NSLock()

    init(
        profiles: any ProviderProfileStoring,
        secureStore: any SecureValueStoring
    ) {
        self.profiles = profiles
        self.secureStore = secureStore
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock {
            try profiles.load()
        }
    }

    func loadProfile(for kind: AIProviderKind) throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock {
            if let presets = profiles as? any ProviderPresetProfileStoring {
                return try presets.loadProfile(for: kind)
            }
            return kind == .openAICompatible ? try profiles.load() : nil
        }
    }

    func activeProviderKind() throws -> AIProviderKind {
        try lock.withLock {
            if let presets = profiles as? any ProviderPresetProfileStoring {
                return try presets.activeProviderKind()
            }
            return .openAICompatible
        }
    }

    func setActiveProviderKind(_ kind: AIProviderKind) throws {
        try lock.withLock {
            guard let presets = profiles as? any ProviderPresetProfileStoring else {
                guard kind == .openAICompatible else { throw ProviderRepositoryError.unsupportedProviderPreset }
                return
            }
            try presets.setActiveProviderKind(kind)
        }
    }

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            guard let profile = try profiles.load() else {
                throw ProviderRepositoryError.missingProfile
            }
            return try makeSnapshot(profile: profile)
        }
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            try makeSnapshot(profile: profile)
        }
    }

    func save(
        profile: OpenAICompatibleProviderProfile,
        replacementAPIKey: String?
    ) throws {
        try lock.withLock {
            let profile = try OpenAICompatibleProviderProfile.validatedPersisted(profile)
            if let replacementAPIKey, !replacementAPIKey.isEmpty {
                let identity = OpenAICompatibleProviderCredential.identity(for: profile.providerKind)
                try secureStore.save(
                    Data(replacementAPIKey.utf8),
                    service: identity.service,
                    account: identity.account
                )
            }
            try profiles.save(profile)
        }
    }

    func hasAPIKey() throws -> Bool {
        try lock.withLock {
            guard let profile = try profiles.load() else { return false }
            return try loadAPIKey(for: profile.providerKind) != nil
        }
    }

    func removeAPIKey() throws {
        try lock.withLock {
            let kind = (try profiles.load())?.providerKind ?? .openAICompatible
            let identity = OpenAICompatibleProviderCredential.identity(for: kind)
            try secureStore.delete(
                service: identity.service,
                account: identity.account
            )
        }
    }

    func hasAPIKey(for kind: AIProviderKind) throws -> Bool {
        try lock.withLock { try loadAPIKey(for: kind) != nil }
    }

    func removeAPIKey(for kind: AIProviderKind) throws {
        try lock.withLock {
            let identity = OpenAICompatibleProviderCredential.identity(for: kind)
            try secureStore.delete(service: identity.service, account: identity.account)
        }
    }

    func migrateLegacyIfNeeded(
        settingsURL: URL
    ) throws -> LegacyProviderMigrationOutcome {
        try migrateLegacyIfNeeded(
            settingsURL: settingsURL,
            reader: LegacyOMLXSettingsReader(),
            fileManager: .default
        )
    }

    func migrateLegacyIfNeeded(
        settingsURL: URL,
        reader: LegacyOMLXSettingsReader,
        fileManager: FileManager
    ) throws -> LegacyProviderMigrationOutcome {
        try lock.withLock {
            if try hasAnyProfile() {
                return .alreadyConfigured
            }
            guard fileManager.fileExists(atPath: settingsURL.path) else {
                return .notFound
            }

            let legacy = try reader.read(from: settingsURL)
            let profile = try OpenAICompatibleProviderProfile.validated(
                baseURLText: legacy.baseURL.absoluteString,
                asrModel: "mlx-community--Qwen3-ASR-1.7B-4bit",
                llmModel: "legacy-unconfigured-llm",
                language: "yue",
                prompt: "香港粵語商務會議，可能夾雜英文、人名、"
                    + "公司名、產品名及技術縮寫。請忠實轉錄錄音"
                    + "內容，不要翻譯或補寫沒有說出的內容。"
            )
            let existingKey = try loadAPIKey(for: .openAICompatible)
            if let existingKey,
               let legacyKey = legacy.apiKey,
               existingKey != legacyKey {
                throw ProviderRepositoryError.legacyCredentialMismatch
            }
            var newlySavedLegacyKey: Data?
            if existingKey == nil, let legacyKey = legacy.apiKey {
                let data = Data(legacyKey.utf8)
                try secureStore.save(
                    data,
                    service: OpenAICompatibleProviderCredential.service,
                    account: OpenAICompatibleProviderCredential.account
                )
                newlySavedLegacyKey = data
            }

            do {
                if let newlySavedLegacyKey {
                    guard try secureStore.load(
                        service: OpenAICompatibleProviderCredential.service,
                        account: OpenAICompatibleProviderCredential.account
                    ) == newlySavedLegacyKey else {
                        throw ProviderRepositoryError.migrationVerificationFailed
                    }
                }
                try profiles.save(profile)
            } catch {
                if newlySavedLegacyKey != nil {
                    do {
                        try secureStore.delete(
                            service: OpenAICompatibleProviderCredential.service,
                            account: OpenAICompatibleProviderCredential.account
                        )
                    } catch {
                        throw ProviderRepositoryError.migrationRollbackFailed
                    }
                }
                throw error
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: settingsURL.deletingLastPathComponent().path
            )
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
            return .migrated
        }
    }

    private func hasAnyProfile() throws -> Bool {
        if let presets = profiles as? any ProviderPresetProfileStoring {
            return try presets.hasAnyProfile()
        }
        return try profiles.load() != nil
    }

    private func makeSnapshot(
        profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        let profile = try OpenAICompatibleProviderProfile.validatedPersisted(profile)
        // Configuration is validated before a credential lookup.
        return OpenAICompatibleProviderSnapshot(
            providerKind: profile.providerKind,
            authentication: .forProviderKind(profile.providerKind),
            profile: profile,
            apiKey: try loadAPIKey(for: profile.providerKind)
        )
    }

    private func loadAPIKey(for kind: AIProviderKind) throws -> String? {
        let identity = OpenAICompatibleProviderCredential.identity(for: kind)
        guard let data = try secureStore.load(
            service: identity.service,
            account: identity.account
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ProviderRepositoryError.invalidAPIKeyEncoding
        }
        return value
    }
}
