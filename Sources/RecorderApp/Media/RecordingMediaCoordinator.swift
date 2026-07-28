@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

struct RecordingOutputURLs: Equatable {
    let folder: URL
    let partialMP4: URL
    let finalMP4: URL
    let audioBackup: URL
    let recoveredM4A: URL

    init(folder: URL) {
        self.folder = folder
        partialMP4 = folder.appendingPathComponent("recording.partial.mp4")
        finalMP4 = folder.appendingPathComponent("recording.mp4")
        audioBackup = folder.appendingPathComponent("recording.audio-backup.m4a")
        recoveredM4A = folder.appendingPathComponent("recording.m4a")
    }

    init(folder: URL, partialMP4: URL, finalMP4: URL, audioBackup: URL, recoveredM4A: URL) {
        self.folder = folder
        self.partialMP4 = partialMP4
        self.finalMP4 = finalMP4
        self.audioBackup = audioBackup
        self.recoveredM4A = recoveredM4A
    }
}

struct RecordingMediaOutcome: Equatable {
    let finalURL: URL
    let mediaKind: RecordingMediaKind
    let screenIntervals: [RecordedScreenInterval]
    let capturedWindow: RecordedTeamsWindowIdentity?
    let recoveryState: RecordingRecoveryState
    let videoDroppedFrames: Int
    let videoFailureDescription: String?
    let safetyCleanupDiagnostic: String?
}

enum RecordingVideoEventKind: Equatable, Sendable {
    case sourceStalled
    case sourceRecovered
    case droppedFrames(Int)
    case muxFailed(String)
}

struct RecordingVideoEvent: Equatable, Sendable {
    let sourceSessionID: UUID
    let recordingEpoch: UInt64
    let kind: RecordingVideoEventKind
}

protocol RecordingMediaCoordinating: AnyObject {
    func setVideoEventHandler(_ handler: (@Sendable (RecordingVideoEvent) -> Void)?)
    func enqueueAudio(_ block: MixedAudioBlock)
    func enqueueVideo(_ frame: ScreenVideoFrame)
    func setScreenCaptureRequested(
        _ requested: Bool,
        expectedRevision: CaptureFilterRevision?,
        window: RecordedTeamsWindowIdentity?
    )
    func markScreenSourceUnavailable()
    func finish() async throws -> RecordingMediaOutcome
}

protocol RecordingMediaFileOperating: AnyObject {
    func promoteNoReplace(_ source: URL, to destination: URL) throws
    func rollbackOwnedPromotion(_ destination: URL, to source: URL) throws
    func remove(_ url: URL) throws
    func validateMP4(_ url: URL) async throws
    func validateM4A(_ url: URL) throws
}

enum RecordingMediaFinalizationError: Error, Equatable {
    case muxFailed(String)
    case safetyFailed(String)
    case aggregate(mux: String, safety: String)
    case promotionFailed(String)
    case invalidOutputURLs
}

struct POSIXFileIdentity {
    let device: dev_t
    let inode: ino_t
    let isRegularFile: Bool
    let isSymbolicLink: Bool
}

enum RecordingMediaFileError: Error, LocalizedError, Equatable {
    case missingSource(URL)
    case sourceIsNotRegular(URL)
    case destinationAlreadyExists(URL)
    case parentMismatch(source: URL, destination: URL)
    case crossDevice(source: URL, destination: URL)
    case posix(operation: String, source: URL, destination: URL?, errno: Int32)
    case invalidMP4(URL)
    case invalidM4A(URL)

    var errorDescription: String? {
        switch self {
        case .missingSource(let url): return "Missing source: \(url.lastPathComponent)"
        case .sourceIsNotRegular(let url): return "Source is not a regular file: \(url.lastPathComponent)"
        case .destinationAlreadyExists(let url): return "Destination already exists: \(url.lastPathComponent)"
        case .parentMismatch: return "Promotion requires the same directory"
        case .crossDevice: return "Promotion cannot cross devices"
        case .posix(let operation, _, _, let code): return "\(operation) failed with errno \(code)"
        case .invalidMP4(let url): return "Invalid MP4: \(url.lastPathComponent)"
        case .invalidM4A(let url): return "Invalid M4A: \(url.lastPathComponent)"
        }
    }
}

