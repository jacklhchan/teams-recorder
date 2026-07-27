@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

enum CaptureEvent: Error, Equatable {
    case applicationDisconnected(String)
    case selectedApplicationRequiresReconnect
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case microphoneUnavailable
    case microphoneDisconnected
    case microphoneSilence
    case systemAudioCaptureFailed
    case microphoneCaptureFailed
    case invalidSampleBuffer(AudioSourceKind)
    case conversionFailed(AudioSourceKind)
    case missingCaptureEntitlements
    case streamStoppedByUser
    case streamStoppedBySystem
    case streamFailed
    case screenTargetLost
    case screenCaptureFailed
}

enum CaptureStatus: Equatable {
    case ready(String)
    case warning(String)
    case error(String)
}

enum CaptureStatusMapper {
    static func status(for event: CaptureEvent) -> CaptureStatus {
        switch event {
        case .applicationDisconnected, .selectedApplicationRequiresReconnect:
            return .warning("App audio disconnected")
        case .screenRecordingPermissionDenied:
            return .error("Screen & System Audio Recording permission denied")
        case .microphonePermissionDenied:
            return .error("Microphone permission denied")
        case .microphoneUnavailable:
            return .error("Microphone unavailable")
        case .microphoneDisconnected:
            return .warning("Microphone disconnected")
        case .microphoneSilence:
            return .warning("No microphone signal")
        case .systemAudioCaptureFailed:
            return .error("System audio capture failed")
        case .microphoneCaptureFailed:
            return .error("Microphone capture failed")
        case .invalidSampleBuffer, .conversionFailed:
            return .warning("Audio buffer skipped")
        case .missingCaptureEntitlements:
            return .error("Audio capture is missing required entitlements")
        case .streamStoppedByUser:
            return .warning("Audio capture stopped by user")
        case .streamStoppedBySystem:
            return .error("Audio capture stopped by macOS")
        case .streamFailed:
            return .error("Audio capture failed")
        case .screenTargetLost:
            return .warning("Teams screen target was closed")
        case .screenCaptureFailed:
            return .warning("Screen frame capture unavailable")
        }
    }
}

enum CaptureSourceError: LocalizedError, Equatable {
    case noDisplay
    case selectedApplicationUnavailable
    case microphoneDeviceUnavailable
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case systemAudioCaptureFailed
    case microphoneCaptureFailed
    case missingCaptureEntitlements
    case streamAlreadyRunning
    case streamStartCancelled
    case streamStoppedByUser
    case streamStoppedBySystem
    case streamFailure

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available for system audio capture."
        case .selectedApplicationUnavailable:
            return "The selected application is no longer running."
        case .microphoneDeviceUnavailable:
            return "The selected microphone is unavailable."
        case .screenRecordingPermissionDenied:
            return "Screen & System Audio Recording permission is denied."
        case .microphonePermissionDenied:
            return "Microphone permission is denied."
        case .systemAudioCaptureFailed:
            return "System audio capture failed."
        case .microphoneCaptureFailed:
            return "Microphone capture failed."
        case .missingCaptureEntitlements:
            return "Audio capture is missing required entitlements."
        case .streamAlreadyRunning:
            return "Audio capture is already running."
        case .streamStartCancelled:
            return "Audio capture start was cancelled."
        case .streamStoppedByUser:
            return "Audio capture was stopped by the user."
        case .streamStoppedBySystem:
            return "Audio capture was stopped by macOS."
        case .streamFailure:
            return "Audio capture failed."
        }
    }
}

enum CaptureErrorMapper {
    static func event(for error: NSError) -> CaptureEvent {
        guard error.domain == SCStreamErrorDomain,
              let code = SCStreamError.Code(rawValue: error.code) else {
            return .streamFailed
        }
        switch code {
        case .userDeclined:
            return .screenRecordingPermissionDenied
        case .failedNoMatchingApplicationContext:
            return .selectedApplicationRequiresReconnect
        case .missingEntitlements:
            return .missingCaptureEntitlements
        case .userStopped:
            return .streamStoppedByUser
        case .failedToStartAudioCapture, .failedToStopAudioCapture:
            return .systemAudioCaptureFailed
        case .failedToStartMicrophoneCapture:
            return .microphoneCaptureFailed
        case .systemStoppedStream:
            return .streamStoppedBySystem
        default:
            return .streamFailed
        }
    }

    static func sourceError(for event: CaptureEvent) -> CaptureSourceError {
        switch event {
        case .screenRecordingPermissionDenied:
            return .screenRecordingPermissionDenied
        case .microphonePermissionDenied:
            return .microphonePermissionDenied
        case .microphoneUnavailable, .microphoneDisconnected:
            return .microphoneDeviceUnavailable
        case .systemAudioCaptureFailed:
            return .systemAudioCaptureFailed
        case .microphoneCaptureFailed:
            return .microphoneCaptureFailed
        case .selectedApplicationRequiresReconnect, .applicationDisconnected:
            return .selectedApplicationUnavailable
        case .missingCaptureEntitlements:
            return .missingCaptureEntitlements
        case .streamStoppedByUser:
            return .streamStoppedByUser
        case .streamStoppedBySystem:
            return .streamStoppedBySystem
        default:
            return .streamFailure
        }
    }
}

