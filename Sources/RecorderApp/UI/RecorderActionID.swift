enum RecorderActionID {
    static let startStop = "recorder.action.start-stop"
    static let muteMic = "recorder.action.mute-mic"
    static let testAudio = "recorder.action.test-audio"
    static let uploadAudio = "recorder.action.upload-audio"
    static let refreshRecordings = "recorder.action.refresh-recordings"
    static let openTranscript = "recorder.action.open-transcript"
    static let saveTranscript = "recorder.action.save-transcript"
    static let captureRecovery = "recorder.action.capture-recovery"

    static let all = [
        startStop,
        muteMic,
        testAudio,
        uploadAudio,
        refreshRecordings,
        openTranscript,
        saveTranscript,
        captureRecovery
    ]
}
