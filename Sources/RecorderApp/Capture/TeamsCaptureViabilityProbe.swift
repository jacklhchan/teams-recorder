@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

struct TeamsCaptureViabilityDwell: Codable, Equatable {
    let filterRevision: UInt64
    let windowID: UInt32?
    let duration: TimeInterval
    let streamIdentity: String
    let completeScreenFrameCount: Int
    let nonSilentSystemBufferCount: Int
    let nonSilentMicrophoneBufferCount: Int
    var maximumSystemPTSGap: TimeInterval
    var maximumMicrophonePTSGap: TimeInterval
    let capturedFramePNG: String?
}

struct TeamsCaptureViabilityReport: Codable, Equatable {
    var streamIdentities: Set<String>
    // Kept for report compatibility; this is the number of completed
    // application -> window -> application round trips.
    var filterTransitionCount: Int
    var applicationBaseline: TeamsCaptureViabilityDwell
    var windowFilterDwells: [TeamsCaptureViabilityDwell]
    var observedWindowIDs: Set<UInt32>
    var notes: [String]
}

enum TeamsCaptureViabilityEvaluator {
    private static let minimumDwellDuration: TimeInterval = 5
    private static let minimumCompleteFrames = 10
    private static let maximumPTSGap =
        TeamsCaptureViabilityGateFailure.maximumAllowedAudioGap

    static func failures(in report: TeamsCaptureViabilityReport) -> [String] {
        var failures: [String] = []
        let soleIdentity: String?
        if report.streamIdentities.count == 1 {
            soleIdentity = report.streamIdentities.first
        } else {
            soleIdentity = nil
            failures.append("Expected exactly one stream identity.")
        }
        if let soleIdentity,
           report.applicationBaseline.streamIdentity != soleIdentity {
            failures.append("The application baseline stream identity differs from the sole report identity.")
        }
        if report.filterTransitionCount < 4 {
            failures.append(
                "Expected at least four complete application-window-application round trips."
            )
        }
        if report.windowFilterDwells.isEmpty {
            failures.append("No window-filter dwell was recorded.")
        }
        if report.notes.contains(where: {
            $0.localizedCaseInsensitiveContains("callback stopped")
        }) {
            failures.append("A capture callback stopped during the probe.")
        }
        if report.notes.contains(where: {
            $0.localizedCaseInsensitiveContains("audio timing diagnostic")
        }) {
            failures.append("The report contains an audio timing diagnostic.")
        }
        if report.notes.contains(where: {
            $0.hasPrefix(TeamsCaptureViabilityGateFailure.prefix)
        }) {
            failures.append("The report contains gate failure evidence.")
        }

        for dwell in report.windowFilterDwells {
            let label = "Window dwell revision \(dwell.filterRevision)"
            if let soleIdentity, dwell.streamIdentity != soleIdentity {
                failures.append("\(label) window dwell stream identity differs from the sole report identity.")
            }
            if dwell.duration < minimumDwellDuration {
                failures.append("\(label) lasted less than five seconds.")
            }
            if dwell.nonSilentSystemBufferCount == 0 {
                failures.append("\(label) has no non-silent system audio.")
            }
            if dwell.nonSilentMicrophoneBufferCount == 0 {
                failures.append("\(label) has no non-silent microphone audio.")
            }
            if dwell.completeScreenFrameCount < minimumCompleteFrames {
                failures.append("\(label) has fewer than ten complete frames.")
            }
            if dwell.capturedFramePNG == nil {
                failures.append("\(label) has no captured PNG.")
            }
            if dwell.maximumSystemPTSGap > maximumPTSGap {
                failures.append("\(label) system PTS gap exceeds 250 ms.")
            }
            if dwell.maximumMicrophonePTSGap > maximumPTSGap {
                failures.append("\(label) microphone PTS gap exceeds 250 ms.")
            }
        }
        return failures
    }
}

enum TeamsCaptureViabilityFilterTarget: Equatable {
    case application
    case window(UInt32)
}

enum TeamsCaptureViabilityGateFailure {
    static let prefix = "Gate failure:"
    static let maximumAllowedAudioGap: TimeInterval = 0.250

    static func filterUpdate(
        target: TeamsCaptureViabilityFilterTarget,
        attemptedRevision: UInt64,
        errorDescription: String
    ) -> String {
        let targetLabel: String
        switch target {
        case .application:
            targetLabel = "application"
        case let .window(windowID):
            targetLabel = "window(\(windowID))"
        }
        return "\(prefix) updateContentFilter target=\(targetLabel) revision=\(attemptedRevision) error=\(errorDescription)"
    }

    static func stopCapture(errorDescription: String) -> String {
        "\(prefix) stopCapture error=\(errorDescription)"
    }

    static func audioGap(
        source: AudioSourceKind,
        filterRevision: UInt64,
        unexplainedGap: TimeInterval
    ) -> String {
        let gap = String(
            format: "%.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            unexplainedGap
        )
        return "\(prefix) unexplained audio gap source=\(source.viabilityLabel) revision=\(filterRevision) gap=\(gap)s"
    }
}

struct TeamsCaptureViabilityStopFailurePlan: Equatable {
    let gateFailureNote: String
    let shouldDetachOutputs: Bool
    let shouldRetireActiveStream: Bool
    let shouldFinalizeEvidence: Bool

    static func make(errorDescription: String) -> Self {
        Self(
            gateFailureNote: TeamsCaptureViabilityGateFailure.stopCapture(
                errorDescription: errorDescription
            ),
            shouldDetachOutputs: true,
            shouldRetireActiveStream: true,
            shouldFinalizeEvidence: true
        )
    }
}

struct TeamsCaptureViabilityCycleCounter {
    private var selectedTarget: TeamsCaptureViabilityFilterTarget = .application
    private(set) var completedRoundTrips = 0

    func shouldUpdateFilter(to target: TeamsCaptureViabilityFilterTarget) -> Bool {
        selectedTarget != target
    }

    mutating func recordSuccessfulSelection(_ target: TeamsCaptureViabilityFilterTarget) {
        guard target != selectedTarget else { return }
        if case .window = selectedTarget, target == .application {
            completedRoundTrips += 1
        }
        selectedTarget = target
    }
}

struct TeamsCaptureViabilityPTSObservation: Equatable {
    let filterRevision: UInt64
    let unexplainedGap: TimeInterval
    let diagnostic: String?
}