final class ProductionRecordingMediaFileOperations: RecordingMediaFileOperating {
    typealias ExclusiveRename = (_ source: String, _ destination: String) -> (result: Int32, code: Int32)

    private let exclusiveRename: ExclusiveRename

    init(exclusiveRename: @escaping ExclusiveRename = ProductionRecordingMediaFileOperations.systemExclusiveRename) {
        self.exclusiveRename = exclusiveRename
    }

    func promoteNoReplace(_ source: URL, to destination: URL) throws {
        let sourceIdentity = try identity(at: source)
        guard sourceIdentity.isRegularFile, !sourceIdentity.isSymbolicLink else {
            throw RecordingMediaFileError.sourceIsNotRegular(source)
        }
        let sourceParent = source.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        guard sourceParent.standardizedFileURL == destinationParent.standardizedFileURL else {
            throw RecordingMediaFileError.parentMismatch(source: source, destination: destination)
        }
        let parentIdentity = try identity(at: sourceParent)
        guard parentIdentity.device == sourceIdentity.device else {
            throw RecordingMediaFileError.crossDevice(source: source, destination: destination)
        }
        do {
            _ = try identity(at: destination)
            throw RecordingMediaFileError.destinationAlreadyExists(destination)
        } catch let error as RecordingMediaFileError {
            if case .missingSource = error {
                // The destination is absent, which is the only promotable state.
            } else {
                throw error
            }
        }

        let rename = exclusiveRename(source.path, destination.path)
        guard rename.result == 0 else {
            let code = rename.code
            if code == EXDEV {
                throw RecordingMediaFileError.crossDevice(source: source, destination: destination)
            }
            throw RecordingMediaFileError.posix(operation: "renameatx_np", source: source, destination: destination, errno: code)
        }
        let destinationIdentity = try identity(at: destination)
        guard destinationIdentity.isRegularFile, !destinationIdentity.isSymbolicLink,
              destinationIdentity.device == sourceIdentity.device,
              destinationIdentity.inode == sourceIdentity.inode else {
            throw RecordingMediaFileError.sourceIsNotRegular(destination)
        }
    }

    private static func systemExclusiveRename(_ source: String, _ destination: String) -> (result: Int32, code: Int32) {
        let result = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                renameatx_np(AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
            }
        }
        return (result, errno)
    }

    func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func rollbackOwnedPromotion(_ destination: URL, to source: URL) throws {
        try promoteNoReplace(destination, to: source)
    }

    func validateMP4(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw RecordingMediaFileError.invalidMP4(url) }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard video.count == 1, audio.count == 1,
              let videoDescription = try await video[0].load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(videoDescription) == kCMVideoCodecType_HEVC,
              CMVideoFormatDescriptionGetDimensions(videoDescription).width == 1_600,
              CMVideoFormatDescriptionGetDimensions(videoDescription).height == 900,
              let audioDescription = try await audio[0].load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription)?.pointee,
              abs(stream.mSampleRate - 48_000) < 0.01,
              stream.mChannelsPerFrame == 2 else {
            throw RecordingMediaFileError.invalidMP4(url)
        }
    }

    func validateM4A(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              file.processingFormat.sampleRate.isFinite,
              file.processingFormat.sampleRate > 0,
              file.processingFormat.channelCount == 2,
              file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            throw RecordingMediaFileError.invalidM4A(url)
        }
    }

    private func identity(at url: URL) throws -> POSIXFileIdentity {
        var attributes = stat()
        let result = url.path.withCString { lstat($0, &attributes) }
        guard result == 0 else {
            let code = errno
            if code == ENOENT { throw RecordingMediaFileError.missingSource(url) }
            throw RecordingMediaFileError.posix(operation: "lstat", source: url, destination: nil, errno: code)
        }
        return POSIXFileIdentity(
            device: attributes.st_dev,
            inode: attributes.st_ino,
            isRegularFile: (attributes.st_mode & S_IFMT) == S_IFREG,
            isSymbolicLink: (attributes.st_mode & S_IFMT) == S_IFLNK
        )
    }
}

