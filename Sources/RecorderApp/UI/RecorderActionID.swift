enum RecorderActionID {
    static let startStop = "recorder.action.start-stop"
    static let refreshCapture = "recorder.action.refresh-capture"
    static let muteMic = "recorder.action.mute-mic"
    static let testAudio = "recorder.action.test-audio"
    static let moreRecordActions = "recorder.action.more-record-actions"
    static let chooseOutputFolder = "recorder.action.choose-output-folder"
    static let openOutputFolder = "recorder.action.open-output-folder"
    static let uploadAudio = "recorder.action.upload-audio"
    static let refreshRecordings = "recorder.action.refresh-recordings"
    static let filterFavorites = "recorder.action.filter-favorites"
    static let openTranscript = "recorder.action.open-transcript"
    static let saveTranscript = "recorder.action.save-transcript"
    static let captureRecovery = "recorder.action.capture-recovery"
    static let providerKind = "recorder.provider.kind"
    static let providerHKTGroupID = "recorder.provider.hkt-group-id"
    static let providerHKTResolvedURL = "recorder.provider.hkt-resolved-url"
    static let providerBaseURL = "recorder.provider.base-url"
    static let providerAPIKey = "recorder.provider.api-key"
    static let providerASRModel = "recorder.provider.asr-model"
    static let providerLLMModel = "recorder.provider.llm-model"
    static let providerLanguage = "recorder.provider.language"
    static let providerPrompt = "recorder.provider.prompt"
    static let providerSave = "recorder.provider.save"
    static let providerTest = "recorder.provider.test"
    static let providerRemoveKey = "recorder.provider.remove-key"
    static let providerStatus = "recorder.provider.status"
    static let meetingIntelligenceCard = "recorder.meeting-intelligence.card"
    static let meetingIntelligenceStatus = "recorder.meeting-intelligence.status"
    static let meetingIntelligenceSummary = "recorder.meeting-intelligence.summary"
    static let meetingIntelligenceGenerate = "recorder.meeting-intelligence.generate"
    static let meetingIntelligenceRegenerate = "recorder.meeting-intelligence.regenerate"
    static let meetingIntelligenceCancel = "recorder.meeting-intelligence.cancel"
    static let meetingIntelligenceCheckAgain = "recorder.meeting-intelligence.check-again"
    static let meetingIntelligenceRetryGeneration = "recorder.meeting-intelligence.retry-generation"
    static let meetingIntelligenceSuggestedTitle = "recorder.meeting-intelligence.suggested-title"
    static let meetingIntelligenceApplyTitle = "recorder.meeting-intelligence.apply-title"
    static let meetingIntelligenceManualTitleProtection = "recorder.meeting-intelligence.manual-title-protection"

    static let all = [
        startStop,
        refreshCapture,
        muteMic,
        testAudio,
        moreRecordActions,
        chooseOutputFolder,
        openOutputFolder,
        uploadAudio,
        refreshRecordings,
        filterFavorites,
        openTranscript,
        saveTranscript,
        captureRecovery,
        providerKind,
        providerHKTGroupID,
        providerHKTResolvedURL,
        providerBaseURL,
        providerAPIKey,
        providerASRModel,
        providerLLMModel,
        providerLanguage,
        providerPrompt,
        providerSave,
        providerTest,
        providerRemoveKey,
        providerStatus,
        meetingIntelligenceCard,
        meetingIntelligenceStatus,
        meetingIntelligenceSummary,
        meetingIntelligenceGenerate,
        meetingIntelligenceRegenerate,
        meetingIntelligenceCancel,
        meetingIntelligenceCheckAgain,
        meetingIntelligenceRetryGeneration,
        meetingIntelligenceSuggestedTitle,
        meetingIntelligenceApplyTitle,
        meetingIntelligenceManualTitleProtection
    ]
}