struct TeamsCaptureViabilityPTSTracker {
    private let source: AudioSourceKind
    private var lastValidEndPTS: TimeInterval?

    init(source: AudioSourceKind) {
        self.source = source
    }

    mutating func observe(
        startPTS: TimeInterval?,
        duration: TimeInterval?,
        filterRevision: UInt64
    ) -> TeamsCaptureViabilityPTSObservation {
        guard let startPTS, startPTS.isFinite, startPTS >= 0 else {
            return .init(
                filterRevision: filterRevision,
                unexplainedGap: 0,
                diagnostic: "Audio timing diagnostic: Invalid \(source.viabilityLabel) PTS at filter revision \(filterRevision)."
            )
        }

        let unexplainedGap = lastValidEndPTS.map {
            max(0, startPTS - $0)
        } ?? 0
        guard let duration, duration.isFinite, duration > 0,
              (startPTS + duration).isFinite else {
            return .init(
                filterRevision: filterRevision,
                unexplainedGap: unexplainedGap,
                diagnostic: "Audio timing diagnostic: Invalid \(source.viabilityLabel) duration at filter revision \(filterRevision)."
            )
        }

        let endPTS = startPTS + duration
        lastValidEndPTS = max(lastValidEndPTS ?? endPTS, endPTS)
        return .init(
            filterRevision: filterRevision,
            unexplainedGap: unexplainedGap,
            diagnostic: nil
        )
    }
}

enum TeamsCaptureViabilityAudioTiming {
    static func duration(
        sampleCount: Int,
        sampleRate: Double?,
        validBufferDuration: TimeInterval?
    ) -> TimeInterval? {
        if sampleCount > 0,
           let sampleRate,
           sampleRate.isFinite,
           sampleRate > 0 {
            return Double(sampleCount) / sampleRate
        }
        guard let validBufferDuration,
              validBufferDuration.isFinite,
              validBufferDuration > 0 else {
            return nil
        }
        return validBufferDuration
    }

    static func values(in sampleBuffer: CMSampleBuffer) -> (
        startPTS: TimeInterval?,
        duration: TimeInterval?
    ) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let startPTS: TimeInterval?
        if presentationTime.isValid,
           presentationTime.isNumeric,
           presentationTime >= .zero {
            let seconds = CMTimeGetSeconds(presentationTime)
            startPTS = seconds.isFinite ? seconds : nil
        } else {
            startPTS = nil
        }

        let sampleRate: Double? = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?
            .pointee.mSampleRate
        let bufferDuration = CMSampleBufferGetDuration(sampleBuffer)
        let validBufferDuration: TimeInterval?
        if bufferDuration.isValid, bufferDuration.isNumeric {
            let seconds = CMTimeGetSeconds(bufferDuration)
            validBufferDuration = seconds.isFinite && seconds > 0 ? seconds : nil
        } else {
            validBufferDuration = nil
        }
        return (
            startPTS,
            duration(
                sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
                sampleRate: sampleRate,
                validBufferDuration: validBufferDuration
            )
        )
    }
}

enum TeamsCaptureViabilityAudioMeasurement {
    static func rms(in pcm: OwnedPCMBuffer) -> Double {
        var sumOfSquares = 0.0
        var sampleCount = 0
        for channel in pcm.channels {
            for sample in channel {
                guard sample.isFinite else { return 0 }
                let value = Double(sample)
                sumOfSquares += value * value
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 0 }
        return (sumOfSquares / Double(sampleCount)).squareRoot()
    }
}

enum TeamsCaptureViabilityPixelFormat: Equatable {
    case nv12
    case bgra

    var coreVideoValue: OSType {
        switch self {
        case .nv12:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .bgra:
            return kCVPixelFormatType_32BGRA
        }
    }

    var label: String {
        switch self {
        case .nv12: "NV12"
        case .bgra: "BGRA"
        }
    }
}

struct TeamsCaptureViabilityStartupAttemptSequence {
    private var nextIndex = 0
    private static let order: [TeamsCaptureViabilityPixelFormat] = [.nv12, .bgra]

    mutating func next() -> TeamsCaptureViabilityPixelFormat? {
        guard nextIndex < Self.order.count else { return nil }
        defer { nextIndex += 1 }
        return Self.order[nextIndex]
    }
}

enum TeamsCaptureViabilityDelegateStopDisposition: Equatable {
    case ignored
    case startupCandidate
    case active(shouldFinalize: Bool)
}

struct TeamsCaptureViabilityEvidenceFinalizationCoordinator {
    private var filterUpdateInFlight = false
    private var stopRequestInFlight = false
    private var finalizationRequested = false
    private var finalizationScheduled = false

    mutating func beginFilterUpdate() -> Bool {
        guard !filterUpdateInFlight else { return false }
        filterUpdateInFlight = true
        return true
    }

    mutating func finishFilterUpdate() -> Bool {
        guard filterUpdateInFlight else { return false }
        filterUpdateInFlight = false
        return scheduleIfReady()
    }

    mutating func beginStopRequest() -> Bool {
        guard !stopRequestInFlight else { return false }
        stopRequestInFlight = true
        return true
    }

    mutating func finishStopRequest() -> Bool {
        guard stopRequestInFlight else { return false }
        stopRequestInFlight = false
        return scheduleIfReady()
    }

    mutating func requestFinalization() -> Bool {
        finalizationRequested = true
        return scheduleIfReady()
    }

    private mutating func scheduleIfReady() -> Bool {
        guard finalizationRequested,
              !finalizationScheduled,
              !filterUpdateInFlight,
              !stopRequestInFlight else {
            return false
        }
        finalizationScheduled = true
        return true
    }
}

struct TeamsCaptureViabilityLifecycleCoordinator {
    private enum State {
        case idle
        case starting
        case capturing
        case finalizing
        case finalized
    }

    private var state: State = .idle
    private var nextGeneration: UInt64 = 0
    private var startupCandidateGeneration: UInt64?
    private var startupCandidateStopError: String?
    private var activeGeneration: UInt64?

    var isCapturing: Bool {
        state == .capturing
    }

    var acceptsCallbacks: Bool {
        state == .capturing || state == .finalizing
    }

    mutating func beginStart() -> Bool {
        guard state == .idle || state == .finalized else { return false }
        state = .starting
        startupCandidateGeneration = nil
        startupCandidateStopError = nil
        activeGeneration = nil
        return true
    }

