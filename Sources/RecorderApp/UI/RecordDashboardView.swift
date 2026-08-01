import SwiftUI

struct RecordDashboardView: View {
    @ObservedObject var model: AppModel
    let openCaptureSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let presentation = RecordDashboardPresentation.make(
                isRecording: model.recorder.isRecording,
                startedAt: model.recorder.startedAt,
                now: timeline.date,
                isCaptureLifecycleWorking: model.isCaptureLifecycleWorking,
                isRunningTestRecording: model.isRunningTestRecording,
                localMicMuted: model.localMicMuted,
                nativeInputMicMuted: model.nativeInputMicMuted,
                teamsMicMuted: model.teamsMicMuted
            )
            dashboard(presentation: presentation)
        }
    }

    private func dashboard(presentation: RecordDashboardPresentation) -> some View {
        let toolbarPresentation = RecordToolbarPresentation.make(
            sourceControlsEnabled: model.sourceControlsEnabled,
            isRecording: model.recorder.isRecording,
            dashboard: presentation
        )

        return VStack(alignment: .leading, spacing: 10) {
            RecordDashboardHeader(model: model, presentation: presentation)
                .accessibilityIdentifier("record-state")
                .background(RecordDashboardFrameMarker(identifier: "record-state"))
            if let message = blockingCaptureMessage {
                RecordDashboardCaptureRecovery(
                    message: message,
                    openCaptureSettings: openCaptureSettings
                )
            }
            RecordDashboardMeters(model: model, recorder: model.recorder)
            RecordDashboardControls(model: model, presentation: presentation)
            RecordDashboardHealth(model: model)
                .accessibilityIdentifier("capture-health")
                .background(RecordDashboardFrameMarker(identifier: "capture-health"))
            RecordDashboardFooter(model: model)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: "recorder.destination.record"
            )
        )
        .accessibilityIdentifier("recorder.destination.record")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.refreshAllCaptureState()
                } label: {
                    Label("Refresh Capture", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(RecorderActionID.refreshCapture)
                .disabled(toolbarPresentation.refreshDisabled)

                Button {
                    model.toggleRecorderMicMute()
                } label: {
                    Label(
                        micMuteTitle,
                        systemImage: model.localMicMuted
                            ? "mic.fill"
                            : "mic.slash.fill"
                    )
                }
                .accessibilityIdentifier(RecorderActionID.muteMic)
                .accessibilityValue(
                    model.localMicMuted
                        ? "local-muted"
                        : (
                            model.teamsMicMuted
                                ? "teams-muted"
                                : (
                                    model.nativeInputMicMuted
                                        ? "input-muted"
                                        : "active"
                                )
                        )
                )
                .disabled(toolbarPresentation.muteDisabled)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(action: model.runTestRecording) {
                        Label(
                            model.isRunningTestRecording
                                ? "Testing..."
                                : "Test 10 Seconds",
                            systemImage: "waveform.badge.magnifyingglass"
                        )
                    }
                    .accessibilityIdentifier(RecorderActionID.testAudio)
                    .disabled(toolbarPresentation.testDisabled)

                    Divider()

                    Button(action: model.chooseOutputFolder) {
                        Label("Choose Output Folder", systemImage: "folder")
                    }
                    .accessibilityIdentifier(RecorderActionID.chooseOutputFolder)
                    .disabled(
                        toolbarPresentation.chooseOutputFolderDisabled
                    )

                    Button(action: model.openRecordingFolder) {
                        Label("Open Output Folder", systemImage: "arrow.up.right.square")
                    }
                    .accessibilityIdentifier(RecorderActionID.openOutputFolder)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier(RecorderActionID.moreRecordActions)
            }
        }
    }

    private var micMuteTitle: String {
        if model.localMicMuted { return "Unmute Recorder Mic" }
        if model.teamsMicMuted { return "Muted by Teams" }
        if model.nativeInputMicMuted { return "Muted by Input" }
        return "Mute Recorder Mic"
    }

    private var blockingCaptureMessage: String? {
        if model.systemAudioPermission == .denied
            || model.systemAudioPermission == .restricted
            || model.systemAudioPermission == .notDetermined
        {
            return "Screen and system audio permission is required before recording."
        }
        if model.microphonePermission == .denied
            || model.microphonePermission == .restricted
            || model.microphonePermission == .notDetermined
        {
            return "Microphone permission is required before recording."
        }
        if case .disconnected = model.resolvedCaptureSelection {
            return "The selected application is disconnected. Review Capture settings."
        }
        return nil
    }
}

private struct RecordDashboardHeader: View {
    @ObservedObject var model: AppModel
    let presentation: RecordDashboardPresentation

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.recorder.isRecording ? RecorderVisualStyle.recording : Color.secondary.opacity(0.45))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Meeting Recorder")
                    .font(.system(size: 20, weight: .semibold))
                Text(model.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(presentation.elapsedText)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(model.recorder.isRecording ? RecorderVisualStyle.recording : .secondary)
                .frame(width: 88, alignment: .trailing)
                .accessibilityIdentifier("elapsed-time")
                .background(RecordDashboardFrameMarker(identifier: "elapsed-time"))
        }
    }

}

