import Foundation

struct OpenAICompatibleProviderProfile: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let baseURL: URL
    let asrModel: String
    let llmModel: String
    let language: String
    let prompt: String

    private init(
        schemaVersion: Int,
        baseURL: URL,
        asrModel: String,
        llmModel: String,
        language: String,
        prompt: String
    ) {
        self.schemaVersion = schemaVersion
        self.baseURL = baseURL
        self.asrModel = asrModel
        self.llmModel = llmModel
        self.language = language
        self.prompt = prompt
    }

    static func validated(
        baseURLText: String,
        asrModel: String,
        llmModel: String,
        language: String,
        prompt: String
    ) throws -> Self {
        let trimmedURL = baseURLText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard var components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ProviderProfileValidationError.unsupportedURLComponents
        }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else {
            throw ProviderProfileValidationError.insecureRemoteURL
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" {
            path = "/v1"
        } else if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = path

        guard let normalizedURL = components.url else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        let asr = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let llm = llmModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asr.isEmpty else {
            throw ProviderProfileValidationError.missingASRModel
        }
        guard !llm.isEmpty else {
            throw ProviderProfileValidationError.missingLLMModel
        }

        return Self(
            schemaVersion: currentSchemaVersion,
            baseURL: normalizedURL,
            asrModel: asr,
            llmModel: llm,
            language: language.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({
                  guard let value = UInt8($0) else { return false }
                  return String(value) == $0 || $0 == "0"
              }) else {
            return false
        }
        return true
    }
}

enum ProviderProfileValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case unsupportedURLComponents
    case insecureRemoteURL
    case missingASRModel
    case missingLLMModel
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter a valid API base URL."
        case .unsupportedURLComponents:
            "The API URL cannot contain credentials, a query, or a fragment."
        case .insecureRemoteURL:
            "Remote providers must use HTTPS."
        case .missingASRModel:
            "Enter an ASR model identifier."
        case .missingLLMModel:
            "Enter an LLM model identifier."
        case .unsupportedSchemaVersion(let version):
            "Provider profile version \(version) is not supported."
        }
    }
}
