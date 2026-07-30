struct RecordToolbarPresentation: Equatable {
    let refreshDisabled: Bool
    let muteDisabled: Bool
    let testDisabled: Bool
    let chooseOutputFolderDisabled: Bool

    static func make(
        sourceControlsEnabled: Bool,
        isRecording: Bool,
        dashboard: RecordDashboardPresentation
    ) -> Self {
        .init(
            refreshDisabled: !sourceControlsEnabled,
            muteDisabled: dashboard.muteDisabled,
            testDisabled: dashboard.testDisabled,
            chooseOutputFolderDisabled: isRecording
        )
    }
}

struct RecordingsToolbarPresentation: Equatable {
    let uploadDisabled: Bool

    static func make(isTranscribing: Bool) -> Self {
        .init(uploadDisabled: isTranscribing)
    }
}
