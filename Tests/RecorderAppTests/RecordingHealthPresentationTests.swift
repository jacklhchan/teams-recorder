import XCTest
@testable import RecorderApp

final class RecordingHealthPresentationTests: XCTestCase {
    func testNilReportIsUnavailableWithStableEmptyCopy() {
        let presentation = RecordingHealthPresentation.make(report: nil)

        XCTAssertEqual(presentation.status, .unavailable)
        XCTAssertEqual(presentation.title, "Recording Health")
        XCTAssertNil(presentation.systemAudioText)
        XCTAssertNil(presentation.microphoneText)
        XCTAssertEqual(presentation.counters, [])
    }

    func testHealthyReportProjectsGoodStatusAndNoCounterRows() {
        let presentation = RecordingHealthPresentation.make(report: .init(
            systemSignalSeen: true,
            micSignalSeen: true
        ))

        XCTAssertEqual(presentation.status, .good)
        XCTAssertEqual(presentation.title, "Capture looks good")
        XCTAssertEqual(presentation.systemAudioText, "System audio captured")
        XCTAssertEqual(presentation.microphoneText, "Mic captured")
        XCTAssertEqual(presentation.counters, [])
    }

    func testMissingSignalsAndNonzeroCountersProjectInSourceOrder() {
        let presentation = RecordingHealthPresentation.make(report: .init(
            clippingEvents: 1,
            droppedBuffers: 2,
            videoDroppedFrames: 3,
            metadataWriteFailures: 4
        ))

        XCTAssertEqual(presentation.status, .attention)
        XCTAssertEqual(presentation.title, "Capture needs attention")
        XCTAssertEqual(presentation.systemAudioText, "No system audio")
        XCTAssertEqual(presentation.microphoneText, "No mic signal")
        XCTAssertEqual(
            presentation.counters,
            [
                .init(identifier: "clipping-events", label: "clipping events", count: 1),
                .init(identifier: "dropped-buffers", label: "dropped buffers", count: 2),
                .init(identifier: "video-dropped-frames", label: "video frames dropped", count: 3),
                .init(identifier: "metadata-write-failures", label: "metadata write failures", count: 4)
            ]
        )
    }
}
