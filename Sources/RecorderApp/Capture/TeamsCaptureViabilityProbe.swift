@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AudioToolbox
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
        if report.streamIdentities.count != 1 {
            failures.append("Expected exactly one stream identity.")
        }
        if report.filterTransitionCount < 4 {
            failures.append("Expected at least four application-window-application filter transitions.")
        }
        if report.windowFilterDwells.isEmpty {
            failures.append("No window-filter dwell was recorded.")
        }
        if report.notes.contains(where: { $0.localizedCaseInsensitiveContains("callback stopped") }) {
            failures.append("A capture callback stopped during the probe.")
        }

        for dwell in report.windowFilterDwells {
            let label = "Window dwell revision \(dwell.filterRevision)"
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

    private let callbackQueue = DispatchQueue(
        label: "local-meeting-recorder.teams-viability.callbacks",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var applicationFilter: SCContentFilter?
    private var activeDwell: MutableDwell?
    private var applicationBaseline: MutableDwell?
    private var windowDwells: [MutableDwell] = []
    private var streamIdentities = Set<String>()
    private var observedWindowIDs = Set<UInt32>()
    private var filterTransitionCount = 0
    private var notes: [String] = []
    private var activeFilterRevision: UInt64 = 0

    func refreshWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                let teamsWindows = content.windows.compactMap { window -> TeamsCaptureViabilityWindow? in
                    guard window.owningApplication?.bundleIdentifier == "com.microsoft.teams2" else {
                        return nil
                    }
                    return TeamsCaptureViabilityWindow(
                        id: window.windowID,
                        title: window.title ?? "",
                        window: window
                    )
                }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
                publish { self.status = "Could not enumerate Teams windows: \(error.localizedDescription)" }
            }
        }
    }

    func start() {
        Task {
            do {
                try await startCapture()
            } catch {
                publish { self.status = "Could not start probe: \(error.localizedDescription)" }
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
                    windowID: selectedWindow.id
                )
            } catch {
                publish { self.status = "Could not switch to window filter: \(error.localizedDescription)" }
            }
        }
    }

    func switchToApplication() {
        guard let applicationFilter else {
            status = "Start the probe before switching filters."
            return
        }
        Task {
            do {
                try await updateFilter(applicationFilter, windowID: nil)
            } catch {
                publish { self.status = "Could not switch to application filter: \(error.localizedDescription)" }
            }
        }
    }

    func stop() {
        Task {
            let activeStream = withState { stream }
            do {
                try await activeStream?.stopCapture()
            } catch {
                record(note: "Stop request error: \(error.localizedDescription)")
            }
            finalizeAndSaveEvidence()
        }
    }

    private func startCapture() async throws {
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
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.width = 1600
        configuration.height = 900
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.preservesAspectRatio = true
        configuration.backgroundColor = .black
        configuration.showsCursor = false
        configuration.excludesCurrentProcessAudio = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: callbackQueue)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callbackQueue)

        withState {
            resetEvidence(stream: newStream)
            stream = newStream
            applicationFilter = filter
        }
        publish {
            self.isCapturing = true
            self.status = "Application filter active on one SCStream."
        }
        try await newStream.startCapture()
    }

    private func updateFilter(_ filter: SCContentFilter, windowID: UInt32?) async throws {
        let activeStream = withState { stream }
        guard let activeStream else { throw TeamsCaptureViabilityProbeError.streamNotRunning }
        try await activeStream.updateContentFilter(filter)
        let revision = withState { () -> UInt64 in
            finishActiveDwell(at: Date())
            activeFilterRevision &+= 1
            filterTransitionCount += 1
            activeDwell = MutableDwell(
                filterRevision: activeFilterRevision,
                windowID: windowID,
                streamIdentity: identity(of: activeStream)
            )
            if let windowID { observedWindowIDs.insert(windowID) }
            return activeFilterRevision
        }
        publish {
            self.filterRevision = revision
            self.completeFrameCount = 0
            self.status = windowID == nil
                ? "Application filter active on the original SCStream."
                : "Window filter active on the original SCStream."
        }
    }

    private func receive(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream != nil else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let pts = timestamp.isValid ? CMTimeGetSeconds(timestamp) : nil
        switch type {
        case .audio:
            let rms = TeamsCaptureViabilityAudioRMS.value(in: sampleBuffer)
            activeDwell?.recordSystemAudio(rms: rms, pts: pts)
            publishMetricsLocked()
        case .microphone:
            let rms = TeamsCaptureViabilityAudioRMS.value(in: sampleBuffer)
            activeDwell?.recordMicrophoneAudio(rms: rms, pts: pts)
            publishMetricsLocked()
        case .screen:
            guard TeamsCaptureViabilityFrame.isComplete(sampleBuffer) else { return }
            activeDwell?.recordCompleteFrame(sampleBuffer)
            publishMetricsLocked()
        @unknown default:
            break
        }
    }

    private func finalizeAndSaveEvidence() {
        do {
            let directory = Self.evidenceDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let report = withState { () -> TeamsCaptureViabilityReport in
                finishActiveDwell(at: Date())
                let report = makeReportLocked(savingTo: directory)
                stream = nil
                applicationFilter = nil
                return report
            }
            let reportURL = directory.appendingPathComponent("teams-screen-capture-viability-report.json")
            let data = try JSONEncoder.pretty.encode(report)
            try data.write(to: reportURL, options: .atomic)
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
        filterTransitionCount = 0
        notes = []
        activeFilterRevision = 0
        applicationBaseline = MutableDwell(filterRevision: 0, windowID: nil, streamIdentity: identity)
        activeDwell = applicationBaseline
        windowDwells = []
        publish {
            self.streamIdentity = identity
            self.filterRevision = 0
            self.systemRMS = 0
            self.microphoneRMS = 0
            self.completeFrameCount = 0
            self.systemPTSGap = 0
            self.microphonePTSGap = 0
        }
    }

    private func finishActiveDwell(at date: Date) {
        guard let activeDwell else { return }
        activeDwell.stop(at: date)
        if activeDwell.windowID != nil {
            windowDwells.append(activeDwell)
        }
    }

    private func makeReportLocked(savingTo directory: URL) -> TeamsCaptureViabilityReport {
        let baseline = applicationBaseline?.report(savingPNGTo: directory) ?? MutableDwell.empty.report(savingPNGTo: directory)
        return TeamsCaptureViabilityReport(
            streamIdentities: streamIdentities,
            filterTransitionCount: filterTransitionCount,
            applicationBaseline: baseline,
            windowFilterDwells: windowDwells.map { $0.report(savingPNGTo: directory) },
            observedWindowIDs: observedWindowIDs,
            notes: notes
        )
    }

    private func publishMetricsLocked() {
        let dwell = activeDwell
        publish {
            self.systemRMS = dwell?.latestSystemRMS ?? 0
            self.microphoneRMS = dwell?.latestMicrophoneRMS ?? 0
            self.completeFrameCount = dwell?.completeScreenFrameCount ?? 0
            self.systemPTSGap = dwell?.maximumSystemPTSGap ?? 0
            self.microphonePTSGap = dwell?.maximumMicrophonePTSGap ?? 0
        }
    }

    private func record(note: String) {
        stateLock.lock()
        notes.append(note)
        stateLock.unlock()
        publish { self.status = note }
    }

    private func identity(of stream: SCStream) -> String {
        String(UInt(bitPattern: ObjectIdentifier(stream)))
    }

    private static func evidenceDirectory() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeamsCaptureViability", isDirectory: true)
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
        receive(sampleBuffer, type: type)
    }
}

