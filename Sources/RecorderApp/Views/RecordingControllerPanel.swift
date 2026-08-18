import AppKit
import Combine
import SwiftUI

enum RecordingControllerAccessibility {
    static let runningID = "recording-controller-running"
    static let panelToggleID = "recording-controller-panel-toggle"
    static let statusID = "recording-controller-status"
    static let elapsedID = "recording-controller-elapsed"
    static let recordingIndicatorID = "recording-controller-recording-indicator"
    static let recordingIndicatorToggleID = "recording-controller-recording-indicator-toggle"
    static let systemWaveformID = "recording-controller-system-waveform"
    static let microphoneWaveformID = "recording-controller-microphone-waveform"
    static let microphoneMuteID = "recording-controller-microphone-mute"
    static let screenStatusID = "recording-controller-screen-status"
    static let screenToggleID = "recording-controller-screen-toggle"
    static let stopID = "recording-controller-stop"
    static let allIDs = [
        runningID,
        panelToggleID,
        statusID,
        elapsedID,
        recordingIndicatorID,
        systemWaveformID,
        microphoneWaveformID,
        microphoneMuteID,
        screenStatusID,
        screenToggleID,
        stopID
    ]
    static let stopLabel = "Stop recording"
    static let screenCaptureLabel = "Capture Teams screen"

    static func microphoneMuteLabel(isMuted: Bool) -> String {
        isMuted ? "Unmute microphone" : "Mute microphone"
    }

    static func microphoneMuteValue(isMuted: Bool) -> String {
        isMuted ? "Muted" : "Active"
    }

    static func screenCaptureValue(isOn: Bool) -> String {
        isOn ? "On" : "Off"
    }
}

enum RecordingControllerInputStatus: String, Equatable {
    case signal = "Signal"
    case quiet = "Quiet"
    case muted = "Muted"
    case disconnected = "Disconnected"

    static func make(
        level: LevelSnapshot,
        isConnected: Bool,
        isMuted: Bool
    ) -> Self {
        if !isConnected { return .disconnected }
        if isMuted { return .muted }
        return level.isSilent ? .quiet : .signal
    }
}

enum RecordingControllerPanelCommand: Equatable {
    case none
    case present
    case dismiss
}

struct RecordingControllerPanelEpisode {
    private(set) var isPresented = false

    mutating func handle(
        isRecording: Bool
    ) -> RecordingControllerPanelCommand {
        switch (isPresented, isRecording) {
        case (false, true):
            isPresented = true
            return .present
        case (true, false):
            isPresented = false
            return .dismiss
        default:
            return .none
        }
    }
}

@MainActor
protocol RecordingControllerPresenting: AnyObject {
    func present(model: AppModel)
    func dismiss()
}

@MainActor
protocol RecordingControllerPresenterFactory {
    func makePresenter() -> any RecordingControllerPresenting
}

@MainActor
final class RecordingControllerCoordinator {
    private let model: AppModel
    private let presenter: any RecordingControllerPresenting
    private var episode = RecordingControllerPanelEpisode()
    private var observation: AnyCancellable?
    private var isShutdown = false

    convenience init(model: AppModel) {
        self.init(
            model: model,
            presenterFactory: RecordingControllerPanelPresenterFactory(),
            isRecordingPublisher: nil
        )
    }

    init(
        model: AppModel,
        presenterFactory: any RecordingControllerPresenterFactory,
        isRecordingPublisher: AnyPublisher<Bool, Never>? = nil
    ) {
        self.model = model
        presenter = presenterFactory.makePresenter()
        observation = (
            isRecordingPublisher ??
                model.recorder.$isRecording.eraseToAnyPublisher()
        )
        .removeDuplicates()
        .sink { [weak self] isRecording in
            self?.handle(isRecording: isRecording)
        }
    }

    deinit {
        observation?.cancel()
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        observation?.cancel()
        observation = nil
        presenter.dismiss()
    }

    private func handle(isRecording: Bool) {
        switch episode.handle(isRecording: isRecording) {
        case .none:
            break
        case .present:
            presenter.present(model: model)
        case .dismiss:
            presenter.dismiss()
        }
    }
}

