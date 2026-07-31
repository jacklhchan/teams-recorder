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
        XCTAssertEqual(
            RecorderActionID.filterFavorites,
            "recorder.action.filter-favorites"
        )
        XCTAssertEqual(RecorderActionID.openTranscript, "recorder.action.open-transcript")
        XCTAssertEqual(RecorderActionID.saveTranscript, "recorder.action.save-transcript")
        XCTAssertEqual(RecorderActionID.captureRecovery, "recorder.action.capture-recovery")
        XCTAssertEqual(RecorderActionID.providerKind, "recorder.provider.kind")
        XCTAssertEqual(RecorderActionID.providerHKTGroupID, "recorder.provider.hkt-group-id")
        XCTAssertEqual(RecorderActionID.providerHKTResolvedURL, "recorder.provider.hkt-resolved-url")
        XCTAssertEqual(RecorderActionID.providerBaseURL, "recorder.provider.base-url")
        XCTAssertEqual(RecorderActionID.providerAPIKey, "recorder.provider.api-key")
        XCTAssertEqual(RecorderActionID.providerASRModel, "recorder.provider.asr-model")
        XCTAssertEqual(RecorderActionID.providerLLMModel, "recorder.provider.llm-model")
        XCTAssertEqual(RecorderActionID.providerLanguage, "recorder.provider.language")
        XCTAssertEqual(RecorderActionID.providerPrompt, "recorder.provider.prompt")
        XCTAssertEqual(RecorderActionID.providerSave, "recorder.provider.save")
        XCTAssertEqual(RecorderActionID.providerTest, "recorder.provider.test")
        XCTAssertEqual(RecorderActionID.providerRemoveKey, "recorder.provider.remove-key")
        XCTAssertEqual(RecorderActionID.providerStatus, "recorder.provider.status")
        XCTAssertEqual(Set(RecorderActionID.all).count, RecorderActionID.all.count)
    }
}
