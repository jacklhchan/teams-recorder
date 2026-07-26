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
    private static let maximumPTSGap: TimeInterval = 0.250

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

struct TeamsCaptureViabilityLifecycleCoordinator {
    private enum State {
        case idle
        case starting
        case capturing
        case finalizing
        case finalized
    }

    private var state: State = .idle

    var isCapturing: Bool {
        state == .capturing
    }

    var acceptsCallbacks: Bool {
        state == .capturing || state == .finalizing
    }

    mutating func beginStart() -> Bool {
        guard state == .idle || state == .finalized else { return false }
        state = .starting
        return true
    }

    mutating func startSucceeded() {
        guard state == .starting else { return }
        state = .capturing
    }

    mutating func startFailed() {
        guard state == .starting else { return }
        state = .idle
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
    let id: UInt32
    let title: String
    fileprivate let window: SCWindow

    var displayName: String {
        title.isEmpty ? "Teams window \(id)" : "\(title) (\(id))"
    }
}

final class TeamsCaptureViabilityProbe: NSObject, ObservableObject {
    @Published private(set) var windows: [TeamsCaptureViabilityWindow] = []
    @Published var selectedWindowID: UInt32?
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
    private var filterUpdateInFlight = false

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
                    return TeamsCaptureViabilityWindow(
                        id: window.windowID,
                        title: window.title ?? "",
                        window: window
                    )
                }
                .sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                        == .orderedAscending
                }
                publish {
                    self.windows = teamsWindows
                    if !teamsWindows.contains(where: { $0.id == self.selectedWindowID }) {
                        self.selectedWindowID = teamsWindows.first?.id
                    }
                    self.status = teamsWindows.isEmpty
                        ? "No windows owned by com.microsoft.teams2 were found."
                        : "Select a Teams window, then start the standalone probe."
                }
            } catch {
                publish {
                    self.status = "Could not enumerate Teams windows: \(error.localizedDescription)"
                }
            }
        }
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
                let candidate = try await startCaptureCandidate()
                let identity = withState { () -> String in
                    resetEvidence(stream: candidate.stream)
                    stream = candidate.stream
                    applicationFilter = candidate.applicationFilter
                    lifecycle.startSucceeded()
                    return self.identity(of: candidate.stream)
                }
                publish {
                    self.isCapturing = true
                    self.streamIdentity = identity
                    self.status = "Application filter active on one \(candidate.pixelFormat.label) SCStream."
                }
            } catch {
                withState {
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
            guard lifecycle.requestFinalization() else { return nil }
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
            do {
                try await activeStream.stopCapture()
            } catch {
                appendUniqueNote("Stop request error: \(error.localizedDescription)")
            }
            scheduleEvidenceFinalization()
        }
    }

    private func startCaptureCandidate() async throws -> (
        stream: SCStream,
        applicationFilter: SCContentFilter,
        pixelFormat: TeamsCaptureViabilityPixelFormat
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
                try await candidateStream.startCapture()
                return (candidateStream, filter, pixelFormat)
            } catch {
                failures.append("\(pixelFormat.label): \(error.localizedDescription)")
                await cleanUpFailedAttempt(candidateStream)
            }
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

    private func cleanUpFailedAttempt(_ stream: SCStream) async {
        try? stream.removeStreamOutput(self, type: .audio)
        try? stream.removeStreamOutput(self, type: .microphone)
        try? stream.removeStreamOutput(self, type: .screen)
        try? await stream.stopCapture()
    }

    private func updateFilter(
        _ filter: SCContentFilter,
        target: TeamsCaptureViabilityFilterTarget
    ) async throws {
        let preparation = withState { () -> (SCStream?, String?) in
            guard lifecycle.isCapturing, let stream else {
                return (nil, "The viability probe is not running.")
            }
            guard !filterUpdateInFlight else {
                return (nil, "Another filter update is already in progress.")
            }
            guard cycleCounter.shouldUpdateFilter(to: target) else {
                return (nil, "The requested filter is already active; no round trip was counted.")
            }
            filterUpdateInFlight = true
            return (stream, nil)
        }
        guard let activeStream = preparation.0 else {
            if let message = preparation.1 {
                publish { self.status = message }
            }
            return
        }

        do {
            try await activeStream.updateContentFilter(filter)
            let revision = withState { () -> UInt64? in
                defer { filterUpdateInFlight = false }
                guard stream === activeStream, lifecycle.isCapturing else {
                    return nil
                }
                finishActiveDwell(at: Date())
                cycleCounter.recordSuccessfulSelection(target)
                activeFilterRevision &+= 1
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
                return activeFilterRevision
            }
            guard let revision else {
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
        } catch {
            withState { filterUpdateInFlight = false }
            throw error
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
            stream = nil
            applicationFilter = nil
            activeDwell = nil
            filterUpdateInFlight = false
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
        filterUpdateInFlight = false
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
        let decision = withState { () -> (isActiveStream: Bool, shouldFinalize: Bool) in
            let isActiveStream = self.stream === stream
            guard isActiveStream else { return (false, false) }
            appendUniqueNoteLocked("Callback stopped: \(error.localizedDescription)")
            return (
                true,
                lifecycle.requestDelegateFinalization(isActiveStream: true)
            )
        }
        guard decision.isActiveStream else { return }
        publish {
            self.isCapturing = false
            self.status = "Callback stopped: \(error.localizedDescription)"
        }
        if decision.shouldFinalize {
            scheduleEvidenceFinalization()
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
