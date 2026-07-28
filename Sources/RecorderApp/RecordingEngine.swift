import CoreVideo
import Foundation

typealias RecordingMediaCoordinatorFactory = (
    RecordingOutputURLs,
    UUID,
    UInt64,
    CaptureFilterRevision,
    OSType
) throws -> RecordingMediaCoordinating
typealias RecordingMetadataWriter = (RecordingSessionMetadata, URL) throws -> Void

protocol CaptureSourceProtocol: AnyObject {
    var screenVideoFormat: ScreenVideoFormat { get }
    func refreshContent() async throws -> [CaptureApplication]
    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot]
    func reconnect(selection: ResolvedCaptureSelection) async throws
    func updateVideoTarget(_ target: TeamsWindowIdentity?) async throws -> CaptureFilterRevision
    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onVideo: @escaping (ScreenVideoFrame) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws
    func stop() async
}

extension ScreenCaptureSource: CaptureSourceProtocol {}

struct RecordingContinuitySnapshot: Equatable {
    let sourceSessionID: UUID?
    let recordingEpoch: UInt64?
    let recordingURL: URL?
    let outputFolder: URL?
    let startedAt: Date?
    let microphoneUID: String?
}

struct CaptureConnectionSnapshot: Equatable {
    let sourceSessionID: UUID?
    let activeSelection: ResolvedCaptureSelection?
    let isMonitoring: Bool
    let isSystemCaptureConnected: Bool

    static let idle = CaptureConnectionSnapshot(
        sourceSessionID: nil,
        activeSelection: nil,
        isMonitoring: false,
        isSystemCaptureConnected: true
    )
}

