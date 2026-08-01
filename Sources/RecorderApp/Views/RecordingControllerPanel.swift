import AppKit
import Combine
import SwiftUI

enum RecordingControllerAccessibility {
    static let statusID = "recording-controller-status"
    static let elapsedID = "recording-controller-elapsed"
    static let screenStatusID = "recording-controller-screen-status"
    static let screenToggleID = "recording-controller-screen-toggle"
    static let stopID = "recording-controller-stop"
    static let allIDs = [statusID, elapsedID, screenStatusID, screenToggleID, stopID]
    static let stopLabel = "Stop recording"
    static let screenCaptureLabel = "Capture Teams screen"

    static func screenCaptureValue(isOn: Bool) -> String {
        isOn ? "On" : "Off"
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

    func present(model: AppModel) {
        if hostingView == nil {
            let hostingView = NSHostingView(
                rootView: RecordingControllerView(model: model)
            )
            hostingView.frame = panel.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            self.hostingView = hostingView
        }

        panel.positionNearPointer()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
    }
}

@MainActor
final class RecordingControllerPanel: NSPanel {
    private static let panelSize = NSSize(width: 390, height: 112)
    private static let screenInset: CGFloat = 16

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .nonactivatingPanel],
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

    init(model: AppModel) {
        self.model = model
        recorder = model.recorder
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
                setScreenRequested: { requested in
                    Task {
                        await model.setTeamsScreenCaptureRequested(requested)
                    }
                }
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

}

struct RecordingControllerPanelContent: View {
    let presentation: RecordingControllerPresentation
    let stop: () -> Void
    let setScreenRequested: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(presentation.title)
                    .font(.headline)
                    .accessibilityIdentifier(RecordingControllerAccessibility.statusID)
                    .background(RecorderPanelRenderLocationMarker(productionIdentifier: RecordingControllerAccessibility.statusID))
                Spacer(minLength: 8)
                Text(presentation.elapsedText)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .accessibilityIdentifier(RecordingControllerAccessibility.elapsedID)
                    .background(RecorderPanelRenderLocationMarker(productionIdentifier: RecordingControllerAccessibility.elapsedID))
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(RecorderMotionButtonStyle(prominence: .prominent, tint: .red))
                .disabled(presentation.stopDisabled)
                .help("Stop recording")
                .accessibilityLabel(RecordingControllerAccessibility.stopLabel)
                .accessibilityIdentifier(RecordingControllerAccessibility.stopID)
                .background(RecorderPanelRenderLocationMarker(productionIdentifier: RecordingControllerAccessibility.stopID))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                Image(systemName: "rectangle.inset.filled").foregroundStyle(screenColor(for: presentation.screenTone))
                Text(presentation.screenStatusText)
                    .foregroundStyle(screenColor(for: presentation.screenTone))
                    .lineLimit(1)
                    .accessibilityIdentifier(RecordingControllerAccessibility.screenStatusID)
                    .background(RecorderPanelRenderLocationMarker(productionIdentifier: RecordingControllerAccessibility.screenStatusID))
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { presentation.screenRequested }, set: setScreenRequested))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(presentation.screenToggleDisabled || presentation.stopDisabled)
                    .help("Capture Teams screen")
                    .accessibilityLabel(RecordingControllerAccessibility.screenCaptureLabel)
                    .accessibilityValue(RecordingControllerAccessibility.screenCaptureValue(isOn: presentation.screenRequested))
                    .accessibilityIdentifier(RecordingControllerAccessibility.screenToggleID)
                    .background(RecorderPanelRenderLocationMarker(productionIdentifier: RecordingControllerAccessibility.screenToggleID))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 390, height: 112)
        .recorderGlassSurface(.navigation)
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
