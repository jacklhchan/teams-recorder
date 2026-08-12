import Foundation
import XCTest
@testable import RecorderApp

final class RecordingDiagnosticRedactorTests: XCTestCase {
    func testRedactorKeepsOnlyTypedAllowlistedFields() throws {
        let diagnostic = RecordingDiagnosticRedactor.redact(
            .init(
                event: .transcriptionFailure,
                component: .transcription,
                stage: .upload,
                outcome: .failed,
                errorCode: .providerHTTPFailure,
                httpStatus: 429,
                attemptCount: 2,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                artifactClass: .transcriptionLog,
                byteCount: 1_024
            )
        )

        let object = try jsonObject(diagnostic)

        XCTAssertEqual(Set(object.keys), [
            "event", "schemaVersion", "component", "stage", "outcome",
            "errorCode", "httpStatus", "attemptCount", "timestamp",
            "artifactClass", "byteCount"
        ])
        XCTAssertEqual(object["httpStatus"] as? Int, 429)
        XCTAssertEqual(object["attemptCount"] as? Int, 2)
        XCTAssertEqual(object["byteCount"] as? Int, 1_024)
        XCTAssertEqual(object["timestamp"] as? String, "2023-11-14T22:13:20Z")
    }

    func testRedactorDropsOutOfRangeOptionalValues() throws {
        let diagnostic = RecordingDiagnosticRedactor.redact(
            .init(
                event: .transcriptionFailure,
                component: .transcription,
                stage: .publication,
                outcome: .failed,
                errorCode: .unknown,
                httpStatus: 99,
                attemptCount: -1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                artifactClass: .transcriptionFailureDiagnostic,
                byteCount: -1
            )
        )

        let object = try jsonObject(diagnostic)

        XCTAssertNil(object["httpStatus"])
        XCTAssertEqual(object["attemptCount"] as? Int, 0)
        XCTAssertEqual(object["byteCount"] as? Int, 0)
    }

    func testEncodedDiagnosticSchemaHasNoUnstructuredStringOrBinaryFields() throws {
        let diagnostic = RecordingDiagnosticRedactor.redact(
            .init(
                event: .transcriptionFailure,
                component: .transcription,
                stage: .upload,
                outcome: .failed,
                errorCode: .unknown,
                httpStatus: nil,
                attemptCount: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                artifactClass: .transcriptionLog,
                byteCount: 0
            )
        )

        let mirror = Mirror(reflecting: diagnostic)
        let labels = Set(mirror.children.compactMap(\.label))
        XCTAssertEqual(labels, [
            "event", "schemaVersion", "component", "stage", "outcome",
            "errorCode", "httpStatus", "attemptCount", "timestamp",
            "artifactClass", "byteCount"
        ])
        XCTAssertFalse(mirror.children.contains { child in
            child.value is Data || child.value is URL || child.value is Error
        })
    }

    private func jsonObject(_ diagnostic: SafeRecordingDiagnostic) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any]
        )
    }
}