struct RecordingControllerPanelPresenterFactory:
    RecordingControllerPresenterFactory
{
    func makePresenter() -> any RecordingControllerPresenting {
        RecordingControllerPanelPresenter()
    }
}

@MainActor
final class RecordingControllerPanelPresenter: RecordingControllerPresenting {
    private let panel = RecordingControllerPanel()
    private var hostingView: NSHostingView<RecordingControllerView>?
    private var panelState: FloatingPanelPresentationState = .expanded

    var panelFrame: NSRect { panel.frame }

    var panelToggleAccessibilityValue: String? {
        guard let hostingView,
              let toggle = allViews(hostingView).first(where: {
                  $0.accessibilityIdentifier()
                      == RecordingControllerAccessibility.panelToggleID
              }),
              let value = toggle.accessibilityValue() as? String else {
            return panelState.accessibilityValue
        }
        return value
    }

    func present(model: AppModel) {
        // A new hosting view gives every recording episode a fresh SwiftUI
        // presentation state.  Do this even if a caller presents twice.
        hostingView = nil
        panel.contentView = nil

        let hostingView = NSHostingView(
            rootView: RecordingControllerView(
                model: model,
                onPresentationChange: { [weak self] state in
                    self?.setPresentation(state)
                }
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: panel.frame.size
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.hostingView = hostingView

        setPresentation(.expanded)
        panel.positionNearPointer()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
        hostingView = nil
        panel.contentView = nil
    }

    func setPresentation(_ state: FloatingPanelPresentationState) {
        panelState = state
        let targetSize = state == .expanded
            ? RecordingControllerPanel.panelSize
            : FloatingPanelLayout.collapsedSize
        panel.setFrame(
            FloatingPanelLayout.frame(
                preservingTopRightOf: panel.frame,
                targetSize: targetSize
            ),
            display: true
        )
    }

    private func allViews(_ view: NSView) -> [NSView] {
        let children = view.subviews
            + ((view.accessibilityChildren() as? [NSView]) ?? [])
        return [view] + children.flatMap(allViews)
    }
}

@MainActor
final class RecordingControllerPanel: NSPanel {
    static let panelSize = NSSize(width: 390, height: 180)
    private static let screenInset: CGFloat = 16

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionNearPointer() {
        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(pointerLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - Self.screenInset,
            y: visibleFrame.maxY - frame.height - Self.screenInset
        ))
    }
}

@MainActor
struct RecordingControllerView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var recorder: RecordingEngine
    @State private var panelState: FloatingPanelPresentationState = .expanded
    private let onPresentationChange: (
        FloatingPanelPresentationState
    ) -> Void

    init(
        model: AppModel,
        onPresentationChange: @escaping (
            FloatingPanelPresentationState
        ) -> Void = { _ in }
    ) {
        self.model = model
        recorder = model.recorder
        self.onPresentationChange = onPresentationChange
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = RecordingControllerPresentation.make(
                snapshot: snapshot,
                now: context.date
            )
            RecordingControllerPanelContent(
                presentation: presentation,
                stop: model.startOrStop,
                toggleMicrophoneMute: {
                    model.toggleRecorderMicMute(source: "Floating panel")
                },
                setScreenRequested: { requested in
                    Task {
                        await model.setTeamsScreenCaptureRequested(requested)
                    }
                },
                systemLevel: recorder.systemLevel,
                microphoneLevel: recorder.micLevel,
                isSystemConnected: recorder.isSystemCaptureConnected,
                isMicrophoneConnected: recorder.isMicrophoneCaptureConnected,
                isMicrophoneMuted: recorder.micMuted,
                isLocalMicrophoneMuted: model.localMicMuted,
                panelState: panelState,
                togglePanel: togglePanel
            )
        }
    }

    private var snapshot: RecordingControllerSnapshot {
        RecordingControllerSnapshot(
            isRecording: recorder.isRecording,
            isFinalizing: model.isFinalizingRecording,
            startedAt: recorder.startedAt,
            showsTeamsScreenControl: model.showsTeamsScreenCaptureControls,
            screenRequested: model.isTeamsScreenCaptureRequested,
            screenStatusText: model.teamsScreenStatusText,
            screenToggleDisabled:
                model.isTeamsScreenCaptureToggleDisabled
        )
    }

    private func togglePanel() {
        panelState = panelState == .expanded ? .collapsed : .expanded
        onPresentationChange(panelState)
    }

}

