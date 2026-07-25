import Foundation

protocol CaptureSourceProtocol: AnyObject {
    func refreshContent() async throws -> [CaptureApplication]
    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onEvent: @escaping (CaptureEvent) -> Void
    ) async throws
    func stop() async
}

extension ScreenCaptureSource: CaptureSourceProtocol {}

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

    private let captureSource: CaptureSourceProtocol
    private let writerFactory: MixedAudioWriterFactory
    private let mixerBlockFrames: Int
    private let callbackGate = RecordingCallbackGate()

    private var mixer: TimestampedAudioMixer
    private var mixedWriter: MixedAudioWriting?
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

    init(
        captureSource: CaptureSourceProtocol = ScreenCaptureSource(),
        writerFactory: @escaping MixedAudioWriterFactory = { try AACMixedAudioWriter(url: $0) },
        mixerBlockFrames: Int = 960
    ) {
        self.captureSource = captureSource
        self.writerFactory = writerFactory
        self.mixerBlockFrames = mixerBlockFrames
        self.mixer = try! TimestampedAudioMixer(
            sampleRate: 48_000,
            blockFrames: mixerBlockFrames
        )
    }

    func startMonitoring(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?
    ) async throws {
        if isMonitoring,
           activeSelection == selection,
           activeMicrophoneUID == microphoneUID {
            return
        }
        guard !isRecording else { return }

        await stopActiveSourceSession()
        resetMonitoringState()

        let sessionID = UUID()
        callbackGate.activate(sessionID: sessionID, recordingEpoch: nil)
        sourceSessionID = sessionID
        activeSelection = selection
        activeMicrophoneUID = microphoneUID

        do {
            try await captureSource.start(
                selection: selection,
                microphoneUID: microphoneUID,
                onAudio: { [weak self, callbackGate] block in
                    guard let ticket = callbackGate.begin(sessionID: sessionID) else { return }
                    Task { @MainActor [weak self, callbackGate] in
                        defer { callbackGate.finish(ticket) }
                        self?.receive(block, ticket: ticket)
                    }
                },
                onEvent: { [weak self, callbackGate] event in
                    guard let ticket = callbackGate.begin(sessionID: sessionID) else { return }
                    Task { @MainActor [weak self, callbackGate] in
                        defer { callbackGate.finish(ticket) }
                        self?.receive(event, ticket: ticket)
                    }
                }
            )
            isMonitoring = true
            startMeterTimer()
        } catch {
            callbackGate.deactivate(sessionID: sessionID)
            await callbackGate.waitForIdle(sessionID: sessionID)
            clearSourceSession(sessionID: sessionID)
            applyStartFailure(error)
            throw RecordingEngineError.captureStartFailed(error.localizedDescription)
        }
    }

    func stopMonitoring() async {
        guard !isRecording else { return }
        await stopActiveSourceSession()
        resetMonitoringState()
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

        try await startMonitoring(selection: selection, microphoneUID: microphoneUID)
        guard let sourceSessionID else {
            throw RecordingEngineError.captureStartFailed("Capture session did not start.")
        }

        let folder = baseFolder.appendingPathComponent(
            "\(folderPrefix)-\(Self.folderStamp.string(from: Date()))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecordingEngineError.cannotCreateFolder
        }

        let recordingURL = folder.appendingPathComponent("recording.m4a")
        do {
            mixedWriter = try writerFactory(recordingURL)
        } catch {
            throw RecordingEngineError.writerFailed(error.localizedDescription)
        }

        nextRecordingEpoch &+= 1
        recordingEpoch = nextRecordingEpoch
        callbackGate.setRecordingEpoch(recordingEpoch, for: sourceSessionID)
        mixer = makeMixer()
        currentHealth = RecordingHealthReport(startedAt: Date())
        latestObservedSourceEndFrame = nil
        previousMixedSourceEndFrame = nil
        writerBoundaryDiscontinuities = 0
        observedMixerLateFrames = 0
        currentRecordingURL = recordingURL
        outputFolder = folder
        startedAt = Date()
        isRecording = true
        isStopping = false
        return folder
    }

    func stop() async -> RecordingResult? {
        guard isRecording, !isStopping,
              let activeEpoch = recordingEpoch else {
            return nil
        }
        isStopping = true
        let recordingFolder = outputFolder
        let recordingURL = currentRecordingURL
        let sourceSessionID = sourceSessionID

        if let sourceSessionID {
            await captureSource.stop()
            callbackGate.deactivate(sessionID: sourceSessionID)
            await callbackGate.waitForIdle(sessionID: sourceSessionID)
        }

        guard recordingEpoch == activeEpoch else {
            return nil
        }

        if let latestObservedSourceEndFrame {
            write(mixer.flushThrough(frame: latestObservedSourceEndFrame))
        }
        reconcileMixerHealth()

        let writer = mixedWriter
        mixedWriter = nil
        do {
            try writer?.close()
        } catch {
            currentHealth.streamFailures += 1
            captureStatus = .error("Recording file could not be finalized")
        }

        currentHealth.endedAt = Date()
        let result = recordingFolder.flatMap { folder in
            recordingURL.map { RecordingResult(folderURL: folder, recordingURL: $0, health: currentHealth) }
        }
        recordingEpoch = nil
        currentRecordingURL = nil
        startedAt = nil
        isRecording = false
        isStopping = false
        micMuted = false
        if let sourceSessionID {
            clearSourceSession(sessionID: sourceSessionID)
        }
        resetMonitoringState()
        return result
    }

    func toggleMicMute() {
        micMuted.toggle()
    }

    private func receive(_ block: AudioFrameBlock, ticket: RecordingCallbackTicket) {
        guard ticket.sourceSessionID == sourceSessionID else { return }

        let snapshot = Self.levelSnapshot(for: block)
        switch block.source {
        case .system:
            latestSystemLevel = snapshot
        case .microphone:
            latestMicLevel = snapshot
        }

        guard let activeEpoch = recordingEpoch,
              ticket.recordingEpoch == activeEpoch,
              mixedWriter != nil else {
            return
        }

        updateHealth(with: snapshot, source: block.source)
        mixer.isMicrophoneMuted = micMuted
        latestObservedSourceEndFrame = max(
            latestObservedSourceEndFrame ?? block.startFrame,
            block.startFrame + Int64(block.frameCount)
        )
        write(mixer.push(block))
        reconcileMixerHealth()
    }

    private func receive(_ event: CaptureEvent, ticket: RecordingCallbackTicket) {
        guard ticket.sourceSessionID == sourceSessionID else { return }
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
            }
        case .microphoneSilence:
            break
        }
    }

    private func disconnectSystemCapture() {
        guard isSystemCaptureConnected else { return }
        isSystemCaptureConnected = false
        mixer.setSystemSourceConnected(false)
        if isRecording { currentHealth.systemDisconnects += 1 }
    }

    private func disconnectMicrophoneCapture() {
        guard isMicrophoneCaptureConnected else { return }
        isMicrophoneCaptureConnected = false
        mixer.setMicrophoneSourceConnected(false)
        if isRecording { currentHealth.microphoneDisconnects += 1 }
    }

    private func updateHealth(with snapshot: LevelSnapshot, source: AudioSourceKind) {
        switch source {
        case .system:
            currentHealth.systemSignalSeen = currentHealth.systemSignalSeen || snapshot.rms > -55
        case .microphone:
            currentHealth.micSignalSeen = currentHealth.micSignalSeen || (!micMuted && snapshot.rms > -55)
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
            do {
                try mixedWriter?.write(block)
            } catch {
                currentHealth.streamFailures += 1
                captureStatus = .error("Recording file write failed")
            }
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
        clearSourceSession(sessionID: sourceSessionID)
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