    mutating func registerStartupCandidate() -> UInt64? {
        guard state == .starting, startupCandidateGeneration == nil else {
            return nil
        }
        nextGeneration &+= 1
        startupCandidateGeneration = nextGeneration
        startupCandidateStopError = nil
        return nextGeneration
    }

    mutating func recordDelegateStop(
        generation: UInt64,
        errorDescription: String
    ) -> TeamsCaptureViabilityDelegateStopDisposition {
        if startupCandidateGeneration == generation {
            if startupCandidateStopError == nil {
                startupCandidateStopError = errorDescription
            }
            return .startupCandidate
        }
        guard activeGeneration == generation else { return .ignored }
        return .active(shouldFinalize: requestFinalization())
    }

    mutating func adoptStartupCandidate(generation: UInt64) -> Bool {
        guard state == .starting,
              startupCandidateGeneration == generation,
              startupCandidateStopError == nil else {
            return false
        }
        startupCandidateGeneration = nil
        activeGeneration = generation
        state = .capturing
        return true
    }

    func startupCandidateFailure(generation: UInt64) -> String? {
        guard startupCandidateGeneration == generation else { return nil }
        return startupCandidateStopError
    }

    mutating func clearStartupCandidate(generation: UInt64) {
        guard startupCandidateGeneration == generation else { return }
        startupCandidateGeneration = nil
        startupCandidateStopError = nil
    }

    func shouldPublishCapturing(generation: UInt64) -> Bool {
        state == .capturing && activeGeneration == generation
    }

    mutating func startSucceeded() {
        guard state == .starting else { return }
        state = .capturing
    }

    mutating func startFailed() {
        guard state == .starting else { return }
        state = .idle
        startupCandidateGeneration = nil
        startupCandidateStopError = nil
        activeGeneration = nil
    }

    mutating func requestFinalization() -> Bool {
        guard state == .capturing else { return false }
        state = .finalizing
        return true
    }

    mutating func requestDelegateFinalization(isActiveStream: Bool) -> Bool {
        guard isActiveStream else { return false }
        return requestFinalization()
    }

    mutating func finishFinalization() {
        guard state == .finalizing else { return }
        state = .finalized
        activeGeneration = nil
    }
}

enum TeamsCaptureViabilityQueuePlan {
    static let systemAudio = "local-meeting-recorder.teams-viability.system-audio"
    static let microphone = "local-meeting-recorder.teams-viability.microphone"
    static let screen = "local-meeting-recorder.teams-viability.screen"
    static let evidence = "local-meeting-recorder.teams-viability.evidence"
    static let allLabels = [systemAudio, microphone, screen, evidence]
}

struct TeamsCaptureViabilityWindow: Identifiable, Hashable {
    let descriptor: TeamsCaptureWindowDescriptor
    let includesWindowID: Bool
    fileprivate let window: SCWindow

    var id: UInt32 { descriptor.windowID }

    var displayName: String {
        TeamsCaptureWindowPickerModel.displayName(
            for: descriptor,
            includesWindowID: includesWindowID
        )
    }

    func presented(includesWindowID: Bool) -> Self {
        Self(
            descriptor: descriptor,
            includesWindowID: includesWindowID,
            window: window
        )
    }
}

final class TeamsCaptureViabilityProbe: NSObject, ObservableObject {
    @Published private(set) var windows: [TeamsCaptureViabilityWindow] = []
    @Published var selectedWindowID: UInt32?
    @Published var showsAllTeamsWindows = false {
        didSet {
            guard oldValue != showsAllTeamsWindows else { return }
            rebuildWindowPicker()
        }
    }
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Refresh Teams windows before starting the probe."
    @Published private(set) var systemRMS: Double = 0
    @Published private(set) var microphoneRMS: Double = 0
    @Published private(set) var completeFrameCount = 0
    @Published private(set) var filterRevision: UInt64 = 0
    @Published private(set) var streamIdentity = "Not started"
    @Published private(set) var systemPTSGap: TimeInterval = 0
    @Published private(set) var microphonePTSGap: TimeInterval = 0

    private let systemAudioQueue = DispatchQueue(
        label: TeamsCaptureViabilityQueuePlan.systemAudio,
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: TeamsCaptureViabilityQueuePlan.microphone,
        qos: .userInitiated
    )
    private let screenQueue = DispatchQueue(
        label: TeamsCaptureViabilityQueuePlan.screen,
        qos: .userInitiated
    )
    private let evidenceQueue = DispatchQueue(
        label: TeamsCaptureViabilityQueuePlan.evidence,
        qos: .utility
    )
    private let finalizationQueue = DispatchQueue(
        label: "local-meeting-recorder.teams-viability.finalization",
        qos: .utility
    )
    private lazy var evidenceImageContext = CIContext()
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var startupCandidate: (stream: SCStream, generation: UInt64)?
    private var activeStreamGeneration: UInt64?
    private var applicationFilter: SCContentFilter?
    private var activeDwell: MutableDwell?
    private var applicationBaseline: MutableDwell?
    private var windowDwells: [MutableDwell] = []
    private var dwellsByRevision: [UInt64: MutableDwell] = [:]
    private var streamIdentities = Set<String>()
    private var observedWindowIDs = Set<UInt32>()
    private var notes: [String] = []
    private var activeFilterRevision: UInt64 = 0
    private var cycleCounter = TeamsCaptureViabilityCycleCounter()
    private var systemPTSTracker = TeamsCaptureViabilityPTSTracker(source: .system)
    private var microphonePTSTracker = TeamsCaptureViabilityPTSTracker(source: .microphone)
    private var lifecycle = TeamsCaptureViabilityLifecycleCoordinator()
    private var evidenceFinalization =
        TeamsCaptureViabilityEvidenceFinalizationCoordinator()
    private var discoveredWindows: [TeamsCaptureViabilityWindow] = []

