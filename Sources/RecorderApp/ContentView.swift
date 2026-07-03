import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(recorder: model.recorder, statusMessage: model.statusMessage) {
                model.refreshDevices()
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    permissionRow
                    deviceSection
                    MeterSectionView(
                        recorder: model.recorder,
                        systemDeviceName: model.selectedSystemDevice?.name,
                        micDeviceName: model.selectedMicDevice?.name
                    )
                    ControlsView(
                        recorder: model.recorder,
                        startOrStop: model.startOrStop,
                        runTestRecording: model.runTestRecording,
                        toggleRecorderMicMute: {
                            model.toggleRecorderMicMute()
                        },
                        chooseOutputFolder: model.chooseOutputFolder,
                        openRecordingFolder: model.openRecordingFolder,
                        isRunningTestRecording: model.isRunningTestRecording
                    )
                    if let report = model.lastHealthReport {
                        HealthSummaryView(report: report)
                    }
                    RoutingAssistantView(
                        checks: model.routingChecks,
                        refresh: model.refreshRoutingChecks,
                        openAudioMIDISetup: model.openAudioMIDISetup
                    )
                    SessionListView(
                        sessions: model.sessions,
                        playingSessionID: model.playingSessionID,
                        playbackProgress: model.playbackProgress,
                        playbackDuration: model.playbackDuration,
                        isPlaybackActive: model.isPlaybackActive,
                        refresh: model.refreshSessions,
                        play: model.play,
                        open: model.open,
                        stopPlayback: {
                            model.stopPlayback()
                        },
                        seekPlayback: model.seekPlayback
                    )
                    FooterView(recorder: model.recorder, outputFolder: model.outputFolder)
                }
                .padding(20)
            }
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.permissionMessage.isEmpty {
                Label(model.permissionMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Microphone permission ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var deviceSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Label("System audio", systemImage: "waveform")
                    .font(.headline)
                Picker("System audio", selection: $model.selectedSystemDevice) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(Optional(device))
                    }
                }
                .onChange(of: model.selectedSystemDevice) { _, _ in
                    model.refreshMonitoring()
                }
                .labelsHidden()
                .frame(minWidth: 380)
                Text(model.selectedSystemDevice?.channelText ?? "No input")
                    .foregroundStyle(.secondary)
            }

            GridRow {
                Label("Microphone", systemImage: "mic")
                    .font(.headline)
                Picker("Microphone", selection: $model.selectedMicDevice) {
                    ForEach(model.devices) { device in
                        Text(device.displayName).tag(Optional(device))
                    }
                }
                .onChange(of: model.selectedMicDevice) { _, _ in
                    model.refreshMonitoring()
                }
                .labelsHidden()
                .frame(minWidth: 380)
                Text(model.selectedMicDevice?.channelText ?? "No input")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(model.recorder.isRecording)
    }

}

private struct HeaderView: View {
    @ObservedObject var recorder: RecordingEngine
    let statusMessage: String
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(recorder.isRecording ? Color.red : Color.secondary.opacity(0.45))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Meeting Recorder")
                    .font(.system(size: 22, weight: .semibold))
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            recordingTimer
            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var elapsedText: String {
        guard let startedAt = recorder.startedAt else { return "00:00:00" }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private var recordingTimer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(elapsedText)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(recorder.isRecording ? .red : .secondary)
                .frame(width: 96, alignment: .trailing)
        }
    }
}

private struct MeterSectionView: View {
    @ObservedObject var recorder: RecordingEngine
    let systemDeviceName: String?
    let micDeviceName: String?