private final class EarlyVideoReservation {
    let frame: ScreenVideoFrame
    private let release: () -> Void

    init(frame: ScreenVideoFrame, release: @escaping () -> Void) {
        self.frame = frame
        self.release = release
    }

    deinit { release() }
}

final class RecordingMediaCoordinator: RecordingMediaCoordinating, @unchecked Sendable {
    typealias SafetyWriterFactory = (URL) throws -> MixedAudioWriting
    typealias MuxWriterFactory = (URL) throws -> MuxedMediaWriting
    typealias BlackFrameFactory = () throws -> CVPixelBuffer
    typealias StateEnqueuing = (@escaping @Sendable () -> Void) -> Void
    typealias EventEnqueuing = (@escaping @Sendable () -> Void) -> Void

    private let outputs: RecordingOutputURLs
    private let sourceSessionID: UUID
    private let recordingEpoch: UInt64
    private let safetyWriter: MixedAudioWriting
    private let muxWriter: MuxedMediaWriting
    private let fileOperations: RecordingMediaFileOperating
    private let blackFrameFactory: BlackFrameFactory
    private let activeFilterRevision: CaptureFilterRevision
    private let stateQueue: DispatchQueue
    private let stateEnqueue: StateEnqueuing
    private let eventEnqueue: EventEnqueuing
    private let mailboxLock = NSCondition()
    private let handlerLock = NSLock()
    private let finishLock = NSLock()

    private var acceptingIngress = true
    private var mailbox: [ScreenVideoFrame] = []
    private var inFlightVideoCount = 0
    private var drainScheduled = false
    private var eventHandler: (@Sendable (RecordingVideoEvent) -> Void)?
    private var eventGeneration: UInt64 = 0
    private var finishTask: Task<RecordingMediaOutcome, Error>?
    private var pendingMailboxDrops = 0
    private var maximumOwnedVideoFrames = 0
    private var scheduledDrainJobs = 0
    private var activeDrainJobs = 0
    private var maximumActiveDrainJobs = 0
    private var heldEarlyVideoCount = 0
    private var pendingStateEnqueues = 0

    // All fields below are owned only by stateQueue.
    private var timeline = RecordingTimeline()
    private var gate: VideoGate
    private var gateStarted = false
    private var sourceUnavailable = false
    private var capturedWindow: RecordedTeamsWindowIdentity?
    private var firstMuxFailure: Error?
    private var safetyFailure: Error?
    private var videoDroppedFrames = 0
    private var wasStalled = false
    private var expectedRevision: CaptureFilterRevision?
    private var initialMuxSetupFailure: Error?
    private var priorScreenIntervals: [RecordedScreenInterval] = []
    private var retainedEarlyVideoReservation: EarlyVideoReservation?
    private var earlyVideoSeenCount = 0
    private var earliestEarlyVideoPTS: CMTime?
    var replayInterleavingHook: (() -> Void)?

    var pendingVideoOwnershipCount: Int {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return mailbox.count + inFlightVideoCount + heldEarlyVideoCount
    }

    var scheduledVideoDrainCount: Int {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return scheduledDrainJobs
    }

    var peakVideoOwnershipCount: Int {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return maximumOwnedVideoFrames
    }

    var activeVideoDrainCount: Int {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return activeDrainJobs
    }

    var peakActiveVideoDrainCount: Int {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        return maximumActiveDrainJobs
    }

    convenience init(
        outputs: RecordingOutputURLs,
        sourceSessionID: UUID,
        recordingEpoch: UInt64,
        activeFilterRevision: CaptureFilterRevision,
        pixelFormat: OSType
    ) throws {
        try self.init(
            outputs: outputs,
            sourceSessionID: sourceSessionID,
            recordingEpoch: recordingEpoch,
            activeFilterRevision: activeFilterRevision,
            safetyWriterFactory: { try AACMixedAudioWriter(url: $0, bitRate: 128_000) },
            muxWriterFactory: { try MuxedMediaWriter(url: $0, profile: .production(pixelFormat: pixelFormat)) },
            fileOperations: ProductionRecordingMediaFileOperations(),
            blackFrameFactory: { try VideoFrameSurface.makeBlack(format: pixelFormat == kCVPixelFormatType_32BGRA ? .bgra : .nv12).pixelBuffer },
            stateEnqueue: nil,
            eventEnqueue: nil
        )
    }

