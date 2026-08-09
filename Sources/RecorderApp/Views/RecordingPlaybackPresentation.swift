import CoreGraphics
import Foundation

struct RecordingPlaybackPresentation: Equatable {
    let title: String
    let detailText: String
    let elapsedText: String
    let remainingText: String
    let totalText: String
    let skipBackwardTarget: TimeInterval
    let skipForwardTarget: TimeInterval
    let mediaLabel: String
    let sourceLabel: String
    let recoveryLabel: String?
    let defaultContentSize: CGSize
    let minimumContentSize: CGSize

    static func make(
        session: RecordingSession,
        progress: TimeInterval,
        duration: TimeInterval
    ) -> Self {
        let safeDuration = duration.isFinite ? max(duration, 0) : 0
        let safeProgress = progress.isFinite
            ? min(max(progress, 0), safeDuration)
            : 0
        let includesHours = safeDuration >= 3_600
        let totalText = timeText(safeDuration, includesHours: includesHours)
        let isVideo = session.mediaKind == .video

        return Self(
            title: session.displayName,
            detailText: [
                session.createdAt.formatted(date: .abbreviated, time: .shortened),
                totalText,
                session.recordingURL.lastPathComponent
            ].joined(separator: " · "),
            elapsedText: timeText(safeProgress, includesHours: includesHours),
            remainingText: "-" + timeText(
                safeDuration - safeProgress,
                includesHours: includesHours
            ),
            totalText: totalText,
            skipBackwardTarget: max(safeProgress - 15, 0),
            skipForwardTarget: min(safeProgress + 15, safeDuration),
            mediaLabel: isVideo ? "Video" : "Audio only",
            sourceLabel: sourceLabel(session.metadata.source),
            recoveryLabel: recoveryLabel(session.recoveryState),
            defaultContentSize: isVideo
                ? CGSize(width: 980, height: 720)
                : CGSize(width: 720, height: 360),
            minimumContentSize: isVideo
                ? CGSize(width: 680, height: 520)
                : CGSize(width: 600, height: 300)
        )
    }

    private static func timeText(
        _ time: TimeInterval,
        includesHours: Bool
    ) -> String {
        let seconds = max(0, Int(time.rounded()))
        if includesHours {
            return String(
                format: "%02d:%02d:%02d",
                seconds / 3_600,
                seconds / 60 % 60,
                seconds % 60
            )
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func sourceLabel(_ source: RecordingSource) -> String {
        switch source {
        case .manual:
            "Manual"
        case .teamsAutomatic:
            "Teams automatic"
        case .imported:
            "Imported"
        }
    }

    private static func recoveryLabel(
        _ recoveryState: RecordingRecoveryState
    ) -> String? {
        switch recoveryState {
        case .none:
            nil
        case .videoLostAudioPreserved:
            "Video lost; audio preserved"
        case .recoveredAfterInterruption:
            "Recovered after interruption"
        }
    }
}