@MainActor
final class RecordingEngine: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var outputFolder: URL?
    @Published private(set) var systemLevel = LevelSnapshot()
    @Published private(set) var micLevel = LevelSnapshot()
    @Published private(set) var micMuted = false
    @Published private(set) var isSystemCaptureConnected = true
    @Published private(set) var isMicrophoneCaptureConnected = true
    @Published private(set) var captureStatus: CaptureStatus?
    @Published private(set) var captureConnectionSnapshot: CaptureConnectionSnapshot = .idle
    @Published private(set) var virtualMicPublisherState: VirtualMicPublisherState = .stopped
    @Published private(set) var meetingScreenCaptureState: MeetingScreenCaptureState = .unavailable
    @Published private(set) var teamsWindowCandidates: [TeamsWindowDescriptor] = []

    private let captureSource: CaptureSourceProtocol
    private let coordinatorFactory: RecordingMediaCoordinatorFactory
    private let metadataWriter: RecordingMetadataWriter
    private let mixerBlockFrames: Int
    private let callbackGate = RecordingCallbackGate()
    nonisolated private let microphoneAudioPaths: MicrophoneAudioPaths
    nonisolated private let videoIngress = VideoIngress()

    private var mixer: TimestampedAudioMixer
    private var mediaCoordinator: RecordingMediaCoordinating?
    private var sourceSessionID: UUID?
    private var recordingEpoch: UInt64?
    private var nextRecordingEpoch: UInt64 = 0
    private var activeSelection: ResolvedCaptureSelection?
    private var activeMicrophoneUID: String?
    private var isStopping = false
    private var currentRecordingURL: URL?
    private var currentHealth = RecordingHealthReport()
    private var latestSystemLevel = LevelSnapshot()
    private var latestMicLevel = LevelSnapshot()
    private var rollingSystemSamples = Array(repeating: Float(0), count: 160)
    private var rollingMicSamples = Array(repeating: Float(0), count: 160)
    private var meterTimer: Timer?
    private var latestObservedSourceEndFrame: Int64?
    private var previousMixedSourceEndFrame: Int64?
    private var writerBoundaryDiscontinuities = 0
    private var observedMixerLateFrames = 0
    private var monitoringTransition: MonitoringTransition?
    private var recordingStartTransition: RecordingStartTransition?
    private var reconnectTransition: ReconnectTransition?
    private var teamsWindowResolver = TeamsMeetingWindowResolver()
    private var teamsSourceProcessID: pid_t?
    private var teamsMeetingActive = false
    private var teamsManualWindowOverride: TeamsWindowIdentity?
    private var screenCaptureRequested = false
    private var screenTarget: TeamsWindowDescriptor?
    private(set) var resolvedTeamsManualWindowIdentity: TeamsWindowIdentity?
    private var activeFilterRevision = CaptureFilterRevision(sessionGeneration: 0, revision: 0)
    private var activeScreenFilterRevision: CaptureFilterRevision?
    private var screenToggleGeneration: UInt64 = 0
    private var hasHardScreenFailure = false
    private var hasCountedMuxFallback = false

    init(
        captureSource: CaptureSourceProtocol = ScreenCaptureSource(),
        writerFactory: MixedAudioWriterFactory? = nil,
        coordinatorFactory: RecordingMediaCoordinatorFactory? = nil,
        metadataWriter: @escaping RecordingMetadataWriter = { metadata, folder in
            try RecordingSessionMetadataStore.save(metadata, in: folder)
        },
        mixerBlockFrames: Int = 960,
        virtualMicPublisher: VirtualMicPublishing = VirtualMicPublisher()
    ) {
        self.captureSource = captureSource
        self.metadataWriter = metadataWriter
        if let coordinatorFactory {
            self.coordinatorFactory = coordinatorFactory
        } else if let writerFactory {
            // Compatibility injection retained for the pre-media-pipeline test seam.
            self.coordinatorFactory = { outputs, _, _, _, _ in
                try LegacyMediaCoordinator(writer: writerFactory(outputs.recoveredM4A), outputs: outputs)
            }
        } else {
            self.coordinatorFactory = { outputs, sourceSessionID, epoch, revision, pixelFormat in
                try RecordingMediaCoordinator(
                    outputs: outputs,
                    sourceSessionID: sourceSessionID,
                    recordingEpoch: epoch,
                    activeFilterRevision: revision,
                    pixelFormat: pixelFormat
                )
            }
        }
        self.mixerBlockFrames = mixerBlockFrames
        microphoneAudioPaths = MicrophoneAudioPaths(publisher: virtualMicPublisher)
        self.mixer = try! TimestampedAudioMixer(
            sampleRate: 48_000,
            blockFrames: mixerBlockFrames
        )
    }

    var continuitySnapshot: RecordingContinuitySnapshot {
        RecordingContinuitySnapshot(
            sourceSessionID: sourceSessionID,
            recordingEpoch: recordingEpoch,
            recordingURL: currentRecordingURL,
            outputFolder: outputFolder,
            startedAt: startedAt,
            microphoneUID: activeMicrophoneUID
        )
    }

    func startMonitoring(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?
    ) async throws {
        let request = MonitoringRequest(
            selection: selection,
            microphoneUID: microphoneUID
        )

        while true {
            if isMonitoring,
               activeSelection == selection,
               activeMicrophoneUID == microphoneUID,
               monitoringTransition == nil {
                return
            }
            guard !isRecording else { return }

            if let transition = monitoringTransition {
                let isSameRequest = transition.request == request
                do {
                    try await transition.task.value
                    clearMonitoringTransition(id: transition.id)
                    if isSameRequest { return }
                } catch {
                    clearMonitoringTransition(id: transition.id)
                    if isSameRequest { throw error }
                }
                continue
            }

            let transitionID = UUID()
            let task = Task { @MainActor in
                try await self.performStartMonitoring(request)
            }
            monitoringTransition = MonitoringTransition(
                id: transitionID,
                request: request,
                task: task
            )
            do {
                try await task.value
                clearMonitoringTransition(id: transitionID)
                return
            } catch {
                clearMonitoringTransition(id: transitionID)
                throw error
            }
        }
    }

    private func performStartMonitoring(_ request: MonitoringRequest) async throws {
        if isMonitoring,
           activeSelection == request.selection,
           activeMicrophoneUID == request.microphoneUID {
            return
        }
        guard !isRecording else { return }

        await stopActiveSourceSession()
        resetMonitoringState()

        let sessionID = UUID()
        callbackGate.activate(sessionID: sessionID, recordingEpoch: nil)
        sourceSessionID = sessionID
        activeSelection = request.selection
        activeMicrophoneUID = request.microphoneUID
        virtualMicPublisherState = microphoneAudioPaths.start()

        do {
            try await captureSource.start(
                selection: request.selection,
                microphoneUID: request.microphoneUID,
                onAudio: { [weak self, callbackGate] block in
                    guard let ticket = callbackGate.begin(sessionID: sessionID) else { return }
                    Task { @MainActor [weak self, callbackGate] in
                        defer { callbackGate.finish(ticket) }
                        self?.receive(block, ticket: ticket)
                    }
                },
                onVideo: { [callbackGate, videoIngress] frame in
                    guard let ticket = callbackGate.begin(sessionID: sessionID) else { return }
                    defer { callbackGate.finish(ticket) }
                    videoIngress.enqueue(frame, ticket: ticket)
                },
                onEvent: { [weak self, callbackGate] event in
                    guard let ticket = callbackGate.begin(sessionID: sessionID) else { return }
                    Task { @MainActor [weak self, callbackGate] in
                        defer { callbackGate.finish(ticket) }
                        self?.receive(event, ticket: ticket)
                    }
                }
            )
            guard sourceSessionID == sessionID,
                  callbackGate.isActive(sessionID: sessionID) else {
                throw RecordingEngineError.captureStartFailed(
                    "Capture session stopped during startup."
                )
            }
            isMonitoring = true
            publishConnectionSnapshot()
            startMeterTimer()
        } catch {
            let shouldApplyFailure = sourceSessionID == sessionID
                && callbackGate.isActive(sessionID: sessionID)
            await captureSource.stop()
            callbackGate.deactivate(sessionID: sessionID)
            await callbackGate.waitForIdle(sessionID: sessionID)
            virtualMicPublisherState = microphoneAudioPaths.stop()
            clearSourceSession(sessionID: sessionID)
            if shouldApplyFailure {
                applyStartFailure(error)
            }
            if let engineError = error as? RecordingEngineError {
                throw engineError
            }
            throw RecordingEngineError.captureStartFailed(error.localizedDescription)
        }
    }

    func stopMonitoring() async {
        guard !isRecording else { return }
        await stopActiveSourceSession()
        resetMonitoringState()
    }

    func refreshCaptureApplications() async throws -> [CaptureApplication] {
        try await captureSource.refreshContent()
    }

    func reconnect(selection: ResolvedCaptureSelection) async throws {
        guard isMonitoring,
              let sourceSessionID,
              !isSystemCaptureConnected,
              case let .application(targetApplication) = selection,
              case let .application(activeApplication) = activeSelection,
              targetApplication.bundleIdentifier == activeApplication.bundleIdentifier else {
            throw CaptureSourceError.selectedApplicationUnavailable
        }
        let request = ReconnectRequest(
            sourceSessionID: sourceSessionID,
            application: targetApplication
        )

        if let transition = reconnectTransition {
            guard transition.request == request else {
                throw CaptureSourceError.selectedApplicationUnavailable
            }
            return try await transition.task.value
        }

        let transitionID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CaptureSourceError.streamStartCancelled }
            try await self.captureSource.reconnect(selection: selection)
            guard self.sourceSessionID == sourceSessionID,
                  self.callbackGate.isActive(sessionID: sourceSessionID),
                  self.isMonitoring,
                  !self.isStopping else {
                throw CaptureSourceError.streamStartCancelled
            }
            self.activeSelection = selection
            self.isSystemCaptureConnected = true
            self.mixer.setSystemSourceConnected(true)
            self.captureStatus = nil
            self.publishConnectionSnapshot()
        }
        reconnectTransition = ReconnectTransition(
            id: transitionID,
            request: request,
            task: task
        )

        do {
            try await task.value
            clearReconnectTransition(id: transitionID)
        } catch {
            clearReconnectTransition(id: transitionID)
            if self.sourceSessionID == sourceSessionID {
                disconnectSystemCapture()
            }
            throw error
        }
    }

    @discardableResult
    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        baseFolder: URL,
        folderPrefix: String = "meeting"
    ) async throws -> URL {
        if isRecording {
            return outputFolder ?? baseFolder
        }

        if let transition = recordingStartTransition {
            return try await transition.task.value
        }

        let transitionID = UUID()
        let task = Task { @MainActor in
            try await self.performRecordingStart(
                selection: selection,
                microphoneUID: microphoneUID,
                baseFolder: baseFolder,
                folderPrefix: folderPrefix
            )
        }
        recordingStartTransition = RecordingStartTransition(
            id: transitionID,
            task: task
        )
        do {
            let folder = try await task.value
            clearRecordingStartTransition(id: transitionID)
            return folder
        } catch {
            clearRecordingStartTransition(id: transitionID)
            throw error
        }
    }

    private func performRecordingStart(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        baseFolder: URL,
        folderPrefix: String
    ) async throws -> URL {
        if isRecording {
            return outputFolder ?? baseFolder
        }

        try await startMonitoring(selection: selection, microphoneUID: microphoneUID)
        if isRecording {
            return outputFolder ?? baseFolder
        }
        guard let sourceSessionID else {
            throw RecordingEngineError.captureStartFailed("Capture session did not start.")
        }

        let folder = baseFolder.appendingPathComponent(
            "\(folderPrefix)-\(Self.folderStamp.string(from: Date()))",
            isDirectory: true
        )
        let folderExistedBeforeStart = FileManager.default.fileExists(
            atPath: folder.path
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            await rollbackFailedStart(
                folder: folder,
                removeFolderIfEmpty: false
            )
            throw RecordingEngineError.cannotCreateFolder
        }
        let createdFolder = !folderExistedBeforeStart

        let outputs = RecordingOutputURLs(folder: folder)
        nextRecordingEpoch &+= 1
        let epoch = nextRecordingEpoch
        do {
            let coordinator = try coordinatorFactory(
                outputs,
                sourceSessionID,
                epoch,
                activeFilterRevision,
                captureSource.screenVideoFormat.pixelFormat
            )
            coordinator.setVideoEventHandler { [weak self] event in
                Task { @MainActor [weak self] in self?.receive(videoEvent: event) }
            }
            mediaCoordinator = coordinator
        } catch {
            await rollbackFailedStart(
                folder: folder,
                removeFolderIfEmpty: createdFolder
            )
            throw RecordingEngineError.writerFailed(error.localizedDescription)
        }

        recordingEpoch = epoch
        callbackGate.setRecordingEpoch(recordingEpoch, for: sourceSessionID)
        mixer = makeMixer()
        currentHealth = RecordingHealthReport(startedAt: Date())
        latestObservedSourceEndFrame = nil
        previousMixedSourceEndFrame = nil
        writerBoundaryDiscontinuities = 0
        observedMixerLateFrames = 0
        currentRecordingURL = outputs.finalMP4
        outputFolder = folder
        startedAt = Date()
        isRecording = true
        isStopping = false
        screenCaptureRequested = false
        screenTarget = nil
        meetingScreenCaptureState = .off
        hasHardScreenFailure = false
        hasCountedMuxFallback = false
        videoIngress.activate(sessionID: sourceSessionID, epoch: epoch, coordinator: mediaCoordinator)
        return folder
    }

    func stop() async -> RecordingResult? {
        guard isRecording, !isStopping,
              let activeEpoch = recordingEpoch else {
            return nil
        }
        isStopping = true
        screenToggleGeneration &+= 1
        let recordingFolder = outputFolder
        let sourceSessionID = sourceSessionID

        if let sourceSessionID {
            await captureSource.stop()
            callbackGate.deactivate(sessionID: sourceSessionID)
            await callbackGate.waitForIdle(sessionID: sourceSessionID)
        }
        currentHealth.videoInvalidTimestamps += videoIngress.takeInvalidTimestampCount(
            sessionID: sourceSessionID,
            epoch: activeEpoch
        )
        videoIngress.deactivate()
        virtualMicPublisherState = microphoneAudioPaths.stop()

        guard recordingEpoch == activeEpoch else {
            return nil
        }

        if let latestObservedSourceEndFrame {
            write(mixer.flushThrough(frame: latestObservedSourceEndFrame))
        }
        reconcileMixerHealth()

        let coordinator = mediaCoordinator
        var outcome: RecordingMediaOutcome?
        do {
            outcome = try await coordinator?.finish()
        } catch {
            currentHealth.streamFailures += 1
            captureStatus = .error("Recording file could not be finalized")
        }
        coordinator?.setVideoEventHandler(nil)
        mediaCoordinator = nil

        currentHealth.endedAt = Date()
        if let outcome {
            currentHealth.videoDroppedFrames = max(
                currentHealth.videoDroppedFrames,
                outcome.videoDroppedFrames
            )
            if let warning = outcome.videoFailureDescription {
                recordMuxFallbackIfNeeded()
                captureStatus = .warning(warning)
            }
            if let recordingFolder {
                do {
                    try metadataWriter(
                        RecordingSessionMetadata(
                            mediaKind: outcome.mediaKind,
                            screenIntervals: outcome.screenIntervals,
                            capturedTeamsWindow: outcome.capturedWindow,
                            recoveryState: outcome.recoveryState
                        ),
                        recordingFolder
                    )
                } catch {
                    currentHealth.metadataWriteFailures += 1
                    captureStatus = .warning("Recording saved, but metadata could not be written")
                }
            }
        }
        let result = recordingFolder.flatMap { folder in
            outcome.map {
                RecordingResult(
                    folderURL: folder,
                    recordingURL: $0.finalURL,
                    health: currentHealth,
                    mediaKind: $0.mediaKind,
                    screenIntervals: $0.screenIntervals,
                    capturedWindow: $0.capturedWindow,
                    recoveryState: $0.recoveryState,
                    warning: currentHealth.metadataWriteFailures > 0
                        ? "Recording saved, but metadata could not be written"
                        : $0.safetyCleanupDiagnostic ?? $0.videoFailureDescription
                )
            }
        }
        recordingEpoch = nil
        currentRecordingURL = nil
        startedAt = nil
        isRecording = false
        isStopping = false
        screenCaptureRequested = false
        screenTarget = nil
        meetingScreenCaptureState = .off
        if let sourceSessionID {
            clearSourceSession(sessionID: sourceSessionID)
        }
        resetMonitoringState()
        return result
    }

    func refreshTeamsWindows(
        selectedTeamsProcessID: pid_t,
        meetingActive: Bool,
        manualOverride: TeamsWindowIdentity?
    ) async {
        screenToggleGeneration &+= 1
        let generation = screenToggleGeneration
        let previousManualOverride = teamsManualWindowOverride
        teamsSourceProcessID = selectedTeamsProcessID
        teamsMeetingActive = meetingActive
        teamsManualWindowOverride = manualOverride
        if manualOverride == nil || manualOverride != previousManualOverride {
            resolvedTeamsManualWindowIdentity = nil
        }
        teamsWindowResolver.selectManualOverride(manualOverride)
        do {
            let windows = try await captureSource.refreshTeamsWindows().filter {
                $0.identity.processID == selectedTeamsProcessID
            }
            guard generation == screenToggleGeneration else { return }
            let now = Date()
            teamsWindowCandidates = windows.compactMap { window in
                guard window.isOnScreen,
                      window.layer == 0,
                      TeamsMeetingWindowResolver.rejectionReasons(for: window).isEmpty else { return nil }
                return TeamsWindowDescriptor(
                    identity: window.identity, title: window.title, frame: window.frame,
                    isOnScreen: window.isOnScreen, layer: window.layer,
                    firstSeenAt: now, lastSurfacedAt: window.isOnScreen ? now : nil
                )
            }
            let previousState = meetingScreenCaptureState
            let previousTarget = screenTarget
            switch teamsWindowResolver.observe(windows, meetingActive: meetingActive, now: now) {
            case let .ready(match):
                if manualOverride != nil {
                    teamsManualWindowOverride = match.window.identity
                    resolvedTeamsManualWindowIdentity = match.window.identity
                }
                screenTarget = match.window
                if screenCaptureRequested {
                    await applyScreenTarget(
                        match.window,
                        generation: generation,
                        previousState: previousState
                    )
                } else {
                    meetingScreenCaptureState = .ready(match.window)
                }
            case let .ambiguous(descriptors):
                screenTarget = nil
                meetingScreenCaptureState = .waiting(descriptors)
                if screenCaptureRequested {
                    await applyWaitingScreenTarget(generation: generation)
                }
            case .waiting:
                screenTarget = nil
                let previousLostTarget: TeamsWindowDescriptor?
                if case let .targetLost(target) = previousState {
                    previousLostTarget = target
                } else {
                    previousLostTarget = nil
                }
                if screenCaptureRequested,
                   previousTarget != nil || previousLostTarget != nil {
                    meetingScreenCaptureState = .targetLost(previousLostTarget ?? previousTarget)
                } else {
                    meetingScreenCaptureState = .waiting([])
                }
                if screenCaptureRequested {
                    await applyWaitingScreenTarget(generation: generation)
                }
            }
        } catch {
            guard generation == screenToggleGeneration else { return }
            meetingScreenCaptureState = .failed(error.localizedDescription)
            currentHealth.videoFilterFailures += 1
        }
    }

    func resetTeamsWindowResolution() {
        screenToggleGeneration &+= 1
        teamsWindowResolver.resetForApplicationRestart()
        teamsSourceProcessID = nil
        teamsMeetingActive = false
        teamsManualWindowOverride = nil
        resolvedTeamsManualWindowIdentity = nil
        teamsWindowCandidates = []
        screenTarget = nil
        activeScreenFilterRevision = nil
        if !isRecording {
            meetingScreenCaptureState = .off
        }
    }

    func setScreenCaptureRequested(_ requested: Bool) async {
        guard isRecording, let coordinator = mediaCoordinator else { return }
        screenToggleGeneration &+= 1
        let generation = screenToggleGeneration
        screenCaptureRequested = requested
        if !requested {
            coordinator.setScreenCaptureRequested(false, expectedRevision: nil, window: nil)
            do {
                let revision = try await captureSource.updateVideoTarget(nil)
                guard generation == screenToggleGeneration else { return }
                activeFilterRevision = revision
                activeScreenFilterRevision = nil
                screenTarget = nil
                meetingScreenCaptureState = .off
            } catch {
                guard generation == screenToggleGeneration else { return }
                meetingScreenCaptureState = .failed(error.localizedDescription)
                currentHealth.videoFilterFailures += 1
            }
            return
        }

        if let screenTarget {
            await applyScreenTarget(screenTarget, generation: generation)
        } else {
            guard let teamsSourceProcessID else {
                meetingScreenCaptureState = .waiting([])
                await applyWaitingScreenTarget(generation: generation)
                return
            }
            await refreshTeamsWindows(
                selectedTeamsProcessID: teamsSourceProcessID,
                meetingActive: teamsMeetingActive,
                manualOverride: teamsManualWindowOverride
            )
        }
    }

    private func applyScreenTarget(
        _ target: TeamsWindowDescriptor,
        generation: UInt64,
        previousState: MeetingScreenCaptureState? = nil
    ) async {
        guard let coordinator = mediaCoordinator,
              isRecording,
              !isStopping else { return }
        do {
            let previousRevision = activeFilterRevision
            let revision = try await captureSource.updateVideoTarget(target.identity)
            guard generation == screenToggleGeneration,
                  screenCaptureRequested,
                  isRecording,
                  !isStopping else { return }
            activeFilterRevision = revision
            activeScreenFilterRevision = revision
            coordinator.setScreenCaptureRequested(
                true,
                expectedRevision: revision,
                window: RecordedTeamsWindowIdentity(
                    processID: target.identity.processID,
                    windowID: target.identity.windowID,
                    title: target.title
                )
            )
            if revision == previousRevision {
                switch previousState {
                case let .frameUnavailable(previousTarget)
                    where previousTarget.identity == target.identity:
                    meetingScreenCaptureState = .frameUnavailable(target)
                case let .capturing(previousTarget)
                    where previousTarget.identity == target.identity:
                    meetingScreenCaptureState = .capturing(target)
                case let .awaitingFrames(previousTarget)
                    where previousTarget.identity == target.identity:
                    meetingScreenCaptureState = .awaitingFrames(target)
                default:
                    meetingScreenCaptureState = .awaitingFrames(target)
                }
            } else {
                meetingScreenCaptureState = .awaitingFrames(target)
            }
        } catch {
            guard generation == screenToggleGeneration else { return }
            meetingScreenCaptureState = .failed(error.localizedDescription)
            currentHealth.videoFilterFailures += 1
        }
    }

    private func applyWaitingScreenTarget(generation: UInt64) async {
        guard let coordinator = mediaCoordinator,
              isRecording,
              !isStopping else { return }
        activeScreenFilterRevision = nil
        do {
            let revision = try await captureSource.updateVideoTarget(nil)
            guard generation == screenToggleGeneration,
                  screenCaptureRequested,
                  isRecording,
                  !isStopping else { return }
            activeFilterRevision = revision
            coordinator.setScreenCaptureRequested(true, expectedRevision: nil, window: nil)
        } catch {
            guard generation == screenToggleGeneration else { return }
            meetingScreenCaptureState = .failed(error.localizedDescription)
            currentHealth.videoFilterFailures += 1
        }
    }

    func toggleMicMute() {
        let muted = !micMuted
        applyInputMuteToAudioPaths(muted)
        updateMicMuteDisplay(muted)
    }

    nonisolated func applyInputMuteToAudioPaths(_ muted: Bool) {
        _ = microphoneAudioPaths.setMuted(muted)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.virtualMicPublisherState = self.microphoneAudioPaths.currentPublisherState()
        }
    }

    func updateMicMuteDisplay(_ muted: Bool) {
        micMuted = muted
    }

    private func receive(_ block: AudioFrameBlock, ticket: RecordingCallbackTicket) {
        guard ticket.sourceSessionID == sourceSessionID else { return }

        let snapshot = Self.levelSnapshot(for: block)
        microphoneAudioPaths.withLockedState { muted, publisher in
            switch block.source {
            case .system:
                latestSystemLevel = snapshot
            case .microphone:
                latestMicLevel = snapshot
                publisher.publishMicrophone(left: block.left, right: block.right)
                virtualMicPublisherState = publisher.state
            }

            guard let activeEpoch = recordingEpoch,
                  ticket.recordingEpoch == activeEpoch,
                  mediaCoordinator != nil else {
                return
            }

            updateHealth(with: snapshot, source: block.source, microphoneMuted: muted)
            mixer.isMicrophoneMuted = muted
            latestObservedSourceEndFrame = max(
                latestObservedSourceEndFrame ?? block.startFrame,
                block.startFrame + Int64(block.frameCount)
            )
            write(mixer.push(block))
            reconcileMixerHealth()
        }
    }

    private func receive(_ event: CaptureEvent, ticket: RecordingCallbackTicket) {
        guard ticket.sourceSessionID == sourceSessionID else { return }
        switch event {
        case let .screenTargetLost(revision), let .screenFrameUnavailable(revision):
            guard isRecording,
                  ticket.recordingEpoch == recordingEpoch,
                  screenCaptureRequested,
                  activeScreenFilterRevision == revision else {
                return
            }
        default:
            break
        }
        captureStatus = CaptureStatusMapper.status(for: event)

        switch event {
        case .applicationDisconnected, .selectedApplicationRequiresReconnect,
             .screenRecordingPermissionDenied, .systemAudioCaptureFailed:
            disconnectSystemCapture()
        case .microphonePermissionDenied, .microphoneUnavailable,
             .microphoneDisconnected, .microphoneCaptureFailed:
            disconnectMicrophoneCapture()
        case .invalidSampleBuffer, .conversionFailed:
            if isRecording, ticket.recordingEpoch == recordingEpoch {
                currentHealth.conversionFailures += 1
                currentHealth.droppedBuffers += 1
            }
        case .streamStoppedByUser, .streamStoppedBySystem, .streamFailed,
             .missingCaptureEntitlements:
            if isRecording, ticket.recordingEpoch == recordingEpoch {
                currentHealth.streamFailures += 1
                Task { @MainActor [weak self] in _ = await self?.stop() }
                return
            }
            terminateSourceSession(sessionID: ticket.sourceSessionID)
        case .microphoneSilence:
            break
        case let .screenTargetLost(revision):
            if isRecording,
               ticket.recordingEpoch == recordingEpoch,
               screenCaptureRequested,
               activeFilterRevision == revision {
                mediaCoordinator?.markScreenSourceUnavailable()
                meetingScreenCaptureState = .targetLost(screenTarget)
            }
        case let .screenFrameUnavailable(revision):
            if isRecording,
               ticket.recordingEpoch == recordingEpoch,
               screenCaptureRequested,
               activeFilterRevision == revision {
                mediaCoordinator?.markScreenSourceUnavailable()
                if let screenTarget {
                    meetingScreenCaptureState = .frameUnavailable(screenTarget)
                } else {
                    meetingScreenCaptureState = .waiting([])
                }
            }
        case .screenCaptureFailed:
            if isRecording, ticket.recordingEpoch == recordingEpoch {
                mediaCoordinator?.markScreenSourceUnavailable()
                currentHealth.videoFilterFailures += 1
                hasHardScreenFailure = true
                meetingScreenCaptureState = .failed("Screen frame capture unavailable")
            }
            break
        }
    }

    private func receive(videoEvent: RecordingVideoEvent) {
        guard videoEvent.sourceSessionID == sourceSessionID,
              videoEvent.recordingEpoch == recordingEpoch,
              isRecording else { return }
        switch videoEvent.kind {
        case .sourceStalled, .sourceRecovered:
            guard screenCaptureRequested,
                  let revision = videoEvent.filterRevision,
                  revision == activeScreenFilterRevision,
                  videoEvent.acceptedFrameRevision == nil
                    || videoEvent.acceptedFrameRevision == revision else {
                return
            }
        case .droppedFrames, .muxFailed:
            break
        }
        switch videoEvent.kind {
        case .sourceStalled:
            currentHealth.videoStallEvents += 1
            if !hasHardScreenFailure, let screenTarget {
                meetingScreenCaptureState = .frameUnavailable(screenTarget)
            }
        case .sourceRecovered:
            if !hasHardScreenFailure, let screenTarget {
                meetingScreenCaptureState = .capturing(screenTarget)
            }
        case let .droppedFrames(count):
            currentHealth.videoDroppedFrames = max(currentHealth.videoDroppedFrames, count)
        case let .muxFailed(description):
            hasHardScreenFailure = true
            recordMuxFallbackIfNeeded()
            meetingScreenCaptureState = .failed(description)
        }
    }

    private func recordMuxFallbackIfNeeded() {
        guard !hasCountedMuxFallback else { return }
        hasCountedMuxFallback = true
        currentHealth.muxFallbackEvents += 1
    }

    private func disconnectSystemCapture(publishSnapshot: Bool = true) {
        guard isSystemCaptureConnected else { return }
        isSystemCaptureConnected = false
        mixer.setSystemSourceConnected(false)
        if isRecording { currentHealth.systemDisconnects += 1 }
        if publishSnapshot {
            publishConnectionSnapshot()
        }
    }

    private func disconnectMicrophoneCapture() {
        guard isMicrophoneCaptureConnected else { return }
        isMicrophoneCaptureConnected = false
        mixer.setMicrophoneSourceConnected(false)
        virtualMicPublisherState = microphoneAudioPaths.stop()
        if isRecording { currentHealth.microphoneDisconnects += 1 }
    }

    private func updateHealth(
        with snapshot: LevelSnapshot,
        source: AudioSourceKind,
        microphoneMuted: Bool
    ) {
        switch source {
        case .system:
            currentHealth.systemSignalSeen = currentHealth.systemSignalSeen || snapshot.rms > -55
        case .microphone:
            currentHealth.micSignalSeen = currentHealth.micSignalSeen
                || (!microphoneMuted && snapshot.rms > -55)
        }
        if snapshot.isClipping { currentHealth.clippingEvents += 1 }
    }

    private func write(_ blocks: [MixedAudioBlock]) {
        for block in blocks {
            if let previousMixedSourceEndFrame,
               block.startFrame != previousMixedSourceEndFrame {
                writerBoundaryDiscontinuities += 1
            }
            previousMixedSourceEndFrame = block.startFrame + Int64(block.left.count)
            mediaCoordinator?.enqueueAudio(block)
        }
    }

    private func reconcileMixerHealth() {
        let newLateFrames = max(0, mixer.lateFrameCount - observedMixerLateFrames)
        currentHealth.lateFrames += newLateFrames
        observedMixerLateFrames = mixer.lateFrameCount
        currentHealth.timelineDiscontinuities = max(
            writerBoundaryDiscontinuities,
            mixer.timelineDiscontinuityCount
        )
    }

    private func stopActiveSourceSession() async {
        guard let sourceSessionID else { return }
        await captureSource.stop()
        callbackGate.deactivate(sessionID: sourceSessionID)
        await callbackGate.waitForIdle(sessionID: sourceSessionID)
        virtualMicPublisherState = microphoneAudioPaths.stop()
        clearSourceSession(sessionID: sourceSessionID)
    }

    private func terminateSourceSession(sessionID: UUID) {
        guard sourceSessionID == sessionID else { return }
        let terminalSelection = activeSelection
        disconnectSystemCapture(publishSnapshot: false)
        disconnectMicrophoneCapture()
        callbackGate.deactivate(sessionID: sessionID)
        isMonitoring = false
        captureConnectionSnapshot = CaptureConnectionSnapshot(
            sourceSessionID: sessionID,
            activeSelection: terminalSelection,
            isMonitoring: false,
            isSystemCaptureConnected: false
        )
        sourceSessionID = nil
        activeSelection = nil
        activeMicrophoneUID = nil
        virtualMicPublisherState = microphoneAudioPaths.stop()
        stopMeterTimer()
    }

    private func clearSourceSession(sessionID: UUID) {
        guard self.sourceSessionID == sessionID else { return }
        self.sourceSessionID = nil
        activeSelection = nil
        activeMicrophoneUID = nil
        isMonitoring = false
        stopMeterTimer()
    }

    private func resetMonitoringState() {
        mixer = makeMixer()
        isSystemCaptureConnected = true
        isMicrophoneCaptureConnected = true
        captureStatus = nil
        latestSystemLevel = LevelSnapshot()
        latestMicLevel = LevelSnapshot()
        rollingSystemSamples = Array(repeating: 0, count: 160)
        rollingMicSamples = Array(repeating: 0, count: 160)
        systemLevel = LevelSnapshot()
        micLevel = LevelSnapshot()
        publishConnectionSnapshot()
    }

    private func rollbackFailedStart(
        folder: URL,
        removeFolderIfEmpty: Bool
    ) async {
        mediaCoordinator?.setVideoEventHandler(nil)
        mediaCoordinator = nil
        videoIngress.deactivate()
        recordingEpoch = nil
        currentRecordingURL = nil
        outputFolder = nil
        startedAt = nil
        isRecording = false
        isStopping = false
        latestObservedSourceEndFrame = nil
        previousMixedSourceEndFrame = nil
        writerBoundaryDiscontinuities = 0
        observedMixerLateFrames = 0
        screenCaptureRequested = false
        screenTarget = nil
        meetingScreenCaptureState = .off
        hasHardScreenFailure = false
        hasCountedMuxFallback = false

        await stopActiveSourceSession()
        resetMonitoringState()

        guard removeFolderIfEmpty,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: folder,
                  includingPropertiesForKeys: nil
              ),
              contents.isEmpty else {
            return
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func clearMonitoringTransition(id: UUID) {
        guard monitoringTransition?.id == id else { return }
        monitoringTransition = nil
    }

    private func clearRecordingStartTransition(id: UUID) {
        guard recordingStartTransition?.id == id else { return }
        recordingStartTransition = nil
    }

    private func clearReconnectTransition(id: UUID) {
        guard reconnectTransition?.id == id else { return }
        reconnectTransition = nil
    }

    private func applyStartFailure(_ error: Error) {
        if let sourceError = error as? CaptureSourceError {
            switch sourceError {
            case .microphoneDeviceUnavailable, .microphonePermissionDenied,
                 .microphoneCaptureFailed:
                isMicrophoneCaptureConnected = false
            default:
                isSystemCaptureConnected = false
            }
        }
        captureStatus = .error(error.localizedDescription)
        publishConnectionSnapshot()
    }

    private func publishConnectionSnapshot() {
        captureConnectionSnapshot = CaptureConnectionSnapshot(
            sourceSessionID: sourceSessionID,
            activeSelection: activeSelection,
            isMonitoring: isMonitoring,
            isSystemCaptureConnected: isSystemCaptureConnected
        )
    }

    private func makeMixer() -> TimestampedAudioMixer {
        try! TimestampedAudioMixer(sampleRate: 48_000, blockFrames: mixerBlockFrames)
    }

    private func startMeterTimer() {
        stopMeterTimer()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rollingSystemSamples = Self.roll(
                    self.rollingSystemSamples,
                    next: Self.waveformSample(from: self.latestSystemLevel)
                )
                self.rollingMicSamples = Self.roll(
                    self.rollingMicSamples,
                    next: self.micMuted ? 0 : Self.waveformSample(from: self.latestMicLevel)
                )
                self.systemLevel = Self.smoothedLevel(
                    current: self.systemLevel,
                    target: self.latestSystemLevel,
                    samples: self.rollingSystemSamples
                )
                let displayedMicLevel = self.micMuted ? LevelSnapshot() : self.latestMicLevel
                self.micLevel = Self.smoothedLevel(
                    current: self.micLevel,
                    target: displayedMicLevel,
                    samples: self.rollingMicSamples
                )
            }
        }
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    nonisolated private static func levelSnapshot(for block: AudioFrameBlock) -> LevelSnapshot {
        guard !block.left.isEmpty else { return LevelSnapshot() }
        return block.left.withUnsafeBufferPointer {
            LevelAnalyzer.snapshot(samples: $0.baseAddress!, frameCount: block.left.count)
        }
    }

    nonisolated private static func waveformSample(from snapshot: LevelSnapshot) -> Float {
        if let peak = snapshot.samples.max(), peak > 0 { return min(1, max(0, peak)) }
        guard snapshot.rms > -90 else { return 0 }
        return min(1, max(0, pow(10, snapshot.rms / 20)))
    }

    nonisolated private static func roll(_ samples: [Float], next sample: Float) -> [Float] {
        guard !samples.isEmpty else { return [sample] }
        return Array(samples.dropFirst()) + [sample]
    }

    nonisolated private static func smoothedLevel(
        current: LevelSnapshot,
        target: LevelSnapshot,
        samples: [Float]
    ) -> LevelSnapshot {
        func smooth(_ current: Float, _ target: Float) -> Float {
            let coefficient: Float = target > current ? 0.42 : 0.16
            return current + (target - current) * coefficient
        }
        return LevelSnapshot(
            rms: smooth(current.rms, target.rms),
            peak: smooth(current.peak, target.peak),
            samples: samples
        )
    }

    private static let folderStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}