    init(
        outputs: RecordingOutputURLs,
        sourceSessionID: UUID,
        recordingEpoch: UInt64,
        activeFilterRevision: CaptureFilterRevision,
        safetyWriterFactory: SafetyWriterFactory,
        muxWriterFactory: MuxWriterFactory,
        fileOperations: RecordingMediaFileOperating,
        blackFrameFactory: @escaping BlackFrameFactory,
        stateEnqueue: StateEnqueuing? = nil,
        eventEnqueue: EventEnqueuing? = nil
    ) throws {
        let queue = DispatchQueue(label: "local.meeting.recorder.recording-media")
        guard Self.areValid(outputs: outputs) else {
            throw RecordingMediaFinalizationError.invalidOutputURLs
        }
        self.outputs = outputs
        self.sourceSessionID = sourceSessionID
        self.recordingEpoch = recordingEpoch
        safetyWriter = try safetyWriterFactory(outputs.audioBackup)
        do {
            muxWriter = try muxWriterFactory(outputs.partialMP4)
        } catch {
            muxWriter = UnavailableMuxWriter(error: error)
            initialMuxSetupFailure = error
        }
        self.fileOperations = fileOperations
        self.blackFrameFactory = blackFrameFactory
        self.activeFilterRevision = activeFilterRevision
        gate = VideoGate(activeFilterRevision: activeFilterRevision)
        expectedRevision = activeFilterRevision
        stateQueue = queue
        self.stateEnqueue = stateEnqueue ?? { work in queue.async(execute: work) }
        let eventQueue = DispatchQueue(label: "local.meeting.recorder.recording-media-events")
        self.eventEnqueue = eventEnqueue ?? { work in eventQueue.async(execute: work) }
    }

    func setVideoEventHandler(_ handler: (@Sendable (RecordingVideoEvent) -> Void)?) {
        handlerLock.lock()
        eventGeneration &+= 1
        eventHandler = handler
        handlerLock.unlock()
    }

    func enqueueAudio(_ block: MixedAudioBlock) {
        admitAndEnqueueState { [weak self] in self?.processAudio(block) }
    }

    func enqueueVideo(_ frame: ScreenVideoFrame) {
        mailboxLock.lock()
        guard acceptingIngress else {
            mailboxLock.unlock()
            return
        }
        let availableSlots = max(0, 2 - inFlightVideoCount - heldEarlyVideoCount)
        if availableSlots == 0 {
            pendingMailboxDrops += 1
            mailboxLock.unlock()
            return
        }
        if mailbox.count >= availableSlots {
            mailbox.removeFirst()
            pendingMailboxDrops += 1
        }
        mailbox.append(frame)
        maximumOwnedVideoFrames = max(maximumOwnedVideoFrames, mailbox.count + inFlightVideoCount + heldEarlyVideoCount)
        let scheduleDrain = !drainScheduled
        drainScheduled = true
        if scheduleDrain { scheduledDrainJobs += 1 }
        mailboxLock.unlock()
        if scheduleDrain {
            enqueueState { [weak self] in self?.drainVideoMailbox() }
        }
    }

    func setScreenCaptureRequested(
        _ requested: Bool,
        expectedRevision: CaptureFilterRevision?,
        window: RecordedTeamsWindowIdentity?
    ) {
        admitAndEnqueueState { [weak self] in
            guard let self else { return }
            self.ensureGateStarted()
            self.sourceUnavailable = false
            self.capturedWindow = requested ? window : self.capturedWindow
            self.replaceExpectedRevision(expectedRevision)
            self.appendGateActions(self.gate.setScreenIntent(requested, at: self.timeline.currentAudioEndTime), realFrame: nil)
        }
    }

