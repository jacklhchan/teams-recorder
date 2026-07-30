import XCTest
@testable import RecorderApp

final class RecorderActionIDTests: XCTestCase {
    func testExactAndUniqueIDs() {
        XCTAssertEqual(RecorderActionID.startStop, "recorder.action.start-stop")
        XCTAssertEqual(RecorderActionID.refreshCapture, "recorder.action.refresh-capture")
        XCTAssertEqual(RecorderActionID.muteMic, "recorder.action.mute-mic")
        XCTAssertEqual(RecorderActionID.testAudio, "recorder.action.test-audio")
        XCTAssertEqual(RecorderActionID.moreRecordActions, "recorder.action.more-record-actions")
        XCTAssertEqual(
            RecorderActionID.chooseOutputFolder,
            "recorder.action.choose-output-folder"
        )
        XCTAssertEqual(
            RecorderActionID.openOutputFolder,
            "recorder.action.open-output-folder"
        )
        XCTAssertEqual(RecorderActionID.uploadAudio, "recorder.action.upload-audio")
        XCTAssertEqual(RecorderActionID.refreshRecordings, "recorder.action.refresh-recordings")
        XCTAssertEqual(RecorderActionID.openTranscript, "recorder.action.open-transcript")
        XCTAssertEqual(RecorderActionID.saveTranscript, "recorder.action.save-transcript")
        XCTAssertEqual(RecorderActionID.captureRecovery, "recorder.action.capture-recovery")
        XCTAssertEqual(Set(RecorderActionID.all).count, RecorderActionID.all.count)
    }
}
