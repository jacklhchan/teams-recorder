import AppKit
import SwiftUI

struct TeamsAutoMeetingPresentation: Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let showsCancel: Bool

    static func make(
        state: TeamsAutoMeetingState,
        connectionStatus: TeamsMuteSyncStatus
    ) -> TeamsAutoMeetingPresentation {
        if state == .waitingForMeeting {
            switch connectionStatus {
            case .connecting:
                return .init(
                    title: "Connecting to Teams",
                    detail: "Automatic recording remains armed",
                    systemImage: "arrow.triangle.2.circlepath",
                    showsCancel: false
                )
            case .waitingForTeamsAPI:
                return .init(
                    title: "Teams API unavailable",
                    detail: "Automatic recording remains armed",
                    systemImage: "exclamationmark.triangle.fill",
                    showsCancel: false
                )
            case .waitingForPairingApproval:
                return .init(
                    title: "Waiting for Teams approval",
                    detail: "Automatic recording remains armed",
                    systemImage: "exclamationmark.triangle.fill",
                    showsCancel: false
                )
            case .failed(let message):
                return .init(
                    title: "Teams connection error",
                    detail: message,
                    systemImage: "exclamationmark.triangle.fill",
                    showsCancel: false
                )
            case .disabled, .waitingForMeeting, .ready, .inMeeting:
                break
            }
        }

        return switch state {
        case .disabled:
            .init(
                title: "Off",
                detail: "Automatic recording is disabled",
                systemImage: "circle.dashed",
                showsCancel: false
            )
        case .waitingForMeeting:
            .init(
                title: "Waiting for meeting",
                detail: "Automatic recording is armed",
                systemImage: "clock",
                showsCancel: false
            )
        case .startCountdown(let secondsRemaining):
            .init(
                title: "Recording starts in \(secondsRemaining)s",
                detail: "Teams meeting detected",
                systemImage: "record.circle",
                showsCancel: true
            )
        case .starting:
            .init(
                title: "Starting recording",
                detail: "Teams meeting detected",
                systemImage: "record.circle",
                showsCancel: false
            )
        case .automaticRecording:
            .init(
                title: "Recording automatically",
                detail: "Teams meeting in progress",
                systemImage: "record.circle.fill",
                showsCancel: false
            )
        case .stopCountdown(let secondsRemaining):
            .init(
                title: "Stopping in \(secondsRemaining)s",
                detail: "Confirming the meeting has ended",
                systemImage: "stop.circle",
                showsCancel: false
            )
        case .suppressedUntilMeetingEnd:
            .init(
                title: "Cancelled for this meeting",
                detail: "Automatic recording will re-arm after the meeting",
                systemImage: "xmark.circle",
                showsCancel: false
            )
        case .startBlocked(let message):
            .init(
                title: "Needs permission",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                showsCancel: false
            )
        case .startFailed(let message):
            .init(
                title: "Start failed",
                detail: message,
                systemImage: "exclamationmark.triangle.fill",
                showsCancel: false
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

    override init() {
        panel = TeamsAutoMeetingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 94),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Teams Auto Recording"
        panel.delegate = self
    }

    func present(
        seconds: Int,
        cancel: @escaping @MainActor () -> Void
    ) {
        let shouldOrderPanel = episode.present(cancel: cancel)
        panel.contentView = NSHostingView(
            rootView: TeamsAutoMeetingCountdownView(
                seconds: seconds,
                cancel: { [weak self] in
                    self?.episode.consumeCancel()
                }
            )
        )

        if shouldOrderPanel {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    func dismiss() {
        episode.dismiss()
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        episode.consumeCancel()
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 3) {
                Text("Teams meeting detected")
                    .font(.callout.weight(.semibold))
                Text("Recording starts in \(seconds)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "teams-auto-countdown-seconds"
                    )
                    .background(RecorderPanelAccessibilityBridge(identifier: "teams-auto-countdown-seconds"))
            }

            Spacer(minLength: 8)

            Button(action: cancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(RecorderMotionButtonStyle(prominence: .compact, tint: .secondary))
            .help("Cancel automatic recording")
            .accessibilityLabel("Cancel automatic recording")
            .accessibilityIdentifier("teams-auto-countdown-cancel")
            .background(RecorderPanelAccessibilityBridge(identifier: "teams-auto-countdown-cancel"))
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: 94)
        .recorderGlassSurface(.navigation)
        .accessibilityIdentifier("teams-auto-countdown-panel")
        .background(RecorderPanelAccessibilityBridge(identifier: "teams-auto-countdown-panel"))
    }
}