    func markScreenSourceUnavailable() {
        admitAndEnqueueState { [weak self] in
            guard let self else { return }
            self.sourceUnavailable = true
            if !self.wasStalled {
                self.wasStalled = true
                self.emit(.sourceStalled)
            }
            self.appendGateActions(
                self.gate.submitFrame(
                    at: self.timeline.currentAudioEndTime,
                    isComplete: false,
                    sourceAvailable: false,
                    filterRevision: self.activeFilterRevision
                ),
                realFrame: nil
            )
        }
    }

    func finish() async throws -> RecordingMediaOutcome {
        let task = makeFinishTask()
        return try await task.value
    }

    private func makeFinishTask() -> Task<RecordingMediaOutcome, Error> {
        finishLock.lock()
        if let task = finishTask {
            finishLock.unlock()
            return task
        }
        mailboxLock.lock()
        acceptingIngress = false
        while pendingStateEnqueues > 0 {
            mailboxLock.wait()
        }
        mailboxLock.unlock()
        let task = Task { [weak self] () throws -> RecordingMediaOutcome in
            guard let self else { throw RecordingMediaFinalizationError.muxFailed("Coordinator released") }
            return try await self.finishOnce()
        }
        finishTask = task
        finishLock.unlock()
        return task
    }

    private func enqueueState(_ work: @escaping @Sendable () -> Void) {
        stateEnqueue(work)
    }

    /// Admission is atomic, but the executor is always invoked after releasing
    /// the condition lock.  This permits synchronous test executors and gives
    /// finish a precise boundary for accepted audio/control work.
    private func admitAndEnqueueState(_ work: @escaping @Sendable () -> Void) {
        mailboxLock.lock()
        guard acceptingIngress else {
            mailboxLock.unlock()
            return
        }
        pendingStateEnqueues += 1
        mailboxLock.unlock()

        stateEnqueue(work)

        mailboxLock.lock()
        pendingStateEnqueues -= 1
        if pendingStateEnqueues == 0 {
            mailboxLock.broadcast()
        }
        mailboxLock.unlock()
    }

    private func consumeMailboxDrops() {
        mailboxLock.lock()
        let drops = pendingMailboxDrops
        pendingMailboxDrops = 0
        mailboxLock.unlock()
        guard drops > 0 else { return }
        videoDroppedFrames += drops
        emit(.droppedFrames(videoDroppedFrames))
    }

    private func announceInitialMuxFailureIfNeeded() {
        guard let initialMuxSetupFailure else { return }
        self.initialMuxSetupFailure = nil
        latchMuxFailure(initialMuxSetupFailure)
    }

    private func replaceExpectedRevision(_ revision: CaptureFilterRevision?) {
        guard expectedRevision != revision else { return }
        appendGateActions(gate.setScreenIntent(false, at: timeline.currentAudioEndTime), realFrame: nil)
        expectedRevision = revision
    }

    private func processAudio(_ block: MixedAudioBlock) {
        do { try safetyWriter.write(block) } catch { safetyFailure = safetyFailure ?? error }
        announceInitialMuxFailureIfNeeded()
        let timed = timeline.mapAudio(block)
        replayEarlyVideoFrames()
        ensureGateStarted()
        appendMuxAudio(timed)
    }

    private func drainVideoMailbox() {
        mailboxLock.lock()
        activeDrainJobs += 1
        maximumActiveDrainJobs = max(maximumActiveDrainJobs, activeDrainJobs)
        mailboxLock.unlock()
        consumeMailboxDrops()
        while let frame = takeVideoFrame() {
            let transferredToEarlyHold = processVideo(frame)
            if !transferredToEarlyHold {
                completeInFlightVideo()
            }
        }
        var needsAnotherDrain = false
        while true {
            consumeMailboxDrops()
            mailboxLock.lock()
            // Any drop admitted before this point is consumed by this drain;
            // an offer after clearing the flag schedules exactly one successor.
            if pendingMailboxDrops == 0 {
                activeDrainJobs -= 1
                drainScheduled = false
                needsAnotherDrain = !mailbox.isEmpty
                if needsAnotherDrain {
                    drainScheduled = true
                    scheduledDrainJobs += 1
                }
                mailboxLock.unlock()
                break
            }
            mailboxLock.unlock()
        }
        if needsAnotherDrain { enqueueState { [weak self] in self?.drainVideoMailbox() } }
    }