private struct RecordDashboardMeters: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recorder: RecordingEngine

    var body: some View {
        VStack(spacing: 8) {
            RecordDashboardMeter(
                title: "System Audio",
                subtitle: model.systemAudioSubtitle,
                level: recorder.systemLevel,
                tint: RecorderVisualStyle.systemAudio
            )
            .accessibilityIdentifier("system-meter")
            .background(RecordDashboardFrameMarker(identifier: "system-meter"))
            RecordDashboardMeter(
                title: "Mic Input",
                subtitle: recorder.micMuted ? "Recorder mic track muted" : (model.selectedMicDevice?.name ?? "Select microphone"),
                level: recorder.micLevel,
                tint: recorder.micMuted ? .secondary : RecorderVisualStyle.microphone
            )
            .accessibilityIdentifier("microphone-meter")
            .background(RecordDashboardFrameMarker(identifier: "microphone-meter"))
        }
    }
}

private struct RecordDashboardMeter: View {
    let title: String
    let subtitle: String
    let level: LevelSnapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(level.rms)) dBFS")
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .foregroundStyle(level.isClipping ? .red : .primary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(level.isClipping ? .red : tint)
                        .frame(width: max(4, proxy.size.width * normalizedLevel))
                }
            }
            .frame(height: 10)
            WaveformView(samples: level.samples, tint: tint)
                .frame(height: 32)
            HStack(spacing: 14) {
                if level.isSilent {
                    Label("No signal detected", systemImage: "speaker.slash.fill")
                        .foregroundStyle(.orange)
                }
                if level.isClipping {
                    Label("Clipping", systemImage: "waveform.path.badge.exclamationmark")
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("Peak \(Int(level.peak)) dB")
                    .foregroundStyle(.secondary)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6), lineWidth: 1))
    }

    private var normalizedLevel: Double {
        let clamped = min(0, max(-60, Double(level.rms)))
        return (clamped + 60) / 60
    }
}

private struct RecordDashboardCaptureRecovery: View {
    let message: String
    let openCaptureSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).lineLimit(2)
            Spacer(minLength: 8)
            Button("Open Capture Settings", action: openCaptureSettings)
                .buttonStyle(.bordered)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(RecorderActionID.captureRecovery)
                .background(
                    RecordDashboardFrameMarker(
                        identifier: "recorder.probe.capture-recovery"
                    )
                )
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RecordDashboardControls: View {
    @ObservedObject var model: AppModel
    let presentation: RecordDashboardPresentation

    var body: some View {
        Button(action: model.startOrStop) {
            Label(
                model.recorder.isRecording
                    ? "Stop Recording"
                    : "Start Recording",
                systemImage: model.recorder.isRecording
                    ? "stop.fill"
                    : "record.circle"
            )
            .frame(minWidth: 180)
        }
        .buttonStyle(
            RecorderMotionButtonStyle(
                prominence: .prominent,
                tint: model.recorder.isRecording ? .red : .accentColor
            )
        )
        .controlSize(.large)
        .accessibilityIdentifier(RecorderActionID.startStop)
        .background(
            RecordDashboardFrameMarker(identifier: RecorderActionID.startStop)
        )
        .background(
            RecorderDestinationAccessibilityMarker(
                identifier: RecorderActionID.primaryActionCluster
            )
        )
        .disabled(presentation.startStopDisabled)
    }
}

private struct RecordDashboardHealth: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RecordDashboardLiveAudioHealth(recorder: model.recorder)
            if let report = model.lastHealthReport {
                RecordDashboardHealthSummary(report: report)
            }
        }
    }
}

private struct RecordDashboardLiveAudioHealth: View {
    @ObservedObject var recorder: RecordingEngine

    var body: some View {
        let assessment = AudioHealthAdvisor.assessment(
            systemLevel: recorder.systemLevel,
            micLevel: recorder.micLevel,
            isMicMuted: recorder.micMuted,
            isMonitoring: recorder.isMonitoring,
            isRecording: recorder.isRecording
        )
        return HStack(spacing: 18) {
            input(assessment.system, icon: "speaker.wave.2")
            input(assessment.mic, icon: "mic")
            Spacer()
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55), lineWidth: 1))
    }

    private func input(_ input: AudioHealthAssessment.Input, icon: String) -> some View {
        Label(input.title, systemImage: icon)
            .foregroundStyle(color(for: input.status))
            .help(input.detail)
    }

    private func color(for status: AudioHealthAssessment.Status) -> Color {
        switch status {
        case .ok: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

private struct RecordDashboardHealthSummary: View {
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
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.55), lineWidth: 1))
    }
}

private struct RecordDashboardFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let fullPath = model.recorder.outputFolder?.path ?? model.outputFolder.path
        VStack(alignment: .leading, spacing: 4) {
            Text("Output: \(fullPath)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .help(fullPath)
                .accessibilityValue(fullPath)
            HStack {
                Label("Writes one combined recording.mp4 file", systemImage: "doc.badge.gearshape")
                Spacer()
                Label("Captures without changing Mac output", systemImage: "speaker.wave.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if model.lastRecordingSavedAsM4A {
                Label("Last recording recovered as recording.m4a", systemImage: "waveform.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecordDashboardFrameMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context _: Context) -> RecordDashboardFrameMarkerView {
        let view = RecordDashboardFrameMarkerView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_: RecordDashboardFrameMarkerView, context _: Context) {}
}

private final class RecordDashboardFrameMarkerView: NSView {}