    func refreshWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                let teamsWindows = content.windows.compactMap {
                    window -> TeamsCaptureViabilityWindow? in
                    guard window.owningApplication?.bundleIdentifier == "com.microsoft.teams2" else {
                        return nil
                    }
                    let descriptor = TeamsCaptureWindowDescriptor(
                        windowID: window.windowID,
                        title: window.title ?? "",
                        width: Int(window.frame.width.rounded()),
                        height: Int(window.frame.height.rounded()),
                        isOnScreen: window.isOnScreen,
                        windowLayer: window.windowLayer
                    )
                    return TeamsCaptureViabilityWindow(
                        descriptor: descriptor,
                        includesWindowID: false,
                        window: window
                    )
                }
                publish {
                    self.discoveredWindows = teamsWindows
                    self.rebuildWindowPicker()
                }
            } catch {
                publish {
                    self.status = "Could not enumerate Teams windows: \(error.localizedDescription)"
                }
            }
        }
    }

    private func rebuildWindowPicker() {
        let result = TeamsCaptureWindowPickerModel.makeResult(
            descriptors: discoveredWindows.map(\.descriptor),
            showAll: showsAllTeamsWindows,
            selectedWindowID: selectedWindowID
        )
        let byID = Dictionary(
            uniqueKeysWithValues: discoveredWindows.map { ($0.id, $0) }
        )
        let includesWindowID =
            showsAllTeamsWindows || result.isUsingAllWindowsFallback

        windows = result.windowIDs.compactMap {
            byID[$0]?.presented(includesWindowID: includesWindowID)
        }
        selectedWindowID = result.selectedWindowID
        status = result.status
    }

    func start() {
        let canStart = withState { lifecycle.beginStart() }
        guard canStart else {
            status = "The probe is already starting or capturing."
            return
        }
        publish {
            self.isCapturing = false
            self.status = "Starting probe with NV12 configuration."
        }
        Task {
            do {
                let activeCapture = try await startCaptureCandidate()
                publish {
                    let isCurrentCapture = self.withState {
                        self.stream === activeCapture.stream
                            && self.activeStreamGeneration == activeCapture.generation
                            && self.lifecycle.shouldPublishCapturing(
                                generation: activeCapture.generation
                            )
                    }
                    guard isCurrentCapture else { return }
                    self.isCapturing = true
                    self.streamIdentity = activeCapture.identity
                    self.status = "Application filter active on one \(activeCapture.pixelFormat.label) SCStream."
                }
            } catch {
                withState {
                    startupCandidate = nil
                    activeStreamGeneration = nil
                    stream = nil
                    applicationFilter = nil
                    lifecycle.startFailed()
                }
                publish {
                    self.isCapturing = false
                    self.status = "Could not start probe: \(error.localizedDescription)"
                }
            }
        }
    }

    func switchToSelectedWindow() {
        guard let selectedWindow = windows.first(where: { $0.id == selectedWindowID }) else {
            status = "Select a Teams window before switching filters."
            return
        }
        Task {
            do {
                try await updateFilter(
                    SCContentFilter(desktopIndependentWindow: selectedWindow.window),
                    target: .window(selectedWindow.id)
                )
            } catch {
                publish {
                    self.status = "Could not switch to window filter: \(error.localizedDescription)"
                }
            }
        }
    }

    func switchToApplication() {
        guard let filter = withState({ applicationFilter }) else {
            status = "Start the probe before switching filters."
            return
        }
        Task {
            do {
                try await updateFilter(filter, target: .application)
            } catch {
                publish {
                    self.status = "Could not switch to application filter: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        let activeStream = withState { () -> SCStream? in
            guard lifecycle.isCapturing,
                  let stream,
                  evidenceFinalization.beginStopRequest() else {
                return nil
            }
            _ = lifecycle.requestFinalization()
            _ = evidenceFinalization.requestFinalization()
            return stream
        }
        guard let activeStream else {
            status = "The viability probe is not capturing."
            return
        }
        publish {
            self.isCapturing = false
            self.status = "Stopping probe and finalizing evidence."
        }
        Task {
            var shouldFinalizeEvidence = true
            do {
                try await activeStream.stopCapture()
            } catch {
                let plan = TeamsCaptureViabilityStopFailurePlan.make(
                    errorDescription: error.localizedDescription
                )
                shouldFinalizeEvidence = plan.shouldFinalizeEvidence
                appendUniqueNote(plan.gateFailureNote)
                if plan.shouldDetachOutputs {
                    for cleanupFailure in detachOutputs(from: activeStream) {
                        appendUniqueNote(
                            "\(TeamsCaptureViabilityGateFailure.prefix) stop cleanup \(cleanupFailure)"
                        )
                    }
                }
                if plan.shouldRetireActiveStream {
                    withState {
                        guard stream === activeStream else { return }
                        stream = nil
                        activeStreamGeneration = nil
                    }
                }
            }
            guard shouldFinalizeEvidence else { return }
            let shouldSchedule = withState {
                evidenceFinalization.finishStopRequest()
            }
            if shouldSchedule {
                scheduleEvidenceFinalization()
            }
        }
    }

    private func startCaptureCandidate() async throws -> (
        stream: SCStream,
        pixelFormat: TeamsCaptureViabilityPixelFormat,
        generation: UInt64,
        identity: String
    ) {
        guard CGPreflightScreenCaptureAccess() else {
            throw TeamsCaptureViabilityProbeError.screenRecordingPermissionDenied
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw TeamsCaptureViabilityProbeError.microphonePermissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let teamsApplication = content.applications.first(where: {
            $0.bundleIdentifier == "com.microsoft.teams2"
        }), let display = content.displays.first(where: {
            $0.displayID == CGMainDisplayID()
        }) ?? content.displays.first else {
            throw TeamsCaptureViabilityProbeError.teamsApplicationUnavailable
        }
        let recorderApplication = content.applications.first { $0.processID == getpid() }
        let applications = [teamsApplication] + (recorderApplication.map { [$0] } ?? [])
        let filter = SCContentFilter(
            display: display,
            including: applications,
            exceptingWindows: []
        )
        let persistedMicrophoneUID = CaptureSelectionPersistence().loadMicrophoneUID()
        let microphoneUID = try MicrophoneDeviceResolver.resolveCurrentCaptureDeviceUID(
            coreAudioUID: persistedMicrophoneUID
        )
        var attempts = TeamsCaptureViabilityStartupAttemptSequence()
        var failures: [String] = []
        while let pixelFormat = attempts.next() {
            let configuration = makeConfiguration(
                pixelFormat: pixelFormat,
                microphoneUID: microphoneUID
            )
            let candidateStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: self
            )
            do {
                try addOutputs(to: candidateStream)
            } catch {
                failures.append("\(pixelFormat.label): \(error.localizedDescription)")
                await cleanUpFailedAttempt(candidateStream, generation: nil)
                continue
            }
            guard let generation = withState({ () -> UInt64? in
                guard let generation = lifecycle.registerStartupCandidate() else {
                    return nil
                }
                startupCandidate = (candidateStream, generation)
                return generation
            }) else {
                failures.append("\(pixelFormat.label): startup candidate registration failed")
                await cleanUpFailedAttempt(candidateStream, generation: nil)
                continue
            }

            do {
                try await candidateStream.startCapture()
            } catch {
                let callbackFailure = withState {
                    lifecycle.startupCandidateFailure(generation: generation)
                }
                var reason = "startCapture error=\(error.localizedDescription)"
                if let callbackFailure {
                    reason += " callback error=\(callbackFailure)"
                }
                failures.append("\(pixelFormat.label): \(reason)")
                await cleanUpFailedAttempt(
                    candidateStream,
                    generation: generation
                )
                continue
            }

            let adoption = withState { () -> (identity: String?, failure: String?) in
                guard let registration = startupCandidate,
                      registration.stream === candidateStream,
                      registration.generation == generation else {
                    return (nil, "startup candidate registration was lost")
                }
                let callbackFailure = lifecycle.startupCandidateFailure(
                    generation: generation
                )
                guard lifecycle.adoptStartupCandidate(generation: generation) else {
                    return (
                        nil,
                        callbackFailure.map {
                            "callback stopped before adoption error=\($0)"
                        } ?? "startup candidate could not be adopted"
                    )
                }
                startupCandidate = nil
                stream = candidateStream
                activeStreamGeneration = generation
                applicationFilter = filter
                resetEvidence(stream: candidateStream)
                return (identity(of: candidateStream), nil)
            }
            if let identity = adoption.identity {
                return (candidateStream, pixelFormat, generation, identity)
            }
            failures.append(
                "\(pixelFormat.label): \(adoption.failure ?? "startup candidate could not be adopted")"
            )
            await cleanUpFailedAttempt(candidateStream, generation: generation)
        }
        throw TeamsCaptureViabilityProbeError.startupAttemptsFailed(failures)
    }

    private func makeConfiguration(
        pixelFormat: TeamsCaptureViabilityPixelFormat,
        microphoneUID: String?
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = Int(SampleBufferConverter.outputSampleRate)
        configuration.channelCount = 2
        configuration.microphoneCaptureDeviceID = microphoneUID
        configuration.width = 1600
        configuration.height = 900
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.pixelFormat = pixelFormat.coreVideoValue
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true
        configuration.backgroundColor = .black
        configuration.showsCursor = false
        configuration.excludesCurrentProcessAudio = true
        return configuration
    }

    private func addOutputs(to stream: SCStream) throws {
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: systemAudioQueue
        )
        try stream.addStreamOutput(
            self,
            type: .microphone,
            sampleHandlerQueue: microphoneQueue
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: screenQueue
        )
    }

    private func cleanUpFailedAttempt(
        _ stream: SCStream,
        generation: UInt64?
    ) async {
        _ = detachOutputs(from: stream)
        try? await stream.stopCapture()
        guard let generation else { return }
        withState {
            if let registration = startupCandidate,
               registration.stream === stream,
               registration.generation == generation {
                startupCandidate = nil
            }
            lifecycle.clearStartupCandidate(generation: generation)
        }
    }

    private func detachOutputs(from stream: SCStream) -> [String] {
        var failures: [String] = []
        do {
            try stream.removeStreamOutput(self, type: .audio)
        } catch {
            failures.append("system-audio error=\(error.localizedDescription)")
        }
        do {
            try stream.removeStreamOutput(self, type: .microphone)
        } catch {
            failures.append("microphone error=\(error.localizedDescription)")
        }
        do {
            try stream.removeStreamOutput(self, type: .screen)
        } catch {
            failures.append("screen error=\(error.localizedDescription)")
        }
        return failures
    }

    private func updateFilter(
        _ filter: SCContentFilter,
        target: TeamsCaptureViabilityFilterTarget
    ) async throws {
        let preparation = withState {
            () -> (stream: SCStream?, attemptedRevision: UInt64?, message: String?) in
            guard lifecycle.isCapturing, let stream else {
                return (nil, nil, "The viability probe is not running.")
            }
            guard cycleCounter.shouldUpdateFilter(to: target) else {
                return (
                    nil,
                    nil,
                    "The requested filter is already active; no round trip was counted."
                )
            }
            guard evidenceFinalization.beginFilterUpdate() else {
                return (nil, nil, "Another filter update is already in progress.")
            }
            return (stream, activeFilterRevision &+ 1, nil)
        }
        guard let activeStream = preparation.stream,
              let attemptedRevision = preparation.attemptedRevision else {
            if let message = preparation.message {
                publish { self.status = message }
            }
            return
        }

        do {
            try await activeStream.updateContentFilter(filter)
        } catch {
            let shouldSchedule = withState {
                appendUniqueNoteLocked(
                    TeamsCaptureViabilityGateFailure.filterUpdate(
                        target: target,
                        attemptedRevision: attemptedRevision,
                        errorDescription: error.localizedDescription
                    )
                )
                return evidenceFinalization.finishFilterUpdate()
            }
            if shouldSchedule {
                scheduleEvidenceFinalization()
            }
            throw error
        }

        let outcome = withState {
            () -> (revision: UInt64?, shouldScheduleFinalization: Bool) in
            let revision: UInt64?
            if stream === activeStream, lifecycle.isCapturing {
                finishActiveDwell(at: Date())
                cycleCounter.recordSuccessfulSelection(target)
                activeFilterRevision = attemptedRevision
                let windowID: UInt32?
                if case let .window(id) = target {
                    windowID = id
                    observedWindowIDs.insert(id)
                } else {
                    windowID = nil
                }
                let dwell = MutableDwell(
                    filterRevision: activeFilterRevision,
                    windowID: windowID,
                    streamIdentity: identity(of: activeStream)
                )
                activeDwell = dwell
                dwellsByRevision[activeFilterRevision] = dwell
                revision = activeFilterRevision
            } else {
                revision = nil
            }
            return (
                revision,
                evidenceFinalization.finishFilterUpdate()
            )
        }
        if outcome.shouldScheduleFinalization {
            scheduleEvidenceFinalization()
        }
        guard let revision = outcome.revision else {
            throw TeamsCaptureViabilityProbeError.streamNotRunning
        }
        publish {
            self.filterRevision = revision
            self.completeFrameCount = 0
            self.systemPTSGap = 0
            self.microphonePTSGap = 0
            self.status = target == .application
                ? "Application filter active; completed round trips: \(self.completedRoundTrips)."
                : "Window filter active on the original SCStream."
        }
    }

    private var completedRoundTrips: Int {
        withState { cycleCounter.completedRoundTrips }
    }

    private func receiveAudio(
        _ sampleBuffer: CMSampleBuffer,
        source: AudioSourceKind,
        from callbackStream: SCStream
    ) {
        guard let revision = activeRevision(accepting: callbackStream) else { return }
        let rawTiming = TeamsCaptureViabilityAudioTiming.values(in: sampleBuffer)
        let rms: Double
        let startPTS: TimeInterval?
        let duration: TimeInterval?
        var measurementDiagnostic: String?
        do {
            let packet = try SampleBufferConverter.copy(sampleBuffer)
            rms = TeamsCaptureViabilityAudioMeasurement.rms(in: packet.pcm)
            startPTS = CMTimeGetSeconds(packet.presentationTime)
            duration = TeamsCaptureViabilityAudioTiming.duration(
                sampleCount: packet.pcm.frameCount,
                sampleRate: packet.pcm.sampleRate,
                validBufferDuration: rawTiming.duration
            )
        } catch {
            rms = 0
            startPTS = rawTiming.startPTS
            duration = rawTiming.duration
            measurementDiagnostic = "Audio measurement diagnostic: \(source.viabilityLabel) filter revision \(revision): \(error)."
        }

        let metrics = withState { () -> LiveMetrics? in
            guard let dwell = dwellsByRevision[revision] else { return nil }
            let observation: TeamsCaptureViabilityPTSObservation
            switch source {
            case .system:
                observation = systemPTSTracker.observe(
                    startPTS: startPTS,
                    duration: duration,
                    filterRevision: revision
                )
            case .microphone:
                observation = microphonePTSTracker.observe(
                    startPTS: startPTS,
                    duration: duration,
                    filterRevision: revision
                )
            }
            dwell.recordAudio(
                source: source,
                rms: rms,
                unexplainedGap: observation.unexplainedGap
            )
            if observation.unexplainedGap
                > TeamsCaptureViabilityGateFailure.maximumAllowedAudioGap {
                appendUniqueNoteLocked(
                    TeamsCaptureViabilityGateFailure.audioGap(
                        source: source,
                        filterRevision: revision,
                        unexplainedGap: observation.unexplainedGap
                    )
                )
            }
            if let diagnostic = observation.diagnostic {
                appendUniqueNoteLocked(diagnostic)
            }
            if let measurementDiagnostic {
                appendUniqueNoteLocked(measurementDiagnostic)
            }
            return activeDwell?.filterRevision == revision ? dwell.liveMetrics : nil
        }
        if let metrics {
            publish(metrics)
        }
    }

    private func receiveScreen(
        _ sampleBuffer: CMSampleBuffer,
        from callbackStream: SCStream
    ) {
        guard TeamsCaptureViabilityFrame.isComplete(sampleBuffer),
              let revision = activeRevision(accepting: callbackStream) else {
            return
        }
        let state = withState { () -> (LiveMetrics?, Bool) in
            guard let dwell = dwellsByRevision[revision] else { return (nil, false) }
            let shouldEncode = dwell.recordCompleteFrameAndReserveEvidence()
            let metrics = activeDwell?.filterRevision == revision
                ? dwell.liveMetrics
                : nil
            return (metrics, shouldEncode)
        }
        if let metrics = state.0 {
            publish(metrics)
        }
        guard state.1 else { return }
        guard let copiedPixelBuffer = TeamsCaptureViabilityFrame.copyPixelBuffer(
            from: sampleBuffer
        ) else {
            frameEvidenceFailed(
                revision: revision,
                diagnostic: "Frame evidence diagnostic: Could not copy complete frame for revision \(revision)."
            )
            return
        }
        evidenceQueue.async { [weak self] in
            guard let self else { return }
            guard let pngData = TeamsCaptureViabilityFrame.pngData(
                from: copiedPixelBuffer,
                context: self.evidenceImageContext
            ) else {
                self.frameEvidenceFailed(
                    revision: revision,
                    diagnostic: "Frame evidence diagnostic: Could not encode PNG for revision \(revision)."
                )
                return
            }
            self.withState {
                self.dwellsByRevision[revision]?.setFramePNGData(pngData)
            }
        }
    }

    private func frameEvidenceFailed(revision: UInt64, diagnostic: String) {
        withState {
            dwellsByRevision[revision]?.cancelFrameEvidenceReservation()
            appendUniqueNoteLocked(diagnostic)
        }
    }

    private func activeRevision(accepting callbackStream: SCStream) -> UInt64? {
        withState {
            guard stream === callbackStream,
                  lifecycle.acceptsCallbacks else {
                return nil
            }
            return activeDwell?.filterRevision
        }
    }

    private func scheduleEvidenceFinalization() {
        finalizationQueue.async { [weak self] in
            guard let self else { return }
            self.systemAudioQueue.sync {}
            self.microphoneQueue.sync {}
            self.screenQueue.sync {}
            self.evidenceQueue.async { [weak self] in
                self?.persistEvidenceExactlyOnce()
            }
        }
    }

    private func requestEvidenceFinalization() {
        let shouldSchedule = withState {
            evidenceFinalization.requestFinalization()
        }
        if shouldSchedule {
            scheduleEvidenceFinalization()
        }
    }

    private func persistEvidenceExactlyOnce() {
        let snapshot = withState { () -> EvidenceSnapshot? in
            guard !lifecycle.isCapturing, lifecycle.acceptsCallbacks else {
                return nil
            }
            finishActiveDwell(at: Date())
            let baseline = applicationBaseline?.snapshot()
                ?? MutableDwell.empty.snapshot()
            let snapshot = EvidenceSnapshot(
                streamIdentities: streamIdentities,
                completedRoundTrips: cycleCounter.completedRoundTrips,
                applicationBaseline: baseline,
                windowDwells: windowDwells.map { $0.snapshot() },
                observedWindowIDs: observedWindowIDs,
                notes: notes
            )
            startupCandidate = nil
            activeStreamGeneration = nil
            stream = nil
            applicationFilter = nil
            activeDwell = nil
            evidenceFinalization =
                TeamsCaptureViabilityEvidenceFinalizationCoordinator()
            lifecycle.finishFinalization()
            return snapshot
        }
        guard let snapshot else { return }

        do {
            let directory = Self.evidenceDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var persistenceNotes = snapshot.notes
            let windowReports = snapshot.windowDwells.map { dwell -> TeamsCaptureViabilityDwell in
                let pngPath: String?
                if let data = dwell.framePNGData {
                    let url = directory.appendingPathComponent(
                        "window-\(dwell.windowID ?? 0)-revision-\(dwell.filterRevision).png"
                    )
                    do {
                        try data.write(to: url, options: .atomic)
                        pngPath = url.path
                    } catch {
                        pngPath = nil
                        persistenceNotes.append(
                            "PNG write failed for revision \(dwell.filterRevision): \(error.localizedDescription)"
                        )
                    }
                } else {
                    pngPath = nil
                }
                return dwell.report(capturedFramePNG: pngPath)
            }
            let report = TeamsCaptureViabilityReport(
                streamIdentities: snapshot.streamIdentities,
                filterTransitionCount: snapshot.completedRoundTrips,
                applicationBaseline: snapshot.applicationBaseline.report(
                    capturedFramePNG: nil
                ),
                windowFilterDwells: windowReports,
                observedWindowIDs: snapshot.observedWindowIDs,
                notes: persistenceNotes
            )
            let reportURL = directory.appendingPathComponent(
                "teams-screen-capture-viability-report.json"
            )
            try JSONEncoder.pretty.encode(report).write(to: reportURL, options: .atomic)
            publish {
                self.isCapturing = false
                self.status = "Saved pending live evidence to \(reportURL.path)."
            }
        } catch {
            publish {
                self.isCapturing = false
                self.status = "Probe stopped, but evidence could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func resetEvidence(stream: SCStream) {
        let identity = identity(of: stream)
        streamIdentities = [identity]
        observedWindowIDs = []
        notes = []
        activeFilterRevision = 0
        cycleCounter = TeamsCaptureViabilityCycleCounter()
        systemPTSTracker = TeamsCaptureViabilityPTSTracker(source: .system)
        microphonePTSTracker = TeamsCaptureViabilityPTSTracker(source: .microphone)
        let baseline = MutableDwell(
            filterRevision: 0,
            windowID: nil,
            streamIdentity: identity
        )
        applicationBaseline = baseline
        activeDwell = baseline
        windowDwells = []
        dwellsByRevision = [0: baseline]
        evidenceFinalization =
            TeamsCaptureViabilityEvidenceFinalizationCoordinator()
        publish {
            self.filterRevision = 0
            self.systemRMS = 0
            self.microphoneRMS = 0
            self.completeFrameCount = 0
            self.systemPTSGap = 0
            self.microphonePTSGap = 0
        }
    }

    private func finishActiveDwell(at date: Date) {
        guard let activeDwell, activeDwell.stop(at: date) else { return }
        if activeDwell.windowID != nil {
            windowDwells.append(activeDwell)
        }
    }

    private func appendUniqueNote(_ note: String) {
        withState { appendUniqueNoteLocked(note) }
    }

    private func appendUniqueNoteLocked(_ note: String) {
        guard !notes.contains(note) else { return }
        notes.append(note)
    }

    private func identity(of stream: SCStream) -> String {
        String(UInt(bitPattern: ObjectIdentifier(stream)))
    }

    private static func evidenceDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeamsCaptureViability", isDirectory: true)
    }

    private func publish(_ metrics: LiveMetrics) {
        publish {
            self.systemRMS = metrics.systemRMS
            self.microphoneRMS = metrics.microphoneRMS
            self.completeFrameCount = metrics.completeFrameCount
            self.systemPTSGap = metrics.systemPTSGap
            self.microphonePTSGap = metrics.microphonePTSGap
        }
    }

    private func publish(_ update: @escaping () -> Void) {
        DispatchQueue.main.async(execute: update)
    }

    private func withState<T>(_ work: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return work()
    }
}

extension TeamsCaptureViabilityProbe: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .audio:
            receiveAudio(sampleBuffer, source: .system, from: stream)
        case .microphone:
            receiveAudio(sampleBuffer, source: .microphone, from: stream)
        case .screen:
            receiveScreen(sampleBuffer, from: stream)
        @unknown default:
            break
        }
    }
}

