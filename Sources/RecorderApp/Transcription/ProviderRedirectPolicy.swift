import Foundation

enum ProviderRedirectPolicy {
    static func allows(from source: URL, to destination: URL) -> Bool {
        guard source.scheme?.lowercased() == destination.scheme?.lowercased(),
              source.host?.lowercased() == destination.host?.lowercased() else {
            return false
        }
        return effectivePort(for: source) == effectivePort(for: destination)
    }

    static func redirectedRequest(from source: URLRequest, proposed: URLRequest, statusCode: Int) -> URLRequest? {
        var proposed = proposed
        for header in credentialHeaders {
            proposed.setValue(nil, forHTTPHeaderField: header)
        }
        guard statusCode == 307 || statusCode == 308,
              source.httpMethod == "POST", proposed.httpMethod == "POST",
              let sourceBody = source.httpBody, proposed.httpBody == sourceBody,
              let sourceType = normalizedContentType(source),
              sourceType == normalizedContentType(proposed), isSupportedContentType(sourceType),
              let sourceURL = source.url, let destinationURL = proposed.url,
              allows(from: sourceURL, to: destinationURL) else { return nil }
        for header in credentialHeaders {
            if let value = source.value(forHTTPHeaderField: header) {
                proposed.setValue(value, forHTTPHeaderField: header)
            }
        }
        return proposed
    }

    private static let credentialHeaders = ["Authorization", "X-API-KEY"]

    private static func normalizedContentType(_ request: URLRequest) -> String? {
        guard let raw = request.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false)
        let mediaType = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mediaType else { return nil }
        if mediaType == "application/json" { return mediaType }
        let parameters = parts.dropFirst().map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ([mediaType] + parameters).joined(separator: ";")
    }

    private static func isSupportedContentType(_ value: String) -> Bool {
        value == "application/json" || value.hasPrefix("multipart/form-data;")
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() { case "https": return 443; case "http": return 80; default: return nil }
    }
}
