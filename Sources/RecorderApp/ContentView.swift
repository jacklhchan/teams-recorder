import SwiftUI

struct ContentView: View {
    @ObservedObject private var model: AppModel
    @State private var autoMeetingPanel:
        any TeamsAutoMeetingCountdownPresenting
    @State private var playbackWindow:
        any PlaybackWindowPresenting
    @State private var navigation = RecorderNavigationState(selection: .record)
    private let navigationOverride: Binding<RecorderNavigationState>?

    @MainActor
    init(
        model: AppModel,
        autoMeetingPanelFactory:
            any TeamsAutoMeetingCountdownPresenterFactory =
                TeamsAutoMeetingCountdownPanelFactory(),
        playbackWindowPresenterFactory:
            any PlaybackWindowPresenterFactory =
                PlaybackWindowControllerFactory(),
        // Internal deterministic presentation-test seam. Production passes nil
        // and ContentView remains the sole owner of its navigation state.
        navigationOverride: Binding<RecorderNavigationState>? = nil
    ) {
        self.model = model
        _autoMeetingPanel = State(
            initialValue: autoMeetingPanelFactory.makePresenter()
        )
        _playbackWindow = State(
            initialValue:
                playbackWindowPresenterFactory.makePresenter()
        )
        self.navigationOverride = navigationOverride
    }

    var body: some View {
        RecorderWorkspaceContent(
            model: model,
            navigation: workspaceNavigation
        )
        .onChange(
            of: model.teamsAutoMeetingState,
            initial: true
        ) { _, state in
            if case let .startCountdown(secondsRemaining) = state {
                autoMeetingPanel.present(
                    seconds: secondsRemaining,
                    cancel: model.cancelTeamsAutoMeetingCountdown
                )
            } else {
                autoMeetingPanel.dismiss()
            }
        }
        .onChange(
            of: model.playingSessionID,
            initial: true
        ) { _, sessionID in
            guard sessionID != nil else {
                playbackWindow.dismiss()
                return
            }
            playbackWindow.present(
                presentation: model.playbackPresentation,
                togglePlayback: model.playbackToggle,
                stopPlayback: {
                    model.stopPlayback()
                },
                seekPlayback: model.seekPlayback
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            autoMeetingPanel.dismiss()
            playbackWindow.dismiss()
        }
        .onDisappear {
            autoMeetingPanel.dismiss()
            playbackWindow.dismiss()
        }
    }

    private var workspaceNavigation: Binding<RecorderNavigationState> {
        navigationOverride ?? $navigation
    }
}

struct RecorderWorkspaceContent: View {
    @ObservedObject var model: AppModel
    @Binding var navigation: RecorderNavigationState

    var body: some View {
        HStack(spacing: 0) {
            RecorderSidebar(selection: selection)
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            Divider()
            destinationContent
        }
        .frame(minWidth: 860, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selection: Binding<RecorderDestination> {
        Binding(
            get: { navigation.selection },
            set: { navigation.select($0, hasUnsavedChanges: false) }
        )
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch navigation.selection {
        case .record:
            RecordDashboardView(model: model) {
                navigation.select(.settings, hasUnsavedChanges: false)
            }
        case .recordings:
            RecordingsLibraryView(model: model)
        case .settings:
            RecorderSettingsView(model: model)
        }
    }
}