extension TeamsCaptureViabilityProbe: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let decision = withState {
            () -> TeamsCaptureViabilityDelegateStopDisposition in
            if let registration = startupCandidate,
               registration.stream === stream {
                return lifecycle.recordDelegateStop(
                    generation: registration.generation,
                    errorDescription: error.localizedDescription
                )
            }
            guard self.stream === stream,
                  let generation = activeStreamGeneration else {
                return .ignored
            }
            let decision = lifecycle.recordDelegateStop(
                generation: generation,
                errorDescription: error.localizedDescription
            )
            if case .active = decision {
                appendUniqueNoteLocked(
                    "Callback stopped: \(error.localizedDescription)"
                )
            }
            return decision
        }
        guard case let .active(shouldFinalize) = decision else { return }
        publish {
            self.isCapturing = false
            self.status = "Callback stopped: \(error.localizedDescription)"
        }
        if shouldFinalize {
            requestEvidenceFinalization()
        }
    }
}

private struct LiveMetrics {
    let systemRMS: Double
    let microphoneRMS: Double
    let completeFrameCount: Int
    let systemPTSGap: TimeInterval
    let microphonePTSGap: TimeInterval
}

private final class MutableDwell {
    static let empty = MutableDwell(
        filterRevision: 0,
        windowID: nil,
        streamIdentity: "not-started"
    )

