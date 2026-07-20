import Foundation
import XCTest
@testable import RecorderApp

final class ReleaseManifestTests: XCTestCase {
    func testBundledManifestPinsOfficialDependenciesAndModelRevision() throws {
        let manifest = try ReleaseManifest.bundled()
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.model.repository, "mlx-community/Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(manifest.model.revision, "78a389c776a5483b2d0d4ea5494e11012e0d6159")
        XCTAssertEqual(manifest.model.expectedOMLXIdentifier, "mlx-community--Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(manifest.omlx.version, "0.5.1")
        XCTAssertEqual(manifest.blackHole.version, "0.7.1")
    }

    func testManifestRejectsUnpinnedOrNonHTTPSSources() throws {
        var manifest = ReleaseManifest.fixture
        manifest.omlx.sourceURL = URL(string: "http://example.com/latest.dmg")!
        XCTAssertThrowsError(try manifest.validate())
    }
}

private extension ReleaseManifest {
    static var fixture: ReleaseManifest {
        ReleaseManifest(
            blackHole: .init(name: "BlackHole", version: "0.7.1", sourceURL: URL(string: "https://github.com/ExistentialAudio/BlackHole/releases/tag/v0.7.1")!, sha256: nil),
            omlx: .init(name: "oMLX", version: "0.5.1", sourceURL: URL(string: "https://github.com/jundot/omlx/releases/tag/v0.5.1")!, sha256: nil),
            model: .init(repository: "mlx-community/Qwen3-ASR-1.7B-4bit", revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159", expectedOMLXIdentifier: "mlx-community--Qwen3-ASR-1.7B-4bit", estimatedBytes: 1_728_724_336)
        )
    }
}