struct RecordingControllerPanelContent: View {
    let presentation: RecordingControllerPresentation
    let stop: () -> Void
    let toggleMicrophoneMute: () -> Void
    let setScreenRequested: (Bool) -> Void
    let systemLevel: LevelSnapshot
    let microphoneLevel: LevelSnapshot
    let isSystemConnected: Bool
    let isMicrophoneConnected: Bool
    let isMicrophoneMuted: Bool
    let isLocalMicrophoneMuted: Bool
    let panelState: FloatingPanelPresentationState
    let togglePanel: () -> Void

    init(
        presentation: RecordingControllerPresentation,
        stop: @escaping () -> Void,
        toggleMicrophoneMute: @escaping () -> Void,
        setScreenRequested: @escaping (Bool) -> Void,
        systemLevel: LevelSnapshot,
        microphoneLevel: LevelSnapshot,
        isSystemConnected: Bool,
        isMicrophoneConnected: Bool,
        isMicrophoneMuted: Bool,
        isLocalMicrophoneMuted: Bool,
        panelState: FloatingPanelPresentationState,
        togglePanel: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.stop = stop
        self.toggleMicrophoneMute = toggleMicrophoneMute
        self.setScreenRequested = setScreenRequested
        self.systemLevel = systemLevel
        self.microphoneLevel = microphoneLevel
        self.isSystemConnected = isSystemConnected
        self.isMicrophoneConnected = isMicrophoneConnected
        self.isMicrophoneMuted = isMicrophoneMuted
        self.isLocalMicrophoneMuted = isLocalMicrophoneMuted
        self.panelState = panelState
        self.togglePanel = togglePanel
    }

    var body: some View {
        if panelState == .collapsed {
            HStack(spacing: 10) {
                Text("Running")
                    .accessibilityIdentifier(
                        RecordingControllerAccessibility.runningID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility.runningID
                        )
                    )
                floatingPanelToggleButton
            }
            .padding(.horizontal, 12)
            .frame(width: 132, height: 40)
            .recorderGlassSurface(.navigation)
        } else {
            expandedContent
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility
                                .recordingIndicatorID
                        )
                    )
                floatingPanelToggleButton
                Text("Running")
                    .font(.headline)
                    .accessibilityIdentifier(
                        RecordingControllerAccessibility.statusID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility.statusID
                        )
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility.runningID
                        )
                    )
                Spacer(minLength: 8)
                Text(presentation.elapsedText)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .accessibilityIdentifier(
                        RecordingControllerAccessibility.elapsedID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility.elapsedID
                        )
                    )
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(
                    RecorderMotionButtonStyle(
                        prominence: .prominent,
                        tint: .red
                    )
                )
                .disabled(presentation.stopDisabled)
                .help("Stop recording")
                .accessibilityLabel(RecordingControllerAccessibility.stopLabel)
                .accessibilityIdentifier(RecordingControllerAccessibility.stopID)
                .background(
                    RecorderPanelRenderLocationMarker(
                        productionIdentifier:
                            RecordingControllerAccessibility.stopID
                    )
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )

            RecordingControllerInputRow(
                title: "System / Teams",
                systemImage: "speaker.wave.2.fill",
                level: systemLevel,
                isConnected: isSystemConnected,
                isMuted: false,
                tint: RecorderVisualStyle.systemAudio,
                accessibilityID: RecordingControllerAccessibility
                    .systemWaveformID,
                iconAction: nil
            )

            RecordingControllerInputRow(
                title: "Microphone",
                systemImage: isLocalMicrophoneMuted
                    ? "mic.slash.fill"
                    : "mic.fill",
                level: microphoneLevel,
                isConnected: isMicrophoneConnected,
                isMuted: isMicrophoneMuted,
                tint: RecorderVisualStyle.microphone,
                accessibilityID: RecordingControllerAccessibility
                    .microphoneWaveformID,
                iconAction: toggleMicrophoneMute,
                iconIsMuted: isLocalMicrophoneMuted
            )

            HStack(spacing: 10) {
                Image(systemName: "rectangle.inset.filled")
                    .foregroundStyle(screenColor(for: presentation.screenTone))
                Text(presentation.screenStatusText)
                    .foregroundStyle(screenColor(for: presentation.screenTone))
                    .lineLimit(1)
                    .accessibilityIdentifier(
                        RecordingControllerAccessibility.screenStatusID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                RecordingControllerAccessibility.screenStatusID
                        )
                    )
                Spacer(minLength: 8)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { presentation.screenRequested },
                        set: setScreenRequested
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(
                    presentation.screenToggleDisabled
                        || presentation.stopDisabled
                )
                .help("Capture Teams screen")
                .accessibilityLabel(
                    RecordingControllerAccessibility.screenCaptureLabel
                )
                .accessibilityValue(
                    RecordingControllerAccessibility.screenCaptureValue(
                        isOn: presentation.screenRequested
                    )
                )
                .accessibilityIdentifier(
                    RecordingControllerAccessibility.screenToggleID
                )
                .background(
                    RecorderPanelRenderLocationMarker(
                        productionIdentifier:
                            RecordingControllerAccessibility.screenToggleID
                    )
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 390, height: 180)
        .recorderGlassSurface(.navigation)
    }

    private var floatingPanelToggleButton: some View {
        Button(action: togglePanel) {
            Image(
                systemName: panelState == .expanded ? "eye.slash" : "eye"
            )
        }
        .buttonStyle(.plain)
        .help(panelState.toggleLabel)
        .accessibilityLabel(panelState.toggleLabel)
        .accessibilityValue(panelState.accessibilityValue)
        .accessibilityIdentifier(RecordingControllerAccessibility.panelToggleID)
        .background(
            RecorderPanelRenderLocationMarker(
                productionIdentifier:
                    RecordingControllerAccessibility.panelToggleID
            )
        )
    }

}