    let filterRevision: UInt64
    let windowID: UInt32?
    let streamIdentity: String
    private let startedAt = Date()
    private var stoppedAt: Date?
    private var completeScreenFrameCount = 0
    private var nonSilentSystemBufferCount = 0
    private var nonSilentMicrophoneBufferCount = 0
    private var maximumSystemPTSGap: TimeInterval = 0
    private var maximumMicrophonePTSGap: TimeInterval = 0
    private var latestSystemRMS: Double = 0
    private var latestMicrophoneRMS: Double = 0
    private var frameEvidenceReserved = false
    private var framePNGData: Data?

    init(filterRevision: UInt64, windowID: UInt32?, streamIdentity: String) {
        self.filterRevision = filterRevision
        self.windowID = windowID
        self.streamIdentity = streamIdentity
    }

    var liveMetrics: LiveMetrics {
        LiveMetrics(
            systemRMS: latestSystemRMS,
            microphoneRMS: latestMicrophoneRMS,
            completeFrameCount: completeScreenFrameCount,
            systemPTSGap: maximumSystemPTSGap,
            microphonePTSGap: maximumMicrophonePTSGap
        )
    }

    func recordAudio(
        source: AudioSourceKind,
        rms: Double,
        unexplainedGap: TimeInterval
    ) {
        switch source {
        case .system:
            latestSystemRMS = rms
            if rms > 0.001 { nonSilentSystemBufferCount += 1 }
            maximumSystemPTSGap = max(maximumSystemPTSGap, unexplainedGap)
        case .microphone:
            latestMicrophoneRMS = rms
            if rms > 0.001 { nonSilentMicrophoneBufferCount += 1 }
            maximumMicrophonePTSGap = max(maximumMicrophonePTSGap, unexplainedGap)
        }
    }

