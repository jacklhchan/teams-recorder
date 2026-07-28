import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private final class TeamsIntegrationIngress: @unchecked Sendable {
    typealias Operation = @MainActor @Sendable () -> Void
    typealias Scheduler = (@escaping Operation) -> Void

    private let lock = NSLock()
    private let scheduler: Scheduler
    private var pending: [Operation] = []
    private var drainScheduled = false

    init(scheduler: @escaping Scheduler) {
        self.scheduler = scheduler
    }

    func enqueue(_ operation: @escaping Operation) {
        lock.lock()
        pending.append(operation)
        let shouldScheduleDrain = !drainScheduled
        drainScheduled = true
        lock.unlock()

        guard shouldScheduleDrain else { return }
        scheduler { @MainActor [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()

            batch.forEach { $0() }
        }
    }
}

enum RecordingOwnership: Equatable {
    case manual
    case teamsAutomatic
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var selectedMicDevice: AudioDevice?
    @Published private(set) var selectedMicrophoneUID: String?
    @Published var availableCaptureApplications: [CaptureApplication] = []
    @Published var captureSelection = CaptureSelection()
    @Published var resolvedCaptureSelection: ResolvedCaptureSelection = .allSystemAudio
    @Published var systemAudioPermission: CapturePermissionState = .notDetermined
    @Published var microphonePermission: CapturePermissionState = .notDetermined
    @Published private(set) var captureConnectionState: CaptureConnectionState = .connected
    @Published var isCaptureLifecycleWorking = false
    @Published var outputFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads")
    @Published var statusMessage = "Ready"
    @Published var sessions: [RecordingSession] = []
    @Published var lastHealthReport: RecordingHealthReport?
    @Published private(set) var lastRecordingSavedAsM4A = false
    @Published var isRunningTestRecording = false
    @Published var playingSessionID: RecordingSession.ID?
    @Published var playbackProgress: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    @Published var isPlaybackActive = false
    @Published var transcribingSessionID: RecordingSession.ID?
    @Published var transcriptionStatus: String = ""
    @Published var lastTranscriptionSessionID: RecordingSession.ID?
    @Published var lastTranscriptionStatus: String = ""
    @Published var lastTranscriptionDidFail = false
    @Published var transcriptURLsBySessionID: [RecordingSession.ID: URL] = [:]
    @Published var transcriptLogURLsBySessionID: [RecordingSession.ID: URL] = [:]
    @Published var transcriptionStatesBySessionID: [RecordingSession.ID: TranscriptionState] = [:]
    @Published var isPreparingASRModel = false
    @Published var asrModelReady = false
    @Published var asrModelStatus = "Checking oMLX ASR server..."
    @Published var asrModelLogURL: URL?
    @Published private(set) var inputMuteControlAvailable = false
    @Published private(set) var virtualMicInstallationState: VirtualMicInstallationState = .absent
    @Published private(set) var teamsMuteSyncStatus: TeamsMuteSyncStatus = .disabled
    @Published private(set) var teamsMuteSyncEnabled: Bool
    @Published private(set) var teamsAutoMeetingEnabled: Bool
    @Published private(set) var teamsAutoMeetingState: TeamsAutoMeetingState
    @Published private(set) var recordingOwnership: RecordingOwnership?
    @Published private(set) var teamsConnectionStatus: TeamsMuteSyncStatus = .disabled
    @Published private(set) var localMicMuted = false
    @Published private(set) var nativeInputMicMuted = false
    @Published private(set) var teamsMicMuted = false
    @Published private(set) var isScreenCaptureAllowedByStorage = true
    @Published private(set) var screenCaptureStorageRestrictionReason: String?
    @Published private(set) var storageWarningMessage: String?
    @Published private(set) var isTeamsScreenCaptureRequested = false
    @Published private(set) var teamsManualWindowIdentity: TeamsWindowIdentity?
    @Published private(set) var teamsScreenCaptureCandidates: [TeamsWindowDescriptor] = []

    let recorder: RecordingEngine
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    private let playbackCoordinator: any PlaybackCoordinating
    private var playbackLoadTask: Task<Void, Never>?
    private var playbackGeneration: UInt64 = 0
    private var playbackSessionID: RecordingSession.ID?
    private var transcriptionProcess: (any TranscriptionProcessing)?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionGeneration: UInt64 = 0
    private var activeTranscriptionAttempt: UUID?
    private var activeTranscriptionSession: RecordingSession?
    private var transcriptionCancellationRequested = false
    private var asrPrepareProcess: Process?
    private let capturePersistence: CaptureSelectionPersistence
    private let inputDevices: () -> [AudioDevice]
    private let defaultInputDeviceID: () -> AudioDeviceID?
    private let inputMuteController: InputMuteControlling
    private let teamsMuteSyncClient: TeamsMuteSyncing
    private let microphoneMuteGate: MicrophoneMuteGate
    private let teamsMuteRelay: TeamsMuteRelay
    private let teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator
    private let teamsIntegrationIngress: TeamsIntegrationIngress
    private let virtualMicStateProvider: () -> VirtualMicInstallationState
    private let recordingSessionLoader: @Sendable (URL) -> [RecordingSession]
    private let recordingSessionRecovery: @Sendable (URL) -> Void
    private let permissionRequestHandler: (@MainActor (Bool, Bool) async -> Void)?
    private let volumeCapacityProvider: any VolumeCapacityProviding
    private let storagePolicy: RecordingStoragePolicy
    private let storageMonitorTick: @Sendable () async -> Void
    private let testRecordingDelay: @Sendable () async -> Void
    private let teamsScreenRefreshTick: @Sendable () async -> Void
    private let transcriptionAudioPreparer: any TranscriptionAudioPreparing
    private let transcriptionProcessLauncher: any TranscriptionProcessLaunching
    private let transcriptionScriptURL: URL?
    private let defaults: UserDefaults
    private let recordingSessionLoadingQueue = DispatchQueue(
        label: "local.meeting.recorder.recording-library",
        qos: .userInitiated
    )
    private var cancellables: Set<AnyCancellable> = []
    private var captureLifecycleGate = CaptureLifecycleGate()
    private var captureLifecycleTask: Task<Void, Never>?
    private struct RecordingStartAttempt: Equatable {
        let id: UUID
        var ownership: RecordingOwnership
        let lifecycleToken: CaptureLifecycleToken
    }
    private var pendingRecordingAttempt: RecordingStartAttempt?
    private var cancelledRecordingAttemptStops:
        [UUID: CaptureLifecycleToken] = [:]
    private var independentlyFinalizedRecordingAttempts: Set<UUID> = []
    private var automaticStopIntentToken: CaptureLifecycleToken?
    private var inputMuteHandlingInstalled = false
    private var teamsIntegrationInstalled = false
    private var teamsIntegrationGeneration: UInt64 = 0
    private var teamsMuteRelayGeneration: UInt64?
    private var pendingTeamsMeetingState: TeamsMeetingState?
    private var lastAuthorizedTeamsMeetingState: TeamsMeetingState?
    private var recordingSessionRefreshGeneration: UInt = 0
    private var recoveredLibraryFolders: Set<URL> = []
    private var storageMonitorTask: Task<Void, Never>?
    private var storageMonitorGeneration: UInt64 = 0
    private var testRecordingStopTask: Task<Void, Never>?
    private var teamsScreenRefreshTask: Task<Void, Never>?
    private var teamsScreenRefreshGeneration: UInt64 = 0
    private var teamsScreenCaptureIntentGeneration: UInt64 = 0
    private var teamsMeetingActive = false

    private static let teamsMuteSyncEnabledKey = "teamsMuteSyncEnabled"
    private static let teamsAutoMeetingEnabledKey = "teamsAutoMeetingEnabled"

    init(
        defaults: UserDefaults = .standard,
        recorder: RecordingEngine? = nil,
        inputDevices: @escaping () -> [AudioDevice] = AudioDeviceManager.inputDevices,
        defaultInputDeviceID: @escaping () -> AudioDeviceID? = AudioDeviceManager.defaultInputDeviceID,
        performStartupWork: Bool = true,
        inputMuteControllerFactory: (
            (@escaping (Bool) -> Void) -> InputMuteControlling
        )? = nil,
        teamsMuteSyncClient: TeamsMuteSyncing? = nil,
        virtualMicStateProvider: @escaping () -> VirtualMicInstallationState = {
            VirtualMicInstallation.currentState()
        },
        recordingSessionLoader: @escaping @Sendable (URL) -> [RecordingSession] = {
            RecordingSessionStore.load(from: $0)
        },
        recordingSessionRecovery: @escaping @Sendable (URL) -> Void = {
            IncompleteSessionRecovery().recover(in: $0)
        },
        permissionRequestHandler: (@MainActor (Bool, Bool) async -> Void)? = nil,
        volumeCapacityProvider: any VolumeCapacityProviding = SelectedVolumeCapacityProvider(),
        storagePolicy: RecordingStoragePolicy = RecordingStoragePolicy(),
        storageMonitorTick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(15))
        },
        testRecordingDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(10))
        },
        teamsScreenRefreshTick: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        },
        transcriptionAudioPreparer: any TranscriptionAudioPreparing = TranscriptionAudioPreparer(),
        transcriptionProcessLauncher: any TranscriptionProcessLaunching = FoundationTranscriptionProcessLauncher(),
        transcriptionScriptURL: URL? = nil,
        playbackCoordinator: (any PlaybackCoordinating)? = nil,
        teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil,
        teamsIntegrationScheduler: @escaping (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        let activeRecorder = recorder ?? RecordingEngine()
        let autoCoordinator = teamsAutoMeetingCoordinator
            ?? TeamsAutoMeetingCoordinator()
        self.recorder = activeRecorder
        self.teamsAutoMeetingCoordinator = autoCoordinator
        teamsIntegrationIngress = TeamsIntegrationIngress(
            scheduler: teamsIntegrationScheduler
        )
        self.inputDevices = inputDevices
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaults = defaults
        teamsMuteSyncEnabled = defaults.object(
            forKey: Self.teamsMuteSyncEnabledKey
        ) as? Bool ?? true
        teamsAutoMeetingEnabled = defaults.bool(
            forKey: Self.teamsAutoMeetingEnabledKey
        )
        teamsAutoMeetingState = autoCoordinator.state
        self.virtualMicStateProvider = virtualMicStateProvider
        self.recordingSessionLoader = recordingSessionLoader
        self.recordingSessionRecovery = recordingSessionRecovery
        self.permissionRequestHandler = permissionRequestHandler
        self.volumeCapacityProvider = volumeCapacityProvider
        self.storagePolicy = storagePolicy
        self.storageMonitorTick = storageMonitorTick
        self.testRecordingDelay = testRecordingDelay
        self.teamsScreenRefreshTick = teamsScreenRefreshTick
        self.transcriptionAudioPreparer = transcriptionAudioPreparer
        self.transcriptionProcessLauncher = transcriptionProcessLauncher
        self.transcriptionScriptURL = transcriptionScriptURL
        self.playbackCoordinator = playbackCoordinator ?? PlaybackCoordinator()
        let microphoneMuteGate = MicrophoneMuteGate { [weak activeRecorder] muted in
            activeRecorder?.applyInputMuteToAudioPaths(muted)
        }
        self.microphoneMuteGate = microphoneMuteGate
        teamsMuteRelay = TeamsMuteRelay(
            microphoneMuteGate: microphoneMuteGate
        )
        let applyMuteToAudioPaths: (Bool) -> Void = { muted in
            microphoneMuteGate.setNativeInputMuted(
                muted,
                ensureAudioGateIsApplied: true
            )
        }
        if let inputMuteControllerFactory {
            inputMuteController = inputMuteControllerFactory(applyMuteToAudioPaths)
        } else {
            inputMuteController = InputMuteController(
                applyMuteToAudioPaths: applyMuteToAudioPaths
            )
        }
        self.teamsMuteSyncClient = teamsMuteSyncClient ?? TeamsMuteSyncClient(
            tokenStore: UserDefaultsTeamsPairingTokenStore(defaults: defaults)
        )
        capturePersistence = CaptureSelectionPersistence(defaults: defaults)
        captureSelection = capturePersistence.loadSelection()
        selectedMicrophoneUID = capturePersistence.loadMicrophoneUID()
        self.playbackCoordinator.onSnapshot = { [weak self] snapshot in
            self?.handlePlaybackSnapshot(snapshot)
        }
        autoCoordinator.onStateChange = { [weak self] state in
            self?.teamsAutoMeetingState = state
        }
        autoCoordinator.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .startRecording:
                self.beginRecording(
                    ownership: .teamsAutomatic,
                    requestPermissions: false
                )
            case .cancelAutomaticStart:
                self.cancelPendingAutomaticRecordingStart()
            case .stopRecording:
                guard self.recordingOwnership == .teamsAutomatic else {
                    return
                }
                self.stopCaptureLifecycle(
                    playAfterStop: false,
                    automaticMeetingEnd: true
                )
            case .transferRecordingToManual:
                if self.recordingOwnership == .teamsAutomatic {
                    self.recordingOwnership = .manual
                }
            }
        }
        autoCoordinator.setEnabled(teamsAutoMeetingEnabled)
        observeRecorderConnection()
        observeRecorderRecordingState()
        refreshDevices()
        guard performStartupWork else { return }
        installInputMuteHandling()
        if teamsIntegrationRequired {
            installTeamsIntegrationIfNeeded()
        }
        hotKeyManager.register()
        refreshPermissionPreflight()
        refreshCaptureApplications()
        refreshSessions()
        refreshASRModelStatus()
        prepareASRModelIfNeeded()
    }

    deinit {
        storageMonitorTask?.cancel()
        testRecordingStopTask?.cancel()
        playbackLoadTask?.cancel()
        transcriptionTask?.cancel()
        teamsScreenRefreshTask?.cancel()
        transcriptionProcess?.terminate()
        teamsMuteRelay.invalidate()
        teamsMuteSyncClient.stop()
        inputMuteController.uninstall()
    }

    func refreshDevices() {
        devices = inputDevices()
        virtualMicInstallationState = virtualMicStateProvider()
        if let selectedMicrophoneUID {
            selectedMicDevice = devices.first { $0.uid == selectedMicrophoneUID }
        } else if selectedMicDevice == nil {
            let defaultID = defaultInputDeviceID()
            selectedMicDevice = devices.first { $0.id == defaultID }
        }
    }

    func refreshAllCaptureState() {
        refreshDevices()
        refreshPermissionPreflight()
        refreshCaptureApplications()
    }

    func refreshCaptureApplications() {
        beginCaptureLifecycle(.refresh) { [self] token in
            guard systemAudioPermission == .granted else { return }
            do {
                let applications = try await recorder.refreshCaptureApplications()
                guard captureLifecycleGate.accepts(token) else { return }
                let previousTeamsProcessID = selectedTeamsApplication?.processID
                availableCaptureApplications = applications
                resolvedCaptureSelection = CaptureConnectionProjection.resolveAfterRefresh(
                    selection: captureSelection,
                    applications: applications,
                    connectionState: captureConnectionState
                )
                if previousTeamsProcessID != selectedTeamsApplication?.processID {
                    handleTeamsScreenSourceChange()
                }
                if !recorder.isRecording {
                    await startMonitoringIfReady()
                }
            } catch {
                guard captureLifecycleGate.accepts(token) else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    func selectCaptureMode(_ mode: CaptureMode) {
        guard sourceControlsEnabled else { return }
        captureSelection.mode = mode
        captureConnectionState = .connected
        resolvedCaptureSelection = CaptureSelectionResolver.resolve(
            selection: captureSelection,
            availableApplications: availableCaptureApplications
        )
        persistCaptureSelection()
        handleTeamsScreenSourceChange()
        refreshCaptureApplications()
    }

    func selectCaptureApplication(bundleIdentifier: String) {
        guard sourceControlsEnabled else { return }
        captureSelection.selectedBundleIdentifier = bundleIdentifier
        captureConnectionState = .connected
        resolvedCaptureSelection = CaptureSelectionResolver.resolve(
            selection: captureSelection,
            availableApplications: availableCaptureApplications,
            reconnect: true
        )
        persistCaptureSelection()
        handleTeamsScreenSourceChange()
        refreshCaptureApplications()
    }

    func selectMicrophone(_ device: AudioDevice?) {
        guard sourceControlsEnabled else { return }
        selectedMicDevice = device
        selectedMicrophoneUID = device?.uid
        capturePersistence.saveMicrophoneUID(selectedMicrophoneUID)
        refreshCaptureApplications()
    }

    var sourceControlsEnabled: Bool {
        !recorder.isRecording && !isCaptureLifecycleWorking
    }

    var captureReadiness: CaptureReadiness {
        CaptureReadiness.evaluate(
            permission: systemAudioPermission,
            selection: captureSelection,
            resolvedSelection: resolvedCaptureSelection,
            microphoneAvailable: microphonePermission == .granted && selectedMicDevice != nil
        )
    }

    var canReconnect: Bool {
        CaptureConnectionProjection.canReconnect(
            systemPermission: systemAudioPermission,
            selection: captureSelection,
            connectionState: captureConnectionState,
            connectionSnapshot: recorder.captureConnectionSnapshot,
            isLifecycleWorking: isCaptureLifecycleWorking
        )
    }

    var showsReconnect: Bool {
        CaptureConnectionProjection.canReconnect(
            systemPermission: systemAudioPermission,
            selection: captureSelection,
            connectionState: captureConnectionState,
            connectionSnapshot: recorder.captureConnectionSnapshot,
            isLifecycleWorking: false
        )
    }

    var systemAudioSubtitle: String {
        switch resolvedCaptureSelection {
        case .allSystemAudio: "All System Audio"
        case .application(let app): app.name
        case .disconnected: "App audio disconnected"
        }
    }

    var showsTeamsScreenCaptureControls: Bool {
        selectedTeamsApplication != nil
    }

    var isFinalizingRecording: Bool {
        recorder.isRecording &&
            captureLifecycleGate.activeOperation == .stop
    }

    var isTeamsScreenCaptureToggleDisabled: Bool {
        guard recorder.isRecording,
              !isCaptureLifecycleWorking else { return true }
        if isTeamsScreenCaptureRequested {
            return false
        }
        guard isScreenCaptureAllowedByStorage else { return true }
        switch recorder.meetingScreenCaptureState {
        case .unavailable, .failed: return true
        default: return false
        }
    }

    var teamsScreenStatusText: String {
        if !isScreenCaptureAllowedByStorage { return TeamsScreenStatusText.unavailable }
        if recorder.isRecording, !isTeamsScreenCaptureRequested {
            return TeamsScreenStatusText.off
        }
        switch recorder.meetingScreenCaptureState {
        case .unavailable, .failed: return TeamsScreenStatusText.unavailable
        case .off: return TeamsScreenStatusText.off
        case .ready: return TeamsScreenStatusText.ready
        case .capturing: return TeamsScreenStatusText.capturing
        case .awaitingFrames: return TeamsScreenStatusText.awaitingFrames
        case .frameUnavailable: return TeamsScreenStatusText.framesUnavailable
        case .targetLost: return TeamsScreenStatusText.reconnecting
        case .waiting:
            return recorder.isRecording && !isTeamsScreenCaptureRequested
                ? TeamsScreenStatusText.off : TeamsScreenStatusText.waiting
        }
    }

    func setTeamsScreenCaptureRequested(_ requested: Bool) async {
        teamsScreenCaptureIntentGeneration &+= 1
        let intentGeneration = teamsScreenCaptureIntentGeneration
        guard recorder.isRecording else { return }
        if !requested {
            guard captureLifecycleGate.activeOperation != .stop else { return }
            isTeamsScreenCaptureRequested = false
            await recorder.setScreenCaptureRequested(false)
            guard intentGeneration == teamsScreenCaptureIntentGeneration else {
                return
            }
            restartTeamsScreenRefreshIfNeeded()
            return
        }

        guard !isCaptureLifecycleWorking,
              isScreenCaptureAllowedByStorage,
              let selectedTeamsApplication,
              isTeamsScreenCaptureActionAvailable else { return }
        let selectedProcessID = selectedTeamsApplication.processID
        isTeamsScreenCaptureRequested = true
        await refreshTeamsScreenCaptureNow()
        guard acceptsTeamsScreenCaptureOnIntent(
            generation: intentGeneration,
            selectedProcessID: selectedProcessID
        ) else { return }
        await recorder.setScreenCaptureRequested(true)
        guard acceptsTeamsScreenCaptureOnIntent(
            generation: intentGeneration,
            selectedProcessID: selectedProcessID
        ) else { return }
        restartTeamsScreenRefreshIfNeeded()
    }

    private var isTeamsScreenCaptureActionAvailable: Bool {
        switch recorder.meetingScreenCaptureState {
        case .unavailable, .failed:
            return false
        default:
            return true
        }
    }

    private func acceptsTeamsScreenCaptureOnIntent(
        generation: UInt64,
        selectedProcessID: pid_t
    ) -> Bool {
        generation == teamsScreenCaptureIntentGeneration
            && isTeamsScreenCaptureRequested
            && recorder.isRecording
            && !isCaptureLifecycleWorking
            && isScreenCaptureAllowedByStorage
            && selectedTeamsApplication?.processID == selectedProcessID
            && isTeamsScreenCaptureActionAvailable
    }

    private func invalidateTeamsScreenCaptureIntent() {
        teamsScreenCaptureIntentGeneration &+= 1
    }

    func selectTeamsScreenCaptureWindow(_ identity: TeamsWindowIdentity?) async {
        guard let app = selectedTeamsApplication,
              identity == nil || identity?.processID == app.processID else { return }
        teamsManualWindowIdentity = identity
        await refreshTeamsScreenCaptureNow()
    }

    func refreshTeamsScreenCaptureNow() async {
        guard let selectedTeamsApplication else { return }
        let generation = teamsScreenRefreshGeneration
        await recorder.refreshTeamsWindows(
            selectedTeamsProcessID: selectedTeamsApplication.processID,
            meetingActive: teamsMeetingActive,
            manualOverride: teamsManualWindowIdentity
        )
        guard generation == teamsScreenRefreshGeneration else { return }
        reconcileTeamsManualWindowIdentity()
        refreshTeamsScreenCandidateProjection()
    }

    private func reconcileTeamsManualWindowIdentity() {
        guard teamsManualWindowIdentity != nil,
              let resolvedIdentity = recorder.resolvedTeamsManualWindowIdentity else { return }
        teamsManualWindowIdentity = resolvedIdentity
    }

    private var selectedTeamsApplication: CaptureApplication? {
        guard case let .application(application) = resolvedCaptureSelection,
              application.bundleIdentifier == "com.microsoft.teams2" else { return nil }
        return application
    }

    private func handleTeamsScreenSourceChange() {
        invalidateTeamsScreenRefresh()
        invalidateTeamsScreenCaptureIntent()
        isTeamsScreenCaptureRequested = false
        teamsMeetingActive = false
        teamsManualWindowIdentity = nil
        teamsScreenCaptureCandidates = []
        recorder.resetTeamsWindowResolution()
        guard selectedTeamsApplication != nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshTeamsScreenCaptureNow()
        }
    }

    private func refreshTeamsScreenCandidateProjection() {
        guard let application = selectedTeamsApplication else {
            teamsScreenCaptureCandidates = []
            return
        }
        teamsScreenCaptureCandidates = recorder.teamsWindowCandidates.filter {
            $0.identity.processID == application.processID
        }
    }

    private func restartTeamsScreenRefreshIfNeeded() {
        invalidateTeamsScreenRefresh()
        guard selectedTeamsApplication != nil,
              recorder.isRecording || isTeamsScreenCaptureRequested else { return }
        let generation = teamsScreenRefreshGeneration
        let tick = teamsScreenRefreshTick
        teamsScreenRefreshTask = Task { @MainActor [weak self, tick] in
            while !Task.isCancelled {
                await tick()
                guard !Task.isCancelled, let self,
                      generation == self.teamsScreenRefreshGeneration else { return }
                await self.refreshTeamsScreenCaptureNow()
            }
        }
    }

    private func invalidateTeamsScreenRefresh() {
        teamsScreenRefreshGeneration &+= 1
        teamsScreenRefreshTask?.cancel()
        teamsScreenRefreshTask = nil
    }

    func reconnectSelectedApplication() {
        guard canReconnect else { return }
        beginCaptureLifecycle(.reconnect, allowedWhileRecording: true) { [self] token in
            do {
                let applications = try await recorder.refreshCaptureApplications()
                guard captureLifecycleGate.accepts(token) else { return }
                availableCaptureApplications = applications
                let resolved = CaptureSelectionResolver.resolve(
                    selection: captureSelection,
                    availableApplications: applications,
                    previousResolution: resolvedCaptureSelection,
                    reconnect: true
                )
                guard case .application = resolved else {
                    resolvedCaptureSelection = .disconnected(captureSelection.selectedBundleIdentifier ?? "")
                    statusMessage = "Selected app unavailable"
                    return
                }
                try await recorder.reconnect(selection: resolved)
                guard captureLifecycleGate.accepts(token) else { return }
                resolvedCaptureSelection = resolved
                captureConnectionState = .connected
                statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
            } catch {
                guard captureLifecycleGate.accepts(token) else { return }
                resolvedCaptureSelection = .disconnected(captureSelection.selectedBundleIdentifier ?? "")
                statusMessage = error.localizedDescription
            }
        }
    }

    func startOrStop() {
        if recorder.isRecording {
            stopCaptureLifecycle(playAfterStop: false)
            return
        }
        if takeOverPendingAutomaticRecordingStart() {
            return
        }

        teamsAutoMeetingCoordinator.manualRecordingStarted()
        beginRecording(ownership: .manual, requestPermissions: true)
    }

    private func takeOverPendingAutomaticRecordingStart() -> Bool {
        guard var attempt = pendingRecordingAttempt,
              attempt.ownership == .teamsAutomatic,
              captureLifecycleGate.accepts(attempt.lifecycleToken) else {
            return false
        }
        attempt.ownership = .manual
        pendingRecordingAttempt = attempt
        teamsAutoMeetingCoordinator.manualRecordingStarted()
        return true
    }

    private func beginRecording(
        ownership: RecordingOwnership,
        requestPermissions: Bool
    ) {
        guard !recorder.isRecording,
              let lifecycleToken = captureLifecycleGate.begin(.start) else {
            if ownership == .teamsAutomatic {
                let message = "Another capture operation is in progress."
                statusMessage = message
                teamsAutoMeetingCoordinator.automaticStartFailed(message)
            }
            return
        }

        let attempt = RecordingStartAttempt(
            id: UUID(),
            ownership: ownership,
            lifecycleToken: lifecycleToken
        )
        pendingRecordingAttempt = attempt
        isCaptureLifecycleWorking = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRecordingStart(
                attempt: attempt,
                requestPermissions: requestPermissions
            )
        }
        captureLifecycleTask = task
    }

    private func performRecordingStart(
        attempt: RecordingStartAttempt,
        requestPermissions: Bool
    ) async {
        if requestPermissions {
            await requestPermissionsFromExplicitAction()
            guard acceptsRecordingAttempt(attempt) else {
                await completeRecordingStartAttempt(attempt)
                return
            }
        }

        switch captureReadiness {
        case .ready:
            break
        case .blocked(let message):
            if let currentAttempt = acceptedRecordingAttempt(
                matching: attempt
            ) {
                statusMessage = message
                if currentAttempt.ownership == .teamsAutomatic {
                    teamsAutoMeetingCoordinator.automaticStartBlocked(message)
                }
            }
            await completeRecordingStartAttempt(attempt)
            return
        case .reconnectRequired:
            if let currentAttempt = acceptedRecordingAttempt(
                matching: attempt
            ) {
                statusMessage = readinessMessage
                if currentAttempt.ownership == .teamsAutomatic {
                    teamsAutoMeetingCoordinator.automaticStartFailed(
                        readinessMessage
                    )
                }
            }
            await completeRecordingStartAttempt(attempt)
            return
        }

        guard acceptsRecordingAttempt(attempt) else {
            await completeRecordingStartAttempt(attempt)
            return
        }
        let recordingFolder = outputFolder
        guard await prepareStorageForNewRecording(in: recordingFolder) else {
            if acceptedRecordingAttempt(matching: attempt)?.ownership
                == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartFailed(statusMessage)
            }
            await completeRecordingStartAttempt(attempt)
            return
        }
        guard acceptsRecordingAttempt(attempt) else {
            await completeRecordingStartAttempt(attempt)
            return
        }
        guard outputFolder == recordingFolder else {
            if let currentAttempt = acceptedRecordingAttempt(
                matching: attempt
            ) {
                statusMessage = "Output folder changed. Start recording again."
                if currentAttempt.ownership == .teamsAutomatic {
                    teamsAutoMeetingCoordinator.automaticStartFailed(
                        statusMessage
                    )
                }
            }
            await completeRecordingStartAttempt(attempt)
            return
        }

        do {
            try await recorder.start(
                selection: resolvedCaptureSelection,
                microphoneUID: selectedMicDevice?.uid,
                baseFolder: recordingFolder
            )
            guard acceptsRecordingAttempt(attempt) else {
                await finalizeLateRecordingStart(attempt)
                return
            }
            invalidateTeamsScreenCaptureIntent()
            isTeamsScreenCaptureRequested = false
            await refreshTeamsScreenCaptureNow()
            guard acceptsRecordingAttempt(attempt), recorder.isRecording else {
                await finalizeLateRecordingStart(attempt)
                return
            }
            restartTeamsScreenRefreshIfNeeded()
            if !isScreenCaptureAllowedByStorage {
                await recorder.setScreenCaptureRequested(false)
                guard acceptsRecordingAttempt(attempt), recorder.isRecording else {
                    await finalizeLateRecordingStart(attempt)
                    return
                }
            }
            guard let currentAttempt = acceptedRecordingAttempt(
                matching: attempt
            ) else {
                await finalizeLateRecordingStart(attempt)
                return
            }
            recordingOwnership = currentAttempt.ownership
            pendingRecordingAttempt = nil
            statusMessage = "Recording"
            lastHealthReport = nil
            startStorageMonitoring(folder: recordingFolder)
            if currentAttempt.ownership == .teamsAutomatic {
                teamsAutoMeetingCoordinator.automaticStartSucceeded()
            }
        } catch {
            if let currentAttempt = acceptedRecordingAttempt(
                matching: attempt
            ) {
                statusMessage = error.localizedDescription
                if currentAttempt.ownership == .teamsAutomatic {
                    teamsAutoMeetingCoordinator.automaticStartFailed(
                        error.localizedDescription
                    )
                }
            }
        }
        await completeRecordingStartAttempt(attempt)
    }

    private func acceptsRecordingAttempt(
        _ attempt: RecordingStartAttempt
    ) -> Bool {
        acceptedRecordingAttempt(matching: attempt) != nil
    }

    private func acceptedRecordingAttempt(
        matching attempt: RecordingStartAttempt
    ) -> RecordingStartAttempt? {
        guard let currentAttempt = pendingRecordingAttempt,
              currentAttempt.id == attempt.id,
              currentAttempt.lifecycleToken == attempt.lifecycleToken,
              captureLifecycleGate.accepts(attempt.lifecycleToken) else {
            return nil
        }
        return currentAttempt
    }

    private func cancelPendingAutomaticRecordingStart() {
        guard let attempt = pendingRecordingAttempt,
              attempt.ownership == .teamsAutomatic else { return }
        pendingRecordingAttempt = nil
        guard let stopToken = captureLifecycleGate.cancelAndBeginStop() else {
            return
        }
        cancelledRecordingAttemptStops[attempt.id] = stopToken
        isCaptureLifecycleWorking = true
    }

    private func finalizeLateRecordingStart(
        _ attempt: RecordingStartAttempt
    ) async {
        let acceptedAttempt = acceptedRecordingAttempt(matching: attempt)
        let stoppedDuringAcceptedStart =
            acceptedAttempt != nil && !recorder.isRecording
        if recorder.isRecording,
           !independentlyFinalizedRecordingAttempts.contains(attempt.id) {
            await finishRecording(
                playAfterStop: false,
                automaticStopToken: nil
            )
        }
        if stoppedDuringAcceptedStart,
           acceptedAttempt?.ownership == .teamsAutomatic {
            let message = "Capture stopped during automatic startup."
            statusMessage = message
            teamsAutoMeetingCoordinator.automaticStartFailed(message)
        }
        await completeRecordingStartAttempt(attempt)
    }

    private func completeRecordingStartAttempt(
        _ attempt: RecordingStartAttempt
    ) async {
        independentlyFinalizedRecordingAttempts.remove(attempt.id)
        if pendingRecordingAttempt?.id == attempt.id {
            pendingRecordingAttempt = nil
        }
        if let stopToken = cancelledRecordingAttemptStops.removeValue(
            forKey: attempt.id
        ) {
            finishCaptureLifecycle(stopToken)
        } else {
            finishCaptureLifecycle(attempt.lifecycleToken)
        }
    }

    func runTestRecording() {
        guard !isRunningTestRecording else { return }
        guard !recorder.isRecording else {
            statusMessage = "Stop the current recording before running a test."
            return
        }

        teamsAutoMeetingCoordinator.manualRecordingStarted()
        beginCaptureLifecycle(.test) { [self] token in
            isRunningTestRecording = true
            lastHealthReport = nil
            await requestPermissionsFromExplicitAction()
            guard captureLifecycleGate.accepts(token) else { return }
            guard captureReadiness == .ready else {
                isRunningTestRecording = false
                statusMessage = readinessMessage
                return
            }
            let recordingFolder = outputFolder
            guard await prepareStorageForNewRecording(in: recordingFolder) else {
                isRunningTestRecording = false
                return
            }
            guard captureLifecycleGate.accepts(token) else { return }
            guard outputFolder == recordingFolder else {
                isRunningTestRecording = false
                statusMessage = "Output folder changed. Start recording again."
                return
            }
            do {
                try await recorder.start(
                    selection: resolvedCaptureSelection,
                    microphoneUID: selectedMicDevice?.uid,
                    baseFolder: recordingFolder,
                    folderPrefix: "test"
                )
                guard testRecordingContinues(token) else {
                    clearTestRecordingRuntimeState()
                    return
                }
                invalidateTeamsScreenCaptureIntent()
                isTeamsScreenCaptureRequested = false
                await refreshTeamsScreenCaptureNow()
                guard testRecordingContinues(token) else {
                    clearTestRecordingRuntimeState()
                    return
                }
                restartTeamsScreenRefreshIfNeeded()
                if !isScreenCaptureAllowedByStorage {
                    await recorder.setScreenCaptureRequested(false)
                    guard testRecordingContinues(token) else {
                        clearTestRecordingRuntimeState()
                        return
                    }
                }
                guard testRecordingContinues(token) else {
                    clearTestRecordingRuntimeState()
                    return
                }
                recordingOwnership = .manual
                statusMessage = "Test recording: 10 seconds"
                startStorageMonitoring(folder: recordingFolder)
            } catch {
                clearTestRecordingRuntimeState()
                guard captureLifecycleGate.accepts(token) else { return }
                statusMessage = error.localizedDescription
                return
            }
            testRecordingStopTask?.cancel()
            let delay = testRecordingDelay
            testRecordingStopTask = Task { @MainActor [weak self, delay] in
                await delay()
                guard !Task.isCancelled,
                      let self,
                      self.isRunningTestRecording else { return }
                self.stopCaptureLifecycle(playAfterStop: true)
            }
        }
    }

    private func testRecordingContinues(
        _ token: CaptureLifecycleToken
    ) -> Bool {
        captureLifecycleGate.accepts(token) && recorder.isRecording
    }

    private func clearTestRecordingRuntimeState() {
        isRunningTestRecording = false
        testRecordingStopTask?.cancel()
        testRecordingStopTask = nil
        if !recorder.isRecording, recordingOwnership == .manual {
            recordingOwnership = nil
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputFolder
        panel.prompt = "Use Folder"

        if panel.runModal() == .OK, let url = panel.url {
            setOutputFolder(url)
        }
    }

    func setOutputFolder(_ folder: URL) {
        outputFolder = folder
        sessions = []
        transcriptionStatesBySessionID = [:]
        transcriptURLsBySessionID = [:]
        transcriptLogURLsBySessionID = [:]
        refreshSessions()
    }

    func chooseAudioFileForTranscription() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ManualTranscriptionImporter.supportedExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Transcribe"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let importedSession = try ManualTranscriptionImporter.importAudioFile(url, into: outputFolder)
            refreshSessions()
            statusMessage = "Audio imported for transcription: \(url.lastPathComponent)"
            transcribe(session: importedSession)
        } catch {
            statusMessage = "Audio import failed: \(error.localizedDescription)"
        }
    }

    func openRecordingFolder() {
        if let folder = recorder.outputFolder {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func refreshSessions() {
        recordingSessionRefreshGeneration &+= 1
        let generation = recordingSessionRefreshGeneration
        let folder = outputFolder
        let loader = recordingSessionLoader
        let recovery = recordingSessionRecovery
        let shouldRecover = recoveredLibraryFolders.insert(folder.standardizedFileURL).inserted

        recordingSessionLoadingQueue.async { [weak self] in
            if shouldRecover { recovery(folder) }
            let loadedSessions = loader(folder)
            let transcriptionStates: [RecordingSession.ID: TranscriptionState] = Dictionary(
                uniqueKeysWithValues: loadedSessions.compactMap { session in
                    guard let state = try? TranscriptionStateStore.load(
                        in: session.folderURL
                    ) else {
                        return nil
                    }
                    return (session.id, state)
                }
            )

            Task { @MainActor [weak self] in
                guard let self,
                      self.recordingSessionRefreshGeneration == generation else {
                    return
                }
                self.sessions = loadedSessions
                self.transcriptionStatesBySessionID = self.projectTranscriptionStates(
                    transcriptionStates
                )
            }
        }
    }

    private func projectTranscriptionStates(
        _ loadedStates: [RecordingSession.ID: TranscriptionState]
    ) -> [RecordingSession.ID: TranscriptionState] {
        var projected = loadedStates.mapValues { state in
            guard [.queued, .uploading, .transcribing].contains(state.phase) else {
                return state
            }
            var interrupted = state
            interrupted.phase = .interrupted
            interrupted.message = "Transcription interrupted. You can start it again."
            interrupted.finishedAt = Date()
            return interrupted
        }

        guard let currentActiveID = transcribingSessionID else {
            return projected
        }
        if let liveState = transcriptionStatesBySessionID[currentActiveID] {
            projected[currentActiveID] = liveState
        } else if let loadedState = loadedStates[currentActiveID] {
            projected[currentActiveID] = loadedState
        }
        return projected
    }

    var playbackPlayer: AVPlayer { playbackCoordinator.player }

    func play(session: RecordingSession) {
        startPlayback(session: session, successStatus: "Playing \(session.displayName)")
    }

    func playbackToggle() {
        guard playbackSessionID != nil else { return }
        if isPlaybackActive {
            playbackCoordinator.pause()
        } else {
            playbackCoordinator.play()
        }
    }

    func stopPlayback(resetStatus: Bool = true) {
        playbackGeneration &+= 1
        playbackLoadTask?.cancel()
        playbackLoadTask = nil
        playbackSessionID = nil
        playbackCoordinator.stop()
        playingSessionID = nil
        playbackProgress = 0
        playbackDuration = 0
        isPlaybackActive = false
        if resetStatus {
            statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
        }
    }

    func seekPlayback(to time: TimeInterval) {
        guard playbackSessionID != nil else { return }
        let generation = playbackGeneration
        let coordinator = playbackCoordinator
        Task { [weak self, coordinator] in
            await coordinator.seek(to: time)
            guard let self, self.playbackGeneration == generation else { return }
        }
    }

    func open(session: RecordingSession) {
        NSWorkspace.shared.open(session.folderURL)
    }

    func transcribe(session: RecordingSession) {
        guard transcriptionTask == nil, transcribingSessionID == nil else {
            statusMessage = "A transcription is already running."
            return
        }
        guard asrModelReady else {
            prepareASRModelIfNeeded()
            statusMessage = "oMLX ASR server is still preparing. Wait until it is ready, then transcribe again."
            return
        }

        let scriptURL = transcriptionScriptURL
            ?? Bundle.main.resourceURL?.appendingPathComponent("transcribe-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/transcribe-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            statusMessage = "Missing transcription launcher: \(scriptURL.path)"
            return
        }

        transcribingSessionID = session.id
        activeTranscriptionSession = session
        transcriptionCancellationRequested = false
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        let attempt = UUID()
        activeTranscriptionAttempt = attempt
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = "Preparing transcription"
        lastTranscriptionDidFail = false
        transcriptionStatus = "Preparing transcription"
        statusMessage = "Preparing transcription"
        updateTranscriptionState(
            .init(phase: .queued, message: transcriptionStatus, startedAt: Date()),
            for: session
        )

        let audioPreparer = transcriptionAudioPreparer
        let processLauncher = transcriptionProcessLauncher
        transcriptionTask = Task { @MainActor [weak self, audioPreparer, processLauncher] in
            var prepared: PreparedTranscriptionAudio?
            defer {
                if let prepared {
                    audioPreparer.cleanup(prepared)
                }
            }

            do {
                try Task.checkCancellation()
                let audio = try await audioPreparer.prepare(for: session)
                prepared = audio
                try Task.checkCancellation()
                guard self?.isActiveTranscription(generation: generation, attempt: attempt) == true else {
                    return
                }

                let process = try processLauncher.makeProcess(
                    request: .init(
                        scriptURL: scriptURL,
                        audioURL: audio.audioURL,
                        folderURL: session.folderURL
                    ),
                    onOutput: { [weak self] output in
                        Task { @MainActor [weak self] in
                            self?.handleTranscriptionOutput(
                                output,
                                session: session,
                                generation: generation,
                                attempt: attempt
                            )
                        }
                    }
                )
                guard self?.isActiveTranscription(generation: generation, attempt: attempt) == true else {
                    return
                }
                self?.transcriptionProcess = process
                try Task.checkCancellation()
                try process.run()
                let result = await process.waitForExit()
                guard self?.isActiveTranscription(generation: generation, attempt: attempt) == true else {
                    return
                }

                // Re-parse the complete drained output before clearing the attempt.
                self?.handleTranscriptionOutput(
                    result.output,
                    session: session,
                    generation: generation,
                    attempt: attempt
                )
                if Task.isCancelled || self?.transcriptionCancellationRequested == true {
                    self?.finishTranscriptionCancellation(
                        session: session,
                        generation: generation,
                        attempt: attempt
                    )
                } else if result.exitStatus == 0 {
                    self?.finishTranscriptionSuccess(
                        session: session,
                        generation: generation,
                        attempt: attempt
                    )
                } else {
                    self?.finishTranscriptionFailure(
                        session: session,
                        message: "Transcription failed with exit code \(result.exitStatus). Open the ASR log for details.",
                        generation: generation,
                        attempt: attempt
                    )
                }
            } catch is CancellationError {
                self?.finishTranscriptionCancellation(
                    session: session,
                    generation: generation,
                    attempt: attempt
                )
            } catch {
                if Task.isCancelled || self?.transcriptionCancellationRequested == true {
                    self?.finishTranscriptionCancellation(
                        session: session,
                        generation: generation,
                        attempt: attempt
                    )
                } else {
                    let prefix = prepared == nil
                        ? "Transcription preparation failed"
                        : "Transcription launch failed"
                    self?.finishTranscriptionFailure(
                        session: session,
                        message: "\(prefix): \(error.localizedDescription)",
                        generation: generation,
                        attempt: attempt
                    )
                }
            }
        }
    }

    func cancelTranscription() {
        guard let session = activeTranscriptionSession, transcriptionTask != nil else { return }
        transcriptionCancellationRequested = true
        transcriptionTask?.cancel()
        transcriptionProcess?.terminate()
        transcriptionStatus = "Cancelling transcription..."
        lastTranscriptionStatus = transcriptionStatus
        updateTranscriptionState(
            .init(phase: .cancelled, message: transcriptionStatus, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
    }

    private func isActiveTranscription(generation: UInt64, attempt: UUID) -> Bool {
        transcriptionGeneration == generation && activeTranscriptionAttempt == attempt
    }

    private func clearActiveTranscription(generation: UInt64, attempt: UUID) {
        guard isActiveTranscription(generation: generation, attempt: attempt) else { return }
        transcriptionProcess = nil
        transcriptionTask = nil
        transcribingSessionID = nil
        activeTranscriptionAttempt = nil
        activeTranscriptionSession = nil
    }

    private func finishTranscriptionCancellation(
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActiveTranscription(generation: generation, attempt: attempt) else { return }
        transcriptionStatus = "Transcription cancelled"
        lastTranscriptionStatus = "Transcription cancelled"
        lastTranscriptionDidFail = false
        updateTranscriptionState(
            .init(phase: .cancelled, message: transcriptionStatus, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
        statusMessage = "Transcription cancelled"
        clearActiveTranscription(generation: generation, attempt: attempt)
    }

    private func finishTranscriptionSuccess(
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActiveTranscription(generation: generation, attempt: attempt) else { return }
        transcriptionStatus = "Transcription complete"
        lastTranscriptionStatus = "Transcription complete"
        lastTranscriptionDidFail = false
        updateTranscriptionState(
            .init(phase: .completed, message: transcriptionStatus, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
        statusMessage = transcriptionStatus
        clearActiveTranscription(generation: generation, attempt: attempt)
    }

    private func finishTranscriptionFailure(
        session: RecordingSession,
        message: String,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActiveTranscription(generation: generation, attempt: attempt) else { return }
        transcriptionStatus = "Transcription failed"
        lastTranscriptionStatus = message
        lastTranscriptionDidFail = true
        updateTranscriptionState(
            .init(phase: .failed, message: message, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
        statusMessage = message
        clearActiveTranscription(generation: generation, attempt: attempt)
    }

    func prepareASRModelIfNeeded() {
        refreshASRModelStatus()
        guard !asrModelReady else { return }
        guard !isPreparingASRModel else { return }

        let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("prepare-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/prepare-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            asrModelStatus = "Missing ASR model preparation script: \(scriptURL.path)"
            return
        }

        isPreparingASRModel = true
        asrModelStatus = "Checking oMLX ASR server in the background..."
        statusMessage = "Checking oMLX ASR server"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        asrPrepareProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.handleASRModelOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.asrPrepareProcess = nil
                self?.isPreparingASRModel = false
                if process.terminationStatus == 0 {
                    self?.asrModelReady = true
                    self?.asrModelStatus = "oMLX ASR server ready"
                    self?.statusMessage = "oMLX ASR server ready"
                } else {
                    self?.asrModelReady = false
                    self?.asrModelStatus = "oMLX ASR server check failed with exit code \(process.terminationStatus)"
                    self?.statusMessage = "oMLX ASR server check failed. Open the ASR log for details."
                }
            }
        }

        do {
            try process.run()
        } catch {
            isPreparingASRModel = false
            asrPrepareProcess = nil
            asrModelStatus = "oMLX ASR server check failed: \(error.localizedDescription)"
        }
    }

    func openASRModelLog() {
        if let asrModelLogURL {
            NSWorkspace.shared.open(asrModelLogURL)
            return
        }

        let expected = URL(fileURLWithPath: "/Users/apple/Documents/AIA ASR/qwen_asr_model_prepare.log")
        if FileManager.default.fileExists(atPath: expected.path) {
            asrModelLogURL = expected
            NSWorkspace.shared.open(expected)
        } else {
            statusMessage = "No oMLX ASR server log found."
        }
    }

    func openTranscript(for session: RecordingSession) {
        if let url = transcriptURLsBySessionID[session.id] {
            NSWorkspace.shared.open(url)
            return
        }

        let expected = TranscriptDocumentStore.editableURL(in: session.folderURL)
        if FileManager.default.fileExists(atPath: expected.path) {
            transcriptURLsBySessionID[session.id] = expected
            NSWorkspace.shared.open(expected)
        } else {
            let qwenTranscript = TranscriptDocumentStore.qwenURL(in: session.folderURL)
            if FileManager.default.fileExists(atPath: qwenTranscript.path) {
                transcriptURLsBySessionID[session.id] = qwenTranscript
                NSWorkspace.shared.open(qwenTranscript)
            } else {
                statusMessage = "No transcript found for \(session.displayName)"
            }
        }
    }

    func openTranscriptLog(for session: RecordingSession) {
        if let url = transcriptLogURLsBySessionID[session.id] {
            NSWorkspace.shared.open(url)
            return
        }

        let expected = session.folderURL.appendingPathComponent("transcription_qwen_asr.log")
        if FileManager.default.fileExists(atPath: expected.path) {
            transcriptLogURLsBySessionID[session.id] = expected
            NSWorkspace.shared.open(expected)
        } else {
            statusMessage = "No ASR log found for \(session.displayName)"
        }
    }

    func toggleRecorderMicMute(source: String = "Button") {
        let current = microphoneMuteGate.snapshot
        if current.teamsInMeeting, current.teamsMuted, !current.localMuted {
            statusMessage = "\(source): recorder mic is muted by Teams"
            return
        }
        if current.nativeInputMuted, !current.localMuted {
            statusMessage = "\(source): recorder mic is muted by the input device"
            return
        }

        let requestedMute = !current.localMuted
        let snapshot = microphoneMuteGate.setLocalMuted(requestedMute)
        publishMicrophoneMuteSnapshot(snapshot)
        if !requestedMute, snapshot.effectiveMuted {
            let owner = snapshot.teamsInMeeting && snapshot.teamsMuted
                ? "Teams"
                : "the input device"
            statusMessage = "\(source): recorder mic remains muted by \(owner)"
        } else {
            statusMessage = "\(source): recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
        }
    }

    func installInputMuteHandling() {
        guard !inputMuteHandlingInstalled else { return }

        do {
            try inputMuteController.install { [weak self] muted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let snapshot = self.microphoneMuteGate.setNativeInputMuted(muted)
                    self.publishMicrophoneMuteSnapshot(snapshot)
                    self.statusMessage = "AirPods / input: recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
                }
            }
            inputMuteHandlingInstalled = true
            inputMuteControlAvailable = true
            let snapshot = microphoneMuteGate.setNativeInputMuted(
                inputMuteController.isMuted,
                ensureAudioGateIsApplied: true
            )
            publishMicrophoneMuteSnapshot(snapshot)
        } catch {
            inputMuteControlAvailable = false
            statusMessage = "AirPods mute control unavailable: \(error.localizedDescription)"
        }
    }

    private var teamsIntegrationRequired: Bool {
        teamsMuteSyncEnabled || teamsAutoMeetingEnabled
    }

    func installTeamsMuteSync() {
        guard teamsMuteSyncEnabled else { return }
        installTeamsIntegrationIfNeeded()
    }

    func installTeamsIntegrationIfNeeded() {
        guard teamsIntegrationRequired else { return }

        var callbackNeedsRefresh = false
        if teamsMuteSyncEnabled, teamsMuteRelayGeneration == nil {
            teamsMuteRelayGeneration = teamsMuteRelay.enable()
            callbackNeedsRefresh = true
        }
        if !teamsIntegrationInstalled {
            teamsIntegrationInstalled = true
            callbackNeedsRefresh = true
        }
        guard callbackNeedsRefresh else { return }
        installCurrentTeamsCallback()
    }

    private func installCurrentTeamsCallback() {
        teamsIntegrationGeneration &+= 1
        let integrationGeneration = teamsIntegrationGeneration
        let relayGeneration = teamsMuteRelayGeneration
        let relay = teamsMuteRelay
        let ingress = teamsIntegrationIngress
        teamsMuteSyncClient.start { [weak self, relay, ingress] event in
            let relayResult = relayGeneration.flatMap {
                relay.apply(event, generation: $0)
            }
            ingress.enqueue { @MainActor [weak self] in
                self?.handleTeamsIntegration(
                    event,
                    relayResult: relayResult,
                    generation: integrationGeneration
                )
            }
        }
    }

    func setTeamsMuteSyncEnabled(_ enabled: Bool) {
        guard teamsMuteSyncEnabled != enabled else { return }

        teamsMuteSyncEnabled = enabled
        defaults.set(enabled, forKey: Self.teamsMuteSyncEnabledKey)
        if enabled {
            let needsFreshState = teamsIntegrationInstalled
            let connectionIsInMeeting: Bool
            if case .inMeeting = teamsConnectionStatus {
                connectionIsInMeeting = true
            } else {
                connectionIsInMeeting = false
            }
            let shouldFailClosed =
                needsFreshState
                && connectionIsInMeeting
                && lastAuthorizedTeamsMeetingState?.isInMeeting == true
            teamsMuteRelayGeneration = teamsMuteRelay.enable()
            if shouldFailClosed {
                let snapshot = microphoneMuteGate.applyTeamsState(
                    TeamsMeetingState(
                        isInMeeting: true,
                        isMuted: true,
                        canToggleMute: false,
                        canPair: false
                    )
                )
                publishMicrophoneMuteSnapshot(snapshot)
            }
            if needsFreshState {
                pendingTeamsMeetingState = nil
                lastAuthorizedTeamsMeetingState = nil
                teamsConnectionStatus = .connecting
                teamsMuteSyncStatus = .connecting
                installCurrentTeamsCallback()
                teamsMuteSyncClient.reconnect()
            } else {
                installTeamsIntegrationIfNeeded()
            }
            return
        }

        let snapshot = teamsMuteRelay.disable()
        teamsMuteRelayGeneration = nil
        teamsMuteSyncStatus = .disabled
        publishMicrophoneMuteSnapshot(snapshot)
        if teamsIntegrationRequired {
            installCurrentTeamsCallback()
        } else {
            stopTeamsIntegrationIfUnused()
        }
    }

    func setTeamsAutoMeetingEnabled(_ enabled: Bool) {
        guard teamsAutoMeetingEnabled != enabled else { return }

        teamsAutoMeetingEnabled = enabled
        defaults.set(enabled, forKey: Self.teamsAutoMeetingEnabledKey)
        teamsAutoMeetingCoordinator.setEnabled(enabled)
        if enabled {
            installTeamsIntegrationIfNeeded()
            if case .inMeeting = teamsConnectionStatus,
               lastAuthorizedTeamsMeetingState?.isInMeeting == true {
                teamsAutoMeetingCoordinator.handleMeetingState(
                    isInMeeting: true
                )
                suppressAutomationForActiveManualRecording()
            }
        } else {
            stopTeamsIntegrationIfUnused()
        }
    }

    func cancelTeamsAutoMeetingCountdown() {
        teamsAutoMeetingCoordinator.cancelCountdown()
    }

    private func stopTeamsIntegrationIfUnused() {
        guard !teamsIntegrationRequired, teamsIntegrationInstalled else {
            return
        }

        invalidateTeamsScreenRefresh()
        teamsIntegrationGeneration &+= 1
        teamsIntegrationInstalled = false
        pendingTeamsMeetingState = nil
        lastAuthorizedTeamsMeetingState = nil
        teamsConnectionStatus = .disabled
        teamsMuteSyncClient.stop()
        teamsMeetingActive = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshTeamsScreenCaptureNow()
            self.restartTeamsScreenRefreshIfNeeded()
        }
    }

    func retryTeamsMuteSync() {
        guard teamsIntegrationRequired else { return }
        teamsMuteSyncClient.reconnect()
    }

    func requestTeamsPairing() {
        guard teamsIntegrationRequired else { return }
        teamsMuteSyncClient.requestPairing()
    }

    private func handleTeamsIntegration(
        _ event: TeamsMuteSyncEvent,
        relayResult: TeamsMuteRelayResult?,
        generation: UInt64
    ) {
        guard teamsIntegrationInstalled,
              teamsIntegrationGeneration == generation else {
            return
        }

        switch event {
        case .status(let status):
            teamsConnectionStatus = status
            teamsMuteSyncStatus = teamsMuteSyncEnabled ? status : .disabled
            routeAuthorizedAutoMeetingState(for: status)
            if relayResult?.didFailClosed == true {
                publishMicrophoneMuteSnapshot(microphoneMuteGate.snapshot)
                statusMessage = "Teams sync lost: recorder mic muted"
            }

        case .meetingState(let state):
            pendingTeamsMeetingState = state
            if relayResult != nil {
                let snapshot = microphoneMuteGate.snapshot
                publishMicrophoneMuteSnapshot(snapshot)
                statusMessage = "Teams / AirPods: recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
            }
            teamsMeetingActive = state.isInMeeting
            Task { @MainActor [weak self] in
                await self?.refreshTeamsScreenCaptureNow()
            }
        }
    }

    private func routeAuthorizedAutoMeetingState(
        for status: TeamsMuteSyncStatus
    ) {
        defer { pendingTeamsMeetingState = nil }
        lastAuthorizedTeamsMeetingState = nil
        guard let state = pendingTeamsMeetingState else { return }

        switch status {
        case .inMeeting:
            guard state.isInMeeting else { return }
        case .ready:
            guard !state.isInMeeting else { return }
        default:
            return
        }

        lastAuthorizedTeamsMeetingState = state
        guard teamsAutoMeetingEnabled else { return }
        teamsAutoMeetingCoordinator.handleMeetingState(
            isInMeeting: state.isInMeeting
        )
        if state.isInMeeting {
            suppressAutomationForActiveManualRecording()
        }
    }

    private func suppressAutomationForActiveManualRecording() {
        guard recorder.isRecording,
              recordingOwnership == .manual else { return }
        teamsAutoMeetingCoordinator.manualRecordingStarted()
    }

    private func publishMicrophoneMuteSnapshot(
        _ snapshot: MicrophoneMuteSnapshot
    ) {
        localMicMuted = snapshot.localMuted
        nativeInputMicMuted = snapshot.nativeInputMuted
        teamsMicMuted = snapshot.teamsInMeeting && snapshot.teamsMuted
        recorder.updateMicMuteDisplay(snapshot.effectiveMuted)
    }

    func transcriptText(for session: RecordingSession) -> String {
        do {
            return try TranscriptDocumentStore.read(in: session.folderURL)
        } catch {
            statusMessage = "Cannot read transcript: \(error.localizedDescription)"
            return ""
        }
    }

    func saveTranscript(_ text: String, for session: RecordingSession) {
        do {
            try TranscriptDocumentStore.save(text, in: session.folderURL)
            transcriptURLsBySessionID[session.id] = TranscriptDocumentStore.editableURL(in: session.folderURL)
            statusMessage = "Transcript saved"
        } catch {
            statusMessage = "Cannot save transcript: \(error.localizedDescription)"
        }
    }

    func exportTranscript(for session: RecordingSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptText(for: session).write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Transcript exported: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Cannot export transcript: \(error.localizedDescription)"
        }
    }

    func copyTranscript(for session: RecordingSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(for: session), forType: .string)
        statusMessage = "Transcript copied"
    }

    func saveMetadata(title: String, tags: String, isFavorite: Bool, for session: RecordingSession) {
        do {
            var metadata = RecordingSessionMetadataStore.load(in: session.folderURL)
            let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.title = cleanedTitle.isEmpty ? nil : cleanedTitle
            metadata.tags = tags.split(separator: ",").map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            metadata.isFavorite = isFavorite
            try RecordingSessionMetadataStore.save(metadata, in: session.folderURL)
            refreshSessions()
            statusMessage = "Recording details saved"
        } catch {
            statusMessage = "Cannot save recording details: \(error.localizedDescription)"
        }
    }

    func moveSessionToTrash(_ session: RecordingSession) {
        do {
            _ = try RecordingSessionStore.moveToTrash(folder: session.folderURL)
            if playingSessionID == session.id { stopPlayback() }
            sessions.removeAll { $0.id == session.id }
            transcriptionStatesBySessionID.removeValue(forKey: session.id)
            transcriptURLsBySessionID.removeValue(forKey: session.id)
            transcriptLogURLsBySessionID.removeValue(forKey: session.id)
            refreshSessions()
            statusMessage = "Moved \(session.displayName) to Trash"
        } catch {
            statusMessage = "Cannot move recording to Trash: \(error.localizedDescription)"
        }
    }

    private func finishRecording(
        playAfterStop: Bool,
        automaticStopToken: CaptureLifecycleToken? = nil
    ) async {
        let result = await recorder.stop()
        isRunningTestRecording = false
        if let result {
            lastHealthReport = result.health
            lastRecordingSavedAsM4A =
                result.recordingURL.lastPathComponent == "recording.m4a"
            refreshSessions()
            statusMessage = "Recording saved: \(result.health.summary)"

            if playAfterStop {
                let session = RecordingSessionStore.session(
                    for: result.folderURL,
                    recordingURL: result.recordingURL
                )
                startPlayback(
                    session: session,
                    successStatus:
                        "Test saved and playing: \(result.health.summary)"
                )
            }
        } else if automaticStopToken == nil {
            statusMessage = "No active recording."
        }
        if let automaticStopToken, !recorder.isRecording {
            completeAutomaticStopIntent(automaticStopToken)
        }
    }

    private func completeAutomaticStopIntent(
        _ token: CaptureLifecycleToken? = nil
    ) {
        guard let pendingToken = automaticStopIntentToken,
              token == nil || token == pendingToken else { return }
        automaticStopIntentToken = nil
        teamsAutoMeetingCoordinator.automaticStopCompleted()
    }

    private func startPlayback(session: RecordingSession, successStatus: String) {
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackLoadTask?.cancel()
        playbackCoordinator.stop()
        playbackSessionID = session.id
        playingSessionID = session.id
        playbackProgress = 0
        playbackDuration = 0
        isPlaybackActive = false
        let coordinator = playbackCoordinator
        playbackLoadTask = Task { [weak self, coordinator] in
            do {
                try await coordinator.load(session)
                guard !Task.isCancelled,
                      let self,
                      self.playbackGeneration == generation,
                      self.playbackSessionID == session.id else { return }
                coordinator.play()
                self.statusMessage = successStatus
                self.playbackLoadTask = nil
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.playbackGeneration == generation,
                      self.playbackSessionID == session.id else { return }
                self.playbackLoadTask = nil
                self.playbackSessionID = nil
                self.playingSessionID = nil
                self.playbackProgress = 0
                self.playbackDuration = 0
                self.isPlaybackActive = false
                self.statusMessage = "Playback failed: \(error.localizedDescription)"
            }
        }
    }

    private func handlePlaybackSnapshot(_ snapshot: PlaybackSnapshot) {
        guard snapshot.sessionID == playbackSessionID else { return }
        playingSessionID = snapshot.sessionID
        playbackProgress = snapshot.progress
        playbackDuration = snapshot.duration
        isPlaybackActive = snapshot.isPlaying
    }

    private func handleTranscriptionOutput(
        _ text: String,
        session: RecordingSession,
        generation: UInt64,
        attempt: UUID
    ) {
        guard isActiveTranscription(generation: generation, attempt: attempt),
              !transcriptionCancellationRequested else { return }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let lastUsefulLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            transcriptionStatus = lastUsefulLine
            lastTranscriptionStatus = lastUsefulLine
        }

        for line in lines where line.hasPrefix("TRANSCRIPT_PATH=") {
            let path = String(line.dropFirst("TRANSCRIPT_PATH=".count))
            let url = URL(fileURLWithPath: path)
            transcriptURLsBySessionID[session.id] = url
            statusMessage = "Transcript saved: \(url.lastPathComponent)"
        }

        for line in lines where line.hasPrefix("STATUS=") {
            let message = String(line.dropFirst("STATUS=".count))
            transcriptionStatus = message
            lastTranscriptionStatus = message
            let phase: TranscriptionState.Phase = message.localizedCaseInsensitiveContains("upload") ? .uploading : .transcribing
            updateTranscriptionState(
                .init(phase: phase, message: message, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date()),
                for: session
            )
        }

        for line in lines where line.hasPrefix("LOG_PATH=") {
            let path = String(line.dropFirst("LOG_PATH=".count))
            transcriptLogURLsBySessionID[session.id] = URL(fileURLWithPath: path)
        }
    }

    private func updateTranscriptionState(_ state: TranscriptionState, for session: RecordingSession) {
        transcriptionStatesBySessionID[session.id] = state
        try? TranscriptionStateStore.save(state, in: session.folderURL)
    }

    private func refreshASRModelStatus() {
        if !asrModelReady && !isPreparingASRModel {
            asrModelStatus = "oMLX ASR server not checked yet"
        }

        let logURL = URL(fileURLWithPath: "/Users/apple/Documents/AIA ASR/qwen_asr_model_prepare.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            asrModelLogURL = logURL
        }
    }

    private func handleASRModelOutput(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if let lastUsefulLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            asrModelStatus = friendlyASRModelStatus(for: lastUsefulLine)
        }

        for line in lines where line.hasPrefix("LOG_PATH=") {
            let path = String(line.dropFirst("LOG_PATH=".count))
            asrModelLogURL = URL(fileURLWithPath: path)
        }

        for line in lines where line.hasPrefix("MODEL_READY=") {
            asrModelReady = true
            asrModelStatus = "oMLX ASR server ready"
        }
    }

    private func friendlyASRModelStatus(for line: String) -> String {
        if line.contains("Checking oMLX ASR server") {
            return "Checking oMLX ASR server..."
        }
        if line.contains("Waiting for oMLX ASR model") {
            return "Waiting for oMLX ASR model..."
        }
        if line.hasPrefix("LOG_PATH=") {
            return isPreparingASRModel ? "Checking oMLX ASR server in the background..." : asrModelStatus
        }
        return line
    }

    func requestSystemAudioPermission() {
        beginCaptureLifecycle(.permission) { [self] _ in
            await requestPermissionsFromExplicitAction(requestSystemOnly: true)
        }
    }

    func requestMicrophonePermission() {
        beginCaptureLifecycle(.permission) { [self] _ in
            await requestPermissionsFromExplicitAction(requestMicrophoneOnly: true)
        }
    }

    func openScreenCaptureSettings() {
        CapturePermission.openScreenCaptureSettings()
    }

    func openMicrophoneSettings() {
        CapturePermission.openMicrophoneSettings()
    }

    private func refreshPermissionPreflight() {
        let screen = CapturePermission.screenCapturePreflight()
        if screen == .granted || systemAudioPermission == .notDetermined {
            systemAudioPermission = screen
        }
        microphonePermission = CapturePermission.microphonePreflight()
    }

    private func requestPermissionsFromExplicitAction(
        requestSystemOnly: Bool = false,
        requestMicrophoneOnly: Bool = false
    ) async {
        if let permissionRequestHandler {
            await permissionRequestHandler(requestSystemOnly, requestMicrophoneOnly)
            return
        }
        refreshPermissionPreflight()
        if !requestMicrophoneOnly {
            switch systemAudioPermission {
            case .notDetermined:
                systemAudioPermission = CapturePermission.requestScreenCaptureAccess()
            case .denied, .restricted:
                CapturePermission.openScreenCaptureSettings()
            case .granted:
                break
            }
        }
        if !requestSystemOnly {
            switch microphonePermission {
            case .notDetermined:
                microphonePermission = await CapturePermission.requestMicrophoneAccess()
            case .denied, .restricted:
                CapturePermission.openMicrophoneSettings()
            case .granted:
                break
            }
        }
        refreshPermissionPreflight()
        if systemAudioPermission == .granted {
            availableCaptureApplications = (try? await recorder.refreshCaptureApplications()) ?? availableCaptureApplications
            resolvedCaptureSelection = CaptureSelectionResolver.resolve(
                selection: captureSelection,
                availableApplications: availableCaptureApplications,
                previousResolution: resolvedCaptureSelection
            )
        }
    }

    private func startMonitoringIfReady() async {
        guard !recorder.isRecording,
              captureReadiness == .ready else { return }
        do {
            try await recorder.startMonitoring(
                selection: resolvedCaptureSelection,
                microphoneUID: selectedMicDevice?.uid
            )
            statusMessage = "Monitoring"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private var readinessMessage: String {
        switch captureReadiness {
        case .ready: "Ready"
        case .reconnectRequired: "Selected app unavailable"
        case .blocked(let message): message
        }
    }

    private func persistCaptureSelection() {
        capturePersistence.saveSelection(captureSelection)
    }

    private func beginCaptureLifecycle(
        _ operation: CaptureLifecycleOperation,
        allowedWhileRecording: Bool = false,
        _ work: @escaping (CaptureLifecycleToken) async -> Void
    ) {
        guard allowedWhileRecording || !recorder.isRecording,
              let token = captureLifecycleGate.begin(operation) else {
            return
        }
        isCaptureLifecycleWorking = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(token)
            self.finishCaptureLifecycle(token)
        }
        captureLifecycleTask = task
    }

    private func stopCaptureLifecycle(
        playAfterStop: Bool,
        automaticMeetingEnd: Bool = false
    ) {
        if let pendingAttempt = pendingRecordingAttempt,
           pendingAttempt.ownership == .teamsAutomatic,
           !recorder.isRecording {
            if !automaticMeetingEnd {
                teamsAutoMeetingCoordinator.suppressUntilMeetingEnd()
            }
            cancelPendingAutomaticRecordingStart()
            return
        }
        guard let token = captureLifecycleGate.cancelAndBeginStop() else {
            return
        }
        let endingOwnership = recordingOwnership
            ?? pendingRecordingAttempt?.ownership
        if let pendingAttempt = pendingRecordingAttempt {
            independentlyFinalizedRecordingAttempts.insert(pendingAttempt.id)
        }
        pendingRecordingAttempt = nil
        let automaticStopToken: CaptureLifecycleToken?
        if automaticMeetingEnd, endingOwnership == .teamsAutomatic {
            automaticStopIntentToken = token
            automaticStopToken = token
        } else {
            automaticStopToken = nil
        }
        if endingOwnership == .teamsAutomatic, !automaticMeetingEnd {
            teamsAutoMeetingCoordinator.suppressUntilMeetingEnd()
        }
        recordingOwnership = nil
        invalidateStorageMonitoring()
        invalidateTeamsScreenRefresh()
        invalidateTeamsScreenCaptureIntent()
        isTeamsScreenCaptureRequested = false
        testRecordingStopTask?.cancel()
        testRecordingStopTask = nil
        captureLifecycleTask?.cancel()
        isCaptureLifecycleWorking = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishRecording(
                playAfterStop: playAfterStop,
                automaticStopToken: automaticStopToken
            )
            self.finishCaptureLifecycle(token)
        }
        captureLifecycleTask = task
    }

    private func finishCaptureLifecycle(_ token: CaptureLifecycleToken) {
        guard captureLifecycleGate.finish(token) else { return }
        captureLifecycleTask = nil
        isCaptureLifecycleWorking = false
    }

    private func observeRecorderConnection() {
        recorder.$captureConnectionSnapshot
            .sink { [weak self] snapshot in
                guard let self else { return }
                let state = CaptureConnectionProjection.observeSystemConnection(
                    current: self.captureConnectionState,
                    snapshot: snapshot,
                    selection: self.captureSelection
                )
                self.captureConnectionState = state
                if case let .selectedApplicationDisconnected(
                    _,
                    bundleIdentifier
                ) = state {
                    self.resolvedCaptureSelection = .disconnected(bundleIdentifier)
                    self.resetTeamsScreenCaptureAfterApplicationDisconnect()
                } else if state == .connected {
                    self.resolvedCaptureSelection = CaptureSelectionResolver.resolve(
                        selection: self.captureSelection,
                        availableApplications: self.availableCaptureApplications
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func resetTeamsScreenCaptureAfterApplicationDisconnect() {
        guard isTeamsScreenCaptureRequested else { return }
        invalidateTeamsScreenRefresh()
        invalidateTeamsScreenCaptureIntent()
        let intentGeneration = teamsScreenCaptureIntentGeneration
        isTeamsScreenCaptureRequested = false
        teamsScreenCaptureCandidates = []
        Task { @MainActor [weak self] in
            guard let self,
                  self.teamsScreenCaptureIntentGeneration == intentGeneration,
                  !self.isTeamsScreenCaptureRequested,
                  self.recorder.isRecording else { return }
            await self.recorder.setScreenCaptureRequested(false)
        }
    }

    private func observeRecorderRecordingState() {
        recorder.$isRecording
            .dropFirst()
            .sink { [weak self] isRecording in
                guard let self, !isRecording else { return }
                self.invalidateStorageMonitoring()
                self.invalidateTeamsScreenRefresh()
                self.invalidateTeamsScreenCaptureIntent()
                self.isTeamsScreenCaptureRequested = false
                self.clearTestRecordingRuntimeState()
                self.completeAutomaticStopIntent()
                guard let ownership = self.recordingOwnership else { return }
                self.recordingOwnership = nil
                if ownership == .teamsAutomatic {
                    self.teamsAutoMeetingCoordinator.suppressUntilMeetingEnd()
                }
            }
            .store(in: &cancellables)
    }

    private func prepareStorageForNewRecording(in folder: URL) async -> Bool {
        invalidateStorageMonitoring(resetAllowance: true)
        let check = await storageCapacityCheck(for: folder)
        switch check {
        case .decision(.normal):
            return true
        case .decision(.warn):
            storageWarningMessage = "Low storage space: less than 5 GB available."
            return true
        case .decision(.audioOnly):
            let reason = "Screen capture disabled: less than 1 GB available. Audio recording can continue."
            isScreenCaptureAllowedByStorage = false
            screenCaptureStorageRestrictionReason = reason
            storageWarningMessage = reason
            return true
        case .decision(.stop):
            statusMessage = "Recording cannot start: less than 256 MB available."
            return false
        case .unavailable(let description):
            storageWarningMessage = "Storage check unavailable: \(description). Recording can continue."
            return true
        }
    }

    private func startStorageMonitoring(folder: URL) {
        guard recorder.isRecording else { return }
        storageMonitorTask?.cancel()
        storageMonitorGeneration &+= 1
        let generation = storageMonitorGeneration
        let tick = storageMonitorTick
        storageMonitorTask = Task(priority: .utility) { [weak self, tick] in
            while !Task.isCancelled {
                await tick()
                guard !Task.isCancelled, let self else { return }
                await self.runStorageMonitorCheck(
                    generation: generation,
                    folder: folder
                )
            }
        }
    }

    private func runStorageMonitorCheck(generation: UInt64, folder: URL) async {
        let check = await storageCapacityCheck(for: folder)
        guard generation == storageMonitorGeneration, recorder.isRecording else { return }

        switch check {
        case .decision(.normal):
            return
        case .decision(.warn):
            storageWarningMessage = "Low storage space: less than 5 GB available."
        case .decision(.audioOnly):
            let reason = "Screen capture disabled: less than 1 GB available. Audio recording can continue."
            isScreenCaptureAllowedByStorage = false
            screenCaptureStorageRestrictionReason = reason
            storageWarningMessage = reason
            invalidateTeamsScreenCaptureIntent()
            isTeamsScreenCaptureRequested = false
            await recorder.setScreenCaptureRequested(false)
            guard generation == storageMonitorGeneration, recorder.isRecording else { return }
            statusMessage = "Low storage: screen capture disabled; audio recording continues."
        case .decision(.stop):
            statusMessage = "Low storage: finalizing recording safely."
            stopCaptureLifecycle(playAfterStop: false)
        case .unavailable(let description):
            storageWarningMessage = "Storage check unavailable: \(description). Recording can continue."
            statusMessage = storageWarningMessage ?? statusMessage
        }
    }

    private func storageCapacityCheck(for folder: URL) async -> StorageCapacityCheck {
        let policy = storagePolicy
        let provider = volumeCapacityProvider
        return await Task.detached(priority: .utility) {
            do {
                let availableBytes = try provider.availableBytes(onVolumeContaining: folder)
                return .decision(policy.decision(availableBytes: availableBytes))
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }.value
    }

    private func invalidateStorageMonitoring(resetAllowance: Bool = false) {
        storageMonitorGeneration &+= 1
        storageMonitorTask?.cancel()
        storageMonitorTask = nil
        guard resetAllowance else { return }
        isScreenCaptureAllowedByStorage = true
        screenCaptureStorageRestrictionReason = nil
        storageWarningMessage = nil
    }
}

private enum StorageCapacityCheck: Sendable {
    case decision(RecordingStorageDecision)
    case unavailable(String)
}
