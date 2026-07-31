import Foundation

struct OpenAICompatibleProviderProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let hktBaseURLPrefix = "https://api.uat.bot-builder.pccw.com/v1/groups/"

    let schemaVersion: Int
    let providerKind: AIProviderKind
    let baseURL: URL
    let groupID: String?
    let asrModel: String
    let llmModel: String
    let language: String
    let prompt: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, providerKind, baseURL, groupID, asrModel, llmModel, language, prompt
    }

    private init(schemaVersion: Int = currentSchemaVersion, providerKind: AIProviderKind, baseURL: URL, groupID: String?, asrModel: String, llmModel: String, language: String, prompt: String) {
        self.schemaVersion = schemaVersion
        self.providerKind = providerKind
        self.baseURL = baseURL
        self.groupID = groupID
        self.asrModel = asrModel
        self.llmModel = llmModel
        self.language = language
        self.prompt = prompt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        providerKind = try container.decodeIfPresent(AIProviderKind.self, forKey: .providerKind) ?? .openAICompatible
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
        asrModel = try container.decode(String.self, forKey: .asrModel)
        llmModel = try container.decode(String.self, forKey: .llmModel)
        language = try container.decode(String.self, forKey: .language)
        prompt = try container.decode(String.self, forKey: .prompt)
    }

    static func validated(baseURLText: String, asrModel: String, llmModel: String, language: String, prompt: String) throws -> Self {
        let normalizedURL = try normalizedGenericURL(baseURLText)
        return try make(providerKind: .openAICompatible, baseURL: normalizedURL, groupID: nil, asrModel: asrModel, llmModel: llmModel, language: language, prompt: prompt)
    }

    static func hktValidated(groupID: String, asrModel: String, llmModel: String, language: String, prompt: String) throws -> Self {
        let normalizedGroupID = try validatedHKTGroupID(groupID)
        return try make(providerKind: .hktGenAI, baseURL: hktBaseURL(groupID: normalizedGroupID), groupID: normalizedGroupID, asrModel: asrModel, llmModel: llmModel, language: language, prompt: prompt)
    }

    static func hktBaseURL(groupID: String) -> URL {
        URL(string: hktBaseURLPrefix + groupID + "/openai")!
    }

    static func validatedHKTGroupID(_ value: String) throws -> String {
        // Deliberately do not trim: whitespace is not an ASCII digit and must be rejected.
        guard (1...32).contains(value.utf8.count), value.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw ProviderProfileValidationError.invalidHKTGroupID
        }
        return value
    }

    static func validatedPersisted(_ profile: Self) throws -> Self {
        guard profile.schemaVersion == currentSchemaVersion else {
            throw ProviderProfileValidationError.unsupportedSchemaVersion(profile.schemaVersion)
        }
        switch profile.providerKind {
        case .openAICompatible:
            guard profile.groupID == nil else { throw ProviderProfileValidationError.invalidProviderConfiguration }
            return try validated(baseURLText: profile.baseURL.absoluteString, asrModel: profile.asrModel, llmModel: profile.llmModel, language: profile.language, prompt: profile.prompt)
        case .hktGenAI:
            guard let groupID = profile.groupID else { throw ProviderProfileValidationError.invalidHKTGroupID }
            let validated = try hktValidated(groupID: groupID, asrModel: profile.asrModel, llmModel: profile.llmModel, language: profile.language, prompt: profile.prompt)
            guard validated.baseURL == profile.baseURL else { throw ProviderProfileValidationError.invalidProviderConfiguration }
            return validated
        }
    }

    private static func make(providerKind: AIProviderKind, baseURL: URL, groupID: String?, asrModel: String, llmModel: String, language: String, prompt: String) throws -> Self {
        let asr = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let llm = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = try validatedLanguage(language)
        guard !asr.isEmpty else { throw ProviderProfileValidationError.missingASRModel }
        guard !llm.isEmpty else { throw ProviderProfileValidationError.missingLLMModel }
        return Self(providerKind: providerKind, baseURL: baseURL, groupID: groupID, asrModel: asr, llmModel: llm, language: language, prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func validatedLanguage(_ value: String) throws -> String {
        let language = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["yue", "en", "zh"].contains(language) else {
            throw ProviderProfileValidationError.invalidLanguage
        }
        return language
    }

    private static func normalizedGenericURL(_ text: String) throws -> URL {
        let trimmedURL = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURL), let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else { throw ProviderProfileValidationError.invalidBaseURL }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { throw ProviderProfileValidationError.unsupportedURLComponents }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else { throw ProviderProfileValidationError.insecureRemoteURL }
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty || path == "/" { path = "/v1" } else if !path.hasSuffix("/v1") { path += "/v1" }
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = path
        guard let url = components.url else { throw ProviderProfileValidationError.invalidBaseURL }
        return url
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127", octets.allSatisfy({ guard let value = UInt8($0) else { return false }; return String(value) == $0 || $0 == "0" }) else { return false }
        return true
    }
}

enum ProviderProfileValidationError: LocalizedError, Equatable {
    case invalidBaseURL, unsupportedURLComponents, insecureRemoteURL, missingASRModel, missingLLMModel, invalidLanguage, invalidHKTGroupID, invalidProviderConfiguration, unsupportedSchemaVersion(Int)
    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Enter a valid API base URL."
        case .unsupportedURLComponents: "The API URL cannot contain credentials, a query, or a fragment."
        case .insecureRemoteURL: "Remote providers must use HTTPS."
        case .missingASRModel: "Enter an ASR model identifier."
        case .missingLLMModel: "Enter an LLM model identifier."
        case .invalidLanguage: "Choose Cantonese, English, or Chinese."
        case .invalidHKTGroupID: "Enter a group ID containing 1 to 32 ASCII digits."
        case .invalidProviderConfiguration: "The saved provider configuration is invalid."
        case let .unsupportedSchemaVersion(version): "Provider profile version \(version) is not supported."
        }
    }
}
