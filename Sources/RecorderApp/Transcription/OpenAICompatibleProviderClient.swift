import Foundation

protocol ProviderHTTPDataLoading: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionProviderHTTPDataLoader: ProviderHTTPDataLoading {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderConnectionError.invalidResponse
        }
        return (data, response)
    }
}

struct ProviderConnectionReport: Equatable, Sendable {
    let supportsModelDiscovery: Bool
    let models: [String]
}

protocol ProviderConnectionTesting: Sendable {
    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport
}

enum ProviderConnectionError: LocalizedError, Equatable {
    case invalidResponse
    case authenticationRejected
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The provider returned an invalid response."
        case .authenticationRejected:
            "The provider rejected the API key."
        case .httpStatus(let status):
            "The provider returned HTTP \(status)."
        }
    }
}

struct OpenAICompatibleProviderClient: ProviderConnectionTesting {
    private let loader: any ProviderHTTPDataLoading

    init(
        loader: any ProviderHTTPDataLoading =
            URLSessionProviderHTTPDataLoader()
    ) {
        self.loader = loader
    }

    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport {
        var request = URLRequest(
            url: profile.baseURL.appendingPathComponent("models")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await loader.data(for: request)
        switch response.statusCode {
        case 200..<300:
            let decoded = try? JSONDecoder().decode(ModelList.self, from: data)
            return ProviderConnectionReport(
                supportsModelDiscovery: decoded != nil,
                models: decoded?.data.map(\.id).sorted() ?? []
            )
        case 404, 405:
            return ProviderConnectionReport(
                supportsModelDiscovery: false,
                models: []
            )
        case 401, 403:
            throw ProviderConnectionError.authenticationRejected
        default:
            throw ProviderConnectionError.httpStatus(response.statusCode)
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }
}
