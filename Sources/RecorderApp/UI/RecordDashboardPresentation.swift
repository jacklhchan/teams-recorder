import Foundation

struct RecordDashboardPresentation: Equatable {
    let elapsedText: String
    let startStopDisabled: Bool
    let testDisabled: Bool
    let muteDisabled: Bool

    static let operationalProbeIDs = [
        "record-state",
        "elapsed-time",
        RecorderActionID.startStop,
        "system-meter",
        "microphone-meter",
        "capture-health"
    ]

    static func make(
        isRecording: Bool,
        startedAt: Date?,
        now: Date,
        isCaptureLifecycleWorking: Bool,
        isRunningTestRecording: Bool,
        localMicMuted: Bool,
        nativeInputMicMuted: Bool,
        teamsMicMuted: Bool
    ) -> Self {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        return .init(
            elapsedText: String(
                format: "%02d:%02d:%02d",
                seconds / 3_600,
                (seconds / 60) % 60,
                seconds % 60
            ),
            startStopDisabled: !isRecording && isCaptureLifecycleWorking,
            testDisabled: isRecording || isRunningTestRecording || isCaptureLifecycleWorking,
            muteDisabled: (teamsMicMuted || nativeInputMicMuted) && !localMicMuted
        )
    }
}

struct RecordDashboardMeterPresentation: Equatable {
    let waveformSamples: [Float]

    static func make(level: LevelSnapshot) -> Self {
        .init(waveformSamples: level.samples)
    }
}
