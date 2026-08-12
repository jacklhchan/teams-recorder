import SwiftUI

struct ContentView: View {
    @ObservedObject private var model: AppModel
    @ObservedObject private var playbackFeature: PlaybackFeatureModel
    @State private var autoMeetingPanel:
        any TeamsAutoMeetingCountdownPresenting
    @State private var playbackWindow:
        any PlaybackWindowPresenting
    @State private var navigation = RecorderNavigationState(selection: .record)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
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
        _playbackFeature = ObservedObject(
            wrappedValue: model.playbackFeature
        )
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
            navigation: workspaceNavigation,
            columnVisibility: $columnVisibility
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
            of: playbackFeature.activeSessionID,
            initial: true
        ) { _, sessionID in
            guard sessionID != nil,
                  let session = playbackFeature.presentation.session else {
                playbackWindow.dismiss()
                return
            }
            playbackWindow.present(
                presentation: playbackFeature.presentation,
                togglePlayback: model.playbackToggle,
                stopPlayback: {
                    model.stopPlayback()
                },
                seekPlayback: model.seekPlayback,
                revealRecording: {
                    model.revealRecording(session)
                },
                setVolume: model.setPlaybackVolume,
                setRate: model.setPlaybackRate
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
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RecorderSidebar(
                selection: selection,
                outputFolder: model.outputFolder,
                storageWarning: model.storageWarningMessage
            )
                .navigationSplitViewColumnWidth(
                    min: 185,
                    ideal: 232,
                    max: 278
                )
        } detail: {
            destinationContent
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 680)
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
        case .health:
            RecordingHealthView(model: model)
        case .recovery:
            RecoveryCenterView(model: model)
        case .settings:
            RecorderSettingsView(model: model)
        }
    }
}
