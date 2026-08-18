import AppKit
import SwiftUI

enum TeamsAutoMeetingCountdownAccessibility {
    static let panelID = "teams-auto-countdown-panel"
    static let runningID = "teams-auto-countdown-running"
    static let panelToggleID = "teams-auto-countdown-panel-toggle"
    static let secondsID = "teams-auto-countdown-seconds"
    static let recordingIndicatorID = "teams-auto-countdown-recording-indicator"
    static let cancelID = "teams-auto-countdown-cancel"
    static let allIDs = [
        panelID,
        secondsID,
        recordingIndicatorID,
        panelToggleID,
        cancelID
    ]
    static let cancelLabel = "Cancel automatic recording"
}

struct TeamsAutoMeetingPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let showsCancel: Bool
    let showsRearmNow: Bool

    static func make(state: TeamsAutoMeetingState) -> TeamsAutoMeetingPresentation {
        return switch state {
        case .disabled:
            .init(
                title: "Off",
                detail: "Automatic recording is disabled",
                systemImage: "circle.dashed",
                showsCancel: false,
                showsRearmNow: false
            )
        case .waitingForMeeting:
            .init(
                title: "Waiting for meeting",
                detail: "Watching Teams meeting windows locally",
                systemImage: "clock",
                showsCancel: false,
                showsRearmNow: false
            )
        case .startCountdown(let secondsRemaining):
            .init(
                title: "Recording starts in \(secondsRemaining)s",
                detail: "Teams meeting detected",
                systemImage: "record.circle",
                showsCancel: true,
                showsRearmNow: false
            )
        case .starting:
            .init(
                title: "Starting recording",
                detail: "Teams meeting detected",
                systemImage: "record.circle",
                showsCancel: false,
                showsRearmNow: false
            )
        case .automaticRecording:
            .init(
                title: "Recording automatically",
                detail: "Teams meeting in progress",
                systemImage: "record.circle.fill",
                showsCancel: false,
                showsRearmNow: false
            )
        case .stopCountdown(let secondsRemaining):
            .init(
                title: "Stopping in \(secondsRemaining)s",
                detail: "Confirming the meeting has ended",
                systemImage: "stop.circle",
                showsCancel: false,
                showsRearmNow: false
            )
        case .suppressedUntilMeetingEnd:
            .init(
                title: "Cancelled for this meeting",
                detail: "Automatic recording will re-arm after the meeting",
                systemImage: "xmark.circle",
                showsCancel: false,
                showsRearmNow: true
            )
        case .startBlocked(let message):
            .init(
                title: "Needs permission",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                showsCancel: false,
                showsRearmNow: false
            )
        case .startFailed(let message):
            .init(
                title: "Start failed",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                showsCancel: false,
                showsRearmNow: false
            )
        }
    }
}

@MainActor
final class TeamsAutoMeetingPresentationEpisode {
    private enum State {
        case idle
        case armed(@MainActor () -> Void)
        case consumed
    }

    private var state: State = .idle

    @discardableResult
    func present(
        cancel: @escaping @MainActor () -> Void
    ) -> Bool {
        switch state {
        case .idle:
            state = .armed(cancel)
            return true
        case .armed:
            state = .armed(cancel)
            return false
        case .consumed:
            return false
        }
    }

    func consumeCancel() {
        guard case .armed(let action) = state else { return }
        state = .consumed
        action()
    }

    func dismiss() {
        state = .idle
    }
}

@MainActor
protocol TeamsAutoMeetingCountdownPresenting: AnyObject {
    func present(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void
    )
    func dismiss()
}

@MainActor
protocol TeamsAutoMeetingCountdownPresenterFactory {
    func makePresenter() -> any TeamsAutoMeetingCountdownPresenting
}

@MainActor
struct TeamsAutoMeetingCountdownPanelFactory:
    TeamsAutoMeetingCountdownPresenterFactory
{
    nonisolated init() {}

    func makePresenter() -> any TeamsAutoMeetingCountdownPresenting {
        TeamsAutoMeetingCountdownPanelController()
    }
}

