import Darwin
import Foundation
import XCTest
@testable import RecorderApp

final class SafeSupportBundleTests: XCTestCase {
    func testProductionBundleTypeHasNoUnsafeDecodingOrMemberwiseConstructionSeam() throws {
        let source = try String(
            contentsOf: sourceRoot()
                .appendingPathComponent("Sources/RecorderApp/Storage/SafeSupportBundle.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Codable"))
        XCTAssertFalse(source.contains("Decodable"))
        XCTAssertTrue(source.contains("private init("))
        XCTAssertTrue(source.contains("static func make("))
    }

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
            build: .make(channel: .staging, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 347),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            diagnostics: Array(repeating: diagnostic, count: 101)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["schemaVersion", "generatedAt", "build", "diagnostics"])
        XCTAssertEqual(object["schemaVersion"] as? Int, SafeSupportBundle.schemaVersion)
        XCTAssertEqual(object["generatedAt"] as? String, "2023-11-14T22:13:21Z")
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
            .make(build: .make(channel: .development, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 1))
        )

        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: url), 0o600)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, SafeSupportBundle.schemaVersion)
    }

    func testExportFailsClosedForExistingNonOwnerOnlyDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertThrowsError(
            try SafeSupportBundleStore(rootDirectory: root).export(
                .make(build: .make(channel: .development, versionMajor: 0, versionMinor: 2, versionPatch: 0, buildNumber: 1))
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

    private func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