private final class MicrophoneAudioPaths: @unchecked Sendable {
    private let lock = NSLock()
    private let publisher: VirtualMicPublishing
    private var isMuted = false

    init(publisher: VirtualMicPublishing) {
        self.publisher = publisher
    }

    func start() -> VirtualMicPublisherState {
        lock.lock()
        defer { lock.unlock() }
        publisher.start()
        return publisher.state
    }

    func setMuted(_ muted: Bool) -> VirtualMicPublisherState {
        lock.lock()
        defer { lock.unlock() }
        isMuted = muted
        publisher.setMuted(muted)
        return publisher.state
    }

    func currentPublisherState() -> VirtualMicPublisherState {
        lock.lock()
        defer { lock.unlock() }
        return publisher.state
    }

    func withLockedState<T>(
        _ body: (_ muted: Bool, _ publisher: VirtualMicPublishing) -> T
    ) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(isMuted, publisher)
    }

    func stop() -> VirtualMicPublisherState {
        lock.lock()
        defer { lock.unlock() }
        publisher.stop()
        return publisher.state
    }
}

private struct MonitoringRequest: Equatable {
    let selection: ResolvedCaptureSelection
    let microphoneUID: String?
}

private struct MonitoringTransition {
    let id: UUID
    let request: MonitoringRequest
    let task: Task<Void, Error>
}

