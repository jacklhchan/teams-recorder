import Foundation

struct OpenAICompatibleProviderSnapshot: Codable, Equatable, Sendable {
    let profile: OpenAICompatibleProviderProfile
    let apiKey: String?
}

enum OpenAICompatibleProviderCredential {
    static let service = "local.meeting.recorder.openai-compatible-provider"
    static let account = "active-profile-api-key.v1"
}

enum ProviderRepositoryError: LocalizedError, Equatable {
    case missingProfile
    case invalidAPIKeyEncoding
    case legacyCredentialMismatch
    case migrationVerificationFailed

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
        }
    }
}

enum LegacyProviderMigrationOutcome: Equatable {
    case notFound
    case alreadyConfigured
    case migrated
}

final class OpenAICompatibleProviderRepository: @unchecked Sendable {
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

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            guard let profile = try profiles.load() else {
                throw ProviderRepositoryError.missingProfile
            }
            return OpenAICompatibleProviderSnapshot(
                profile: profile,
                apiKey: try loadAPIKey()
            )
        }
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            OpenAICompatibleProviderSnapshot(
                profile: profile,
                apiKey: try loadAPIKey()
            )
        }
    }

    func save(
        profile: OpenAICompatibleProviderProfile,
        replacementAPIKey: String?
    ) throws {
        try lock.withLock {
            if let replacementAPIKey, !replacementAPIKey.isEmpty {
                try secureStore.save(
                    Data(replacementAPIKey.utf8),
                    service: OpenAICompatibleProviderCredential.service,
                    account: OpenAICompatibleProviderCredential.account
                )
            }
            try profiles.save(profile)
        }
    }

    func hasAPIKey() throws -> Bool {
        try lock.withLock {
            try loadAPIKey() != nil
        }
    }

    func removeAPIKey() throws {
        try lock.withLock {
            try secureStore.delete(
                service: OpenAICompatibleProviderCredential.service,
                account: OpenAICompatibleProviderCredential.account
            )
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
            if try profiles.load() != nil {
                return .alreadyConfigured
            }
            guard fileManager.fileExists(atPath: settingsURL.path) else {
                return .notFound
            }

            let legacy = try reader.read(from: settingsURL)
            let existingKey = try loadAPIKey()
            if let existingKey,
               let legacyKey = legacy.apiKey,
               existingKey != legacyKey {
                throw ProviderRepositoryError.legacyCredentialMismatch
            }
            if existingKey == nil, let legacyKey = legacy.apiKey {
                let data = Data(legacyKey.utf8)
                try secureStore.save(
                    data,
                    service: OpenAICompatibleProviderCredential.service,
                    account: OpenAICompatibleProviderCredential.account
                )
                guard try secureStore.load(
                    service: OpenAICompatibleProviderCredential.service,
                    account: OpenAICompatibleProviderCredential.account
                ) == data else {
                    throw ProviderRepositoryError.migrationVerificationFailed
                }
            }

            let profile = try OpenAICompatibleProviderProfile.validated(
                baseURLText: legacy.baseURL.absoluteString,
                asrModel: "mlx-community--Qwen3-ASR-1.7B-4bit",
                llmModel: "legacy-unconfigured-llm",
                language: "yue",
                prompt: "香港粵語商務會議，可能夾雜英文、人名、"
                    + "公司名、產品名及技術縮寫。請忠實轉錄錄音"
                    + "內容，不要翻譯或補寫沒有說出的內容。"
            )
            try profiles.save(profile)
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

    private func loadAPIKey() throws -> String? {
        guard let data = try secureStore.load(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ProviderRepositoryError.invalidAPIKeyEncoding
        }
        return value
    }
}
