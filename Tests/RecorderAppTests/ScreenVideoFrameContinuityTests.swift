import CoreMedia
import CoreVideo
import ScreenCaptureKit
import XCTest
@testable import RecorderApp

final class ScreenVideoFrameContinuityTests: XCTestCase {
    func testUnavailableFrameDeduplicationIsScopedToFilterRevision() {
        let oldRevision = CaptureFilterRevision(sessionGeneration: 1, revision: 1)
        let newRevision = CaptureFilterRevision(sessionGeneration: 1, revision: 2)
        var tracker = ScreenSourceUnavailableTracker()

        XCTAssertTrue(tracker.shouldEmitUnavailable(for: oldRevision))
        XCTAssertFalse(tracker.shouldEmitUnavailable(for: oldRevision))
        XCTAssertTrue(tracker.shouldEmitUnavailable(for: newRevision))

        tracker.markAvailable(for: oldRevision)
        XCTAssertFalse(tracker.shouldEmitUnavailable(for: newRevision))

        tracker.markAvailable(for: newRevision)
        XCTAssertTrue(tracker.shouldEmitUnavailable(for: newRevision))
    }

    func testNoncontentStatusesMarkTheScreenSourceUnavailable() {
        XCTAssertFalse(SCFrameStatus.complete.indicatesUnavailableScreenSource)
        XCTAssertFalse(SCFrameStatus.started.indicatesUnavailableScreenSource)
        XCTAssertFalse(SCFrameStatus.idle.indicatesUnavailableScreenSource)
        XCTAssertTrue(SCFrameStatus.blank.indicatesUnavailableScreenSource)
        XCTAssertTrue(SCFrameStatus.suspended.indicatesUnavailableScreenSource)
        XCTAssertTrue(SCFrameStatus.stopped.indicatesUnavailableScreenSource)
    }

    func testIdleFrameReusesTheLastSurfaceForTheSameRevision() throws {
        var continuity = ScreenVideoFrameContinuity()
        let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)

        let complete = continuity.makeFrame(
            status: .complete,
            pixelBuffer: surface,
            sourcePTS: CMTime(value: 0, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let idle = try XCTUnwrap(continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: CMTime(value: 1, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ))

        XCTAssertNotNil(complete)
        XCTAssertEqual(idle.status, .idle)
        XCTAssertTrue(idle.pixelBuffer === surface)
    }

    func testIdleFrameCannotReuseASurfaceFromAnotherRevision() throws {
        var continuity = ScreenVideoFrameContinuity()
        let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
        _ = continuity.makeFrame(
            status: .complete,
            pixelBuffer: surface,
            sourcePTS: CMTime(value: 0, timescale: 10),
            filterRevision: CaptureFilterRevision(sessionGeneration: 1, revision: 7),
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let idle = continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: CMTime(value: 1, timescale: 10),
            filterRevision: CaptureFilterRevision(sessionGeneration: 1, revision: 8),
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertNil(idle)
    }

    func testStartedFrameSeedsContinuityAsACompleteFrame() throws {
        var continuity = ScreenVideoFrameContinuity()
        let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)

        let started = try XCTUnwrap(continuity.makeFrame(
            status: .started,
            pixelBuffer: surface,
            sourcePTS: CMTime(value: 0, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ))
        let idle = continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: CMTime(value: 1, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertEqual(started.status, .complete)
        XCTAssertNotNil(idle)
    }

    func testNonContentStatusClearsTheRetainedSurface() throws {
        for status in [SCFrameStatus.blank, .suspended, .stopped] {
            var continuity = ScreenVideoFrameContinuity()
            let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
            let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)
            _ = continuity.makeFrame(
                status: .complete,
                pixelBuffer: surface,
                sourcePTS: .zero,
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )

            let terminal = continuity.makeFrame(
                status: status,
                pixelBuffer: nil,
                sourcePTS: .invalid,
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let idle = continuity.makeFrame(
                status: .idle,
                pixelBuffer: nil,
                sourcePTS: CMTime(value: 1, timescale: 10),
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )

            XCTAssertNil(terminal)
            XCTAssertNil(idle)
        }
    }

    func testMalformedCompleteFrameClearsTheRetainedSurface() throws {
        var continuity = ScreenVideoFrameContinuity()
        let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
        let wrongFormat = try VideoFrameSurface.makeBlack(format: .bgra).pixelBuffer
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)
        _ = continuity.makeFrame(
            status: .complete,
            pixelBuffer: surface,
            sourcePTS: .zero,
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let malformed = continuity.makeFrame(
            status: .complete,
            pixelBuffer: wrongFormat,
            sourcePTS: CMTime(value: 1, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let idle = continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: CMTime(value: 2, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertNil(malformed)
        XCTAssertNil(idle)
    }

    func testInvalidIdleTimestampIsRejectedWithoutDiscardingTheSurface() throws {
        var continuity = ScreenVideoFrameContinuity()
        let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
        let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)
        _ = continuity.makeFrame(
            status: .complete,
            pixelBuffer: surface,
            sourcePTS: .zero,
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        let invalid = continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: .invalid,
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let valid = continuity.makeFrame(
            status: .idle,
            pixelBuffer: nil,
            sourcePTS: CMTime(value: 1, timescale: 10),
            filterRevision: revision,
            expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )

        XCTAssertNil(invalid)
        XCTAssertNotNil(valid)
    }

    func testInvalidRenderableTimestampClearsTheRetainedSurface() throws {
        for status in [SCFrameStatus.complete, .started] {
            var continuity = ScreenVideoFrameContinuity()
            let surface = try VideoFrameSurface.makeBlack(format: .nv12).pixelBuffer
            let revision = CaptureFilterRevision(sessionGeneration: 1, revision: 7)
            _ = continuity.makeFrame(
                status: .complete,
                pixelBuffer: surface,
                sourcePTS: .zero,
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )

            let invalid = continuity.makeFrame(
                status: status,
                pixelBuffer: surface,
                sourcePTS: .invalid,
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
            let idle = continuity.makeFrame(
                status: .idle,
                pixelBuffer: nil,
                sourcePTS: CMTime(value: 1, timescale: 10),
                filterRevision: revision,
                expectedPixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )

            XCTAssertNil(invalid)
            XCTAssertNil(idle)
        }
    }
}
