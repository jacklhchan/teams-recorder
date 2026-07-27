import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    @Published private(set) var localMicMuted = false
    @Published private(set) var nativeInputMicMuted = false
    @Published private(set) var teamsMicMuted = false
    @Published private(set) var isScreenCaptureAllowedByStorage = true
    @Published private(set) var screenCaptureStorageRestrictionReason: String?
    @Published private(set) var storageWarningMessage: String?

    let recorder: RecordingEngine
    private lazy var hotKeyManager = GlobalHotKeyManager { [weak self] in
        self?.toggleRecorderMicMute(source: "Hotkey")
    }
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var transcriptionProcess: Process?
    private var transcriptionCancellationRequested = false
    private var asrPrepareProcess: Process?
    private let capturePersistence: CaptureSelectionPersistence
    private let inputDevices: () -> [AudioDevice]
    private let defaultInputDeviceID: () -> AudioDeviceID?
    private let inputMuteController: InputMuteControlling
    private let teamsMuteSyncClient: TeamsMuteSyncing
    private let microphoneMuteGate: MicrophoneMuteGate
    private let teamsMuteRelay: TeamsMuteRelay
    private let virtualMicStateProvider: () -> VirtualMicInstallationState
    private let recordingSessionLoader: @Sendable (URL) -> [RecordingSession]
    private let recordingSessionRecovery: @Sendable (URL) -> Void
    private let permissionRequestHandler: (@MainActor (Bool, Bool) async -> Void)?
    private let volumeCapacityProvider: any VolumeCapacityProviding
    private let storagePolicy: RecordingStoragePolicy
    private let storageMonitorTick: @Sendable () async -> Void
    private let defaults: UserDefaults
    private let recordingSessionLoadingQueue = DispatchQueue(
        label: "local.meeting.recorder.recording-library",
        qos: .userInitiated
    )
    private var cancellables: Set<AnyCancellable> = []
    private var captureLifecycleGate = CaptureLifecycleGate()
    private var captureLifecycleTask: Task<Void, Never>?
    private var inputMuteHandlingInstalled = false
    private var teamsMuteSyncInstalled = false
    private var recordingSessionRefreshGeneration: UInt = 0
    private var recoveredLibraryFolders: Set<URL> = []
    private var storageMonitorTask: Task<Void, Never>?
    private var storageMonitorGeneration: UInt64 = 0
    private var testRecordingStopTask: Task<Void, Never>?

    private static let teamsMuteSyncEnabledKey = "teamsMuteSyncEnabled"

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
        }
    ) {
        let activeRecorder = recorder ?? RecordingEngine()
        self.recorder = activeRecorder
        self.inputDevices = inputDevices
        self.defaultInputDeviceID = defaultInputDeviceID
        self.defaults = defaults
        teamsMuteSyncEnabled = defaults.object(
            forKey: Self.teamsMuteSyncEnabledKey
        ) as? Bool ?? true
        self.virtualMicStateProvider = virtualMicStateProvider
        self.recordingSessionLoader = recordingSessionLoader
        self.recordingSessionRecovery = recordingSessionRecovery
        self.permissionRequestHandler = permissionRequestHandler
        self.volumeCapacityProvider = volumeCapacityProvider
        self.storagePolicy = storagePolicy
        self.storageMonitorTick = storageMonitorTick
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
        observeRecorderConnection()
        observeRecorderRecordingState()
        refreshDevices()
        guard performStartupWork else { return }
        installInputMuteHandling()
        if teamsMuteSyncEnabled {
            installTeamsMuteSync()
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
                availableCaptureApplications = applications
                resolvedCaptureSelection = CaptureConnectionProjection.resolveAfterRefresh(
                    selection: captureSelection,
                    applications: applications,
                    connectionState: captureConnectionState
                )
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

        beginCaptureLifecycle(.start) { [self] token in
            await requestPermissionsFromExplicitAction()
            guard captureLifecycleGate.accepts(token) else { return }
            guard captureReadiness == .ready else {
                statusMessage = readinessMessage
                return
            }
            let recordingFolder = outputFolder
            guard await prepareStorageForNewRecording(in: recordingFolder) else { return }
            guard captureLifecycleGate.accepts(token) else { return }
            guard outputFolder == recordingFolder else {
                statusMessage = "Output folder changed. Start recording again."
                return
            }
            do {
                try await recorder.start(
                    selection: resolvedCaptureSelection,
                    microphoneUID: selectedMicDevice?.uid,
                    baseFolder: recordingFolder
                )
                guard captureLifecycleGate.accepts(token) else { return }
                if !isScreenCaptureAllowedByStorage {
                    await recorder.setScreenCaptureRequested(false)
                    guard captureLifecycleGate.accepts(token), recorder.isRecording else { return }
                }
                statusMessage = "Recording"
                lastHealthReport = nil
                startStorageMonitoring(folder: recordingFolder)
            } catch {
                guard captureLifecycleGate.accepts(token) else { return }
                statusMessage = error.localizedDescription
            }
        }
    }

    func runTestRecording() {
        guard !isRunningTestRecording else { return }
        guard !recorder.isRecording else {
            statusMessage = "Stop the current recording before running a test."
            return
        }

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
                guard captureLifecycleGate.accepts(token) else { return }
                if !isScreenCaptureAllowedByStorage {
                    await recorder.setScreenCaptureRequested(false)
                    guard captureLifecycleGate.accepts(token), recorder.isRecording else { return }
                }
                statusMessage = "Test recording: 10 seconds"
                startStorageMonitoring(folder: recordingFolder)
            } catch {
                guard captureLifecycleGate.accepts(token) else { return }
                isRunningTestRecording = false
                statusMessage = error.localizedDescription
                return
            }
            testRecordingStopTask?.cancel()
            testRecordingStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled,
                      let self,
                      self.isRunningTestRecording else { return }
                self.stopCaptureLifecycle(playAfterStop: true)
            }
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

    func play(session: RecordingSession) {
        do {
            stopPlayback(resetStatus: false)
            let player = try AVAudioPlayer(contentsOf: session.recordingURL)
            audioPlayer = player
            playingSessionID = session.id
            playbackProgress = 0
            playbackDuration = player.duration
            isPlaybackActive = true
            audioPlayer?.play()
            startPlaybackTimer()
            statusMessage = "Playing \(session.displayName)"
        } catch {
            statusMessage = "Playback failed: \(error.localizedDescription)"
        }
    }

    func stopPlayback(resetStatus: Bool = true) {
        audioPlayer?.stop()
        audioPlayer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        playingSessionID = nil
        playbackProgress = 0
        playbackDuration = 0
        isPlaybackActive = false
        if resetStatus {
            statusMessage = recorder.isRecording ? "Recording" : "Monitoring"
        }
    }

    func seekPlayback(to time: TimeInterval) {
        guard let audioPlayer else { return }
        let clamped = max(0, min(time, audioPlayer.duration))
        audioPlayer.currentTime = clamped
        playbackProgress = clamped
        if !audioPlayer.isPlaying {
            audioPlayer.play()
            isPlaybackActive = true
            startPlaybackTimer()
        }
    }

    func open(session: RecordingSession) {
        NSWorkspace.shared.open(session.folderURL)
    }

    func transcribe(session: RecordingSession) {
        guard transcribingSessionID == nil else {
            statusMessage = "A transcription is already running."
            return
        }
        guard asrModelReady else {
            prepareASRModelIfNeeded()
            statusMessage = "oMLX ASR server is still preparing. Wait until it is ready, then transcribe again."
            return
        }

        let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("transcribe-qwen-asr.sh")
            ?? URL(fileURLWithPath: "/Users/apple/Documents/recorder/scripts/transcribe-qwen-asr.sh")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            statusMessage = "Missing transcription launcher: \(scriptURL.path)"
            return
        }

        transcribingSessionID = session.id
        transcriptionCancellationRequested = false
        lastTranscriptionSessionID = session.id
        lastTranscriptionStatus = "Preparing transcription"
        lastTranscriptionDidFail = false
        transcriptionStatus = "Preparing transcription"
        statusMessage = "Preparing transcription"
        updateTranscriptionState(
            .init(phase: .queued, message: transcriptionStatus, startedAt: Date()),
            for: session
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, session.recordingURL.path, session.folderURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        transcriptionProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.handleTranscriptionOutput(text, session: session)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.transcriptionProcess = nil
                self?.transcribingSessionID = nil
                if self?.transcriptionCancellationRequested == true {
                    self?.transcriptionStatus = "Transcription cancelled"
                    self?.lastTranscriptionStatus = "Transcription cancelled"
                    self?.lastTranscriptionDidFail = false
                    self?.updateTranscriptionState(
                        .init(phase: .cancelled, message: "Transcription cancelled", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
                    self?.statusMessage = "Transcription cancelled"
                } else if process.terminationStatus == 0 {
                    self?.transcriptionStatus = "Transcription complete"
                    self?.lastTranscriptionStatus = "Transcription complete"
                    self?.lastTranscriptionDidFail = false
                    self?.updateTranscriptionState(
                        .init(phase: .completed, message: "Transcription complete", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
                    self?.statusMessage = "Transcription complete"
                } else {
                    self?.transcriptionStatus = "Transcription failed"
                    self?.lastTranscriptionStatus = "Transcription failed with exit code \(process.terminationStatus). Open the ASR log for details."
                    self?.lastTranscriptionDidFail = true
                    self?.updateTranscriptionState(
                        .init(phase: .failed, message: self?.lastTranscriptionStatus ?? "Transcription failed", startedAt: self?.transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                        for: session
                    )
                    self?.statusMessage = "Transcription failed with exit code \(process.terminationStatus). Open the ASR log for details."
                }
            }
        }

        do {
            try process.run()
        } catch {
            transcribingSessionID = nil
            transcriptionProcess = nil
            transcriptionStatus = "Transcription launch failed"
            statusMessage = "Transcription launch failed: \(error.localizedDescription)"
            updateTranscriptionState(
                .init(phase: .failed, message: statusMessage, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
                for: session
            )
        }
    }

    func cancelTranscription() {
        guard let process = transcriptionProcess, let sessionID = transcribingSessionID,
              let session = sessions.first(where: { $0.id == sessionID }) else { return }
        transcriptionCancellationRequested = true
        process.terminate()
        transcriptionStatus = "Cancelling transcription..."
        lastTranscriptionStatus = transcriptionStatus
        updateTranscriptionState(
            .init(phase: .cancelled, message: transcriptionStatus, startedAt: transcriptionStatesBySessionID[session.id]?.startedAt ?? Date(), finishedAt: Date()),
            for: session
        )
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

    func installTeamsMuteSync() {
        guard teamsMuteSyncEnabled, !teamsMuteSyncInstalled else { return }

        teamsMuteSyncInstalled = true
        let generation = teamsMuteRelay.enable()
        let relay = teamsMuteRelay
        teamsMuteSyncClient.start { [weak self, relay] event in
            guard let relayResult = relay.apply(
                event,
                generation: generation
            ) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleTeamsMuteSync(
                    event,
                    relayResult: relayResult,
                    generation: generation
                )
            }
        }
    }

    func setTeamsMuteSyncEnabled(_ enabled: Bool) {
        guard teamsMuteSyncEnabled != enabled else { return }

        teamsMuteSyncEnabled = enabled
        defaults.set(enabled, forKey: Self.teamsMuteSyncEnabledKey)
        if enabled {
            installTeamsMuteSync()
            return
        }

        let snapshot = teamsMuteRelay.disable()
        teamsMuteSyncClient.stop()
        teamsMuteSyncInstalled = false
        teamsMuteSyncStatus = .disabled
        publishMicrophoneMuteSnapshot(snapshot)
    }

    func retryTeamsMuteSync() {
        guard teamsMuteSyncEnabled else { return }
        teamsMuteSyncClient.reconnect()
    }

    func requestTeamsPairing() {
        guard teamsMuteSyncEnabled else { return }
        teamsMuteSyncClient.requestPairing()
    }

    private func handleTeamsMuteSync(
        _ event: TeamsMuteSyncEvent,
        relayResult: TeamsMuteRelayResult,
        generation: UInt64
    ) {
        guard teamsMuteSyncEnabled, teamsMuteRelay.isCurrent(generation) else {
            return
        }

        switch event {
        case .status(let status):
            teamsMuteSyncStatus = status
            if relayResult.didFailClosed {
                publishMicrophoneMuteSnapshot(microphoneMuteGate.snapshot)
                statusMessage = "Teams sync lost: recorder mic muted"
            }

        case .meetingState:
            let snapshot = microphoneMuteGate.snapshot
            publishMicrophoneMuteSnapshot(snapshot)
            statusMessage = "Teams / AirPods: recorder mic \(snapshot.effectiveMuted ? "muted" : "active")"
        }
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

    private func finishRecording(playAfterStop: Bool) async {
        guard let result = await recorder.stop() else {
            statusMessage = "No active recording."
            return
        }
        isRunningTestRecording = false
        lastHealthReport = result.health
        refreshSessions()
        statusMessage = "Recording saved: \(result.health.summary)"

        if playAfterStop {
            isRunningTestRecording = false
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: result.recordingURL)
                playingSessionID = nil
                playbackProgress = 0
                playbackDuration = audioPlayer?.duration ?? 0
                isPlaybackActive = true
                audioPlayer?.play()
                startPlaybackTimer()
                statusMessage = "Test saved and playing: \(result.health.summary)"
            } catch {
                statusMessage = "Test saved, playback failed: \(error.localizedDescription)"
            }
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let audioPlayer = self.audioPlayer else { return }
                self.playbackProgress = audioPlayer.currentTime
                self.playbackDuration = audioPlayer.duration
                if !audioPlayer.isPlaying {
                    self.playbackTimer?.invalidate()
                    self.playbackTimer = nil
                    self.isPlaybackActive = false
                }
            }
        }
    }

    private func handleTranscriptionOutput(_ text: String, session: RecordingSession) {
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

    private func stopCaptureLifecycle(playAfterStop: Bool) {
        guard let token = captureLifecycleGate.cancelAndBeginStop() else {
            return
        }
        invalidateStorageMonitoring()
        testRecordingStopTask?.cancel()
        testRecordingStopTask = nil
        captureLifecycleTask?.cancel()
        isCaptureLifecycleWorking = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finishRecording(playAfterStop: playAfterStop)
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
                } else if state == .connected {
                    self.resolvedCaptureSelection = CaptureSelectionResolver.resolve(
                        selection: self.captureSelection,
                        availableApplications: self.availableCaptureApplications
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func observeRecorderRecordingState() {
        recorder.$isRecording
            .dropFirst()
            .sink { [weak self] isRecording in
                guard let self, !isRecording else { return }
                self.invalidateStorageMonitoring()
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