    private func completeInFlightVideo() {
        mailboxLock.lock()
        inFlightVideoCount -= 1
        mailboxLock.unlock()
    }

    private func takeVideoFrame() -> ScreenVideoFrame? {
        mailboxLock.lock()
        defer { mailboxLock.unlock() }
        guard !mailbox.isEmpty else { return nil }
        inFlightVideoCount += 1
        return mailbox.removeFirst()
    }

    @discardableResult
    private func processVideo(_ frame: ScreenVideoFrame) -> Bool {
        announceInitialMuxFailureIfNeeded()
        guard let expectedRevision, frame.filterRevision == expectedRevision else {
            if let expectedRevision {
                appendGateActions(
                    gate.submitFrame(
                        at: timeline.currentAudioEndTime,
                        isComplete: false,
                        sourceAvailable: false,
                        filterRevision: frame.filterRevision == expectedRevision ? expectedRevision : frame.filterRevision
                    ),
                    realFrame: nil
                )
            }
            return false
        }
        ensureGateStarted()
        switch timeline.mapVideo(frame.sourcePTS) {
        case .append(let timestamp):
            processAcceptedVideo(frame, at: timestamp)
            return false
        case .pending:
            return holdEarlyVideo(frame)
        case .dropDuplicate, .dropBackward, .dropFarFuture:
            return false
        }
    }

    /// Returns true only when the current in-flight ownership was transferred
    /// into the single lock-accounted early-frame hold.
    private func holdEarlyVideo(_ frame: ScreenVideoFrame) -> Bool {
        earlyVideoSeenCount += 1
        var transferred = false
        if retainedEarlyVideoReservation == nil {
            let reservation = EarlyVideoReservation(frame: frame) { [weak self] in
                self?.releaseEarlyVideoHold()
            }
            retainedEarlyVideoReservation = reservation
            earliestEarlyVideoPTS = frame.sourcePTS
            mailboxLock.lock()
            inFlightVideoCount -= 1
            heldEarlyVideoCount = 1
            mailboxLock.unlock()
            transferred = true
        }
        guard let earliest = earliestEarlyVideoPTS else { return transferred }
        let elapsed = CMTimeGetSeconds(frame.sourcePTS - earliest)
        if earlyVideoSeenCount >= 10 || elapsed >= 1 {
            timeline.establishVideoAnchor(at: earliest)
            replayEarlyVideoFrame()
            if frame.sourcePTS != earliest,
               case .append(let timestamp) = timeline.mapVideo(frame.sourcePTS) {
                processAcceptedVideo(frame, at: timestamp)
            }
        }
        return transferred
    }

    private func replayEarlyVideoFrames() {
        replayEarlyVideoFrame()
    }

    private func replayEarlyVideoFrame() {
        let reservation = retainedEarlyVideoReservation
        retainedEarlyVideoReservation = nil
        earliestEarlyVideoPTS = nil
        earlyVideoSeenCount = 0
        guard let reservation else { return }
        // The local reservation keeps its capacity token until this method has
        // returned and the final ScreenVideoFrame reference is gone.
        withExtendedLifetime(reservation) {
            replayInterleavingHook?()
            let frame = reservation.frame
            guard let expectedRevision, frame.filterRevision == expectedRevision else { return }
            if case .append(let timestamp) = timeline.mapVideo(frame.sourcePTS) {
                processAcceptedVideo(frame, at: timestamp)
            }
        }
    }

    private func releaseEarlyVideoHold() {
        mailboxLock.lock()
        heldEarlyVideoCount = 0
        mailboxLock.unlock()
    }