enum CaptureStreamStopClassifier {
    static func event(for error: NSError) -> CaptureEvent {
        let event = CaptureErrorMapper.event(for: error)
        // A delegate stop is terminal: the stream and microphone output are already gone.
        return event == .selectedApplicationRequiresReconnect ? .streamFailed : event
    }
}

enum CaptureMicrophoneAuthorization {
    case authorized
    case denied
    case restricted
    case notDetermined

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .denied
        }
    }
}

enum CapturePermissionPreflight {
    static func error(
        screenCaptureAllowed: Bool,
        microphoneAuthorization: CaptureMicrophoneAuthorization
    ) -> CaptureEvent? {
        guard screenCaptureAllowed else {
            return .screenRecordingPermissionDenied
        }
        switch microphoneAuthorization {
        case .authorized:
            return nil
        case .denied, .restricted, .notDetermined:
            return .microphonePermissionDenied
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

struct CaptureSessionToken: Equatable {
    let generation: UInt64
    let streamIdentity: ObjectIdentifier
}

struct CaptureStartReservation: Equatable {
    fileprivate let generation: UInt64
}

struct CaptureLifecycleCoordinator {
    private enum State: Equatable {
        case idle
        case starting(CaptureStartReservation)
        case cancellingStart(CaptureStartReservation)
        case active(CaptureSessionToken)
        case stopping(CaptureSessionToken)
    }

    private var state: State = .idle
    private var nextReservationGeneration: UInt64 = 0

    mutating func reserveStart() throws -> CaptureStartReservation {
        guard state == .idle else {
            throw CaptureSourceError.streamAlreadyRunning
        }
        nextReservationGeneration &+= 1
        let reservation = CaptureStartReservation(
            generation: nextReservationGeneration
        )
        state = .starting(reservation)
        return reservation
    }

    mutating func activate(
        reservation: CaptureStartReservation,
        token: CaptureSessionToken
    ) -> Bool {
        guard state == .starting(reservation) else {
            return false
        }
        state = .active(token)
        return true
    }

    mutating func cancelStart(_ reservation: CaptureStartReservation) {
        guard state == .starting(reservation) ||
                state == .cancellingStart(reservation) else {
            return
        }
        state = .idle
    }

    mutating func cancelCurrentStart() {
        guard case let .starting(reservation) = state else { return }
        state = .cancellingStart(reservation)
    }

    mutating func beginStop(
        expected token: CaptureSessionToken?
    ) -> CaptureSessionToken? {
        guard case let .active(activeToken) = state,
              token == nil || token == activeToken else {
            return nil
        }
        state = .stopping(activeToken)
        return activeToken
    }

    @discardableResult
    mutating func finishStop(_ token: CaptureSessionToken) -> Bool {
        guard state == .stopping(token) else { return false }
        state = .idle
        return true
    }

    func isActive(_ token: CaptureSessionToken) -> Bool {
        state == .active(token)
    }
}

struct CaptureSessionEventState {
    private var lastMicrophoneAudioAt: Date?
    private var hasReportedMicrophoneSilence = false
    private var hasReportedMicrophoneDisconnect = false
    private var hasReportedSelectedApplicationDisconnect = false

    mutating func markSelectedApplicationDisconnected() -> Bool {
        guard !hasReportedSelectedApplicationDisconnect else {
            return false
        }
        hasReportedSelectedApplicationDisconnect = true
        return true
    }

    mutating func clearSelectedApplicationDisconnect() {
        hasReportedSelectedApplicationDisconnect = false
    }

    mutating func recordMicrophoneAudio(at date: Date = Date()) {
        lastMicrophoneAudioAt = date
        hasReportedMicrophoneSilence = false
    }

    mutating func microphoneHealthEvent(
        now: Date,
        silenceThreshold: TimeInterval,
        isDeviceAvailable: Bool
    ) -> CaptureEvent? {
        guard isDeviceAvailable else {
            guard !hasReportedMicrophoneDisconnect else { return nil }
            hasReportedMicrophoneDisconnect = true
            return .microphoneUnavailable
        }

        guard let lastMicrophoneAudioAt,
              now.timeIntervalSince(lastMicrophoneAudioAt) >= silenceThreshold,
              !hasReportedMicrophoneSilence else {
            return nil
        }
        hasReportedMicrophoneSilence = true
        return .microphoneSilence
    }
}

struct SelectedApplicationLivenessSnapshot: Equatable {
    let filterGeneration: UInt64
    let application: CaptureApplication
}

struct SelectedApplicationReconnectUpdate: Equatable {
    let filterGeneration: UInt64
    let application: CaptureApplication
}

struct SelectedApplicationSessionState {
    private(set) var application: CaptureApplication
    private(set) var isDisconnected = false
    private var filterGeneration: UInt64 = 1
    private var reconnectUpdate: SelectedApplicationReconnectUpdate?

    init(application: CaptureApplication) {
        self.application = application
    }

    var livenessSnapshot: SelectedApplicationLivenessSnapshot? {
        SelectedApplicationLivenessSnapshot(
            filterGeneration: filterGeneration,
            application: application
        )
    }

    mutating func markDisconnected(
        for snapshot: SelectedApplicationLivenessSnapshot
    ) -> CaptureEvent? {
        guard snapshot.filterGeneration == filterGeneration,
              snapshot.application == application,
              !isDisconnected else {
            return nil
        }
        isDisconnected = true
        return .applicationDisconnected(application.name)
    }

    mutating func beginReconnect(
        to application: CaptureApplication
    ) -> SelectedApplicationReconnectUpdate? {
        guard isDisconnected,
              reconnectUpdate == nil,
              application.bundleIdentifier == self.application.bundleIdentifier else {
            return nil
        }
        let update = SelectedApplicationReconnectUpdate(
            filterGeneration: filterGeneration,
            application: application
        )
        reconnectUpdate = update
        return update
    }

    mutating func completeReconnect(
        _ update: SelectedApplicationReconnectUpdate
    ) -> Bool {
        guard reconnectUpdate == update,
              update.filterGeneration == filterGeneration else {
            return false
        }
        application = update.application
        filterGeneration &+= 1
        isDisconnected = false
        reconnectUpdate = nil
        return true
    }

    mutating func failReconnect(_ update: SelectedApplicationReconnectUpdate) {
        guard reconnectUpdate == update else { return }
        reconnectUpdate = nil
    }

    func accepts(_ snapshot: SelectedApplicationLivenessSnapshot) -> Bool {
        snapshot.filterGeneration == filterGeneration &&
            snapshot.application == application &&
            isDisconnected
    }
}

enum SelectedApplicationFilterPlan {
    static func includedProcessIDs(
        selected: CaptureApplication,
        applications: [CaptureApplication],
        recorderProcessID: pid_t
    ) throws -> [pid_t] {
        guard applications.contains(where: {
            $0.processID == selected.processID &&
                $0.bundleIdentifier == selected.bundleIdentifier
        }), applications.contains(where: {
            $0.processID == recorderProcessID
        }) else {
            throw CaptureSourceError.selectedApplicationUnavailable
        }
        return [selected.processID, recorderProcessID]
    }
}

final class CaptureSessionGate {
    private let lock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeToken: CaptureSessionToken?

    func issueToken(streamIdentity: ObjectIdentifier) -> CaptureSessionToken {
        lock.lock()
        defer { lock.unlock() }
        nextGeneration &+= 1
        return CaptureSessionToken(
            generation: nextGeneration,
            streamIdentity: streamIdentity
        )
    }

    func activate(_ token: CaptureSessionToken) {
        lock.lock()
        activeToken = token
        lock.unlock()
    }

    func activate(streamIdentity: ObjectIdentifier) -> CaptureSessionToken {
        let token = issueToken(streamIdentity: streamIdentity)
        activate(token)
        return token
    }

    func deactivate(_ token: CaptureSessionToken) {
        lock.lock()
        if activeToken == token {
            activeToken = nil
        }
        lock.unlock()
    }

    func accepts(
        _ token: CaptureSessionToken,
        streamIdentity: ObjectIdentifier
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeToken == token && token.streamIdentity == streamIdentity
    }
}

final class SerialCaptureDelivery {
    private let token: CaptureSessionToken
    private let gate: CaptureSessionGate
    private let queue: DispatchQueue

    init(
        token: CaptureSessionToken,
        gate: CaptureSessionGate,
        label: String
    ) {
        self.token = token
        self.gate = gate
        self.queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func enqueue(
        streamIdentity: ObjectIdentifier,
        _ work: @escaping () -> Void
    ) {
        queue.async { [gate, token] in
            guard gate.accepts(token, streamIdentity: streamIdentity) else {
                return
            }
            work()
        }
    }

    func isActive(streamIdentity: ObjectIdentifier) -> Bool {
        gate.accepts(token, streamIdentity: streamIdentity)
    }

    func drain() {
        queue.sync {}
    }
}

final class ScreenCaptureSource: NSObject {
    typealias AudioHandler = (AudioFrameBlock) -> Void
    typealias VideoHandler = (ScreenVideoFrame) -> Void
    typealias EventHandler = (CaptureEvent) -> Void
    private static let blackBackgroundColor = CGColor(gray: 0, alpha: 1)

    private final class ActiveSession {
        let stream: SCStream
        let output: ScreenCaptureStreamOutput
        let token: CaptureSessionToken
        let eventHandler: EventHandler
        let videoHandler: VideoHandler
        let videoQueue: DispatchQueue
        let selectedApplication: CaptureApplication?
        var selectedApplicationState: SelectedApplicationSessionState?
        let selectedMicrophoneUID: String?
        var eventState = CaptureSessionEventState()
        var livenessTask: Task<Void, Never>?
        var screenTargetLivenessTask: Task<Void, Never>?
        var filterCoordinator = CaptureFilterCoordinator()
        var committedFilterRevision: CaptureFilterRevision?
        var committedFilterIntent: CaptureStreamIntent?
        var committedScreenTarget: TeamsWindowIdentity?

        init(
            stream: SCStream,
            output: ScreenCaptureStreamOutput,
            token: CaptureSessionToken,
            eventHandler: @escaping EventHandler,
            videoHandler: @escaping VideoHandler,
            selectedApplication: CaptureApplication?,
            selectedMicrophoneUID: String?
        ) {
            self.stream = stream
            self.output = output
            self.token = token
            self.eventHandler = eventHandler
            self.videoHandler = videoHandler
            self.videoQueue = DispatchQueue(
                label: "local-meeting-recorder.capture.video.\(token.generation)",
                qos: .userInitiated
            )
            self.selectedApplication = selectedApplication
            self.selectedApplicationState = selectedApplication.map(
                SelectedApplicationSessionState.init(application:)
            )
            self.selectedMicrophoneUID = selectedMicrophoneUID
        }
    }

    private let stateLock = NSLock()
    private let sessionGate = CaptureSessionGate()
    private let systemAudioQueue = DispatchQueue(
        label: "local-meeting-recorder.capture.system",
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: "local-meeting-recorder.capture.microphone",
        qos: .userInitiated
    )
    private var activeSession: ActiveSession?
    private var lifecycle = CaptureLifecycleCoordinator()

    var screenVideoFormat: ScreenVideoFormat {
        ScreenVideoFormat(
            width: 1_600,
            height: 900,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func refreshContent() async throws -> [CaptureApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return Self.captureApplications(from: content)
    }

    func refreshTeamsWindows() async throws -> [TeamsWindowSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return content.windows.compactMap { window in
            guard let owner = window.owningApplication else { return nil }
            return TeamsWindowSnapshot(
                identity: TeamsWindowIdentity(processID: owner.processID, windowID: window.windowID),
                title: window.title ?? "",
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                layer: window.windowLayer
            )
        }
    }

    func reconnect(selection: ResolvedCaptureSelection) async throws {
        guard case let .application(application) = selection,
              let session = currentSession(),
              let update = beginReconnect(session, to: application) else {
            throw CaptureSourceError.selectedApplicationUnavailable
        }

        do {
            let intent = CaptureStreamIntent(
                filter: .application(application),
                cadence: .idle
            )
            guard let filterUpdate = requestFilterUpdate(session, intent: intent) else {
                throw CaptureSourceError.streamStartCancelled
            }
            try await applyFilterUpdate(filterUpdate, to: session)
            guard completeReconnect(session, update: update) else {
                throw CaptureSourceError.streamStartCancelled
            }
        } catch let error as CaptureSourceError {
            failReconnect(session, update: update)
            throw error
        } catch {
            failReconnect(session, update: update)
            throw CaptureErrorMapper.sourceError(
                for: CaptureErrorMapper.event(for: error as NSError)
            )
        }
    }

    func updateVideoTarget(
        _ target: TeamsWindowIdentity?
    ) async throws -> CaptureFilterRevision {
        guard let session = currentSession(),
              let application = session.selectedApplication else {
            throw CaptureSourceError.selectedApplicationUnavailable
        }
        let intent = CaptureStreamIntent(
            filter: target.map(CaptureFilterIntent.teamsWindow) ?? .application(application),
            cadence: target == nil ? .idle : .enabled
        )
        guard let update = requestFilterUpdate(session, intent: intent) else {
            let revision = committedRevision(for: session)
            guard let revision else { throw CaptureSourceError.streamStartCancelled }
            return revision
        }
        try await applyFilterUpdate(update, to: session)
        return update.revision
    }

    private func requestFilterUpdate(
        _ session: ActiveSession,
        intent: CaptureStreamIntent
    ) -> CaptureFilterUpdate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session, lifecycle.isActive(session.token) else { return nil }
        return session.filterCoordinator.request(intent)
    }

    private func committedRevision(for session: ActiveSession) -> CaptureFilterRevision? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session, lifecycle.isActive(session.token) else { return nil }
        return session.committedFilterRevision
    }

    private func applyFilterUpdate(
        _ update: CaptureFilterUpdate,
        to session: ActiveSession
    ) async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = Self.mainDisplay(in: content) else {
                throw CaptureSourceError.noDisplay
            }
            let filter = try Self.makeFilter(intent: update.intent, content: content, display: display)
            let configuration = Self.screenConfiguration(
                for: update.intent,
                microphoneUID: session.selectedMicrophoneUID
            )
            try await session.stream.updateContentFilter(filter)
            try await session.stream.updateConfiguration(configuration)
            session.videoQueue.sync {}
            let next = completeFilterUpdate(session, update: update, result: .success(()))
            startScreenTargetLiveness(for: session)
            if let next { try await applyFilterUpdate(next, to: session) }
        } catch {
            let sourceError = error as? CaptureSourceError ?? .streamFailure
            await restoreCommittedFilter(for: session)
            _ = completeFilterUpdate(session, update: update, result: .failure(sourceError))
            session.output.enqueue(event: .screenCaptureFailed)
            throw sourceError
        }
    }

    private func completeFilterUpdate(
        _ session: ActiveSession,
        update: CaptureFilterUpdate,
        result: Result<Void, CaptureSourceError>
    ) -> CaptureFilterUpdate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session, lifecycle.isActive(session.token) else { return nil }
        let next = session.filterCoordinator.complete(update, result: result)
        if case .success = result {
            session.committedFilterRevision = update.revision
            session.committedFilterIntent = update.intent
            if case let .teamsWindow(target) = update.intent.filter {
                session.committedScreenTarget = target
            } else {
                session.committedScreenTarget = nil
            }
        }
        return next
    }

    private func restoreCommittedFilter(for session: ActiveSession) async {
        let intent: CaptureStreamIntent? = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard activeSession === session, lifecycle.isActive(session.token) else { return nil }
            return session.committedFilterIntent
        }()
        guard let intent,
              let content = try? await SCShareableContent.excludingDesktopWindows(
                  false,
                  onScreenWindowsOnly: false
              ),
              let display = Self.mainDisplay(in: content),
              let filter = try? Self.makeFilter(intent: intent, content: content, display: display) else {
            return
        }
        try? await session.stream.updateContentFilter(filter)
        try? await session.stream.updateConfiguration(
            Self.screenConfiguration(for: intent, microphoneUID: session.selectedMicrophoneUID)
        )
        session.videoQueue.sync {}
    }

