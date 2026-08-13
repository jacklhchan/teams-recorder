import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum RecordingOwnership: Equatable {
    case manual
    case teamsAutomatic
}

enum RecorderControlActionOutcome: Equatable {
    case accepted
    case noOp
    case rejected(code: String, message: String)
}

private struct ActiveRecordingPublicationContext {
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFence: WorkspacePublicationFence
    let retainedSession: RecordingPendingSession
}

@MainActor
final class AppModel: ObservableObject {
    typealias TranscriptionFeatureFactory = (
        any OpenAICompatibleProviderManaging,
        any TranscriptionAudioPreparing,
        any TranscriptionServicing,
        RecordingSessionMutationGate,
        any ThirdPartyProcessingAdmitting
    ) -> TranscriptionFeatureModel
    typealias RecordingSourceMetadataUpdater = (
        RecordingSource,
        RecordingPendingSession,
        RecordingSessionMutationGate
    ) throws -> Void
    @Published var devices: [AudioDevice] = []
    @Published var selectedMicDevice: AudioDevice?
    @Published private(set) var selectedMicrophoneUID: String?
    @Published private(set) var isMicrophoneSwitchPending = false
    private var microphoneSwitchGeneration: UInt64 = 0
    @Published var availableCaptureApplications: [CaptureApplication] = []
    @Published var captureSelection = CaptureSelection()
    @Published var resolvedCaptureSelection: ResolvedCaptureSelection = .allSystemAudio
    @Published var systemAudioPermission: CapturePermissionState = .notDetermined
    @Published var microphonePermission: CapturePermissionState = .notDetermined
    @Published private(set) var captureConnectionState: CaptureConnectionState = .connected
    @Published private(set) var outputFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads")
    @Published private(set) var recordingDestinationState: RecordingDestinationState = .ready
    @Published private(set) var recordingPublicationPresentation = RecordingPublicationPresentation(stateText: "Up to date", pendingCount: 0, waitingCount: 0, needsAttentionCount: 0)
    @Published private(set) var recoveryCenterSnapshot = RecoveryCenterSnapshot(
        presentation: .init(
            stateText: "Up to date",
            pendingCount: 0,
            waitingCount: 0,
            needsAttentionCount: 0
        ),
        items: []
    )
    @Published private(set) var privacyModeEnabled: Bool
    @Published private(set) var recordingDataLifecyclePolicy: RecordingDataLifecyclePolicy
    @Published private(set) var localRecorderControlEnabled: Bool
    @Published var statusMessage = "Ready"
    @Published var lastHealthReport: RecordingHealthReport?
    @Published private(set) var lastRecordingSavedAsM4A = false
    @Published var isRunningTestRecording = false
    @Published private(set) var inputMuteControlAvailable = false
    @Published private(set) var virtualMicInstallationState: VirtualMicInstallationState = .absent
    @Published private(set) var teamsAutoMeetingEnabled: Bool
    @Published private(set) var teamsAutoMeetingState: TeamsAutoMeetingState
    @Published private(set) var teamsLocalMeetingDetectionState:
        TeamsLocalMeetingDetectionState = .waiting
    @Published private(set) var localMicMuted = false
    @Published private(set) var nativeInputMicMuted = false
    @Published private(set) var isScreenCaptureAllowedByStorage = true
    @Published private(set) var screenCaptureStorageRestrictionReason: String?
    @Published private(set) var storageWarningMessage: String?
    @Published private(set) var isTeamsScreenCaptureRequested = false
    @Published private(set) var teamsManualWindowIdentity: TeamsWindowIdentity?
    @Published private(set) var teamsScreenCaptureCandidates: [TeamsWindowDescriptor] = []

    let recorder: RecordingEngine
    let privacyModePolicy: PrivacyModePolicy
    private let recordingDataLifecyclePolicyStore: RecordingDataLifecyclePolicyStore
    let localRecorderControlPolicy: LocalRecorderControlPolicy
    let aiProviderSettingsModel: AIProviderSettingsModel
    private let recordingSessionCoordinator:
        RecordingSessionCoordinator
    let transcriptionFeature: TranscriptionFeatureModel
    let libraryFeature: LibraryFeatureModel
    /// Compatibility bridge until PR C: all mutable recording artifacts use
    /// the Library feature's one gate, including when that feature is injected.
    let transcriptMutationGate: RecordingSessionMutationGate
    /// PR B compatibility construction owner. AppModel retains precisely one
    /// feature boundary and deliberately mirrors none of its mutable state.
    let meetingIntelligenceFeature: MeetingIntelligenceFeatureModel
    private var prbFeatureBridge: PRBFeatureBridge?
    private let recordingSourceMetadataUpdater: RecordingSourceMetadataUpdater
    private let recordingDestinationStore: any RecordingDestinationStoring
    private let recordingPublicationCoordinator: any RecordingPublicationCoordinating
    private let pendingRecordingStore: RecordingPendingStore
    private(set) var recordingDestinationIdentity: RecordingDestinationIdentity?
    private var activeRecordingPublicationContext: ActiveRecordingPublicationContext?

    var isCaptureLifecycleWorking: Bool {
        recordingSessionCoordinator.isWorking
    }

    var pendingRecordingsFolderURL: URL {
        pendingRecordingStore.root
    }

