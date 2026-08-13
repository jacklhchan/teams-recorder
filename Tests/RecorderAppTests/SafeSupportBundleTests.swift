import Darwin
import Foundation
import XCTest
@testable import RecorderApp

final class SafeSupportBundleTests: XCTestCase {
    func testBundleUsesOnlyDocumentedSafeFieldsAndBoundsDiagnostics() throws {
        let diagnostic = RecordingDiagnosticRedactor.redact(.init(
            event: .storageFailure,
            component: .storage,
            stage: .publication,
            outcome: .failed,
            errorCode: .publicationFailure,
            httpStatus: 503,
            attemptCount: 2,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            artifactClass: .transcriptionFailureDiagnostic,
            byteCount: 42
        ))

        let bundle = SafeSupportBundle.make(
            build: .init(channel: .staging, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 347),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            diagnostics: Array(repeating: diagnostic, count: 101)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["schemaVersion", "generatedAt", "build", "diagnostics"])
        XCTAssertEqual((object["diagnostics"] as? [Any])?.count, 100)
        XCTAssertEqual(
            Set(try XCTUnwrap(object["build"] as? [String: Any]).keys),
            ["channel", "versionMajor", "versionMinor", "versionPatch", "buildNumber"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap((object["diagnostics"] as? [[String: Any]])?.first).keys),
            ["event", "schemaVersion", "component", "stage", "outcome", "errorCode", "httpStatus", "attemptCount", "timestamp", "artifactClass", "byteCount"]
        )
    }

    func testExportCreatesOwnerOnlyArtifact() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try SafeSupportBundleStore(rootDirectory: root).export(
            .make(build: .init(channel: .development, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 1))
        )

        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: url), 0o600)
        XCTAssertEqual(
            try JSONDecoder().decode(SafeSupportBundle.self, from: Data(contentsOf: url)).schemaVersion,
            SafeSupportBundle.schemaVersion
        )
    }

    func testExportFailsClosedForExistingNonOwnerOnlyDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertThrowsError(
            try SafeSupportBundleStore(rootDirectory: root).export(
                .make(build: .init(channel: .development, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 1))
            )
        ) { error in
            XCTAssertEqual(error as? SafeSupportBundleStoreError, .unsafeRootDirectory)
        }
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-support-bundle-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