    private func processAcceptedVideo(_ frame: ScreenVideoFrame, at timestamp: CMTime) {
        if sourceUnavailable, frame.status == .complete {
            sourceUnavailable = false
        }
        let recoversSource = wasStalled && frame.status == .complete && !sourceUnavailable
        let actions = gate.submitFrame(
            at: timestamp,
            isComplete: frame.status == .complete,
            sourceAvailable: !sourceUnavailable,
            filterRevision: activeFilterRevision
        )
        let appendedRealFrame = appendGateActions(actions, realFrame: frame.pixelBuffer)
        if appendedRealFrame, (recoversSource || wasStalled) {
            wasStalled = false
            emit(.sourceRecovered)
        }
    }

    private func ensureGateStarted() {
        guard !gateStarted else { return }
        gateStarted = true
        announceInitialMuxFailureIfNeeded()
        appendGateActions(gate.start(at: timeline.currentAudioEndTime), realFrame: nil)
    }

    @discardableResult
    private func appendGateActions(
        _ actions: [VideoGateAction],
        realFrame: CVPixelBuffer?
    ) -> Bool {
        guard firstMuxFailure == nil else { return false }
        var appendedRealFrame = false
        for action in actions {
            do {
                switch action {
                case .appendBlack(let time):
                    try muxWriter.appendVideo(try blackFrameFactory(), at: time)
                case .appendClosingBlack(let time):
                    try muxWriter.appendCriticalVideo(try blackFrameFactory(), at: time)
                    gate.commitClosingBlack(at: time)
                case .appendReal(let time):
                    guard let realFrame else { continue }
                    try muxWriter.appendVideo(realFrame, at: time)
                    gate.commitRealFrame(at: time)
                    appendedRealFrame = true
                case .drop:
                    continue
                }
            } catch MuxedMediaWriterError.videoAppendDropped {
                recordVideoDrop()
            } catch {
                latchMuxFailure(error)
            }
        }
        return appendedRealFrame
    }

    private func appendMuxAudio(_ block: TimedMixedAudioBlock) {
        guard firstMuxFailure == nil else { return }
        do { try muxWriter.appendAudio(block) } catch { latchMuxFailure(error) }
    }

    private func recordVideoDrop() {
        videoDroppedFrames += 1
        emit(.droppedFrames(videoDroppedFrames))
    }

    private func latchMuxFailure(_ error: Error) {
        guard firstMuxFailure == nil else { return }
        firstMuxFailure = error
        emit(.muxFailed(String(describing: error)))
    }

    private func emit(_ kind: RecordingVideoEventKind) {
        handlerLock.lock()
        let generation = eventGeneration
        handlerLock.unlock()
        let event = RecordingVideoEvent(sourceSessionID: sourceSessionID, recordingEpoch: recordingEpoch, kind: kind)
        eventEnqueue { [weak self] in
            guard let self else { return }
            self.handlerLock.lock()
            let handler = self.eventGeneration == generation ? self.eventHandler : nil
            self.handlerLock.unlock()
            handler?(event)
        }
    }

