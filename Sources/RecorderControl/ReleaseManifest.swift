import CryptoKit
import Foundation

public enum ReleaseManifestError: Int, Error, Equatable, Sendable { case malformed = 65, unsafeFile = 66, unsupported = 67, invalidSignatureOrDigest = 68, rollback = 69, execution = 70 }
public enum ReleaseManifestKeyStatus: String, Codable, Sendable { case active, retired }

public struct ReleaseManifestKey: Codable, Equatable, Sendable {
    public let keyID: String; public let publicKeyBase64: String; public let minimumAcceptedBuild: String; public let status: ReleaseManifestKeyStatus
    public init(keyID: String, publicKeyBase64: String, minimumAcceptedBuild: String, status: ReleaseManifestKeyStatus) { self.keyID = keyID; self.publicKeyBase64 = publicKeyBase64; self.minimumAcceptedBuild = minimumAcceptedBuild; self.status = status }
}
public struct ReleaseManifestKeyring: Codable, Equatable, Sendable {
    public let schemaVersion: Int; public let entries: [ReleaseManifestKey]
    public init(schemaVersion: Int = 1, entries: [ReleaseManifestKey]) { self.schemaVersion = schemaVersion; self.entries = entries }
    func activeKey(_ id: String) throws -> ReleaseManifestKey { guard schemaVersion == 1, let key = entries.first(where: { $0.keyID == id }), key.status == .active, ReleaseManifest.validDecimal(key.minimumAcceptedBuild), ReleaseManifest.validToken(key.keyID), Data(base64Encoded: key.publicKeyBase64)?.count == 32 else { throw ReleaseManifestError.unsupported }; return key }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Artifact: Codable, Equatable, Sendable { public let sha256: String; public let zipFilename: String }
    public let artifact: Artifact; public let build: String; public let keyID: String; public let minimumAcceptedBuild: String; public let provenanceID: String; public let schemaVersion: Int; public let version: String
    public init(version: String, build: String, minimumAcceptedBuild: String, keyID: String, provenanceID: String, zipFilename: String, zipData: Data) throws { self.artifact = Artifact(sha256: Self.digest(zipData), zipFilename: zipFilename); self.build = build; self.keyID = keyID; self.minimumAcceptedBuild = minimumAcceptedBuild; self.provenanceID = provenanceID; self.schemaVersion = 1; self.version = version; try validate() }
    public func canonicalData() throws -> Data { try validate(); return Data("{\"artifact\":{\"sha256\":\"\(artifact.sha256)\",\"zipFilename\":\"\(artifact.zipFilename)\"},\"build\":\"\(build)\",\"keyID\":\"\(keyID)\",\"minimumAcceptedBuild\":\"\(minimumAcceptedBuild)\",\"provenanceID\":\"\(provenanceID)\",\"schemaVersion\":1,\"version\":\"\(version)\"}\n".utf8) }
    public static func decodeCanonical(_ data: Data) throws -> ReleaseManifest { guard let value = try? JSONDecoder().decode(ReleaseManifest.self, from: data) else { throw ReleaseManifestError.malformed }; guard value.schemaVersion == 1 else { throw ReleaseManifestError.unsupported }; guard try value.canonicalData() == data else { throw ReleaseManifestError.malformed }; return value }
    public static func sign(_ data: Data, privateKeySeed: Data) throws -> Data { guard privateKeySeed.count == 32 else { throw ReleaseManifestError.malformed }; return try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeySeed).signature(for: data) }
    public static func verify(manifestData: Data, signature: Data, zipData: Data, keyring: ReleaseManifestKeyring, minimumBuild: String) throws { let manifest = try decodeCanonical(manifestData); let key = try keyring.activeKey(manifest.keyID); guard validDecimal(minimumBuild), signature.count == 64, let keyData = Data(base64Encoded: key.publicKeyBase64) else { throw ReleaseManifestError.invalidSignatureOrDigest }; let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData); guard publicKey.isValidSignature(signature, for: manifestData), digest(zipData) == manifest.artifact.sha256 else { throw ReleaseManifestError.invalidSignatureOrDigest }; let floor = [manifest.minimumAcceptedBuild, key.minimumAcceptedBuild, minimumBuild].max { compareDecimal($0, $1) < 0 }!; guard compareDecimal(manifest.build, floor) >= 0 else { throw ReleaseManifestError.rollback } }
    static func validToken(_ value: String) -> Bool { !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 && $0 != "\\" } }
    static func validDecimal(_ value: String) -> Bool { value.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil }
    static func compareDecimal(_ lhs: String, _ rhs: String) -> Int { lhs.count == rhs.count ? (lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)) : (lhs.count < rhs.count ? -1 : 1) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func validate() throws { guard schemaVersion == 1 else { throw ReleaseManifestError.unsupported }; guard version.range(of: "^[0-9]+(\\.[0-9]+){1,2}$", options: .regularExpression) != nil, Self.validDecimal(build), Self.validDecimal(minimumAcceptedBuild), Self.compareDecimal(minimumAcceptedBuild, build) <= 0, Self.validToken(keyID), Self.validToken(provenanceID), Self.validToken(artifact.zipFilename), artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, artifact.zipFilename == "Local-Meeting-Recorder-\(version)-\(build).zip" else { throw ReleaseManifestError.malformed } }
}