    func recordCompleteFrameAndReserveEvidence() -> Bool {
        completeScreenFrameCount += 1
        guard windowID != nil,
              framePNGData == nil,
              !frameEvidenceReserved else {
            return false
        }
        frameEvidenceReserved = true
        return true
    }

    func setFramePNGData(_ data: Data) {
        framePNGData = data
        frameEvidenceReserved = false
    }

    func cancelFrameEvidenceReservation() {
        frameEvidenceReserved = false
    }

    @discardableResult
    func stop(at date: Date) -> Bool {
        guard stoppedAt == nil else { return false }
        stoppedAt = date
        return true
    }

    func snapshot() -> MutableDwellSnapshot {
        MutableDwellSnapshot(
            filterRevision: filterRevision,
            windowID: windowID,
            duration: (stoppedAt ?? Date()).timeIntervalSince(startedAt),
            streamIdentity: streamIdentity,
            completeScreenFrameCount: completeScreenFrameCount,
            nonSilentSystemBufferCount: nonSilentSystemBufferCount,
            nonSilentMicrophoneBufferCount: nonSilentMicrophoneBufferCount,
            maximumSystemPTSGap: maximumSystemPTSGap,
            maximumMicrophonePTSGap: maximumMicrophonePTSGap,
            framePNGData: framePNGData
        )
    }
}