    func start(
        selection: ResolvedCaptureSelection,
        microphoneUID: String?,
        onAudio: @escaping AudioHandler,
        onVideo: @escaping VideoHandler,
        onEvent: @escaping EventHandler
    ) async throws {
        let reservation = try reserveStart()
        var pendingSession: ActiveSession?
        var didInstallSession = false
        do {
            if let permissionError = CapturePermissionPreflight.error(
                screenCaptureAllowed: CGPreflightScreenCaptureAccess(),
                microphoneAuthorization: CaptureMicrophoneAuthorization(
                    AVCaptureDevice.authorizationStatus(for: .audio)
                )
            ) {
                throw CaptureErrorMapper.sourceError(for: permissionError)
            }

            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = Self.mainDisplay(in: content) else {
                throw CaptureSourceError.noDisplay
            }
            let filter = try Self.makeFilter(
                selection: selection,
                content: content,
                display: display
            )
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
            Self.configureScreenFrames(configuration, cadence: .idle)

            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            let token = sessionGate.issueToken(
                streamIdentity: ObjectIdentifier(stream)
            )
            let output = ScreenCaptureStreamOutput(
                token: token,
                gate: sessionGate,
                onAudio: { [weak self] block in
                    if block.source == .microphone {
                        self?.recordMicrophoneAudio(for: token)
                    }
                    onAudio(block)
                },
                onVideo: { [weak self] frame in
                    self?.deliverVideo(frame, for: token)
                },
                videoRevision: { [weak self] in
                    self?.currentVideoRevision(for: token)
                },
                onEvent: onEvent
            )
            let session = ActiveSession(
                stream: stream,
                output: output,
                token: token,
                eventHandler: onEvent,
                videoHandler: onVideo,
                selectedApplication: Self.selectedApplication(in: selection),
                selectedMicrophoneUID: captureDeviceUID
            )
            pendingSession = session
            try stream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: systemAudioQueue
            )
            try stream.addStreamOutput(
                output,
                type: .microphone,
                sampleHandlerQueue: microphoneQueue
            )
            if Self.selectedApplication(in: selection) != nil {
                try stream.addStreamOutput(
                    output,
                    type: .screen,
                    sampleHandlerQueue: session.videoQueue
                )
            }

            guard install(reservation: reservation, session: session) else {
                throw CaptureSourceError.streamStartCancelled
            }
            didInstallSession = true

            try await stream.startCapture()
            guard isSessionActive(session) else {
                await stop(expected: session)
                throw CaptureSourceError.streamStartCancelled
            }
            startSelectedApplicationLiveness(for: session)
        } catch {
            if didInstallSession, let pendingSession {
                await stop(expected: pendingSession)
            } else if let pendingSession {
                await discardPendingSession(pendingSession)
                cancelStartReservation(reservation)
            } else {
                cancelStartReservation(reservation)
            }
            if let sourceError = error as? CaptureSourceError {
                throw sourceError
            }
            throw CaptureErrorMapper.sourceError(
                for: CaptureErrorMapper.event(for: error as NSError)
            )
        }
    }

    func stop() async {
        await stop(expected: nil)
    }

    /// Checks the original process identity. A restarted app requires an explicit caller-led reconnect.
    func refreshSelectedApplicationLiveness() async {
        guard let session = currentSession() else { return }
        await refreshSelectedApplicationLiveness(for: session)
    }

    private func refreshSelectedApplicationLiveness(
        for session: ActiveSession
    ) async {
        guard let snapshot = livenessSnapshot(for: session) else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        ) else {
            return
        }
        let isCurrentProcessPresent = content.applications.contains {
            $0.processID == snapshot.application.processID &&
                $0.bundleIdentifier == snapshot.application.bundleIdentifier
        }
        guard !isCurrentProcessPresent,
              let event = markSelectedApplicationDisconnected(
                session,
                snapshot: snapshot
              ) else {
            return
        }
        session.output.enqueue(event: event) { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.acceptsDisconnectedSnapshot(session, snapshot: snapshot)
        }
    }

    /// The caller controls refresh cadence; this method never changes the selected microphone.
    func refreshMicrophoneHealth(
        now: Date = Date(),
        silenceThreshold: TimeInterval = 2
    ) {
        guard let (session, event) = microphoneHealthEvent(
            now: now,
            silenceThreshold: silenceThreshold
        ) else {
            return
        }
        session.output.enqueue(event: event)
    }

    private func handleStreamStopped(
        _ stoppedStream: SCStream,
        error: Error
    ) {
        guard let session = beginStop(for: stoppedStream) else {
            return
        }
        session.output.drain()
        removeOutputs(for: session, reportErrors: false)
        session.eventHandler(CaptureStreamStopClassifier.event(for: error as NSError))
        finishStop(session)
    }

    private static func captureApplications(
        from content: SCShareableContent
    ) -> [CaptureApplication] {
        var seenBundleIdentifiers = Set<String>()
        return content.applications.compactMap { application in
            let bundleIdentifier = application.bundleIdentifier
            guard !bundleIdentifier.isEmpty,
                  application.processID != getpid(),
                  seenBundleIdentifiers.insert(bundleIdentifier).inserted else {
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
        content.displays.first {
            $0.displayID == CGMainDisplayID()
        } ?? content.displays.first
    }

    private static func makeFilter(
        selection: ResolvedCaptureSelection,
        content: SCShareableContent,
        display: SCDisplay
    ) throws -> SCContentFilter {
        switch selection {
        case .allSystemAudio:
            let recorderApplication = content.applications.filter {
                $0.processID == getpid()
            }
            return SCContentFilter(
                display: display,
                excludingApplications: recorderApplication,
                exceptingWindows: []
            )
        case let .application(selected):
            guard let currentApplication = content.applications.first(where: {
                $0.processID == selected.processID &&
                    $0.bundleIdentifier == selected.bundleIdentifier
            }), let recorderApplication = content.applications.first(where: {
                $0.processID == getpid()
            }) else {
                throw CaptureSourceError.selectedApplicationUnavailable
            }
            let availableApplications = content.applications.map {
                CaptureApplication(
                    processID: $0.processID,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.applicationName
                )
            }
            _ = try SelectedApplicationFilterPlan.includedProcessIDs(
                selected: selected,
                applications: availableApplications,
                recorderProcessID: getpid()
            )
            // The recorder keeps the filter context alive after the target exits.
            // excludesCurrentProcessAudio prevents recorder audio from entering the stream.
            return SCContentFilter(
                display: display,
                including: [currentApplication, recorderApplication],
                exceptingWindows: []
            )
        case .disconnected:
            throw CaptureSourceError.selectedApplicationUnavailable
        }
    }

    private static func makeFilter(
        intent: CaptureStreamIntent,
        content: SCShareableContent,
        display: SCDisplay
    ) throws -> SCContentFilter {
        switch intent.filter {
        case let .application(application):
            return try makeFilter(
                selection: .application(application),
                content: content,
                display: display
            )
        case let .teamsWindow(identity):
            guard let window = content.windows.first(where: {
                $0.windowID == identity.windowID &&
                    $0.owningApplication?.processID == identity.processID
            }) else {
                throw CaptureSourceError.selectedApplicationUnavailable
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private static func screenConfiguration(
        for intent: CaptureStreamIntent,
        microphoneUID: String?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = Int(SampleBufferConverter.outputSampleRate)
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.microphoneCaptureDeviceID = microphoneUID
        configureScreenFrames(configuration, cadence: intent.cadence)
        return configuration
    }

    private static func configureScreenFrames(
        _ configuration: SCStreamConfiguration,
        cadence: ScreenFrameCadence
    ) {
        configuration.width = 1_600
        configuration.height = 900
        configuration.minimumFrameInterval = CMTime(
            value: cadence == .enabled ? 1 : 1,
            timescale: cadence == .enabled ? 10 : 1
        )
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.backgroundColor = blackBackgroundColor
        configuration.showsCursor = false
    }

    private static func selectedApplication(
        in selection: ResolvedCaptureSelection
    ) -> CaptureApplication? {
        guard case let .application(application) = selection else {
            return nil
        }
        return application
    }

    private func reserveStart() throws -> CaptureStartReservation {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try lifecycle.reserveStart()
    }

    private func install(
        reservation: CaptureStartReservation,
        session: ActiveSession
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession == nil,
              lifecycle.activate(
                  reservation: reservation,
                  token: session.token
              ) else {
            return false
        }
        activeSession = session
        sessionGate.activate(session.token)
        return true
    }

    private func startSelectedApplicationLiveness(for session: ActiveSession) {
        stateLock.lock()
        guard activeSession === session,
              lifecycle.isActive(session.token),
              session.selectedApplicationState != nil,
              session.livenessTask == nil else {
            stateLock.unlock()
            return
        }
        let task = Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let session else { return }
                await self.refreshSelectedApplicationLiveness(for: session)
            }
        }
        session.livenessTask = task
        stateLock.unlock()
    }

    private func startScreenTargetLiveness(for session: ActiveSession) {
        stateLock.lock()
        guard activeSession === session,
              lifecycle.isActive(session.token),
              session.committedScreenTarget != nil,
              session.screenTargetLivenessTask == nil else {
            stateLock.unlock()
            return
        }
        let task = Task { [weak self, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let session else { return }
                await self.refreshScreenTargetLiveness(for: session)
            }
        }
        session.screenTargetLivenessTask = task
        stateLock.unlock()
    }

    private func refreshScreenTargetLiveness(for session: ActiveSession) async {
        guard let snapshot = screenTargetSnapshot(for: session) else { return }
        guard let windows = try? await refreshTeamsWindows(),
              !windows.contains(where: { $0.identity == snapshot.target }) else {
            return
        }
        guard let update = requestWindowFallback(session, snapshot: snapshot) else { return }
        session.output.enqueue(event: .screenTargetLost)
        _ = try? await applyFilterUpdate(update, to: session)
    }

    private func screenTargetSnapshot(
        for session: ActiveSession
    ) -> (target: TeamsWindowIdentity, revision: CaptureFilterRevision, application: CaptureApplication)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token),
              let target = session.committedScreenTarget,
              let revision = session.committedFilterRevision,
              let application = session.selectedApplication else {
            return nil
        }
        return (target, revision, application)
    }

    private func requestWindowFallback(
        _ session: ActiveSession,
        snapshot: (target: TeamsWindowIdentity, revision: CaptureFilterRevision, application: CaptureApplication)
    ) -> CaptureFilterUpdate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token),
              session.committedScreenTarget == snapshot.target,
              session.committedFilterRevision == snapshot.revision else {
            return nil
        }
        return session.filterCoordinator.requestFallback(
            CaptureStreamIntent(filter: .application(snapshot.application), cadence: .idle),
            matching: snapshot.revision
        )
    }

    private func deliverVideo(
        _ frame: ScreenVideoFrame,
        for token: CaptureSessionToken
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = activeSession,
              session.token == token,
              lifecycle.isActive(token),
              session.committedFilterRevision == frame.filterRevision else {
            return
        }
        session.videoHandler(frame)
    }

    private func currentVideoRevision(
        for token: CaptureSessionToken
    ) -> CaptureFilterRevision? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = activeSession,
              session.token == token,
              lifecycle.isActive(token) else {
            return nil
        }
        return session.committedFilterRevision
    }

    private func cancelStartReservation(
        _ reservation: CaptureStartReservation
    ) {
        stateLock.lock()
        lifecycle.cancelStart(reservation)
        stateLock.unlock()
    }

    private func discardPendingSession(_ session: ActiveSession) async {
        sessionGate.deactivate(session.token)
        session.output.drain()
        removeOutputs(for: session, reportErrors: false)
        try? await session.stream.stopCapture()
    }

    private func stop(expected expectedSession: ActiveSession?) async {
        guard let session = beginStop(expected: expectedSession) else {
            return
        }
        session.output.drain()
        removeOutputs(for: session, reportErrors: true)
        do {
            try await session.stream.stopCapture()
        } catch {
            session.eventHandler(CaptureErrorMapper.event(for: error as NSError))
        }
        finishStop(session)
    }

    private func beginStop(
        expected expectedSession: ActiveSession?
    ) -> ActiveSession? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let session = activeSession else {
            if expectedSession == nil {
                lifecycle.cancelCurrentStart()
            }
            return nil
        }
        if let expectedSession, session !== expectedSession {
            return nil
        }
        guard lifecycle.beginStop(expected: expectedSession?.token) == session.token else {
            return nil
        }
        session.livenessTask?.cancel()
        session.livenessTask = nil
        session.screenTargetLivenessTask?.cancel()
        session.screenTargetLivenessTask = nil
        session.filterCoordinator.stop()
        sessionGate.deactivate(session.token)
        return session
    }

    private func beginStop(for stoppedStream: SCStream) -> ActiveSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = activeSession,
              session.stream === stoppedStream,
              lifecycle.beginStop(expected: session.token) == session.token else {
            return nil
        }
        session.livenessTask?.cancel()
        session.livenessTask = nil
        session.screenTargetLivenessTask?.cancel()
        session.screenTargetLivenessTask = nil
        session.filterCoordinator.stop()
        sessionGate.deactivate(session.token)
        return session
    }

    private func finishStop(_ session: ActiveSession) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.finishStop(session.token) else {
            return
        }
        activeSession = nil
    }

    private func removeOutputs(
        for session: ActiveSession,
        reportErrors: Bool
    ) {
        do {
            try session.stream.removeStreamOutput(session.output, type: .audio)
        } catch {
            if reportErrors {
                session.eventHandler(CaptureErrorMapper.event(for: error as NSError))
            }
        }
        do {
            try session.stream.removeStreamOutput(session.output, type: .microphone)
        } catch {
            if reportErrors {
                session.eventHandler(CaptureErrorMapper.event(for: error as NSError))
            }
        }
        do {
            try session.stream.removeStreamOutput(session.output, type: .screen)
        } catch {
            if reportErrors {
                session.eventHandler(.screenCaptureFailed)
            }
        }
    }

    private func isSessionActive(_ session: ActiveSession) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSession === session &&
            lifecycle.isActive(session.token) &&
            sessionGate.accepts(
                session.token,
                streamIdentity: session.token.streamIdentity
            )
    }

    private func currentSession() -> ActiveSession? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = activeSession,
              lifecycle.isActive(session.token) else {
            return nil
        }
        return session
    }

    private func livenessSnapshot(
        for session: ActiveSession
    ) -> SelectedApplicationLivenessSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token) else {
            return nil
        }
        return session.selectedApplicationState?.livenessSnapshot
    }

    private func markSelectedApplicationDisconnected(
        _ session: ActiveSession,
        snapshot: SelectedApplicationLivenessSnapshot
    ) -> CaptureEvent? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token) else {
            return nil
        }
        return session.selectedApplicationState?.markDisconnected(for: snapshot)
    }

    private func acceptsDisconnectedSnapshot(
        _ session: ActiveSession,
        snapshot: SelectedApplicationLivenessSnapshot
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeSession === session &&
            lifecycle.isActive(session.token) &&
            session.selectedApplicationState?.accepts(snapshot) == true
    }

    private func beginReconnect(
        _ session: ActiveSession,
        to application: CaptureApplication
    ) -> SelectedApplicationReconnectUpdate? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token) else {
            return nil
        }
        return session.selectedApplicationState?.beginReconnect(to: application)
    }

    private func completeReconnect(
        _ session: ActiveSession,
        update: SelectedApplicationReconnectUpdate
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token) else {
            return false
        }
        return session.selectedApplicationState?.completeReconnect(update) == true
    }

    private func failReconnect(
        _ session: ActiveSession,
        update: SelectedApplicationReconnectUpdate
    ) {
        stateLock.lock()
        if activeSession === session {
            session.selectedApplicationState?.failReconnect(update)
        }
        stateLock.unlock()
    }

    private func recordMicrophoneAudio(
        for token: CaptureSessionToken
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let session = activeSession,
              session.token == token,
              lifecycle.isActive(token) else {
            return
        }
        session.eventState.recordMicrophoneAudio()
    }

    private func microphoneHealthEvent(
        now: Date,
        silenceThreshold: TimeInterval
    ) -> (ActiveSession, CaptureEvent)? {
        stateLock.lock()
        guard let session = activeSession,
              lifecycle.isActive(session.token) else {
            stateLock.unlock()
            return nil
        }
        let selectedMicrophoneUID = session.selectedMicrophoneUID
        stateLock.unlock()

        let isDeviceAvailable: Bool
        if let selectedMicrophoneUID {
            let availableUIDs = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices.map(\.uniqueID)
            isDeviceAvailable = availableUIDs.contains(selectedMicrophoneUID)
        } else {
            isDeviceAvailable = true
        }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeSession === session,
              lifecycle.isActive(session.token),
              let event = session.eventState.microphoneHealthEvent(
                  now: now,
                  silenceThreshold: silenceThreshold,
                  isDeviceAvailable: isDeviceAvailable
              ) else {
            return nil
        }
        return (session, event)
    }
}