private struct RecordingStartTransition {
    let id: UUID
    let task: Task<URL, Error>
}

private struct ReconnectTransition {
    let id: UUID
    let request: ReconnectRequest
    let task: Task<Void, Error>
}

private struct ReconnectRequest: Equatable {
    let sourceSessionID: UUID
    let application: CaptureApplication
}

private struct RecordingCallbackTicket {
    let sourceSessionID: UUID
    let recordingEpoch: UInt64?
}

private final class RecordingCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activeSourceSessionID: UUID?
    private var activeRecordingEpoch: UInt64?
    private var inFlight: [UUID: Int] = [:]
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func activate(sessionID: UUID, recordingEpoch: UInt64?) {
        lock.lock()
        activeSourceSessionID = sessionID
        activeRecordingEpoch = recordingEpoch
        lock.unlock()
    }

    func setRecordingEpoch(_ recordingEpoch: UInt64?, for sessionID: UUID) {
        lock.lock()
        if activeSourceSessionID == sessionID {
            activeRecordingEpoch = recordingEpoch
        }
        lock.unlock()
    }

    func begin(sessionID: UUID) -> RecordingCallbackTicket? {
        lock.lock()
        defer { lock.unlock() }
        guard activeSourceSessionID == sessionID else { return nil }
        inFlight[sessionID, default: 0] += 1
        return RecordingCallbackTicket(
            sourceSessionID: sessionID,
            recordingEpoch: activeRecordingEpoch
        )
    }

    func finish(_ ticket: RecordingCallbackTicket) {
        lock.lock()
        let remaining = max(0, (inFlight[ticket.sourceSessionID] ?? 1) - 1)
        inFlight[ticket.sourceSessionID] = remaining
        let continuations = remaining == 0 ? waiters.removeValue(forKey: ticket.sourceSessionID) ?? [] : []
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func deactivate(sessionID: UUID) {
        lock.lock()
        if activeSourceSessionID == sessionID {
            activeSourceSessionID = nil
            activeRecordingEpoch = nil
        }
        lock.unlock()
    }

    func isActive(sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSourceSessionID == sessionID
    }

    func waitForIdle(sessionID: UUID) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if inFlight[sessionID, default: 0] == 0 {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[sessionID, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class VideoIngress: @unchecked Sendable {
    private let lock = NSLock()
    private weak var coordinator: RecordingMediaCoordinating?
    private var sessionID: UUID?
    private var epoch: UInt64?
    private var invalidTimestampCount = 0

    func activate(sessionID: UUID, epoch: UInt64, coordinator: RecordingMediaCoordinating?) {
        lock.lock()
        self.sessionID = sessionID
        self.epoch = epoch
        self.coordinator = coordinator
        invalidTimestampCount = 0
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        sessionID = nil
        epoch = nil
        coordinator = nil
        lock.unlock()
    }

    func enqueue(_ frame: ScreenVideoFrame, ticket: RecordingCallbackTicket) {
        lock.lock()
        guard ticket.sourceSessionID == sessionID, ticket.recordingEpoch == epoch else {
            lock.unlock()
            return
        }
        guard frame.sourcePTS.isValid, frame.sourcePTS.isNumeric, frame.sourcePTS >= .zero else {
            invalidTimestampCount += 1
            lock.unlock()
            return
        }
        let target = coordinator
        lock.unlock()
        target?.enqueueVideo(frame)
    }

    func takeInvalidTimestampCount(sessionID: UUID?, epoch: UInt64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionID == sessionID, self.epoch == epoch else { return 0 }
        let count = invalidTimestampCount
        invalidTimestampCount = 0
        return count
    }
}

private final class LegacyMediaCoordinator: RecordingMediaCoordinating {
    private let writer: MixedAudioWriting
    private let outputs: RecordingOutputURLs

    init(writer: MixedAudioWriting, outputs: RecordingOutputURLs) {
        self.writer = writer
        self.outputs = outputs
    }

    func setVideoEventHandler(_: (@Sendable (RecordingVideoEvent) -> Void)?) {}
    func enqueueVideo(_: ScreenVideoFrame) {}
    func setScreenCaptureRequested(_: Bool, expectedRevision _: CaptureFilterRevision?, window _: RecordedTeamsWindowIdentity?) {}
    func markScreenSourceUnavailable() {}

    func enqueueAudio(_ block: MixedAudioBlock) {
        try? writer.write(block)
    }

    func finish() async throws -> RecordingMediaOutcome {
        try writer.close()
        return RecordingMediaOutcome(
            finalURL: outputs.recoveredM4A,
            mediaKind: .audio,
            screenIntervals: [],
            capturedWindow: nil,
            recoveryState: .none,
            videoDroppedFrames: 0,
            videoFailureDescription: nil,
            safetyCleanupDiagnostic: nil
        )
    }
}