private struct MutableDwellSnapshot {
    let filterRevision: UInt64
    let windowID: UInt32?
    let duration: TimeInterval
    let streamIdentity: String
    let completeScreenFrameCount: Int
    let nonSilentSystemBufferCount: Int
    let nonSilentMicrophoneBufferCount: Int
    let maximumSystemPTSGap: TimeInterval
    let maximumMicrophonePTSGap: TimeInterval
    let framePNGData: Data?

    func report(capturedFramePNG: String?) -> TeamsCaptureViabilityDwell {
        TeamsCaptureViabilityDwell(
            filterRevision: filterRevision,
            windowID: windowID,
            duration: duration,
            streamIdentity: streamIdentity,
            completeScreenFrameCount: completeScreenFrameCount,
            nonSilentSystemBufferCount: nonSilentSystemBufferCount,
            nonSilentMicrophoneBufferCount: nonSilentMicrophoneBufferCount,
            maximumSystemPTSGap: maximumSystemPTSGap,
            maximumMicrophonePTSGap: maximumMicrophonePTSGap,
            capturedFramePNG: capturedFramePNG
        )
    }
}

private struct EvidenceSnapshot {
    let streamIdentities: Set<String>
    let completedRoundTrips: Int
    let applicationBaseline: MutableDwellSnapshot
    let windowDwells: [MutableDwellSnapshot]
    let observedWindowIDs: Set<UInt32>
    let notes: [String]
}

private enum TeamsCaptureViabilityFrame {
    static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let status = attachments.first?[.status] as? Int else {
            return false
        }
        return status == SCFrameStatus.complete.rawValue
    }

    static func copyPixelBuffer(from sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            nil,
            &destination
        ) == kCVReturnSuccess,
        let destination else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let sourcePlaneCount = CVPixelBufferGetPlaneCount(source)
        guard sourcePlaneCount == CVPixelBufferGetPlaneCount(destination) else {
            return nil
        }
        if sourcePlaneCount == 0 {
            guard let sourceBase = CVPixelBufferGetBaseAddress(source),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination) else {
                return nil
            }
            copyRows(
                source: sourceBase,
                sourceBytesPerRow: CVPixelBufferGetBytesPerRow(source),
                destination: destinationBase,
                destinationBytesPerRow: CVPixelBufferGetBytesPerRow(destination),
                rowCount: min(
                    CVPixelBufferGetHeight(source),
                    CVPixelBufferGetHeight(destination)
                )
            )
        } else {
            for plane in 0..<sourcePlaneCount {
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(
                        destination,
                        plane
                      ) else {
                    return nil
                }
                copyRows(
                    source: sourceBase,
                    sourceBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                    destination: destinationBase,
                    destinationBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(
                        destination,
                        plane
                    ),
                    rowCount: min(
                        CVPixelBufferGetHeightOfPlane(source, plane),
                        CVPixelBufferGetHeightOfPlane(destination, plane)
                    )
                )
            }
        }
        return destination
    }

    static func pngData(from pixelBuffer: CVPixelBuffer, context: CIContext) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:])
    }

    private static func copyRows(
        source: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        rowCount: Int
    ) {
        let byteCount = min(sourceBytesPerRow, destinationBytesPerRow)
        for row in 0..<rowCount {
            destination
                .advanced(by: row * destinationBytesPerRow)
                .copyMemory(
                    from: source.advanced(by: row * sourceBytesPerRow),
                    byteCount: byteCount
                )
        }
    }
}

private enum TeamsCaptureViabilityProbeError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case teamsApplicationUnavailable
    case streamNotRunning
    case startupAttemptsFailed([String])

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "Screen & System Audio Recording permission is required."
        case .microphonePermissionDenied:
            return "Microphone permission is required."
        case .teamsApplicationUnavailable:
            return "No running com.microsoft.teams2 application was found."
        case .streamNotRunning:
            return "The viability probe is not running."
        case let .startupAttemptsFailed(failures):
            return "NV12 and BGRA startup attempts failed: \(failures.joined(separator: "; "))."
        }
    }
}

private extension AudioSourceKind {
    var viabilityLabel: String {
        switch self {
        case .system: "system"
        case .microphone: "microphone"
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
