@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

enum CaptureEvent: Error, Equatable {
    case applicationDisconnected(String)
    case microphoneDisconnected
    case microphoneSilence
    case invalidSampleBuffer(AudioSourceKind)
    case conversionFailed(AudioSourceKind)
    case streamStopped
    case streamFailed
}

enum CaptureStatus: Equatable {
    case ready(String)
    case warning(String)
    case error(String)
}

enum CaptureStatusMapper {
    static func status(for event: CaptureEvent) -> CaptureStatus {
        switch event {
        case .applicationDisconnected:
            return .warning("App audio disconnected")
        case .microphoneDisconnected:
            return .warning("Microphone disconnected")
        case .microphoneSilence:
            return .warning("No microphone signal")
        case .invalidSampleBuffer, .conversionFailed:
            return .warning("Audio buffer skipped")
        case .streamStopped, .streamFailed:
            return .error("Audio capture stopped")
        }
    }
}

enum CaptureSourceError: LocalizedError, Equatable {
    case noDisplay
    case selectedApplicationUnavailable
    case microphoneDeviceUnavailable
    case streamAlreadyRunning
    case streamStartCancelled
    case streamStartFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for system audio capture."
        case .selectedApplicationUnavailable:
            return "The selected application is no longer running."
        case .microphoneDeviceUnavailable:
            return "The selected microphone is unavailable."
        case .streamAlreadyRunning:
            return "Audio capture is already running."
        case .streamStartCancelled:
            return "Audio capture start was cancelled."
        case .streamStartFailed:
            return "Audio capture could not start."
        }
    }
}

enum CaptureProcessResolver {
    static func currentApplication(
        for selection: ResolvedCaptureSelection,
        availableApplications: [CaptureApplication]
    ) -> CaptureApplication? {
        guard case let .application(selectedApplication) = selection else {
            return nil
        }
        return availableApplications.first {
            $0.processID == selectedApplication.processID &&
                $0.bundleIdentifier == selectedApplication.bundleIdentifier
        }
    }
}

enum MicrophoneDeviceResolver {
    static func resolve(
        coreAudioUID: String,
        availableCaptureDeviceUIDs: [String]
    ) throws -> String {
        guard availableCaptureDeviceUIDs.contains(coreAudioUID) else {
            throw CaptureSourceError.microphoneDeviceUnavailable
        }
        return coreAudioUID
    }

    static func resolveCurrentCaptureDeviceUID(coreAudioUID: String?) throws -> String? {
        guard let coreAudioUID else {
            return nil
        }
        guard !coreAudioUID.isEmpty else {
            throw CaptureSourceError.microphoneDeviceUnavailable
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return try resolve(
            coreAudioUID: coreAudioUID,
            availableCaptureDeviceUIDs: session.devices.map(\.uniqueID)
        )
    }
}

/// Serializes callback acceptance across asynchronous stream starts, stops, and reconnects.
final class CaptureCallbackGate {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: UInt64?

    func activate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    func deactivate() {
        lock.lock()
        activeGeneration = nil
        lock.unlock()
    }

    func accepts(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration == generation
    }

    var currentGeneration: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return activeGeneration
    }
}

final class ScreenCaptureSource: NSObject {
    typealias AudioHandler = (AudioFrameBlock) -> Void
    typealias EventHandler = (CaptureEvent) -> Void

    private let stateLock = NSLock()
    private let callbackGate = CaptureCallbackGate()
    private let systemAudioQueue = DispatchQueue(label: "local-meeting-recorder.capture.system", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "local-meeting-recorder.capture.microphone", qos: .userInitiated)
    private var stream: SCStream?
    private var audioHandler: AudioHandler?
    private var eventHandler: EventHandler?
    private var selectedApplication: CaptureApplication?
    private var selectedMicrophoneUID: String?
    private var lastMicrophoneAudioAt: Date?
    private var hasReportedMicrophoneSilence = false
    private var hasReportedMicrophoneDisconnect = false
    private var isStarting = false
    private var lifecycleEpoch: UInt64 = 0
    private lazy var streamOutput = ScreenCaptureStreamOutput(
        callbackGate: callbackGate
    ) { [weak self] result, generation in
        self?.handleCallback(result, generation: generation)
    }