    private func finishOnce() async throws -> RecordingMediaOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.enqueueState { [weak self] in
                guard let self else { continuation.resume(); return }
                self.drainVideoMailbox()
                // A recording with no audio anchor cannot map an early frame;
                // release its reserved pixel-buffer ownership before closing.
                self.replayEarlyVideoFrame()
                self.ensureGateStarted()
                self.appendGateActions(self.gate.finish(atAudioEnd: self.timeline.currentAudioEndTime), realFrame: nil)
                continuation.resume()
            }
        }

        let snapshot = await withCheckedContinuation { (continuation: CheckedContinuation<(Error?, Error?, CMTime, [RecordedScreenInterval], RecordedTeamsWindowIdentity?, Int), Never>) in
            self.enqueueState { [weak self] in
                guard let self else { return continuation.resume(returning: (nil, nil, .zero, [], nil, 0)) }
                continuation.resume(returning: (self.firstMuxFailure, self.safetyFailure, self.timeline.currentAudioEndTime, self.priorScreenIntervals + self.gate.recordedScreenIntervals, self.capturedWindow, self.videoDroppedFrames))
            }
        }
        var muxFailure = snapshot.0
        if muxFailure == nil {
            do { try await muxWriter.finish(at: snapshot.2) } catch { muxFailure = error }
        }
        if let muxFailure {
            return try finishFallback(muxFailure: muxFailure, snapshot: snapshot)
        }
        return try await finishMP4(snapshot: snapshot)
    }

    private func finishMP4(snapshot: (Error?, Error?, CMTime, [RecordedScreenInterval], RecordedTeamsWindowIdentity?, Int)) async throws -> RecordingMediaOutcome {
        var promoted = false
        do {
            try await fileOperations.validateMP4(outputs.partialMP4)
            try fileOperations.promoteNoReplace(outputs.partialMP4, to: outputs.finalMP4)
            promoted = true
            try await fileOperations.validateMP4(outputs.finalMP4)
        } catch {
            let validationError = error
            if promoted {
                do {
                    try fileOperations.rollbackOwnedPromotion(outputs.finalMP4, to: outputs.partialMP4)
                } catch {
                    throw RecordingMediaFinalizationError.aggregate(
                        mux: String(describing: validationError),
                        safety: String(describing: error)
                    )
                }
            }
            return try finishFallback(muxFailure: validationError, snapshot: snapshot)
        }
        var diagnostic = snapshot.1.map { String(describing: $0) }
        do {
            try safetyWriter.close()
            try fileOperations.remove(outputs.audioBackup)
        } catch {
            diagnostic = diagnostic ?? String(describing: error)
        }
        return RecordingMediaOutcome(
            finalURL: outputs.finalMP4,
            mediaKind: snapshot.3.isEmpty ? .audio : .video,
            screenIntervals: snapshot.3,
            capturedWindow: snapshot.4,
            recoveryState: .none,
            videoDroppedFrames: snapshot.5,
            videoFailureDescription: nil,
            safetyCleanupDiagnostic: diagnostic
        )
    }

    private func finishFallback(
        muxFailure: Error,
        snapshot: (Error?, Error?, CMTime, [RecordedScreenInterval], RecordedTeamsWindowIdentity?, Int)
    ) throws -> RecordingMediaOutcome {
        let muxDescription = String(describing: muxFailure)
        if let safetyFailure = snapshot.1 {
            throw RecordingMediaFinalizationError.aggregate(mux: muxDescription, safety: String(describing: safetyFailure))
        }
        do {
            try safetyWriter.close()
            try fileOperations.validateM4A(outputs.audioBackup)
            try fileOperations.promoteNoReplace(outputs.audioBackup, to: outputs.recoveredM4A)
            try fileOperations.validateM4A(outputs.recoveredM4A)
        } catch {
            throw RecordingMediaFinalizationError.aggregate(mux: muxDescription, safety: String(describing: error))
        }
        return RecordingMediaOutcome(
            finalURL: outputs.recoveredM4A,
            mediaKind: .audio,
            screenIntervals: snapshot.3,
            capturedWindow: snapshot.4,
            recoveryState: .videoLostAudioPreserved,
            videoDroppedFrames: snapshot.5,
            videoFailureDescription: muxDescription,
            safetyCleanupDiagnostic: nil
        )
    }

    private static func areValid(outputs: RecordingOutputURLs) -> Bool {
        let folder = outputs.folder.standardizedFileURL
        let expected = [
            (outputs.partialMP4, "recording.partial.mp4"),
            (outputs.finalMP4, "recording.mp4"),
            (outputs.audioBackup, "recording.audio-backup.m4a"),
            (outputs.recoveredM4A, "recording.m4a")
        ]
        return expected.allSatisfy { url, name in
            let candidate = url.standardizedFileURL
            return candidate.deletingLastPathComponent().path == folder.path && candidate.lastPathComponent == name
        }
    }
}

private final class UnavailableMuxWriter: MuxedMediaWriting {
    private let error: Error
    init(error: Error) { self.error = error }
    func appendAudio(_: TimedMixedAudioBlock) throws { throw error }
    func appendVideo(_: CVPixelBuffer, at _: CMTime) throws { throw error }
    func appendCriticalVideo(_: CVPixelBuffer, at _: CMTime) throws { throw error }
    func finish(at _: CMTime) async throws { throw error }
}
