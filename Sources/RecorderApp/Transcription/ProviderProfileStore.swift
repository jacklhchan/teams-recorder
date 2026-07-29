import Foundation

protocol ProviderProfileStoring: Sendable {
    func load() throws -> OpenAICompatibleProviderProfile?
    func save(_ profile: OpenAICompatibleProviderProfile) throws
}

final class OpenAICompatibleProviderProfileStore: ProviderProfileStoring, @unchecked Sendable {
    static let key = "openAICompatibleProvider.activeProfile.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock {
            guard let data = defaults.data(forKey: Self.key) else {
                return nil
            }
            let profile = try JSONDecoder().decode(
                OpenAICompatibleProviderProfile.self,
                from: data
            )
            guard profile.schemaVersion
                == OpenAICompatibleProviderProfile.currentSchemaVersion else {
                throw ProviderProfileValidationError.unsupportedSchemaVersion(
                    profile.schemaVersion
                )
            }
            return try validate(profile)
        }
    }

    func save(_ profile: OpenAICompatibleProviderProfile) throws {
        let data = try JSONEncoder().encode(validate(profile))
        lock.withLock {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func validate(
        _ profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderProfile {
        guard profile.schemaVersion
            == OpenAICompatibleProviderProfile.currentSchemaVersion else {
            throw ProviderProfileValidationError.unsupportedSchemaVersion(
                profile.schemaVersion
            )
        }
        return try OpenAICompatibleProviderProfile.validated(
            baseURLText: profile.baseURL.absoluteString,
            asrModel: profile.asrModel,
            llmModel: profile.llmModel,
            language: profile.language,
            prompt: profile.prompt
        )
    }
}