    var body: some View {
        VStack(spacing: 14) {
            AudioMeterView(
                title: "System Audio",
                subtitle: systemDeviceName ?? "Select BlackHole 2ch",
                level: recorder.systemLevel,
                tint: .cyan
            )
            AudioMeterView(
                title: "Mic Input",
                subtitle: recorder.micMuted ? "Recorder mic track muted" : (micDeviceName ?? "Select microphone"),
                level: recorder.micLevel,
                tint: recorder.micMuted ? .secondary : .green
            )
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var recorder: RecordingEngine
    let startOrStop: () -> Void
    let runTestRecording: () -> Void
    let toggleRecorderMicMute: () -> Void
    let chooseOutputFolder: () -> Void
    let openRecordingFolder: () -> Void
    let isRunningTestRecording: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                startOrStop()
            } label: {
                Label(recorder.isRecording ? "Stop Recording" : "Start Recording", systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .frame(minWidth: 156)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recorder.isRecording ? .red : .accentColor)

            Button {
                runTestRecording()
            } label: {
                Label(isRunningTestRecording ? "Testing..." : "Test 10s", systemImage: "waveform.badge.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(recorder.isRecording || isRunningTestRecording)

            Button {
                toggleRecorderMicMute()
            } label: {
                Label(recorder.micMuted ? "Unmute Recorder Mic" : "Mute Recorder Mic", systemImage: recorder.micMuted ? "mic.fill" : "mic.slash.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                toggleRecorderMicMute()
            } label: {
                Label("Option+Shift+M", systemImage: "keyboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(true)

            Spacer()

            Button {
                chooseOutputFolder()
            } label: {
                Label("Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .disabled(recorder.isRecording)

            Button {
                openRecordingFolder()
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct HealthSummaryView: View {
    let report: RecordingHealthReport

    var body: some View {
        HStack(spacing: 16) {
            Label(report.systemSignalSeen ? "System audio captured" : "No system audio", systemImage: report.systemSignalSeen ? "checkmark.circle.fill" : "speaker.slash.fill")
                .foregroundStyle(report.systemSignalSeen ? .green : .orange)
            Label(report.micSignalSeen ? "Mic captured" : "No mic signal", systemImage: report.micSignalSeen ? "checkmark.circle.fill" : "mic.slash.fill")
                .foregroundStyle(report.micSignalSeen ? .green : .orange)
            if report.clippingEvents > 0 {
                Label("\(report.clippingEvents) clipping events", systemImage: "waveform.path.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
            if report.droppedBuffers > 0 {
                Label("\(report.droppedBuffers) dropped buffers", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct RoutingAssistantView: View {
    let checks: [RoutingCheck]
    let refresh: () -> Void
    let openAudioMIDISetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Routing Assistant", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Button {
                    openAudioMIDISetup()
                } label: {
                    Label("Audio MIDI", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 8) {
                ForEach(checks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.status.iconName)
                            .foregroundStyle(check.status.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.callout.weight(.medium))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct SessionListView: View {
    let sessions: [RecordingSession]
    let playingSessionID: RecordingSession.ID?
    let playbackProgress: TimeInterval
    let playbackDuration: TimeInterval
    let isPlaybackActive: Bool
    let refresh: () -> Void
    let play: (RecordingSession) -> Void
    let open: (RecordingSession) -> Void
    let stopPlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Recordings", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if sessions.isEmpty {
                Text("No recordings in the selected folder yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions.prefix(8)) { session in
                        VStack(spacing: 8) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayName)
                                        .font(.callout.weight(.medium))
                                    Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(session.durationText) · \(session.fileSizeText)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    play(session)
                                } label: {
                                    Image(systemName: playingSessionID == session.id && isPlaybackActive ? "play.fill" : "play.fill")
                                }
                                .buttonStyle(.bordered)
                                Button {
                                    open(session)
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.bordered)
                            }

                            if playingSessionID == session.id {
                                PlaybackBarView(
                                    progress: playbackProgress,
                                    duration: playbackDuration,
                                    stopPlayback: stopPlayback,
                                    seekPlayback: seekPlayback
                                )
                            }
                        }
                        .padding(.vertical, 8)
                        if session.id != sessions.prefix(8).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct PlaybackBarView: View {
    let progress: TimeInterval
    let duration: TimeInterval
    let stopPlayback: () -> Void
    let seekPlayback: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(Self.timeText(progress))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { progress },
                    set: { seekPlayback($0) }
                ),
                in: 0...max(duration, 1)
            )

            Text(Self.timeText(duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Button {
                stopPlayback()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .help("Stop playback")
        }
        .padding(10)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private static func timeText(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "00:00" }
        let seconds = max(0, Int(time.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct FooterView: View {
    @ObservedObject var recorder: RecordingEngine
    let outputFolder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Output: \(recorder.outputFolder?.path ?? outputFolder.path)")
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Label("Writes one combined recording.m4a file", systemImage: "doc.badge.gearshape")
                Spacer()
                Label("BlackHole Multi-Output Device recommended", systemImage: "speaker.wave.2")
            }
            .foregroundStyle(.secondary)
        }
    }
}

private extension AudioDevice {
    var channelText: String {
        "\(channelCount) channel\(channelCount == 1 ? "" : "s")"
    }
}
