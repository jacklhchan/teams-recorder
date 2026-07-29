import Foundation

struct LegacyOMLXSettings: Equatable, Sendable {
    let baseURL: URL
    let apiKey: String?
}

struct LegacyOMLXSettingsReader {
    private struct Document: Decodable {
        struct Server: Decodable {
            let host: String
            let port: Int
        }

        struct Auth: Decodable {
            let apiKey: String?

            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
            }
        }

        let server: Server
        let auth: Auth?
    }

    func read(from url: URL) throws -> LegacyOMLXSettings {
        let document = try JSONDecoder().decode(
            Document.self,
            from: Data(contentsOf: url)
        )
        let host = ["0.0.0.0", "::"].contains(document.server.host)
            ? "127.0.0.1"
            : document.server.host
        guard (1...65_535).contains(document.server.port),
              let baseURL = URL(
                string: "http://\(host):\(document.server.port)/v1"
              ) else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        let key = document.auth?.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LegacyOMLXSettings(
            baseURL: baseURL,
            apiKey: key?.isEmpty == false ? key : nil
        )
    }
}
