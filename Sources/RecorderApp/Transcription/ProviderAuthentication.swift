import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case hktGenAI
    case openAICompatible
}

enum ProviderAuthentication: Codable, Equatable, Sendable {
    case bearer
    case hktAPIKey

    var headerField: String {
        switch self {
        case .bearer: "Authorization"
        case .hktAPIKey: "X-API-KEY"
        }
    }

    func headerValue(for apiKey: String) -> String {
        switch self {
        case .bearer: "Bearer \(apiKey)"
        case .hktAPIKey: apiKey
        }
    }

    static func forProviderKind(_ kind: AIProviderKind) -> Self {
        switch kind {
        case .openAICompatible: .bearer
        case .hktGenAI: .hktAPIKey
        }
    }
}