extension ScreenCaptureSource: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleStreamStopped(stream, error: error)
    }
}

private final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput {
    private let token: CaptureSessionToken
    private let gate: CaptureSessionGate
    private let delivery: SerialCaptureDelivery
    private let onAudio: (AudioFrameBlock) -> Void
    private let onVideo: (ScreenVideoFrame) -> Void
    private let videoRevision: () -> CaptureFilterRevision?
    private let onEvent: (CaptureEvent) -> Void
    private let systemResampler = PersistentAudioResampler(source: .system)
    private let microphoneResampler = PersistentAudioResampler(source: .microphone)

    init(
        token: CaptureSessionToken,
        gate: CaptureSessionGate,
        onAudio: @escaping (AudioFrameBlock) -> Void,
        onVideo: @escaping (ScreenVideoFrame) -> Void,
        videoRevision: @escaping () -> CaptureFilterRevision?,
        onEvent: @escaping (CaptureEvent) -> Void
    ) {
        self.token = token
        self.gate = gate
        self.delivery = SerialCaptureDelivery(
            token: token,
            gate: gate,
            label: "local-meeting-recorder.capture.session.\(token.generation)"
        )
        self.onAudio = onAudio
        self.onVideo = onVideo
        self.videoRevision = videoRevision
        self.onEvent = onEvent
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .screen {
            deliverScreenFrame(sampleBuffer)
            return
        }

        let source: AudioSourceKind
        switch type {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }

        let streamIdentity = ObjectIdentifier(stream)
        guard gate.accepts(token, streamIdentity: streamIdentity) else {
            return
        }

        let copiedResult: Result<OwnedAudioPacket, CaptureEvent>
        do {
            copiedResult = .success(try SampleBufferConverter.copy(sampleBuffer))
        } catch SampleBufferConverterError.invalidSampleBuffer {
            copiedResult = .failure(.invalidSampleBuffer(source))
        } catch {
            copiedResult = .failure(.conversionFailed(source))
        }

        delivery.enqueue(streamIdentity: streamIdentity) { [weak self] in
            guard let self else { return }
            switch copiedResult {
            case let .failure(event):
                if delivery.isActive(streamIdentity: streamIdentity) {
                    onEvent(event)
                }
            case let .success(packet):
                do {
                    let resampler = source == .system
                        ? systemResampler
                        : microphoneResampler
                    if let block = try resampler.process(packet),
                       delivery.isActive(streamIdentity: streamIdentity) {
                        onAudio(block)
                    }
                } catch {
                    if delivery.isActive(streamIdentity: streamIdentity) {
                        onEvent(.conversionFailed(source))
                    }
                }
            }
        }
    }

    private func deliverScreenFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let revision = videoRevision(),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(imageBuffer)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete else {
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite,
              !pts.isPositiveInfinity, !pts.isNegativeInfinity else {
            return
        }
        // Assigning the Core Foundation object to the frame transfers a strong ARC reference.
        let frame = ScreenVideoFrame(
            pixelBuffer: imageBuffer,
            sourcePTS: pts,
            status: status,
            filterRevision: revision
        )
        onVideo(frame)
    }

    func enqueue(
        event: CaptureEvent,
        ifCurrent: @escaping () -> Bool = { true }
    ) {
        let streamIdentity = token.streamIdentity
        delivery.enqueue(streamIdentity: streamIdentity) { [weak self] in
            guard let self,
                  delivery.isActive(streamIdentity: streamIdentity),
                  ifCurrent() else {
                return
            }
            onEvent(event)
        }
    }

    func drain() {
        delivery.drain()
    }
}