private final class TeamsAutoMeetingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TeamsAutoMeetingCountdownPanelController:
    NSObject,
    TeamsAutoMeetingCountdownPresenting,
    NSWindowDelegate
{
    private let panel: TeamsAutoMeetingPanel
    private let episode = TeamsAutoMeetingPresentationEpisode()
    private var panelState: FloatingPanelPresentationState = .expanded

    override init() {
        panel = TeamsAutoMeetingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 94),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .nonactivatingPanel
            ],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Teams Window Auto Recording"
        panel.delegate = self
    }

    func present(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void
    ) {
        let isNewEpisode = episode.present(cancel: cancel)
        if isNewEpisode { panelState = .expanded }
        render(seconds: seconds)
        applyPanelState()
        if isNewEpisode {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        panel.orderOut(nil)
        episode.dismiss()
        panelState = .expanded
    }

    func windowWillClose(_ notification: Notification) {
        episode.consumeCancel()
    }

    private func render(seconds: Int) {
        let hostingView = NSHostingView(
            rootView: TeamsAutoMeetingCountdownView(
                seconds: seconds,
                cancel: { [weak self] in
                    self?.episode.consumeCancel()
                },
                panelState: panelState,
                togglePanel: { [weak self] in
                    self?.togglePanelState(seconds: seconds)
                }
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: panel.frame.size
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
    }

    private func togglePanelState(seconds: Int) {
        panelState = panelState == .expanded ? .collapsed : .expanded
        render(seconds: seconds)
        applyPanelState()
    }

    private func applyPanelState() {
        let targetSize = panelState == .expanded
            ? NSSize(width: 360, height: 94)
            : FloatingPanelLayout.collapsedSize
        panel.setFrame(
            FloatingPanelLayout.frame(
                preservingTopRightOf: panel.frame,
                targetSize: targetSize
            ),
            display: true
        )
    }

    private func positionPanel() {
        let cursorLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first {
            NSMouseInRect(cursorLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = targetScreen?.visibleFrame else { return }

        let margin: CGFloat = 16
        let origin = NSPoint(
            x: max(
                visibleFrame.minX + margin,
                visibleFrame.maxX - panel.frame.width - margin
            ),
            y: max(
                visibleFrame.minY + margin,
                visibleFrame.maxY - panel.frame.height - margin
            )
        )
        panel.setFrameOrigin(origin)
    }
}

struct TeamsAutoMeetingCountdownView: View {
    let seconds: Int
    let cancel: @MainActor () -> Void
    let panelState: FloatingPanelPresentationState
    let togglePanel: @MainActor () -> Void

    @MainActor
    init(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void,
        panelState: FloatingPanelPresentationState = .expanded,
        togglePanel: @escaping @MainActor () -> Void = {}
    ) {
        self.seconds = seconds
        self.cancel = cancel
        self.panelState = panelState
        self.togglePanel = togglePanel
    }

    var body: some View {
        if panelState == .collapsed {
            HStack(spacing: 10) {
                Text("Running")
                    .accessibilityIdentifier(
                        TeamsAutoMeetingCountdownAccessibility.runningID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                TeamsAutoMeetingCountdownAccessibility.runningID
                        )
                    )
                floatingPanelToggleButton
            }
            .padding(.horizontal, 12)
            .frame(width: 132, height: 40)
            .recorderGlassSurface(.navigation)
            .accessibilityIdentifier(TeamsAutoMeetingCountdownAccessibility.panelID)
            .background(
                RecorderPanelRenderLocationMarker(
                    productionIdentifier:
                        TeamsAutoMeetingCountdownAccessibility.panelID
                )
            )
        } else {
            expandedCountdownContent
                .frame(width: 360, height: 94)
                .recorderGlassSurface(.navigation)
                .accessibilityIdentifier(TeamsAutoMeetingCountdownAccessibility.panelID)
                .background(
                    RecorderPanelRenderLocationMarker(
                        productionIdentifier:
                            TeamsAutoMeetingCountdownAccessibility.panelID
                    )
                )
        }
    }

    private var expandedCountdownContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
                .background(
                    RecorderPanelRenderLocationMarker(
                        productionIdentifier:
                            TeamsAutoMeetingCountdownAccessibility.recordingIndicatorID
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Teams meeting detected")
                    .font(.callout.weight(.semibold))
                Text("Recording starts in \(seconds)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        TeamsAutoMeetingCountdownAccessibility.secondsID
                    )
                    .background(
                        RecorderPanelRenderLocationMarker(
                            productionIdentifier:
                                TeamsAutoMeetingCountdownAccessibility.secondsID
                        )
                    )
            }

            Spacer(minLength: 8)
            floatingPanelToggleButton

            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(
                RecorderMotionButtonStyle(
                    prominence: .compact,
                    tint: .secondary
                )
            )
            .help(TeamsAutoMeetingCountdownAccessibility.cancelLabel)
            .accessibilityLabel(TeamsAutoMeetingCountdownAccessibility.cancelLabel)
            .accessibilityIdentifier(TeamsAutoMeetingCountdownAccessibility.cancelID)
            .background(
                RecorderPanelRenderLocationMarker(
                    productionIdentifier:
                        TeamsAutoMeetingCountdownAccessibility.cancelID
                )
            )
        }
        .padding(.horizontal, 16)
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
        .accessibilityIdentifier(
            TeamsAutoMeetingCountdownAccessibility.panelToggleID
        )
        .background(
            RecorderPanelRenderLocationMarker(
                productionIdentifier:
                    TeamsAutoMeetingCountdownAccessibility.panelToggleID
            )
        )
    }
}
