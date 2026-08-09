import AVKit
import SwiftUI

struct RecordingPlaybackView: View {
    let session: RecordingSession
    let player: AVPlayer
    let progress: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let togglePlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void
    let revealRecording: () -> Void
    let setVolume: (Float) -> Void
    let setRate: (Float) -> Void

    @State private var volume = 1.0
    @State private var selectedRate: Float = 1

    private var presentation: RecordingPlaybackPresentation {
        .make(session: session, progress: progress, duration: duration)
    }

    var body: some View {
        VStack(spacing: 16) {
            metadataHeader
            mediaStage
            timeline
            transportControls
            metadataChips
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("recorder.playback.root")
        .overlay {
            keyboardShortcuts
        }
    }

    private var metadataHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("recorder.playback.title")
                Text(presentation.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("recorder.playback.details")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: revealRecording) {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .help("Reveal this recording in Finder")
            .accessibilityLabel("Show recording in Finder")
            .accessibilityIdentifier("recorder.playback.reveal")
        }
        .accessibilityIdentifier("recorder.playback.header")
    }

    @ViewBuilder
    private var mediaStage: some View {
        if session.mediaKind == .video {
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(transportOverlay)
                .accessibilityLabel("Video recording")
                .accessibilityIdentifier("recorder.playback.stage")
                .layoutPriority(1)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.secondary.opacity(0.10))
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                transportOverlay
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 72, idealHeight: 108, maxHeight: 132)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio-only recording")
            .accessibilityIdentifier("recorder.playback.stage")
        }
    }

    private var transportOverlay: some View {
        HStack(spacing: 14) {
            transportButton(
                systemImage: "gobackward.15",
                label: "Skip back 15 seconds",
                identifier: "recorder.playback.skipBackward",
                action: { seekPlayback(presentation.skipBackwardTarget) }
            )
            transportButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause playback" : "Play recording",
                identifier: "recorder.playback.toggle",
                prominent: true,
                action: togglePlayback
            )
            .keyboardShortcut(.space, modifiers: [])
            transportButton(
                systemImage: "goforward.15",
                label: "Skip forward 15 seconds",
                identifier: "recorder.playback.skipForward",
                action: { seekPlayback(presentation.skipForwardTarget) }
            )
        }
        .padding(10)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recorder.playback.transportOverlay")
    }

    private func transportButton(
        systemImage: String,
        label: String,
        identifier: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: prominent ? 19 : 16, weight: .semibold))
                .frame(
                    width: prominent ? 42 : 34,
                    height: prominent ? 42 : 34
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(
            prominent ? Color.accentColor : Color.primary.opacity(0.10),
            in: Circle()
        )
        .contentShape(Circle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            timelineText(
                presentation.elapsedText,
                alignment: .trailing,
                identifier: "recorder.playback.elapsed"
            )
            Slider(
                value: Binding(
                    get: { min(max(progress, 0), max(duration, 1)) },
                    set: seekPlayback
                ),
                in: 0...max(duration, 1)
            )
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                "Elapsed \(presentation.elapsedText), remaining \(presentation.remainingText)"
            )
            .accessibilityIdentifier("recorder.playback.timeline")
            timelineText(
                presentation.remainingText,
                alignment: .leading,
                identifier: "recorder.playback.remaining"
            )
        }
    }

    private func timelineText(
        _ text: String,
        alignment: Alignment,
        identifier: String
    ) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: duration >= 3_600 ? 70 : 52, alignment: alignment)
            .accessibilityIdentifier(identifier)
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { volume },
                        set: { newValue in
                            volume = newValue
                            setVolume(Float(newValue))
                        }
                    ),
                    in: 0...1
                )
                .frame(width: 132)
                .accessibilityLabel("Playback volume")
                .accessibilityIdentifier("recorder.playback.volume")
            }

            Picker(
                "Speed",
                selection: Binding(
                    get: { selectedRate },
                    set: { newRate in
                        selectedRate = newRate
                        setRate(newRate)
                    }
                )
            ) {
                ForEach(Self.playbackRates, id: \.self) { rate in
                    Text(Self.rateText(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Playback speed")
            .accessibilityIdentifier("recorder.playback.rate")

            Spacer(minLength: 8)

            Text("\(presentation.elapsedText) / \(presentation.totalText)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Elapsed \(presentation.elapsedText) of \(presentation.totalText)"
                )
                .accessibilityIdentifier("recorder.playback.timeReadout")
        }
        .accessibilityIdentifier("recorder.playback.transportControls")
    }

    private var metadataChips: some View {
        HStack(spacing: 8) {
            PlaybackMetadataChip(
                label: presentation.mediaLabel,
                systemImage: session.mediaKind == .video ? "video.fill" : "waveform",
                identifier: "recorder.playback.mediaChip"
            )
            PlaybackMetadataChip(
                label: presentation.sourceLabel,
                systemImage: "record.circle",
                identifier: "recorder.playback.sourceChip"
            )
            if let recoveryLabel = presentation.recoveryLabel {
                PlaybackMetadataChip(
                    label: recoveryLabel,
                    systemImage: "exclamationmark.triangle.fill",
                    identifier: "recorder.playback.recoveryChip"
                )
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recorder.playback.metadataChips")
    }

    private var keyboardShortcuts: some View {
        HStack(spacing: 0) {
            Button("Seek backward 5 seconds") {
                seekPlayback(clampedTarget(progress - 5))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityIdentifier("recorder.playback.keyboardBackward")
            Button("Seek forward 5 seconds") {
                seekPlayback(clampedTarget(progress + 5))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityIdentifier("recorder.playback.keyboardForward")
        }
        .buttonStyle(.plain)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func clampedTarget(_ target: TimeInterval) -> TimeInterval {
        min(max(target, 0), max(duration, 0))
    }

    private static let playbackRates: [Float] = [0.5, 1, 1.25, 1.5, 2]

    private static func rateText(_ rate: Float) -> String {
        rate == rate.rounded()
            ? String(format: "%.0f×", rate)
            : String(format: "%g×", rate)
    }
}

private struct PlaybackMetadataChip: View {
    let label: String
    let systemImage: String
    let identifier: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.secondary.opacity(0.10), in: Capsule())
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}