extension TeamsCaptureViabilityProbe: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        record(note: "Callback stopped: \(error.localizedDescription)")
    }
}

private final class MutableDwell {
    static let empty = MutableDwell(filterRevision: 0, windowID: nil, streamIdentity: "not-started")

    let filterRevision: UInt64
    let windowID: UInt32?
    let streamIdentity: String
    let startedAt = Date()
    private var stoppedAt: Date?
    private(set) var completeScreenFrameCount = 0
    private(set) var nonSilentSystemBufferCount = 0
    private(set) var nonSilentMicrophoneBufferCount = 0
    private(set) var maximumSystemPTSGap: TimeInterval = 0
    private(set) var maximumMicrophonePTSGap: TimeInterval = 0
    private(set) var latestSystemRMS: Double = 0
    private(set) var latestMicrophoneRMS: Double = 0
    private var lastSystemPTS: TimeInterval?
    private var lastMicrophonePTS: TimeInterval?
    private var pngData: Data?

    init(filterRevision: UInt64, windowID: UInt32?, streamIdentity: String) {
        self.filterRevision = filterRevision
        self.windowID = windowID
        self.streamIdentity = streamIdentity
    }

    func recordSystemAudio(rms: Double, pts: TimeInterval?) {
        latestSystemRMS = rms
        if rms > 0.001 { nonSilentSystemBufferCount += 1 }
        maximumSystemPTSGap = max(maximumSystemPTSGap, gap(from: lastSystemPTS, to: pts))
        lastSystemPTS = pts
    }

