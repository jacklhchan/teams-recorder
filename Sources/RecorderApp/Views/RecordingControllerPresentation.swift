import Foundation

enum RecordingControllerTone: Equatable {
    case neutral
    case ready
    case recording
    case warning
}

struct RecordingControllerSnapshot: Equatable {
    let isRecording: Bool
    let isFinalizing: Bool
    let startedAt: Date?
    let showsTeamsScreenControl: Bool
    let screenRequested: Bool
    let screenStatusText: String
    let screenToggleDisabled: Bool
}

struct RecordingControllerPresentation: Equatable {
    let isVisible: Bool
    let title: String
    let elapsedText: String
    let screenStatusText: String
    let screenTone: RecordingControllerTone
    let screenRequested: Bool
    let screenToggleDisabled: Bool
    let stopDisabled: Bool

    static func make(
        snapshot: RecordingControllerSnapshot,
        now: Date
    ) -> RecordingControllerPresentation {
        let statusText = snapshot.showsTeamsScreenControl
            ? snapshot.screenStatusText
            : "Teams screen unavailable"
        return RecordingControllerPresentation(
            isVisible: snapshot.isRecording,
            title: snapshot.isFinalizing ? "Finalizing" : "Recording",
            elapsedText: elapsedText(startedAt: snapshot.startedAt, now: now),
            screenStatusText: statusText,
            screenTone: tone(
                statusText: statusText,
                showsTeamsScreenControl: snapshot.showsTeamsScreenControl
            ),
            screenRequested: snapshot.screenRequested,
            screenToggleDisabled: snapshot.showsTeamsScreenControl
                ? snapshot.screenToggleDisabled
                : true,
            stopDisabled: snapshot.isFinalizing
        )
    }

    private static func elapsedText(startedAt: Date?, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(startedAt ?? now)))
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
    }

    private static func tone(
        statusText: String,
        showsTeamsScreenControl: Bool
    ) -> RecordingControllerTone {
        guard showsTeamsScreenControl else { return .warning }
        switch statusText {
        case TeamsScreenStatusText.off:
            return .neutral
        case TeamsScreenStatusText.ready:
            return .ready
        case TeamsScreenStatusText.capturing:
            return .recording
        default:
            return .warning
        }
    }
}
