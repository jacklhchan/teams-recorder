import CoreVideo
import XCTest
@testable import RecorderApp

final class ScreenCaptureVideoRoutingTests: XCTestCase {
    func testProductionScreenConfigurationIsFixedStorageProfile() {
        let source = ScreenCaptureSource()

        XCTAssertEqual(source.screenVideoFormat.width, 1_600)
        XCTAssertEqual(source.screenVideoFormat.height, 900)
        XCTAssertEqual(
            source.screenVideoFormat.pixelFormat,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testFilterAndFrameCadenceCommitAsOneRevision() {
        var coordinator = CaptureFilterCoordinator()
        let enabled = CaptureStreamIntent(
            filter: .teamsWindow(.init(processID: 7, windowID: 9)),
            cadence: .enabled
        )

        let update = coordinator.request(enabled)
        XCTAssertEqual(update?.intent.cadence, .enabled)
        XCTAssertNil(coordinator.complete(update!, result: .success(())))
    }

    func testVideoFailureDoesNotUseAudioDisconnectEvent() {
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .screenCaptureFailed),
            .warning("Screen frame capture unavailable")
        )
        XCTAssertEqual(
            CaptureStatusMapper.status(for: .screenTargetLost),
            .warning("Teams screen target was closed")
        )
    }
}
