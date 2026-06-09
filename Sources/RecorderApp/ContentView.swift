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
                        toggleRecorderMicMute: {
                            model.toggleRecorderMicMute()
                        },
                        chooseOutputFolder: model.chooseOutputFolder,
                        openRecordingFolder: model.openRecordingFolder
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
    let toggleRecorderMicMute: () -> Void
    let chooseOutputFolder: () -> Void
    let openRecordingFolder: () -> Void

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