    func refreshContent() async throws -> [CaptureApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return Self.captureApplications(from: content)
    }

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping AudioHandler,
        onEvent: @escaping EventHandler
    ) async throws {
        let reservation = try reserveStart()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = Self.mainDisplay(in: content) else {
                throw CaptureSourceError.noDisplay
            }
            let filter = try Self.makeFilter(selection: selection, content: content, display: display)
            let captureDeviceUID = try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(
                coreAudioUID: microphoneUID
            )

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.captureMicrophone = true
            configuration.sampleRate = Int(SampleBufferConverter.outputSampleRate)
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
            configuration.microphoneCaptureDeviceID = captureDeviceUID

            let generation = callbackGate.activate()
            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try newStream.addStreamOutput(
                streamOutput,
                type: .audio,
                sampleHandlerQueue: systemAudioQueue
            )
            try newStream.addStreamOutput(
                streamOutput,
                type: .microphone,
                sampleHandlerQueue: microphoneQueue
            )

            guard install(
                reservation: reservation,
                stream: newStream,
                selectedApplication: Self.selectedApplication(in: selection),
                selectedMicrophoneUID: captureDeviceUID,
                onAudio: onAudio,
                onEvent: onEvent
            ) else {
                callbackGate.deactivate()
                try? newStream.removeStreamOutput(streamOutput, type: .audio)
                try? newStream.removeStreamOutput(streamOutput, type: .microphone)
                try? await newStream.stopCapture()
                throw CaptureSourceError.streamStartCancelled
            }

            try await newStream.startCapture()
            if !callbackGate.accepts(generation) {
                await stop()
            }
        } catch {
            await stop()
            if error is CaptureSourceError {
                throw error
            }
            throw CaptureSourceError.streamStartFailed
        }
    }

    func stop() async {
        callbackGate.deactivate()

        guard let activeStream = takeActiveStream() else { return }
        try? activeStream.removeStreamOutput(streamOutput, type: .audio)
        try? activeStream.removeStreamOutput(streamOutput, type: .microphone)
        try? await activeStream.stopCapture()
    }

    /// Checks the original process identity. A restarted app requires an explicit caller-led reconnect.
    func refreshSelectedApplicationLiveness() async {
        guard let selectedApplication = currentSelectedApplication() else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return
        }
        let isCurrentProcessPresent = content.applications.contains {
            $0.processID == selectedApplication.processID &&
                $0.bundleIdentifier == selectedApplication.bundleIdentifier
        }
        guard !isCurrentProcessPresent else { return }
        guard markSelectedApplicationDisconnected(selectedApplication) else { return }
        let (_, eventHandler) = currentHandlers()
        eventHandler?(.applicationDisconnected(selectedApplication.name))
    }

    /// The caller controls refresh cadence; this method never changes the selected microphone.
    func refreshMicrophoneHealth(
        now: Date = Date(),
        silenceThreshold: TimeInterval = 2
    ) {
        let healthState = microphoneHealthState(now: now, silenceThreshold: silenceThreshold)
        switch healthState {
        case .healthy:
            return
        case .disconnected:
            let (_, eventHandler) = currentHandlers()
            eventHandler?(.microphoneDisconnected)
        case .silent:
            let (_, eventHandler) = currentHandlers()
            eventHandler?(.microphoneSilence)
        }
    }

    private func handleCallback(
        _ result: Result<AudioFrameBlock, CaptureEvent>,
        generation: UInt64
    ) {
        guard callbackGate.accepts(generation) else { return }

        let (audioHandler, eventHandler) = currentHandlers()

        switch result {
        case let .success(block):
            if block.source == .microphone {
                recordMicrophoneAudio()
            }
            audioHandler?(block)
        case let .failure(event):
            eventHandler?(event)
        }
    }

    private func handleStreamStopped(_ stoppedStream: SCStream) {
        let (shouldEmit, eventHandler) = clearStoppedStreamIfCurrent(stoppedStream)

        guard shouldEmit else { return }
        callbackGate.deactivate()
        eventHandler?(.streamFailed)
    }

    private static func captureApplications(from content: SCShareableContent) -> [CaptureApplication] {
        content.applications.compactMap { application in
            let bundleIdentifier = application.bundleIdentifier
            guard !bundleIdentifier.isEmpty else {
                return nil
            }
            return CaptureApplication(
                processID: application.processID,
                bundleIdentifier: bundleIdentifier,
                name: application.applicationName
            )
        }
        .sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            return nameOrder == .orderedSame
                ? $0.bundleIdentifier < $1.bundleIdentifier
                : nameOrder == .orderedAscending
        }
    }

    private static func mainDisplay(in content: SCShareableContent) -> SCDisplay? {
        content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    private static func makeFilter(
        selection: ResolvedCaptureSelection,
        content: SCShareableContent,
        display: SCDisplay
    ) throws -> SCContentFilter {
        switch selection {
        case .allSystemAudio:
            let recorderApplication = content.applications.filter { $0.processID == getpid() }
            return SCContentFilter(
                display: display,
                excludingApplications: recorderApplication,
                exceptingWindows: []
            )
        case let .application(selected):
            guard let currentApplication = content.applications.first(where: {
                $0.processID == selected.processID &&
                    $0.bundleIdentifier == selected.bundleIdentifier
            }) else {
                throw CaptureSourceError.selectedApplicationUnavailable
            }
            return SCContentFilter(
                display: display,
                including: [currentApplication],
                exceptingWindows: []
            )
        case .disconnected:
            throw CaptureSourceError.selectedApplicationUnavailable
        }
    }

    private static func selectedApplication(in selection: ResolvedCaptureSelection) -> CaptureApplication? {
        guard case let .application(application) = selection else { return nil }
        return application
    }

    private func reserveStart() throws -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil, !isStarting else {
            throw CaptureSourceError.streamAlreadyRunning
        }
        lifecycleEpoch &+= 1
        isStarting = true
        return lifecycleEpoch
    }

    private func install(
        reservation: UInt64,
        stream: SCStream,
        selectedApplication: CaptureApplication?,
        selectedMicrophoneUID: String?,
        onAudio: @escaping AudioHandler,
        onEvent: @escaping EventHandler
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isStarting, lifecycleEpoch == reservation, self.stream == nil else {
            return false
        }
        self.stream = stream
        self.selectedApplication = selectedApplication
        self.selectedMicrophoneUID = selectedMicrophoneUID
        lastMicrophoneAudioAt = nil
        hasReportedMicrophoneSilence = false
        hasReportedMicrophoneDisconnect = false
        audioHandler = onAudio
        eventHandler = onEvent
        isStarting = false
        return true
    }

    private func takeActiveStream() -> SCStream? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let activeStream = stream
        stream = nil
        selectedApplication = nil
        selectedMicrophoneUID = nil
        lastMicrophoneAudioAt = nil
        isStarting = false
        lifecycleEpoch &+= 1
        audioHandler = nil
        eventHandler = nil
        return activeStream
    }

    private func currentHandlers() -> (AudioHandler?, EventHandler?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (audioHandler, eventHandler)
    }

    private func currentSelectedApplication() -> CaptureApplication? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedApplication
    }

    private func markSelectedApplicationDisconnected(_ application: CaptureApplication) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard selectedApplication == application else { return false }
        selectedApplication = nil
        return true
    }

    private func recordMicrophoneAudio() {
        stateLock.lock()
        lastMicrophoneAudioAt = Date()
        hasReportedMicrophoneSilence = false
        stateLock.unlock()
    }

    private enum MicrophoneHealthState {
        case healthy
        case disconnected
        case silent
    }

    private func microphoneHealthState(
        now: Date,
        silenceThreshold: TimeInterval
    ) -> MicrophoneHealthState {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream != nil else { return .healthy }

        if let selectedMicrophoneUID {
            let captureDeviceUIDs = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices.map(\.uniqueID)
            if !captureDeviceUIDs.contains(selectedMicrophoneUID) {
                guard !hasReportedMicrophoneDisconnect else { return .healthy }
                hasReportedMicrophoneDisconnect = true
                return .disconnected
            }
        }

        guard let lastMicrophoneAudioAt,
              now.timeIntervalSince(lastMicrophoneAudioAt) >= silenceThreshold,
              !hasReportedMicrophoneSilence else {
            return .healthy
        }
        hasReportedMicrophoneSilence = true
        return .silent
    }

    private func clearStoppedStreamIfCurrent(_ stoppedStream: SCStream) -> (Bool, EventHandler?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream === stoppedStream else {
            return (false, nil)
        }
        stream = nil
        selectedApplication = nil
        selectedMicrophoneUID = nil
        lastMicrophoneAudioAt = nil
        isStarting = false
        lifecycleEpoch &+= 1
        audioHandler = nil
        self.eventHandler = nil
        return (true, eventHandler)
    }
}

extension ScreenCaptureSource: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(stream)
    }
}

private final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
    private let callbackGate: CaptureCallbackGate
    private let handler: (Result<AudioFrameBlock, CaptureEvent>, UInt64) -> Void

    init(
        callbackGate: CaptureCallbackGate,
        handler: @escaping (Result<AudioFrameBlock, CaptureEvent>, UInt64) -> Void
    ) {
        self.callbackGate = callbackGate
        self.handler = handler
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let source: AudioSourceKind
        switch type {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }
        guard let generation = callbackGate.currentGeneration else { return }

        do {
            handler(.success(try SampleBufferConverter.convert(sampleBuffer, source: source)), generation)
        } catch SampleBufferConverterError.invalidSampleBuffer {
            handler(.failure(.invalidSampleBuffer(source)), generation)
        } catch {
            handler(.failure(.conversionFailed(source)), generation)
        }
    }
}
