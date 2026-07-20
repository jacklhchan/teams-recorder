import Foundation

struct ReleaseManifest: Codable, Sendable {
    struct Dependency: Codable, Sendable {
        let name: String
        let version: String
        var sourceURL: URL
        let sha256: String?
    }

    struct Model: Codable, Sendable {
        let repository: String
        let revision: String
        let expectedOMLXIdentifier: String
        let estimatedBytes: Int64
    }

    var blackHole: Dependency
    var omlx: Dependency
    let model: Model

    static func load(from url: URL) throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: url))
    }

    static func bundled() throws -> ReleaseManifest {
        guard let url = Bundle.module.url(forResource: "release-manifest", withExtension: "json") else {
            throw ManifestError.missingBundledManifest
        }
        return try load(from: url)
    }

    func validate() throws {
        for dependency in [blackHole, omlx] {
            guard dependency.sourceURL.scheme == "https",
                  !dependency.sourceURL.absoluteString.localizedCaseInsensitiveContains("latest") else {
                throw ManifestError.unpinnedSource(dependency.name)
            }
            if let sha256 = dependency.sha256,
               sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
                throw ManifestError.invalidHash(dependency.name)
            }
        }
        guard model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ManifestError.invalidRevision
        }
    }
}

enum ManifestError: LocalizedError {
    case missingBundledManifest
    case unpinnedSource(String)
    case invalidHash(String)
    case invalidRevision
}
