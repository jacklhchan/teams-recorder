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

enum ProviderRequestAuthentication {
    static let sensitiveHeaderFields = ["Authorization", "X-API-KEY"]

    static func apply(
        snapshot: OpenAICompatibleProviderSnapshot,
        to request: inout URLRequest
    ) {
        for field in sensitiveHeaderFields {
            request.setValue(nil, forHTTPHeaderField: field)
        }
        guard let key = snapshot.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return
        }
        request.setValue(
            snapshot.authentication.headerValue(for: key),
            forHTTPHeaderField: snapshot.authentication.headerField
        )
    }
}
