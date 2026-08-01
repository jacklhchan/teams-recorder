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
    typealias TranscriptionFeatureFactory = (
        any OpenAICompatibleProviderManaging,
        any TranscriptionAudioPreparing,
        any TranscriptionServicing,
        RecordingSessionMutationGate
    ) -> TranscriptionFeatureModel
    @Published var devices: [AudioDevice] = []
    @Published var selectedMicDevice: AudioDevice?
    @Published private(set) var selectedMicrophoneUID: String?
    @Published var availableCaptureApplications: [CaptureApplication] = []
    @Published var captureSelection = CaptureSelection()
    @Published var resolvedCaptureSelection: ResolvedCaptureSelection = .allSystemAudio
    @Published var systemAudioPermission: CapturePermissionState = .notDetermined
    @Published var microphonePermission: CapturePermissionState = .notDetermined
    @Published private(set) var captureConnectionState: CaptureConnectionState = .connected
    @Published private(set) var outputFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads")
    @Published var statusMessage = "Ready"
    @Published var sessions: [RecordingSession] = []
    @Published var lastHealthReport: RecordingHealthReport?
    @Published private(set) var lastRecordingSavedAsM4A = false
    @Published var isRunningTestRecording = false
    @Published private(set) var inputMuteControlAvailable = false
    @Published private(set) var virtualMicInstallationState: VirtualMicInstallationState = .absent
    @Published private(set) var teamsMuteSyncStatus: TeamsMuteSyncStatus = .disabled
    @Published private(set) var teamsMuteSyncEnabled: Bool
    @Published private(set) var teamsAutoMeetingEnabled: Bool
    @Published private(set) var teamsAutoMeetingState: TeamsAutoMeetingState
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
    let aiProviderSettingsModel: AIProviderSettingsModel
    private let recordingSessionCoordinator:
        RecordingSessionCoordinator
    let transcriptionFeature: TranscriptionFeatureModel
    private let transcriptMutationGate: RecordingSessionMutationGate
    /// AppModel owns the sole meeting-intelligence coordinator.  It projects
    /// presentation and forwards commands; it deliberately owns no parallel
    /// attempt/task/generation state.
    private let meetingIntelligenceCoordinator: MeetingIntelligenceJobCoordinator

    var isCaptureLifecycleWorking: Bool {
        recordingSessionCoordinator.isWorking
    }

    private(set) var recordingOwnership: RecordingOwnership? {
        get { recordingSessionCoordinator.ownership }
        set { recordingSessionCoordinator.ownership = newValue }
    }

    var transcribingSessionID: RecordingSession.ID? {
        transcriptionFeature.presentation.transcribingSessionID
    }

    var transcriptionStatus: String {
        transcriptionFeature.presentation.transcriptionStatus
    }

    var lastTranscriptionSessionID: RecordingSession.ID? {
        transcriptionFeature.presentation.lastTranscriptionSessionID
    }

    var lastTranscriptionStatus: String {
        transcriptionFeature.presentation.lastTranscriptionStatus
    }

    var lastTranscriptionDidFail: Bool {
        transcriptionFeature.presentation.lastTranscriptionDidFail
    }

    var transcriptURLsBySessionID: [RecordingSession.ID: URL] {
        transcriptionFeature.presentation.transcriptURLsBySessionID
    }

    var transcriptLogURLsBySessionID: [RecordingSession.ID: URL] {
        transcriptionFeature.presentation.transcriptLogURLsBySessionID
    }

    var transcriptionStatesBySessionID:
        [RecordingSession.ID: TranscriptionState] {
        transcriptionFeature.presentation.transcriptionStatesBySessionID
    }

    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    let playbackFeature: PlaybackFeatureModel
    private let appPaths: AppPaths
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
    private let recordingSessionReloader: @Sendable (RecordingSession) -> RecordingSession
    private let recordingSearchDocumentLoader:
        @Sendable (RecordingSession) -> RecordingLibrarySearchDocument
    private let recordingSessionRecovery: @Sendable (URL) -> Void
    private let recordingSessionTrashHandler:
        @Sendable (URL) throws -> Bool
    private let permissionRequestHandler: (@MainActor (Bool, Bool) async -> Void)?
    private let volumeCapacityProvider: any VolumeCapacityProviding
    private let storagePolicy: RecordingStoragePolicy
    private let storageMonitorTick: @Sendable () async -> Void
    private let testRecordingDelay: @Sendable () async -> Void
    private let teamsScreenRefreshTick: @Sendable () async -> Void
    private let teamsScreenDisconnectCleanupScheduler: (
        @escaping @MainActor @Sendable () async -> Void
    ) -> Void
    private let defaults: UserDefaults
    private let recordingSessionLoadingQueue = DispatchQueue(
        label: "local.meeting.recorder.recording-library",
        qos: .userInitiated
    )
    private var cancellables: Set<AnyCancellable> = []
    private var captureLifecycleTask: Task<Void, Never>? {
        get { recordingSessionCoordinator.task }
        set { recordingSessionCoordinator.task = newValue }
    }
    private var pendingRecordingAttempt: RecordingStartAttempt? {
        get { recordingSessionCoordinator.pendingAttempt }
        set { recordingSessionCoordinator.pendingAttempt = newValue }
    }
    private var cancelledRecordingAttemptStops:
        [UUID: CaptureLifecycleToken] {
        get { recordingSessionCoordinator.cancelledAttemptStops }
        set {
            recordingSessionCoordinator.cancelledAttemptStops =
                newValue
        }
    }
    private var independentlyFinalizedRecordingAttempts: Set<UUID> {
        get {
            recordingSessionCoordinator
                .independentlyFinalizedAttempts
        }
        set {
            recordingSessionCoordinator
                .independentlyFinalizedAttempts = newValue
        }
    }
    private var automaticStopIntentToken: CaptureLifecycleToken? {
        get { recordingSessionCoordinator.automaticStopIntentToken }
        set {
            recordingSessionCoordinator.automaticStopIntentToken =
                newValue
        }
    }
    private var inputMuteHandlingInstalled = false
    private var teamsIntegrationInstalled = false
    private var teamsIntegrationGeneration: UInt64 = 0
    private var teamsMuteRelayGeneration: UInt64?
    private var pendingTeamsMeetingState: TeamsMeetingState?
    private var lastAuthorizedTeamsMeetingState: TeamsMeetingState?
    private var recordingSessionRefreshGeneration: UInt = 0
    private var recordingSearchDocumentRefreshGeneration: UInt64 = 0
    private var recordingSearchDocumentRefreshGenerations:
        [RecordingSession.ID: UInt64] = [:]
    private var meetingIntelligenceSessionReloadGenerations:
        [RecordingSession.ID: UInt64] = [:]
    private var recoveredLibraryFolders: Set<URL> = []
    private var storageMonitorTask: Task<Void, Never>?
    private var storageMonitorGeneration: UInt64 = 0
    private var testRecordingStopTask: Task<Void, Never>?
    private var teamsScreenRefreshTask: Task<Void, Never>?
    private var teamsScreenRefreshGeneration: UInt64 = 0
    private var teamsScreenCaptureIntentGeneration: UInt64 = 0
    private var teamsMeetingActive = false
    private var workspacePublicationFence: WorkspacePublicationFence = .initial

    private static let teamsMuteSyncEnabledKey = "teamsMuteSyncEnabled"
    private static let teamsAutoMeetingEnabledKey = "teamsAutoMeetingEnabled"

    init(
        defaults: UserDefaults = .standard,
        providerRepository: (any OpenAICompatibleProviderManaging)? = nil,
        appPaths: AppPaths = .live,
        recorder: RecordingEngine? = nil,
        inputDevices: @escaping () -> [AudioDevice] = AudioDeviceManager.inputDevices,
        defaultInputDeviceID: @escaping () -> AudioDeviceID? = AudioDeviceManager.defaultInputDeviceID,
        performStartupWork: Bool = true,
        initialOutputFolder: URL? = nil,
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
        recordingSessionReloader: @escaping @Sendable (RecordingSession) -> RecordingSession = {
            RecordingSessionStore.session(for: $0.folderURL, recordingURL: $0.recordingURL)
        },
        recordingSearchDocumentLoader: @escaping @Sendable (
            RecordingSession
        ) -> RecordingLibrarySearchDocument = { session in
            RecordingLibrarySearchDocument.load(
                folderURL: session.folderURL,
                displayName: session.displayName,
                createdAt: session.createdAt,
                metadata: session.metadata
            )
        },
        recordingSessionRecovery: @escaping @Sendable (URL) -> Void = {
            IncompleteSessionRecovery().recover(in: $0)
        },
        recordingSessionTrashHandler: @escaping @Sendable (
            URL
        ) throws -> Bool = {
            try RecordingSessionStore.moveToTrash(folder: $0)
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
        teamsScreenDisconnectCleanupScheduler: @escaping (
            @escaping @MainActor @Sendable () async -> Void
        ) -> Void = { operation in
            Task { @MainActor in await operation() }
        },
        transcriptionAudioPreparer: any TranscriptionAudioPreparing = TranscriptionAudioPreparer(),
        transcriptionProcessLauncher: any TranscriptionProcessLaunching = FoundationTranscriptionProcessLauncher(),
        transcriptionScriptURL: URL? = nil,
        transcriptionService: (any TranscriptionServicing)? = nil,
        transcriptionFeatureFactory: TranscriptionFeatureFactory? = nil,
        meetingIntelligenceCoordinatorFactory: ((
            any OpenAICompatibleProviderManaging,
            UUID,
            RecordingSessionMutationGate
        ) -> MeetingIntelligenceJobCoordinator)? = nil,
        playbackCoordinator: (any PlaybackCoordinating)? = nil,
        playbackFeature: PlaybackFeatureModel? = nil,
        teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil,
        teamsIntegrationScheduler: @escaping (
            @escaping @MainActor @Sendable () -> Void
        ) -> Void = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        if let initialOutputFolder {
            outputFolder = initialOutputFolder
        }
        let activeRecorder = recorder ?? RecordingEngine()
        let autoCoordinator = teamsAutoMeetingCoordinator
            ?? TeamsAutoMeetingCoordinator()
        self.recorder = activeRecorder
        recordingSessionCoordinator = RecordingSessionCoordinator()
        self.teamsAutoMeetingCoordinator = autoCoordinator
        teamsIntegrationIngress = TeamsIntegrationIngress(
            scheduler: teamsIntegrationScheduler
        )
        self.inputDevices = inputDevices
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaults = defaults
        let activeProviderRepository = providerRepository
            ?? OpenAICompatibleProviderRepository(
                profiles: OpenAICompatibleProviderProfileStore(defaults: defaults),
                secureStore: KeychainSecureValueStore()
            )
        aiProviderSettingsModel = AIProviderSettingsModel(
            repository: activeProviderRepository,
            loadImmediately: false
        )
        let transcriptMutationGate = RecordingSessionMutationGate()
        self.transcriptMutationGate = transcriptMutationGate
        let activeTranscriptionService: any TranscriptionServicing
        if let transcriptionService {
            activeTranscriptionService = transcriptionService
        } else if let transcriptionScriptURL {
            activeTranscriptionService = LegacyProcessTranscriptionService(
                launcher: transcriptionProcessLauncher,
                scriptURL: transcriptionScriptURL
            )
        } else {
            activeTranscriptionService = NativeOpenAICompatibleTranscriptionService(
                publisher: TranscriptionArtifactPublisher(
                    mutationGate: transcriptMutationGate
                )
            )
        }
        if let transcriptionFeatureFactory {
            self.transcriptionFeature = transcriptionFeatureFactory(
                activeProviderRepository,
                transcriptionAudioPreparer,
                activeTranscriptionService,
                transcriptMutationGate
            )
        } else {
            self.transcriptionFeature = TranscriptionFeatureModel(
                coordinator: TranscriptionJobCoordinator(
                    providerRepository: activeProviderRepository,
                    audioPreparer: transcriptionAudioPreparer,
                    service: activeTranscriptionService,
                    mutationGate: transcriptMutationGate
                )
            )
        }
        if let meetingIntelligenceCoordinatorFactory {
            meetingIntelligenceCoordinator = meetingIntelligenceCoordinatorFactory(
                activeProviderRepository,
                self.transcriptionFeature.publicationSourceID,
                transcriptMutationGate
            )
        } else {
            meetingIntelligenceCoordinator = Self.makeMeetingIntelligenceCoordinator(
                repository: activeProviderRepository,
                expectedPublicationSourceID: self.transcriptionFeature.publicationSourceID,
                mutationGate: transcriptMutationGate
            )
        }
        self.appPaths = appPaths
        teamsMuteSyncEnabled = defaults.object(
            forKey: Self.teamsMuteSyncEnabledKey
        ) as? Bool ?? true
        teamsAutoMeetingEnabled = defaults.bool(
            forKey: Self.teamsAutoMeetingEnabledKey
        )
        teamsAutoMeetingState = autoCoordinator.state
        self.virtualMicStateProvider = virtualMicStateProvider
        self.recordingSessionLoader = recordingSessionLoader
        self.recordingSessionReloader = recordingSessionReloader
        self.recordingSearchDocumentLoader =
            recordingSearchDocumentLoader
        self.recordingSessionRecovery = recordingSessionRecovery
        self.recordingSessionTrashHandler = recordingSessionTrashHandler
        self.permissionRequestHandler = permissionRequestHandler
        self.volumeCapacityProvider = volumeCapacityProvider
        self.storagePolicy = storagePolicy
        self.storageMonitorTick = storageMonitorTick
        self.testRecordingDelay = testRecordingDelay
        self.teamsScreenRefreshTick = teamsScreenRefreshTick
        self.teamsScreenDisconnectCleanupScheduler =
            teamsScreenDisconnectCleanupScheduler
        precondition(
            playbackCoordinator == nil || playbackFeature == nil,
            "Inject either a playback coordinator or playback feature, not both."
        )
        if let playbackFeature {
            self.playbackFeature = playbackFeature
        } else {
            self.playbackFeature = PlaybackFeatureModel(
                coordinator: playbackCoordinator ?? PlaybackCoordinator()
            )
        }
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
            tokenStore: KeychainTeamsPairingTokenStore(defaults: defaults)
        )
        capturePersistence = CaptureSelectionPersistence(defaults: defaults)
        captureSelection = capturePersistence.loadSelection()
        selectedMicrophoneUID = capturePersistence.loadMicrophoneUID()
        self.playbackFeature.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        recordingSessionCoordinator.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.transcriptionFeature.onStatusMessage = { [weak self] message in
            self?.statusMessage = message
        }
        self.transcriptionFeature.onSuccessfulPublication = {
            [weak self] event in
            guard let self,
                  self.admitsTranscriptPublication(event) else { return }
            self.rebuildSearchDocument(
                for: event.session,
                publicationFence: event.workspaceFence
            ) { [weak self] in
                guard let self,
                      self.admitsTranscriptPublication(event) else { return }
                self.meetingIntelligenceCoordinator
                    .handleTranscriptPublished(event)
            }
        }
        meetingIntelligenceCoordinator.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        meetingIntelligenceCoordinator.onSuccessfulPublication = {
            [weak self] session in
            self?.reloadMeetingIntelligenceSession(session)
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
        aiProviderSettingsModel.performStartupMigration(
            settingsURL: appPaths.omlxSettingsURL
        )
    }

    deinit {
        storageMonitorTask?.cancel()
        testRecordingStopTask?.cancel()
        teamsScreenRefreshTask?.cancel()
        teamsMuteRelay.invalidate()
        teamsMuteSyncClient.stop()
        inputMuteController.uninstall()
    }

    private static func makeMeetingIntelligenceCoordinator(
        repository: any OpenAICompatibleProviderManaging,
        expectedPublicationSourceID: UUID,
        mutationGate: RecordingSessionMutationGate
    ) -> MeetingIntelligenceJobCoordinator {
        let client = OpenAICompatibleMeetingIntelligenceClient()
        let artifactStore = MeetingIntelligenceArtifactStore(
            mutationGate: mutationGate
        )
        return MeetingIntelligenceJobCoordinator(
            providerRepository: repository,
            expectedPublicationSourceID: expectedPublicationSourceID,
            availabilityChecker:
                OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
                    client: OpenAICompatibleProviderClient()
                ),
            generator: MeetingIntelligencePipeline(client: client),
            publisher: MeetingIntelligencePublisher(
                mutationGate: mutationGate,
                artifactStore: artifactStore
            ),
            artifactStore: artifactStore,
            stateStore: MeetingIntelligenceStateStore(
                mutationGate: mutationGate
            ),
            titleApplier: MeetingIntelligenceSuggestedTitleApplier(
                mutationGate: mutationGate
            )
        )
    }

    func meetingIntelligencePresentation(
        for session: RecordingSession
    ) -> MeetingIntelligencePresentation {
        meetingIntelligenceCoordinator.presentation(for: session)
    }

    func checkMeetingIntelligenceAvailability(for session: RecordingSession) {
        meetingIntelligenceCoordinator.checkAvailability(for: session)
    }

    func generateMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceCoordinator.generate(for: session)
    }

    func regenerateMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceCoordinator.regenerate(for: session)
    }

    func retryMeetingIntelligenceGeneration(for session: RecordingSession) {
        meetingIntelligenceCoordinator.retryGeneration(for: session)
    }

    func cancelMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceCoordinator.cancel(sessionID: session.id)
    }

    func applyMeetingIntelligenceSuggestedTitle(for session: RecordingSession) {
        meetingIntelligenceCoordinator.applySuggestedTitle(for: session)
    }

    func shutdown() {
        playbackFeature.shutdown()
        transcriptionFeature.shutdown()
        meetingIntelligenceCoordinator.shutdown()
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
                guard recordingSessionCoordinator.accepts(token) else { return }
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
                guard recordingSessionCoordinator.accepts(token) else { return }
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
            recordingSessionCoordinator.activeOperation == .stop
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
            guard recordingSessionCoordinator.activeOperation != .stop else { return }
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
                guard recordingSessionCoordinator.accepts(token) else { return }
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
                guard recordingSessionCoordinator.accepts(token) else { return }
                resolvedCaptureSelection = resolved
                captureConnectionState = .connected
                statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
            } catch {
                guard recordingSessionCoordinator.accepts(token) else { return }
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
              recordingSessionCoordinator.accepts(attempt.lifecycleToken) else {
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
              let lifecycleToken = recordingSessionCoordinator.begin(.start) else {
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
              recordingSessionCoordinator.accepts(attempt.lifecycleToken) else {
            return nil
        }
        return currentAttempt
    }

    private func cancelPendingAutomaticRecordingStart() {
        guard let attempt = pendingRecordingAttempt,
              attempt.ownership == .teamsAutomatic else { return }
        pendingRecordingAttempt = nil
        guard let stopToken = recordingSessionCoordinator.cancelAndBeginStop() else {
            return
        }
        cancelledRecordingAttemptStops[attempt.id] = stopToken
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
                automaticStopToken: nil,
                recordingSource: attempt.ownership == .teamsAutomatic
                    ? .teamsAutomatic
                    : .manual
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
            guard recordingSessionCoordinator.accepts(token) else { return }
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
            guard recordingSessionCoordinator.accepts(token) else { return }
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
                guard recordingSessionCoordinator.accepts(token) else { return }
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
        recordingSessionCoordinator.accepts(token) && recorder.isRecording
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
        workspacePublicationFence = workspacePublicationFence.advanced()
        transcriptionFeature.advanceWorkspacePublicationFence(
            to: workspacePublicationFence
        )
        sessions = []
        meetingIntelligenceCoordinator.resetForWorkspaceChange()
        transcriptionFeature.clearProjections()
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
        recordingSearchDocumentRefreshGeneration &+= 1
        recordingSearchDocumentRefreshGenerations.removeAll()
        recordingSessionRefreshGeneration &+= 1
        let generation = recordingSessionRefreshGeneration
        meetingIntelligenceSessionReloadGenerations.removeAll()
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
                self.transcriptionFeature.replaceLoadedStates(
                    transcriptionStates
                )
                self.meetingIntelligenceCoordinator.reload(sessions: loadedSessions)
            }
        }
    }

    private func rebuildSearchDocument(
        for session: RecordingSession,
        publicationFence: WorkspacePublicationFence? = nil,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard admitsSearchDocumentRebuild(
            for: session,
            publicationFence: publicationFence
        ) else {
            return
        }
        let sessionID = session.id
        recordingSearchDocumentRefreshGeneration &+= 1
        let nextGeneration =
            recordingSearchDocumentRefreshGeneration
        recordingSearchDocumentRefreshGenerations[sessionID] =
            nextGeneration
        let loader = recordingSearchDocumentLoader

        recordingSessionLoadingQueue.async { [weak self] in
            let document = loader(session)
            Task { @MainActor [weak self] in
                guard let self,
                      self.recordingSearchDocumentRefreshGenerations[
                        sessionID
                      ] == nextGeneration,
                      self.admitsSearchDocumentRebuild(
                        for: session,
                        publicationFence: publicationFence
                      ) else {
                    return
                }
                if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
                    let current = self.sessions[index]
                    guard current.metadata == session.metadata else {
                        self.rebuildSearchDocument(
                            for: current,
                            publicationFence: publicationFence,
                            completion: completion
                        )
                        return
                    }
                    self.sessions[index] = current.replacingSearchDocument(document)
                } else {
                    self.sessions.append(session.replacingSearchDocument(document))
                }
                self.recordingSearchDocumentRefreshGenerations[
                    sessionID
                ] = nil
                completion?()
            }
        }
    }

    private func reloadMeetingIntelligenceSession(_ session: RecordingSession) {
        let workspaceGeneration = recordingSessionRefreshGeneration
        let workspace = outputFolder.standardizedFileURL
        guard isInCurrentWorkspace(session) else {
            return
        }
        let sessionID = session.id
        let sessionGeneration = (meetingIntelligenceSessionReloadGenerations[sessionID] ?? 0) &+ 1
        meetingIntelligenceSessionReloadGenerations[sessionID] = sessionGeneration
        let reloader = recordingSessionReloader
        recordingSessionLoadingQueue.async { [weak self] in
            let reloaded = reloader(session)
            Task { @MainActor [weak self] in
                guard let self,
                      self.recordingSessionRefreshGeneration == workspaceGeneration,
                      self.outputFolder.standardizedFileURL == workspace,
                      self.meetingIntelligenceSessionReloadGenerations[sessionID] == sessionGeneration else {
                    return
                }
                if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) {
                    self.sessions[index] = reloaded
                } else {
                    self.sessions.append(reloaded)
                }
                self.meetingIntelligenceCoordinator.reload(sessions: [reloaded])
            }
        }
    }

    private func isInCurrentWorkspace(_ session: RecordingSession) -> Bool {
        let workspace = outputFolder.standardizedFileURL
        let sessionFolder = session.folderURL.standardizedFileURL
        return sessionFolder.path == workspace.path ||
            sessionFolder.path.hasPrefix(workspace.path + "/")
    }

    private func admitsTranscriptPublication(
        _ event: TranscriptPublished
    ) -> Bool {
        event.workspaceFence == workspacePublicationFence &&
            isInCurrentWorkspace(event.session)
    }

    private func admitsSearchDocumentRebuild(
        for session: RecordingSession,
        publicationFence: WorkspacePublicationFence?
    ) -> Bool {
        guard let publicationFence else { return true }
        return publicationFence == workspacePublicationFence &&
            isInCurrentWorkspace(session)
    }

    var playingSessionID: RecordingSession.ID? { playbackFeature.activeSessionID }
    var playbackPresentation: PlaybackPresentationModel {
        playbackFeature.presentation
    }
    var playbackPlayer: AVPlayer { playbackFeature.presentation.player }
    var playbackProgress: TimeInterval { playbackFeature.presentation.progress }
    var playbackDuration: TimeInterval { playbackFeature.presentation.duration }
    var isPlaybackActive: Bool { playbackFeature.presentation.isPlaying }

    func play(session: RecordingSession) {
        playbackFeature.play(
            session,
            successStatus: "Playing \(session.displayName)"
        )
    }

    func playbackToggle() {
        playbackFeature.toggle()
    }

    func stopPlayback(resetStatus: Bool = true) {
        playbackFeature.stop()
        if resetStatus {
            statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
        }
    }

    func seekPlayback(to time: TimeInterval) {
        playbackFeature.seek(to: time)
    }

    func open(session: RecordingSession) {
        NSWorkspace.shared.open(session.folderURL)
    }

    func transcribe(session: RecordingSession) {
        transcriptionFeature.start(
            session: session,
            providerIsConfigured: aiProviderSettingsModel.hasSavedProfile
        )
    }

    func cancelTranscription() {
        transcriptionFeature.cancel()
    }
    func openTranscript(for session: RecordingSession) {
        if let url = currentTranscriptURL(for: session) {
            NSWorkspace.shared.open(url)
        } else {
            statusMessage = "No transcript found for \(session.displayName)"
        }
    }

    func openTranscriptLog(for session: RecordingSession) {
        if let url = currentTranscriptLogURL(for: session) {
            NSWorkspace.shared.open(url)
        } else {
            statusMessage = "No ASR log found for \(session.displayName)"
        }
    }

    func currentTranscriptURL(for session: RecordingSession) -> URL? {
        let url = TranscriptDocumentStore.resolvedURL(in: session.folderURL)
        transcriptionFeature.setTranscriptURL(url, for: session.id)
        return url
    }

    func currentTranscriptLogURL(for session: RecordingSession) -> URL? {
        let url = TranscriptDocumentStore.logURL(in: session.folderURL)
        transcriptionFeature.setTranscriptLogURL(url, for: session.id)
        return url
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
            try transcriptMutationGate.withMutation(for: session.folderURL) {
                try TranscriptDocumentStore.save(text, in: session.folderURL)
            }
            transcriptionFeature.setTranscriptURL(
                TranscriptDocumentStore.editableURL(in: session.folderURL),
                for: session.id
            )
            rebuildSearchDocument(
                for: session,
                publicationFence: workspacePublicationFence
            ) { [weak self] in
                self?.meetingIntelligenceCoordinator.transcriptDidSave(session)
            }
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

    func saveMetadata(
        titleEdit: RecordingTitleEdit,
        tags: String,
        isFavorite: Bool,
        for session: RecordingSession
    ) {
        do {
            try transcriptMutationGate.withMutation(for: session.folderURL) {
                var metadata = RecordingSessionMetadataStore.load(in: session.folderURL)
                metadata.applyTitleEdit(titleEdit)
                metadata.tags = tags.split(separator: ",").map(String.init)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                metadata.isFavorite = isFavorite
                try RecordingSessionMetadataStore.save(metadata, in: session.folderURL)
            }
            refreshSessions()
            statusMessage = "Recording details saved"
        } catch {
            statusMessage = "Cannot save recording details: \(error.localizedDescription)"
        }
    }

    /// Compatibility entry point for existing views.  Title identity controls
    /// origin; a tags/favourite-only edit keeps its existing origin intact.
    func saveMetadata(title: String, tags: String, isFavorite: Bool, for session: RecordingSession) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = cleanedTitle.isEmpty ? nil : cleanedTitle
        let titleEdit: RecordingTitleEdit = requestedTitle == session.metadata.title
            ? .unchanged
            : .manual(requestedTitle)
        saveMetadata(
            titleEdit: titleEdit,
            tags: tags,
            isFavorite: isFavorite,
            for: session
        )
    }

    func moveSessionToTrash(_ session: RecordingSession) {
        do {
            _ = try recordingSessionTrashHandler(session.folderURL)
            meetingIntelligenceCoordinator.remove(sessionID: session.id)
            if playingSessionID == session.id { stopPlayback() }
            sessions.removeAll { $0.id == session.id }
            transcriptionFeature.removeProjection(for: session.id)
            refreshSessions()
            statusMessage = "Moved \(session.displayName) to Trash"
        } catch {
            statusMessage = "Cannot move recording to Trash: \(error.localizedDescription)"
        }
    }

    private func finishRecording(
        playAfterStop: Bool,
        automaticStopToken: CaptureLifecycleToken? = nil,
        recordingSource: RecordingSource = .manual
    ) async {
        let result = await recorder.stop()
        isRunningTestRecording = false
        if let result {
            lastHealthReport = result.health
            lastRecordingSavedAsM4A =
                result.recordingURL.lastPathComponent == "recording.m4a"
            var metadataSaveError: Error?
            do {
                try transcriptMutationGate.withMutation(for: result.folderURL) {
                    var metadata = RecordingSessionMetadataStore.load(
                        in: result.folderURL
                    )
                    metadata.source = recordingSource
                    try RecordingSessionMetadataStore.save(
                        metadata,
                        in: result.folderURL
                    )
                }
            } catch {
                metadataSaveError = error
            }
            refreshSessions()
            if let metadataSaveError {
                statusMessage =
                    "Recording saved, but source metadata could not be written: "
                    + metadataSaveError.localizedDescription
            } else {
                statusMessage = "Recording saved: \(result.health.summary)"
            }

            if playAfterStop {
                let session = RecordingSessionStore.session(
                    for: result.folderURL,
                    recordingURL: result.recordingURL
                )
                playbackFeature.play(
                    session,
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
              let token = recordingSessionCoordinator.begin(operation) else {
            return
        }
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
        guard let token = recordingSessionCoordinator.cancelAndBeginStop() else {
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
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishRecording(
                playAfterStop: playAfterStop,
                automaticStopToken: automaticStopToken,
                recordingSource: endingOwnership == .teamsAutomatic
                    ? .teamsAutomatic
                    : .manual
            )
            self.finishCaptureLifecycle(token)
        }
        captureLifecycleTask = task
    }

    private func finishCaptureLifecycle(_ token: CaptureLifecycleToken) {
        _ = recordingSessionCoordinator.finish(token)
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
        let recordingEpoch = recorder.continuitySnapshot.recordingEpoch
        isTeamsScreenCaptureRequested = false
        teamsScreenCaptureCandidates = []
        teamsScreenDisconnectCleanupScheduler { [weak self] in
            guard let self,
                  self.recordingSessionCoordinator.activeOperation != .stop,
                  !self.isTeamsScreenCaptureRequested,
                  self.recorder.isRecording,
                  self.recorder.continuitySnapshot.recordingEpoch
                    == recordingEpoch else { return }
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
