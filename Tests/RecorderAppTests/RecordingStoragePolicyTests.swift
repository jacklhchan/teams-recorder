import Foundation
import XCTest
@testable import RecorderApp

final class RecordingStoragePolicyTests: XCTestCase {
    private let gibibyte: Int64 = 1_024 * 1_024 * 1_024
    private let mebibyte: Int64 = 1_024 * 1_024

    func testDecisionUsesExactBinaryBoundaries() {
        let policy = RecordingStoragePolicy()

        XCTAssertEqual(policy.decision(availableBytes: 5 * gibibyte), .normal)
        XCTAssertEqual(policy.decision(availableBytes: (5 * gibibyte) - 1), .warn)
        XCTAssertEqual(policy.decision(availableBytes: gibibyte), .warn)
        XCTAssertEqual(policy.decision(availableBytes: gibibyte - 1), .audioOnly)
        XCTAssertEqual(policy.decision(availableBytes: 256 * mebibyte), .audioOnly)
        XCTAssertEqual(policy.decision(availableBytes: (256 * mebibyte) - 1), .stop)
    }

    func testDecisionStopsForNegativeValuesAndRemainsNormalForVeryLargeValues() {
        let policy = RecordingStoragePolicy()

        XCTAssertEqual(policy.decision(availableBytes: -1), .stop)
        XCTAssertEqual(policy.decision(availableBytes: .max), .normal)
    }

    func testAudioStopThresholdIsInjectableForTests() {
        let policy = RecordingStoragePolicy(audioStopBytes: 42)

        XCTAssertEqual(policy.decision(availableBytes: 41), .stop)
        XCTAssertEqual(policy.decision(availableBytes: 42), .audioOnly)
    }

    func testSelectedVolumeProviderQueriesTheURLPassedByCaller() throws {
        let expectedURL = URL(fileURLWithPath: "/Volumes/External/Recordings", isDirectory: true)
        let provider = SelectedVolumeCapacityProvider(capacityLookup: { url in
            XCTAssertEqual(url, expectedURL)
            return 9 * 1_024 * 1_024 * 1_024
        })

        XCTAssertEqual(try provider.availableBytes(onVolumeContaining: expectedURL), 9 * gibibyte)
    }

    func testUnavailableCapacityThrowsInsteadOfBeingSilentlyTreatedAsStop() {
        let provider = SelectedVolumeCapacityProvider(capacityLookup: { _ in nil })

        XCTAssertThrowsError(try provider.availableBytes(onVolumeContaining: URL(fileURLWithPath: "/Volumes/Unavailable"))) { error in
            XCTAssertEqual(error as? RecordingStorageError, .capacityUnavailable)
        }
    }

    func testProviderPropagatesResourceValueErrorsInsteadOfReturningStopCapacity() {
        struct ExpectedError: Error {}
        let provider = SelectedVolumeCapacityProvider(capacityLookup: { _ in throw ExpectedError() })

        XCTAssertThrowsError(try provider.availableBytes(onVolumeContaining: URL(fileURLWithPath: "/Volumes/Offline"))) { error in
            XCTAssertTrue(error is ExpectedError)
        }
    }
}
