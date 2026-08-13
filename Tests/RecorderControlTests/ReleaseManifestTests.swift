import CryptoKit
import XCTest
@testable import RecorderControl

final class ReleaseManifestTests: XCTestCase {
    private let seed = Data(0..<32)
    private let zip = Data("test-only zip bytes".utf8)

    private func manifest(build: String = "456", floor: String = "456") throws -> ReleaseManifest {
        try ReleaseManifest(
            version: "1.2.3", build: build, minimumAcceptedBuild: floor,
            keyID: "test-key", provenanceID: "github-actions:owner/repo@1234567890abcdef1234567890abcdef12345678:run-123",
            zipFilename: "Local-Meeting-Recorder-1.2.3-\(build).zip", zipData: zip
        )
    }

    func testCanonicalV1RoundTripAndDetachedSignature() throws {
        let manifest = try manifest()
        let bytes = try manifest.canonicalData()
        let signature = try ReleaseManifest.sign(bytes, privateKeySeed: seed)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let keyring = ReleaseManifestKeyring(entries: [.init(keyID: "test-key", publicKeyBase64: publicKey.base64EncodedString(), minimumAcceptedBuild: "1", status: .active)])

        XCTAssertEqual(try ReleaseManifest.decodeCanonical(bytes), manifest)
        XCTAssertNoThrow(try ReleaseManifest.verify(manifestData: bytes, signature: signature, zipData: zip, keyring: keyring, minimumBuild: "456"))
        for bad in [Data(" {\n".utf8) + bytes, Data("{\"build\":\"456\",\"build\":\"456\"}".utf8)] {
            XCTAssertThrowsError(try ReleaseManifest.decodeCanonical(bad)) { XCTAssertEqual($0 as? ReleaseManifestError, .malformed) }
        }
    }

    func testVerifierRejectsTamperedManifestSignatureAndZipDigest() throws {
        let value = try manifest(); let bytes = try value.canonicalData(); let signature = try ReleaseManifest.sign(bytes, privateKeySeed: seed)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let keyring = ReleaseManifestKeyring(entries: [.init(keyID: "test-key", publicKeyBase64: publicKey.base64EncodedString(), minimumAcceptedBuild: "1", status: .active)])
        var alteredSignature = signature; alteredSignature[0] ^= 1
        XCTAssertThrowsError(try ReleaseManifest.verify(manifestData: bytes, signature: alteredSignature, zipData: zip, keyring: keyring, minimumBuild: "1")) { XCTAssertEqual($0 as? ReleaseManifestError, .invalidSignatureOrDigest) }
        XCTAssertThrowsError(try ReleaseManifest.verify(manifestData: bytes, signature: signature, zipData: Data("changed".utf8), keyring: keyring, minimumBuild: "1")) { XCTAssertEqual($0 as? ReleaseManifestError, .invalidSignatureOrDigest) }
    }

    func testVerifierRejectsUnknownSchemaUnknownOrRetiredKey() throws {
        let value = try manifest(); let bytes = try value.canonicalData(); let signature = try ReleaseManifest.sign(bytes, privateKeySeed: seed)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        XCTAssertThrowsError(try ReleaseManifest.decodeCanonical(Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8))) { XCTAssertEqual($0 as? ReleaseManifestError, .unsupported) }
        for status in [ReleaseManifestKeyStatus.retired] {
            let ring = ReleaseManifestKeyring(entries: [.init(keyID: "test-key", publicKeyBase64: publicKey.base64EncodedString(), minimumAcceptedBuild: "1", status: status)])
            XCTAssertThrowsError(try ReleaseManifest.verify(manifestData: bytes, signature: signature, zipData: zip, keyring: ring, minimumBuild: "1")) { XCTAssertEqual($0 as? ReleaseManifestError, .unsupported) }
        }
    }

    func testVerifierRejectsRollbackAgainstManifestKeyRingAndCallerFloors() throws {
        let value = try manifest(build: "999999999999999999999999", floor: "999999999999999999999998")
        let bytes = try value.canonicalData(); let signature = try ReleaseManifest.sign(bytes, privateKeySeed: seed)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
        let ring = ReleaseManifestKeyring(entries: [.init(keyID: "test-key", publicKeyBase64: publicKey.base64EncodedString(), minimumAcceptedBuild: "999999999999999999999999", status: .active)])
        XCTAssertThrowsError(try ReleaseManifest.verify(manifestData: bytes, signature: signature, zipData: zip, keyring: ring, minimumBuild: "1000000000000000000000000")) { XCTAssertEqual($0 as? ReleaseManifestError, .rollback) }
    }
}