private struct RecordingControllerInputRow: View {
    let title: String
    let systemImage: String
    let level: LevelSnapshot
    let isConnected: Bool
    let isMuted: Bool
    let tint: Color
    let accessibilityID: String
    let iconAction: (() -> Void)?
    var iconIsMuted: Bool? = nil

    private var status: RecordingControllerInputStatus {
        RecordingControllerInputStatus.make(
            level: level,
            isConnected: isConnected,
            isMuted: isMuted
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            if let iconAction {
                let buttonIsMuted = iconIsMuted ?? isMuted
                Button(action: iconAction) {
                    Image(systemName: systemImage)
                        .foregroundStyle(buttonIsMuted ? .orange : tint)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(
                    RecordingControllerAccessibility
                        .microphoneMuteLabel(isMuted: buttonIsMuted)
                )
                .accessibilityLabel(
                    RecordingControllerAccessibility
                        .microphoneMuteLabel(isMuted: buttonIsMuted)
                )
                .accessibilityValue(
                    RecordingControllerAccessibility
                        .microphoneMuteValue(isMuted: buttonIsMuted)
                )
                .accessibilityIdentifier(
                    RecordingControllerAccessibility.microphoneMuteID
                )
                .background(
                    RecorderPanelRenderLocationMarker(
                        productionIdentifier:
                            RecordingControllerAccessibility.microphoneMuteID
                    )
                )
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            WaveformView(samples: level.samples, tint: tint)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .accessibilityHidden(true)
                .background(
                    RecordingControllerInputAccessibilityMarker(
                        identifier: accessibilityID,
                        label: title,
                        value: status.rawValue
                    )
                )
                .background(RecorderPanelRenderLocationMarker(productionIdentifier: accessibilityID))
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusColor: Color {
        switch status {
        case .signal:
            tint
        case .quiet:
            .secondary
        case .muted:
            .orange
        case .disconnected:
            .red
        }
    }
}

private struct RecordingControllerInputAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    let value: String

    func makeNSView(context: Context) -> RecorderPassiveMarkerView {
        let view = RecorderPassiveMarkerView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: RecorderPassiveMarkerView, context _: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityValue(value)
    }
}

private func screenColor(for tone: RecordingControllerTone) -> Color {
        switch tone {
        case .neutral:
            return .secondary
        case .ready:
            return .green
        case .recording:
            return .red
        case .warning:
            return .orange
    }
}