    func recordMicrophoneAudio(rms: Double, pts: TimeInterval?) {
        latestMicrophoneRMS = rms
        if rms > 0.001 { nonSilentMicrophoneBufferCount += 1 }
        maximumMicrophonePTSGap = max(maximumMicrophonePTSGap, gap(from: lastMicrophonePTS, to: pts))
        lastMicrophonePTS = pts
    }

    func recordCompleteFrame(_ sampleBuffer: CMSampleBuffer) {
        completeScreenFrameCount += 1
        guard pngData == nil else { return }
        pngData = TeamsCaptureViabilityFrame.pngData(from: sampleBuffer)
    }

    func stop(at date: Date) {
        stoppedAt = date
    }

    func report(savingPNGTo directory: URL) -> TeamsCaptureViabilityDwell {
        let pngPath = savePNG(to: directory)
        return TeamsCaptureViabilityDwell(
            filterRevision: filterRevision,
            windowID: windowID,
            duration: (stoppedAt ?? Date()).timeIntervalSince(startedAt),
            streamIdentity: streamIdentity,
            completeScreenFrameCount: completeScreenFrameCount,
            nonSilentSystemBufferCount: nonSilentSystemBufferCount,
            nonSilentMicrophoneBufferCount: nonSilentMicrophoneBufferCount,
            maximumSystemPTSGap: maximumSystemPTSGap,
            maximumMicrophonePTSGap: maximumMicrophonePTSGap,
            capturedFramePNG: pngPath
        )
    }

    private func gap(from previous: TimeInterval?, to current: TimeInterval?) -> TimeInterval {
        guard let previous, let current else { return 0 }
        return max(0, current - previous)
    }

    private func savePNG(to directory: URL) -> String? {
        guard let pngData, let windowID else { return nil }
        let url = directory.appendingPathComponent("window-\(windowID)-revision-\(filterRevision).png")
        do {
            try pngData.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }
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

    static func pngData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}

private enum TeamsCaptureViabilityAudioRMS {
    static func value(in sampleBuffer: CMSampleBuffer) -> Double {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              description.pointee.mFormatID == kAudioFormatLinearPCM else {
            return 0
        }
        var bufferListSize = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let buffers = storage.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: buffers,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        ) == noErr else { return 0 }
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffers)
        var sum: Double = 0
        var count = 0
        for audioBuffer in audioBuffers {
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            for index in 0..<sampleCount {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            count += sampleCount
        }
        return count == 0 ? 0 : (sum / Double(count)).squareRoot()
    }
}

private enum TeamsCaptureViabilityProbeError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case teamsApplicationUnavailable
    case streamNotRunning

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
