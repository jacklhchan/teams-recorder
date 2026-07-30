import AVKit
import SwiftUI

struct RecordingPlaybackView: View {
    let session: RecordingSession
    let player: AVPlayer
    let progress: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let togglePlayback: () -> Void
    let stopPlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.screenIntervals.isEmpty {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(
                        minWidth: 520,
                        maxWidth: .infinity,
                        minHeight: 292
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 10) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.bordered)
                .help(isPlaying ? "Pause playback" : "Play recording")
                .accessibilityLabel(isPlaying ? "Pause playback" : "Play recording")

                Button(action: stopPlayback) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .help("Stop playback")
                .accessibilityLabel("Stop playback")

                Text(timeText(progress))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { min(max(progress, 0), max(duration, 1)) },
                        set: seekPlayback
                    ),
                    in: 0...max(duration, 1)
                )
                .accessibilityLabel("Playback position")

                Text(timeText(duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "00:00" }
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