    var recordingLifecycleOperation: CaptureLifecycleOperation? {
        recordingSessionCoordinator.activeOperation
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

    var sessions: [RecordingSession] { libraryFeature.sessions }

    /// Test-only fixture bridge that preserves the same workspace/fence
    /// admission contract as production refreshes.
    func seedLibrarySessionsForTesting(_ sessions: [RecordingSession]) {
        libraryFeature.seedCanonicalSessionsForTesting(
            sessions,
            workspace: outputFolder,
            fence: workspacePublicationFence
        )
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
    private let microphoneMuteGate: MicrophoneMuteGate
    private let teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator
    private let virtualMicStateProvider: () -> VirtualMicInstallationState
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
    private var cancellables: Set<AnyCancellable> = []
    private var teamsApplicationLifecycleCancellables:
        Set<AnyCancellable> = []
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
    private var storageMonitorTask: Task<Void, Never>?
    private var storageMonitorGeneration: UInt64 = 0
    private var testRecordingStopTask: Task<Void, Never>?
    private var teamsScreenRefreshTask: Task<Void, Never>?
    private var teamsScreenRefreshGeneration: UInt64 = 0
    private var teamsScreenCaptureIntentGeneration: UInt64 = 0
    private var teamsLocalMeetingDetector = TeamsLocalMeetingDetector()
    private var workspacePublicationFence: WorkspacePublicationFence = .initial
    private var isShutDown = false

    private static let teamsAutoMeetingEnabledKey = "teamsAutoMeetingEnabled"

    init(
        defaults: UserDefaults = .standard,
        privacyModePolicy: PrivacyModePolicy? = nil,
        localRecorderControlPolicy: LocalRecorderControlPolicy? = nil,
        providerRepository: (any OpenAICompatibleProviderManaging)? = nil,
        appPaths: AppPaths = .live,
        recorder: RecordingEngine? = nil,
        recordingDestinationStore: (any RecordingDestinationStoring)? = nil,
        recordingPublicationCoordinator: (any RecordingPublicationCoordinating)? = nil,
        inputDevices: @escaping () -> [AudioDevice] = AudioDeviceManager.inputDevices,
        defaultInputDeviceID: @escaping () -> AudioDeviceID? = AudioDeviceManager.defaultInputDeviceID,
        performStartupWork: Bool = true,
        initialOutputFolder: URL? = nil,
        inputMuteControllerFactory: (
            (@escaping (Bool) -> Void) -> InputMuteControlling
        )? = nil,
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
        libraryFeature: LibraryFeatureModel? = nil,
        meetingIntelligenceFeature: MeetingIntelligenceFeatureModel? = nil,
        meetingIntelligenceFeatureFactory: MeetingIntelligenceFeatureFactory? = nil,
        playbackCoordinator: (any PlaybackCoordinating)? = nil,
        playbackFeature: PlaybackFeatureModel? = nil,
        featureBoundaries: PRBFeatureBoundaries? = nil,
        defaultFeatureBoundariesFactory: PRBFeatureBoundariesFactory? = nil,
        recordingSourceMetadataUpdater: @escaping RecordingSourceMetadataUpdater = {
            source, session, gate in
            try gate.withMutation(for: session.displayURL) {
                try RecordingPendingStore(root: session.displayURL.deletingLastPathComponent())
                    .updateRecordingSourceMetadata(source, in: session)
            }
        },
        teamsAutoMeetingCoordinator: TeamsAutoMeetingCoordinator? = nil
    ) {
        let activePrivacyModePolicy = privacyModePolicy
            ?? PrivacyModePolicy(defaults: defaults)
        self.privacyModePolicy = activePrivacyModePolicy
        privacyModeEnabled = activePrivacyModePolicy.isEnabled
        let activeLifecyclePolicyStore = RecordingDataLifecyclePolicyStore(defaults: defaults)
        recordingDataLifecyclePolicyStore = activeLifecyclePolicyStore
        let activeLifecyclePolicy = activeLifecyclePolicyStore.load()
        recordingDataLifecyclePolicy = activeLifecyclePolicy
        let activeLocalRecorderControlPolicy = localRecorderControlPolicy
            ?? LocalRecorderControlPolicy(defaults: defaults)
        self.localRecorderControlPolicy = activeLocalRecorderControlPolicy
        localRecorderControlEnabled = activeLocalRecorderControlPolicy.isEnabled
        let activeDestinationStore = recordingDestinationStore
            ?? RecordingDestinationStore(defaults: defaults)
        let destinationSelection: RecordingDestinationSelection
        if let initialOutputFolder {
            do {
                try activeDestinationStore.save(initialOutputFolder)
                destinationSelection = .init(
                    identity: activeDestinationStore.currentIdentity,
                    url: initialOutputFolder,
                    state: activeDestinationStore.currentIdentity == nil
                        ? .unavailable
                        : .ready
                )
            } catch {
                destinationSelection = .init(
                    identity: activeDestinationStore.currentIdentity,
                    url: initialOutputFolder,
                    state: .unavailable
                )
            }
        } else {
            let restored = activeDestinationStore.restore(
                defaultURL: appPaths.recordingsDirectory
            )
            if restored.identity != nil {
                destinationSelection = restored
            } else {
                do {
                    try activeDestinationStore.save(restored.url)
                    if let identity = activeDestinationStore.currentIdentity {
                        destinationSelection = .init(
                            identity: identity,
                            url: restored.url,
                            state: restored.state
                        )
                    } else {
                        destinationSelection = .init(
                            identity: nil,
                            url: restored.url,
                            state: .unavailable
                        )
                    }
                } catch {
                    destinationSelection = .init(
                        identity: nil,
                        url: restored.url,
                        state: .unavailable
                    )
                }
            }
        }
        outputFolder = destinationSelection.url
        recordingDestinationState = destinationSelection.state
        recordingDestinationIdentity = destinationSelection.identity
        let pendingStore = RecordingPendingStore(
            root: appPaths.pendingRecordingsDirectory,
            manifestURL: appPaths.recordingPublicationManifestURL
        )
        pendingRecordingStore = pendingStore
        self.recordingDestinationStore = activeDestinationStore
        self.recordingPublicationCoordinator = recordingPublicationCoordinator
            ?? RecordingPublicationCoordinator(
                manifestStore: RecordingPublicationManifestStore(
                    manifestURL: appPaths.recordingPublicationManifestURL
                ),
                destinationStore: activeDestinationStore,
                publisher: RecordingSessionPublisher(pendingStore: pendingStore),
                pendingStore: pendingStore
            )
        let activeRecorder = recorder ?? RecordingEngine()
        let autoCoordinator = teamsAutoMeetingCoordinator
            ?? TeamsAutoMeetingCoordinator()
        self.recorder = activeRecorder
        recordingSessionCoordinator = RecordingSessionCoordinator()
        self.teamsAutoMeetingCoordinator = autoCoordinator
        self.inputDevices = inputDevices
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaults = defaults
        self.recordingSourceMetadataUpdater = recordingSourceMetadataUpdater
        let activeProviderRepository = providerRepository
            ?? OpenAICompatibleProviderRepository(
                profiles: OpenAICompatibleProviderProfileStore(defaults: defaults),
                secureStore: KeychainSecureValueStore()
            )
        aiProviderSettingsModel = AIProviderSettingsModel(
            repository: activeProviderRepository,
            loadImmediately: false
        )
        let hasIndividualFeatureInjection = transcriptionFeatureFactory != nil
            || libraryFeature != nil
            || meetingIntelligenceFeature != nil
            || meetingIntelligenceFeatureFactory != nil
            || playbackCoordinator != nil
            || playbackFeature != nil
        precondition(
            !hasIndividualFeatureInjection || (
                featureBoundaries == nil
                    && defaultFeatureBoundariesFactory == nil
            ),
            "Inject either PR B feature boundaries or individual feature seams, not both."
        )
        // The fallback is intentionally evaluated only when no aggregate was
        // supplied.  This makes aggregate injection a strict construction
        // boundary rather than a second set of parallel feature objects.
        let selectedFeatureBoundaries = featureBoundaries
            ?? defaultFeatureBoundariesFactory?(activePrivacyModePolicy)
        if let selectedFeatureBoundaries {
            precondition(
                selectedFeatureBoundaries.transcription
                    .thirdPartyProcessingAdmissionIdentity
                    == ObjectIdentifier(activePrivacyModePolicy)
                    && selectedFeatureBoundaries.meetingIntelligence
                        .thirdPartyProcessingAdmissionIdentity
                        == ObjectIdentifier(activePrivacyModePolicy),
                "Injected feature boundaries must share AppModel's Privacy Mode policy."
            )
        }
        let transcriptMutationGate = selectedFeatureBoundaries?.library.mutationGate
            ?? libraryFeature?.mutationGate
            ?? RecordingSessionMutationGate()
        self.transcriptMutationGate = transcriptMutationGate
        if let selectedFeatureBoundaries {
            self.libraryFeature = selectedFeatureBoundaries.library
            self.transcriptionFeature = selectedFeatureBoundaries.transcription
            self.meetingIntelligenceFeature = selectedFeatureBoundaries.meetingIntelligence
            self.playbackFeature = selectedFeatureBoundaries.playback
        } else {
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
                        mutationGate: transcriptMutationGate,
                        lifecyclePolicy: activeLifecyclePolicy,
                        lifecyclePolicyProvider: {
                            activeLifecyclePolicyStore.load()
                        }
                    )
                )
            }
            if let transcriptionFeatureFactory {
                self.transcriptionFeature = transcriptionFeatureFactory(
                    activeProviderRepository,
                    transcriptionAudioPreparer,
                    activeTranscriptionService,
                    transcriptMutationGate,
                    activePrivacyModePolicy
                )
            } else {
                self.transcriptionFeature = TranscriptionFeatureModel(
                    coordinator: TranscriptionJobCoordinator(
                        providerRepository: activeProviderRepository,
                        audioPreparer: transcriptionAudioPreparer,
                        service: activeTranscriptionService,
                        mutationGate: transcriptMutationGate
                    ),
                    thirdPartyProcessingAdmission: activePrivacyModePolicy
                )
            }
            precondition(
                meetingIntelligenceFeature == nil || meetingIntelligenceFeatureFactory == nil,
                "Inject either a meeting intelligence feature or feature factory, not both."
            )
            if let meetingIntelligenceFeature {
                self.meetingIntelligenceFeature = meetingIntelligenceFeature
            } else if let meetingIntelligenceFeatureFactory {
                self.meetingIntelligenceFeature = meetingIntelligenceFeatureFactory(
                    activeProviderRepository,
                    self.transcriptionFeature.publicationSourceID,
                    transcriptMutationGate,
                    activePrivacyModePolicy
                )
            } else {
                self.meetingIntelligenceFeature = MeetingIntelligenceFeatureModel(
                    coordinator: Self.makeMeetingIntelligenceCoordinator(
                        repository: activeProviderRepository,
                        expectedPublicationSourceID: self.transcriptionFeature.publicationSourceID,
                        mutationGate: transcriptMutationGate,
                        thirdPartyProcessingAdmission: activePrivacyModePolicy
                    )
                )
            }
            self.libraryFeature = libraryFeature ?? LibraryFeatureModel(
                sessionLoader: recordingSessionLoader,
                sessionReloader: recordingSessionReloader,
                searchDocumentLoader: recordingSearchDocumentLoader,
                recovery: recordingSessionRecovery,
                trashHandler: recordingSessionTrashHandler,
                mutationGate: transcriptMutationGate
            )
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
        }
        self.appPaths = appPaths
        teamsAutoMeetingEnabled = defaults.bool(
            forKey: Self.teamsAutoMeetingEnabledKey
        )
        teamsAutoMeetingState = autoCoordinator.state
        self.virtualMicStateProvider = virtualMicStateProvider
        self.permissionRequestHandler = permissionRequestHandler
        self.volumeCapacityProvider = volumeCapacityProvider
        self.storagePolicy = storagePolicy
        self.storageMonitorTick = storageMonitorTick
        self.testRecordingDelay = testRecordingDelay
        self.teamsScreenRefreshTick = teamsScreenRefreshTick
        self.teamsScreenDisconnectCleanupScheduler =
            teamsScreenDisconnectCleanupScheduler
        let microphoneMuteGate = MicrophoneMuteGate { [weak activeRecorder] muted in
            activeRecorder?.applyInputMuteToAudioPaths(muted)
        }
        self.microphoneMuteGate = microphoneMuteGate
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
        capturePersistence = CaptureSelectionPersistence(defaults: defaults)
        captureSelection = capturePersistence.loadSelection()
        selectedMicrophoneUID = capturePersistence.loadMicrophoneUID()
        activePrivacyModePolicy.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard self?.privacyModeEnabled != enabled else { return }
                self?.privacyModeEnabled = enabled
            }
            .store(in: &cancellables)
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
        let retainedFeatureBoundaries = PRBFeatureBoundaries(
            library: self.libraryFeature,
            transcription: self.transcriptionFeature,
            meetingIntelligence: self.meetingIntelligenceFeature,
            playback: self.playbackFeature
        )
        precondition(
            retainedFeatureBoundaries.isCompatible(
                with: activeProviderRepository.compositionIdentity,
                thirdPartyProcessingAdmissionIdentity:
                    ObjectIdentifier(activePrivacyModePolicy)
            ) && aiProviderSettingsModel.providerRepositoryIdentity
                == activeProviderRepository.compositionIdentity,
            "PR B boundaries and Provider Settings must share one provider repository, one mutation gate, one Privacy Mode policy, and compatible ASR/meeting-intelligence publication sources."
        )
        let bridge = PRBFeatureBridge(
            boundaries: retainedFeatureBoundaries,
            providerSettings: aiProviderSettingsModel,
            currentWorkspace: { [weak self] in
                guard let self, !self.isShutDown else { return nil }
                return .init(
                    folder: RecordingLibraryURLIdentity.normalized(
                        self.outputFolder
                    ),
                    fence: self.workspacePublicationFence
                )
            },
            transcriptionProviderIsConfigured: {
                [weak aiProviderSettingsModel] in
                aiProviderSettingsModel?.hasSavedProfile ?? false
            },
            reportStatus: { [weak self] message in
                self?.statusMessage = message
            }
        )
        prbFeatureBridge = bridge
        bridge.start()
        self.recordingPublicationPresentation = self.recordingPublicationCoordinator.presentation
        self.recoveryCenterSnapshot = self.recordingPublicationCoordinator.recoveryCenterSnapshot
        self.recordingPublicationCoordinator.onPresentationChange = { [weak self] presentation in
            self?.recordingPublicationPresentation = presentation
            self?.projectRecordingPublicationStatus(presentation)
        }
        self.recordingPublicationCoordinator.onRecoveryCenterSnapshotChange = { [weak self] snapshot in
            self?.recoveryCenterSnapshot = snapshot
        }
        self.recordingPublicationCoordinator.onCompleted = { [weak self] completion in
            self?.acceptRecordingPublicationCompletion(completion)
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
        installTeamsApplicationLifecycleMonitoring()
        do {
            try LegacyTeamsIntegrationCleaner(
                secureStore: KeychainSecureValueStore(),
                defaults: defaults
            ).clean()
        } catch {
            statusMessage = "Retired Teams integration cleanup will retry next launch"
        }
        installInputMuteHandling()
        hotKeyManager.register()
        refreshPermissionPreflight()
        refreshCaptureApplications()
        refreshSessions()
        self.recordingPublicationCoordinator.resume()
        aiProviderSettingsModel.performStartupMigration(
            settingsURL: appPaths.omlxSettingsURL
        )
    }

    func setPrivacyModeEnabled(_ enabled: Bool) {
        privacyModePolicy.setEnabled(enabled)
    }

    func setOwnerOnlyForNewLocalArtifacts(_ enabled: Bool) {
        guard recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts != enabled else {
            return
        }
        recordingDataLifecyclePolicy.ownerOnlyForNewLocalArtifacts = enabled
        try? recordingDataLifecyclePolicyStore.save(recordingDataLifecyclePolicy)
    }

    func setRedactGeneratedDiagnostics(_ enabled: Bool) {
        guard recordingDataLifecyclePolicy.redactGeneratedDiagnostics != enabled else {
            return
        }
        recordingDataLifecyclePolicy.redactGeneratedDiagnostics = enabled
        try? recordingDataLifecyclePolicyStore.save(recordingDataLifecyclePolicy)
    }

    func setLocalRecorderControlEnabled(_ enabled: Bool) {
        guard localRecorderControlEnabled != enabled else { return }
        localRecorderControlEnabled = enabled
        localRecorderControlPolicy.setEnabled(enabled)
    }

    deinit {
        storageMonitorTask?.cancel()
        testRecordingStopTask?.cancel()
        teamsScreenRefreshTask?.cancel()
        inputMuteController.uninstall()
    }

    private static func makeMeetingIntelligenceCoordinator(
        repository: any OpenAICompatibleProviderManaging,
        expectedPublicationSourceID: UUID,
        mutationGate: RecordingSessionMutationGate,
        thirdPartyProcessingAdmission: any ThirdPartyProcessingAdmitting
    ) -> MeetingIntelligenceJobCoordinator {
        let client = OpenAICompatibleMeetingIntelligenceClient()
        let transcriptReader = SecureTranscriptDocumentReader()
        let artifactStore = MeetingIntelligenceArtifactStore(
            mutationGate: mutationGate
        )
        let publisher = MeetingIntelligencePublisher(
            mutationGate: mutationGate,
            transcriptReader: transcriptReader,
            artifactStore: artifactStore
        )
        let artifactEditor = MeetingIntelligenceArtifactEditor(
            mutationGate: mutationGate,
            transcriptReader: transcriptReader,
            artifactStore: artifactStore
        )
        return MeetingIntelligenceJobCoordinator(
            providerRepository: repository,
            expectedPublicationSourceID: expectedPublicationSourceID,
            mutationGate: mutationGate,
            transcriptReader: transcriptReader,
            availabilityChecker:
                OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
                    client: OpenAICompatibleProviderClient()
                ),
            generator: MeetingIntelligencePipeline(client: client),
            publisher: publisher,
            artifactStore: artifactStore,
            stateStore: MeetingIntelligenceStateStore(
                mutationGate: mutationGate
            ),
            artifactEditor: artifactEditor,
            titleApplier: MeetingIntelligenceSuggestedTitleApplier(
                mutationGate: mutationGate,
                transcriptReader: transcriptReader
            ),
            thirdPartyProcessingAdmission: thirdPartyProcessingAdmission
        )
    }

    func meetingIntelligencePresentation(
        for session: RecordingSession
    ) -> MeetingIntelligencePresentation {
        meetingIntelligenceFeature.presentation(for: session)
    }

    func checkMeetingIntelligenceAvailability(for session: RecordingSession) {
        meetingIntelligenceFeature.checkAvailability(
            for: session,
            workspaceFence: workspacePublicationFence
        )
    }

    func generateMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceFeature.generate(
            for: session,
            workspaceFence: workspacePublicationFence
        )
    }

    func regenerateMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceFeature.regenerate(
            for: session,
            workspaceFence: workspacePublicationFence
        )
    }

    func retryMeetingIntelligenceGeneration(for session: RecordingSession) {
        meetingIntelligenceFeature.retryGeneration(
            for: session,
            workspaceFence: workspacePublicationFence
        )
    }

    @discardableResult
    func saveMeetingIntelligenceEdit(
        for session: RecordingSession,
        capturedArtifact: MeetingIntelligenceArtifact,
        capturedTranscriptRevision: TranscriptDocumentRevision,
        summary: String,
        suggestedTitle: String
    ) async -> MeetingIntelligenceEditSaveOutcome {
        let fence = workspacePublicationFence
        let outcome = await meetingIntelligenceFeature.saveEdit(
            for: session,
            capturedArtifact: capturedArtifact,
            summary: summary,
            suggestedTitle: suggestedTitle,
            capturedTranscriptRevision: capturedTranscriptRevision,
            workspaceFence: fence
        )
        if case .conflict = outcome {
            let currentSessions = libraryFeature.sessions.filter {
                $0.id == session.id
            }
            meetingIntelligenceFeature.reload(sessions: currentSessions)
        }
        return outcome
    }

    func cancelMeetingIntelligence(for session: RecordingSession) {
        meetingIntelligenceFeature.cancel(sessionID: session.id)
    }

    func applyMeetingIntelligenceSuggestedTitle(for session: RecordingSession) {
        meetingIntelligenceFeature.applySuggestedTitle(
            for: session,
            workspaceFence: workspacePublicationFence
        )
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        invalidateTeamsScreenRefresh()
        teamsApplicationLifecycleCancellables.removeAll()
        recordingPublicationCoordinator.shutdown()
        prbFeatureBridge?.shutdown()
        playbackFeature.shutdown()
        transcriptionFeature.shutdown()
        meetingIntelligenceFeature.shutdown()
        libraryFeature.shutdown()
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
        if recorder.isRecording {
            guard recorder.supportsLiveMicrophoneSwitch,
                  !isCaptureLifecycleWorking else {
                return
            }
            if let device,
               !devices.contains(where: { $0.uid == device.uid }) {
                statusMessage = "Selected microphone is unavailable"
                return
            }
            microphoneSwitchGeneration &+= 1
            let generation = microphoneSwitchGeneration
            isMicrophoneSwitchPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await recorder.switchMicrophone(to: device?.uid)
                guard generation == self.microphoneSwitchGeneration else { return }
                self.isMicrophoneSwitchPending = false
                if case .switched(_, let currentUID) = outcome,
                   currentUID == device?.uid {
                    self.selectedMicDevice = device
                    self.selectedMicrophoneUID = device?.uid
                    self.capturePersistence.saveMicrophoneUID(device?.uid)
                } else if case .failed = outcome {
                    self.statusMessage = "Microphone switch failed"
                } else if case .unavailable = outcome {
                    self.statusMessage = "Selected microphone is unavailable"
                } else if case .switched = outcome {
                    self.statusMessage = "Microphone switch failed"
                }
            }
            return
        }
        guard sourceControlsEnabled else { return }
        selectedMicDevice = device
        selectedMicrophoneUID = device?.uid
        capturePersistence.saveMicrophoneUID(selectedMicrophoneUID)
        refreshCaptureApplications()
    }

    var sourceControlsEnabled: Bool {
        !recorder.isRecording && !isCaptureLifecycleWorking
    }

    var microphoneSelectionEnabled: Bool {
        if recorder.isRecording {
            return recorder.supportsLiveMicrophoneSwitch && !isMicrophoneSwitchPending
        }
        return sourceControlsEnabled
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
        let outcome = await recorder.refreshTeamsWindows(
            selectedTeamsProcessID: selectedTeamsApplication.processID,
            mode: .localDetection,
            manualOverride: teamsManualWindowIdentity
        )
        guard generation == teamsScreenRefreshGeneration else { return }
        if teamsAutoMeetingEnabled {
            let observation: TeamsLocalMeetingObservation
            switch outcome {
            case .resolved(let resolution):
                observation = .resolved(resolution)
            case .unknown:
                observation = .unknown
            }
            applyLocalMeetingUpdate(
                teamsLocalMeetingDetector.observe(observation)
            )
        }
        guard generation == teamsScreenRefreshGeneration else { return }
        reconcileTeamsManualWindowIdentity()
        refreshTeamsScreenCandidateProjection()
    }

    private func applyLocalMeetingUpdate(_ update: TeamsLocalMeetingUpdate) {
        teamsLocalMeetingDetectionState = update.state
        guard let transition = update.meetingTransition else { return }
        if transition {
            teamsAutoMeetingCoordinator.handleMeetingState(isInMeeting: true)
            suppressAutomationForActiveManualRecording()
        } else {
            teamsAutoMeetingCoordinator.handleConfirmedMeetingEnd()
        }
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
        teamsLocalMeetingDetectionState = teamsLocalMeetingDetector.reset().state
        teamsManualWindowIdentity = nil
        teamsScreenCaptureCandidates = []
        recorder.resetTeamsWindowResolution()
        guard selectedTeamsApplication != nil else { return }
        restartTeamsScreenRefreshIfNeeded()
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
              teamsAutoMeetingEnabled || recorder.isRecording
                || isTeamsScreenCaptureRequested else { return }
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

    private func installTeamsApplicationLifecycleMonitoring() {
        guard teamsApplicationLifecycleCancellables.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            center.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            ),
            center.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            )
        )
        .compactMap { notification in
            notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        }
        .filter {
            $0.bundleIdentifier == "com.microsoft.teams2"
        }
        .receive(on: RunLoop.main)
        .sink { [weak self] application in
            self?.handleTeamsApplicationLifecycleChange(
                processID: application.processIdentifier,
                isTerminated: application.isTerminated
            )
        }
        .store(in: &teamsApplicationLifecycleCancellables)
    }

    func handleTeamsApplicationLifecycleChange(
        processID: pid_t,
        isTerminated: Bool
    ) {
        if isTerminated,
           selectedTeamsApplication?.processID == processID {
            teamsAutoMeetingCoordinator.handleConfirmedMeetingEnd()
        }
        refreshCaptureApplications()
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

    func startRecordingFromControl() -> RecorderControlActionOutcome {
        if recorder.isRecording { return .noOp }
        guard !isCaptureLifecycleWorking else {
            return .rejected(
                code: "busy",
                message: "Another capture operation is in progress."
            )
        }
        guard captureReadiness == .ready else {
            return .rejected(code: "not_ready", message: readinessMessage)
        }
        teamsAutoMeetingCoordinator.manualRecordingStarted()
        beginRecording(ownership: .manual, requestPermissions: false)
        return .accepted
    }

    func stopRecordingFromControl() -> RecorderControlActionOutcome {
        let hadWork = recorder.isRecording || pendingRecordingAttempt != nil
        guard hadWork else { return .noOp }
        stopCaptureLifecycle(playAfterStop: false)
        return .accepted
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
        let recordingFolder = pendingRecordingStore.root
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
        guard let destinationIdentity = recordingDestinationIdentity else {
            statusMessage = "Recording destination needs folder access."
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
            guard let retainedSession = recorder.copyAdmittedPendingSession() else {
                _ = await recorder.stop()
                clearActiveRecordingPublicationContext()
                statusMessage = "Recording saved locally, but publication needs attention"
                await completeRecordingStartAttempt(attempt)
                return
            }
            activeRecordingPublicationContext = .init(
                destinationIdentity: destinationIdentity,
                workspaceFence: workspacePublicationFence,
                retainedSession: retainedSession
            )
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
            clearActiveRecordingPublicationContextIfNotRecording()
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
        } else {
            clearActiveRecordingPublicationContextIfNotRecording()
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
        clearActiveRecordingPublicationContextIfNotRecording()
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
            let recordingFolder = pendingRecordingStore.root
            guard await prepareStorageForNewRecording(in: recordingFolder) else {
                isRunningTestRecording = false
                return
            }
            guard recordingSessionCoordinator.accepts(token) else { return }
            guard let destinationIdentity = recordingDestinationIdentity else {
                isRunningTestRecording = false
                statusMessage = "Recording destination needs folder access."
                return
            }
            do {
                try await recorder.start(
                    selection: resolvedCaptureSelection,
                    microphoneUID: selectedMicDevice?.uid,
                    baseFolder: recordingFolder,
                    folderPrefix: "test"
                )
                guard let retainedSession = recorder.copyAdmittedPendingSession() else {
                    _ = await recorder.stop()
                    clearActiveRecordingPublicationContext()
                    clearTestRecordingRuntimeState()
                    statusMessage = "Recording saved locally, but publication needs attention"
                    return
                }
                activeRecordingPublicationContext = .init(
                    destinationIdentity: destinationIdentity,
                    workspaceFence: workspacePublicationFence,
                    retainedSession: retainedSession
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
                clearActiveRecordingPublicationContext()
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
        clearActiveRecordingPublicationContext()
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
        do {
            try recordingDestinationStore.save(folder)
        } catch {
            statusMessage = "Cannot save recording destination: \(error.localizedDescription)"
            return
        }
        outputFolder = folder
        recordingDestinationIdentity = recordingDestinationStore.currentIdentity
        recordingDestinationState = .ready
        workspacePublicationFence = workspacePublicationFence.advanced()
        prbFeatureBridge?.workspaceDidChange(
            .init(workspace: .init(
                folder: RecordingLibraryURLIdentity.normalized(folder),
                fence: workspacePublicationFence
            ))
        )
    }

    func retryPendingRecordings() {
        recordingPublicationCoordinator.retryNow()
    }

    func openPendingRecordingsFolder() {
        do {
            try pendingRecordingStore.prepareRoot()
            NSWorkspace.shared.open(pendingRecordingStore.root)
        } catch {
            statusMessage = "Cannot open local recordings: \(error.localizedDescription)"
        }
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

        Task { [weak self] in
            guard let self else { return }
            _ = await self.importAudioForTranscription(url)
        }
    }

    @discardableResult
    func importAudioForTranscription(
        _ url: URL
    ) async -> Result<RecordingSession, LibraryFeatureFailure> {
        let workspace = outputFolder
        let fence = workspacePublicationFence
        let outcome = await libraryFeature.importAudio(
            url, workspace: workspace, fence: fence
        )
        guard canPresentWorkspaceResult(for: fence) else { return outcome }
        if case .failure(let error) = outcome {
            statusMessage = error.message
        }
        return outcome
    }

    func openRecordingFolder() {
        if let folder = recorder.outputFolder {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.open(outputFolder)
        }
    }

    func refreshSessions() {
        libraryFeature.refresh(
            workspace: outputFolder,
            fence: workspacePublicationFence
        )
    }

    private func canPresentWorkspaceResult(
        for capturedFence: WorkspacePublicationFence
    ) -> Bool {
        !isShutDown && workspacePublicationFence == capturedFence
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

    func setPlaybackVolume(_ volume: Float) {
        playbackFeature.setVolume(volume)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackFeature.setRate(rate)
    }

    func revealRecording(_ session: RecordingSession) {
        NSWorkspace.shared.activateFileViewerSelecting([session.recordingURL])
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
        let requestedMute = !current.localMuted
        setRecorderMicMuted(requestedMute, source: source)
        let snapshot = microphoneMuteGate.snapshot
        if !requestedMute, snapshot.effectiveMuted {
            statusMessage = "\(source): recorder mic remains muted by the input device"
        }
    }

    func setRecorderMicMuted(
        _ muted: Bool,
        source: String = "Control"
    ) {
        let snapshot = microphoneMuteGate.setLocalMuted(muted)
        publishMicrophoneMuteSnapshot(snapshot)
        statusMessage = "\(source): recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
    }

    var recorderMicMuteSnapshot: MicrophoneMuteSnapshot {
        microphoneMuteGate.snapshot
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

    func setTeamsAutoMeetingEnabled(_ enabled: Bool) {
        guard teamsAutoMeetingEnabled != enabled else { return }

        teamsAutoMeetingEnabled = enabled
        defaults.set(enabled, forKey: Self.teamsAutoMeetingEnabledKey)
        teamsAutoMeetingCoordinator.setEnabled(enabled)
        if !enabled {
            teamsLocalMeetingDetectionState = teamsLocalMeetingDetector.reset().state
        }
        restartTeamsScreenRefreshIfNeeded()
        guard selectedTeamsApplication != nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshTeamsScreenCaptureNow()
        }
    }

    func cancelTeamsAutoMeetingCountdown() {
        teamsAutoMeetingCoordinator.cancelCountdown()
    }

    func rearmTeamsAutoMeeting() -> RecorderControlActionOutcome {
        teamsAutoMeetingCoordinator.rearmCurrentMeeting() ? .accepted : .noOp
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
        recorder.updateMicMuteDisplay(snapshot.effectiveMuted)
    }

    func transcriptText(for session: RecordingSession) -> String {
        do {
            return try libraryFeature.transcriptText(for: session)
        } catch {
            statusMessage = "Cannot read transcript: \(error.localizedDescription)"
            return ""
        }
    }

    func saveTranscript(_ text: String, for session: RecordingSession) async -> LibrarySaveOutcome {
        let fence = workspacePublicationFence
        let outcome = await libraryFeature.saveTranscript(text, for: session, fence: fence)
        guard canPresentWorkspaceResult(for: fence) else { return outcome }
        if outcome.savedArtifacts.contains(.transcript) {
            transcriptionFeature.setTranscriptURL(TranscriptDocumentStore.editableURL(in: session.folderURL), for: session.id)
            statusMessage = "Transcript saved"
        } else {
            statusMessage = outcome.failures.first?.userMessage ?? "Cannot save transcript."
        }
        return outcome
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
    ) async -> LibrarySaveOutcome {
        let fence = workspacePublicationFence
        let outcome = await libraryFeature.saveMetadata(
            titleEdit: titleEdit, tags: tags, isFavorite: isFavorite,
            for: session, fence: fence
        )
        guard canPresentWorkspaceResult(for: fence) else { return outcome }
        if outcome.savedArtifacts.contains(.metadata) {
            statusMessage = "Recording details saved"
        } else {
            statusMessage = outcome.failures.first?.userMessage ?? "Cannot save recording details."
        }
        return outcome
    }

    /// Compatibility entry point for existing views.  Title identity controls
    /// origin; a tags/favourite-only edit keeps its existing origin intact.
    func saveMetadata(title: String, tags: String, isFavorite: Bool, for session: RecordingSession) async -> LibrarySaveOutcome {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = cleanedTitle.isEmpty ? nil : cleanedTitle
        let titleEdit: RecordingTitleEdit = requestedTitle == session.metadata.title
            ? .unchanged
            : .manual(requestedTitle)
        return await saveMetadata(
            titleEdit: titleEdit,
            tags: tags,
            isFavorite: isFavorite,
            for: session
        )
    }

    func moveSessionToTrash(_ session: RecordingSession) async {
        let fence = workspacePublicationFence
        let outcome = await libraryFeature.moveToTrash(session, fence: fence)
        guard canPresentWorkspaceResult(for: fence) else { return }
        switch outcome {
        case .success:
            playbackFeature.stopIfActive(sessionID: session.id)
            statusMessage = "Moved \(session.displayName) to Trash"
        case .failure(let error): statusMessage = error.message
        }
    }

    func finishRecording(
        playAfterStop: Bool,
        automaticStopToken: CaptureLifecycleToken? = nil,
        recordingSource: RecordingSource = .manual
    ) async {
        let publicationContext = activeRecordingPublicationContext
        let result = await recorder.stop()
        isRunningTestRecording = false
        clearActiveRecordingPublicationContext()
        if let result {
            lastHealthReport = result.health
            lastRecordingSavedAsM4A =
                result.recordingURL.lastPathComponent == "recording.m4a"
            guard let publicationContext,
                  validatesRetainedPendingSession(publicationContext, result: result) else {
                statusMessage = "Recording saved locally, but publication needs attention"
                if let automaticStopToken, !recorder.isRecording {
                    completeAutomaticStopIntent(automaticStopToken)
                }
                return
            }
            var metadataSaveError: Error?
            do {
                try recordingSourceMetadataUpdater(
                    recordingSource,
                    publicationContext.retainedSession,
                    transcriptMutationGate
                )
            } catch {
                metadataSaveError = error
            }
            guard validatesRetainedPendingSession(publicationContext, result: result) else {
                statusMessage = "Recording saved locally, but publication needs attention"
                if let automaticStopToken, !recorder.isRecording {
                    completeAutomaticStopIntent(automaticStopToken)
                }
                return
            }
            let request = RecordingPublicationRequest(
                id: UUID(),
                sessionDirectoryName: publicationContext.retainedSession.directoryName,
                destinationIdentity: publicationContext.destinationIdentity,
                workspaceFence: publicationContext.workspaceFence,
                source: recordingSource,
                health: result.health,
                metadataWarning: metadataSaveError?.localizedDescription,
                sourceIdentity: publicationContext.retainedSession.identity,
                sourceRootIdentity: publicationContext.retainedSession.rootIdentity
            )
            recordingPublicationCoordinator.enqueue(request)
            statusMessage = "Recording saved locally; publishing"
        } else if automaticStopToken == nil {
            statusMessage = "No active recording."
        }
        if let automaticStopToken, !recorder.isRecording {
            completeAutomaticStopIntent(automaticStopToken)
        }
    }

    private func validatesRetainedPendingSession(_ context: ActiveRecordingPublicationContext, result: RecordingResult) -> Bool {
        let session = context.retainedSession
        guard result.folderURL.standardizedFileURL == session.displayURL.standardizedFileURL,
              result.recordingURL.standardizedFileURL.deletingLastPathComponent() == session.displayURL.standardizedFileURL else { return false }
        return (try? pendingRecordingStore.validateRetainedSession(session)) != nil
    }

    private func clearActiveRecordingPublicationContext() {
        activeRecordingPublicationContext = nil
    }

    private func clearActiveRecordingPublicationContextIfNotRecording() {
        guard !recorder.isRecording else { return }
        clearActiveRecordingPublicationContext()
    }

    private func projectRecordingPublicationStatus(
        _ presentation: RecordingPublicationPresentation
    ) {
        if presentation.needsAttentionCount > 0 {
            statusMessage = "Recording saved locally; publication needs attention"
        } else if presentation.waitingCount > 0 {
            statusMessage = "Recording saved locally; waiting for OneDrive"
        }
    }

    private func acceptRecordingPublicationCompletion(
        _ completion: RecordingPublicationCompleted
    ) {
        guard completion.destinationIdentity == recordingDestinationIdentity,
              completion.workspaceFence == workspacePublicationFence else { return }
        prbFeatureBridge?.recordingDidFinalize(.init(
            finalizationID: completion.itemID,
            folder: RecordingLibraryURLIdentity.normalized(completion.folderURL),
            workspaceFence: completion.workspaceFence,
            recordingURL: RecordingLibraryURLIdentity.normalized(completion.recordingURL),
            health: completion.health,
            metadataOutcome: completion.metadataWarning.map { .warning($0) } ?? .saved,
            source: completion.source
        ))
        statusMessage = "Recording published: \(completion.health.summary)"
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
        microphoneSwitchGeneration &+= 1
        isMicrophoneSwitchPending = false
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
                guard let self else { return }
                guard !isRecording else { return }
                self.invalidateStorageMonitoring()
                self.invalidateTeamsScreenRefresh()
                self.invalidateTeamsScreenCaptureIntent()
                self.isTeamsScreenCaptureRequested = false
                self.clearTestRecordingRuntimeState()
                self.completeAutomaticStopIntent()
                self.restartTeamsScreenRefreshIfNeeded()
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
