import CoreGraphics
import Foundation

struct CaptureFilterRevision: Hashable, Sendable {
    let sessionGeneration: UInt64
    let revision: UInt64
}

struct CaptureFilterUpdate: Equatable, Sendable {
    let intent: CaptureStreamIntent
    let revision: CaptureFilterRevision
}

enum CaptureFilterIntent: Equatable, Sendable {
    case application(CaptureApplication)
    case teamsWindow(TeamsWindowIdentity)
}

enum ScreenFrameCadence: Equatable, Sendable {
    case idle
    case enabled

    var framesPerSecond: Int {
        self == .enabled ? 10 : 1
    }
}

struct CaptureStreamIntent: Equatable, Sendable {
    let filter: CaptureFilterIntent
    let cadence: ScreenFrameCadence
}

enum ScreenCaptureOutputKind: Equatable, Sendable {
    case audio
    case microphone
    case screen
}

struct ScreenCaptureRoutingPlan: Equatable, Sendable {
    static let audioQueueLabel = "local-meeting-recorder.capture.system"
    static let videoQueueLabel = "local-meeting-recorder.capture.video"

    let outputs: [ScreenCaptureOutputKind]

    static let teamsBundleIdentifier = "com.microsoft.teams2"

    init(application: CaptureApplication?) {
        outputs = application?.bundleIdentifier == Self.teamsBundleIdentifier
            ? [.audio, .microphone, .screen]
            : [.audio, .microphone]
    }

    var acceptsScreenFrames: Bool { outputs.contains(.screen) }
    var audioQueueLabel: String { Self.audioQueueLabel }
    var videoQueueLabel: String { Self.videoQueueLabel }
    var outputsToRemoveOnStop: [ScreenCaptureOutputKind] { outputs }
    var drainsVideoBeforeRemovingOutputs: Bool { acceptsScreenFrames }
}

struct ScreenCaptureRoutingState: Equatable, Sendable {
    private var committedRevision: CaptureFilterRevision?
    private var transitionInFlight = false
    private(set) var activePixelFormat: ScreenCaptureStartupPixelFormat = .nv12

    var videoRevision: CaptureFilterRevision? {
        transitionInFlight ? nil : committedRevision
    }

    mutating func adoptStartupFormat(_ format: ScreenCaptureStartupPixelFormat) {
        activePixelFormat = format
    }

    mutating func publish(_ revision: CaptureFilterRevision) {
        committedRevision = revision
        transitionInFlight = false
    }

    mutating func beginTransition() {
        transitionInFlight = true
    }

    mutating func publishAfterVideoBarrier(_ revision: CaptureFilterRevision) {
        committedRevision = revision
        transitionInFlight = false
    }

    mutating func restoreAfterVideoBarrier() {
        transitionInFlight = false
    }
}

enum ScreenCaptureStartupPixelFormat: Equatable, Sendable {
    case nv12
    case bgra
}

struct ScreenCaptureStartupAttemptSequence {
    private var attempts: [ScreenCaptureStartupPixelFormat] = [.nv12, .bgra]

    mutating func next() -> ScreenCaptureStartupPixelFormat? {
        attempts.isEmpty ? nil : attempts.removeFirst()
    }
}

struct ScreenCaptureRevisionGate {
    private var pending: CaptureFilterRevision?
    private var barrierFinished = false

    mutating func begin(_ revision: CaptureFilterRevision) {
        pending = revision
        barrierFinished = false
    }

    mutating func finishVideoBarrier() {
        barrierFinished = true
    }

    mutating func commitIfBarrierFinished() -> CaptureFilterRevision? {
        guard barrierFinished else { return nil }
        defer {
            pending = nil
            barrierFinished = false
        }
        return pending
    }
}

/// Lock-owned state for callers awaiting a particular filter intent.
/// The source executes the returned actions after releasing its state lock.
enum CaptureFilterWaiterAction: Equatable {
    case resume(UUID, Result<CaptureFilterRevision, CaptureSourceError>)
}

struct CaptureFilterWaiterRegistry {
    private var waiters: [UUID: CaptureStreamIntent] = [:]
    private var pendingRegistration = Set<UUID>()
    private var cancelledBeforeRegistration = Set<UUID>()

    mutating func prepare(_ id: UUID) {
        pendingRegistration.insert(id)
    }

    mutating func register(_ id: UUID, for intent: CaptureStreamIntent) -> [CaptureFilterWaiterAction] {
        pendingRegistration.remove(id)
        if cancelledBeforeRegistration.remove(id) != nil {
            return [.resume(id, .failure(.streamStartCancelled))]
        }
        waiters[id] = intent
        return []
    }

    mutating func cancel(_ id: UUID) -> [CaptureFilterWaiterAction] {
        guard waiters.removeValue(forKey: id) != nil else {
            guard pendingRegistration.contains(id) else { return [] }
            cancelledBeforeRegistration.insert(id)
            return []
        }
        return [.resume(id, .failure(.streamStartCancelled))]
    }

    mutating func discardUnregisteredCancellation(_ id: UUID) {
        pendingRegistration.remove(id)
        cancelledBeforeRegistration.remove(id)
    }

    mutating func supersedeWaiters(except intent: CaptureStreamIntent) -> [CaptureFilterWaiterAction] {
        resolve(where: { $0 != intent }, result: .failure(.streamStartCancelled))
    }

    mutating func resolveWaiters(
        for intent: CaptureStreamIntent,
        result: Result<CaptureFilterRevision, CaptureSourceError>
    ) -> [CaptureFilterWaiterAction] {
        resolve(where: { $0 == intent }, result: result)
    }

    mutating func drain(error: CaptureSourceError) -> [CaptureFilterWaiterAction] {
        let actions: [CaptureFilterWaiterAction] = waiters.keys.map {
            .resume($0, .failure(error))
        }
        waiters.removeAll()
        pendingRegistration.removeAll()
        cancelledBeforeRegistration.removeAll()
        return actions
    }

    private mutating func resolve(
        where predicate: (CaptureStreamIntent) -> Bool,
        result: Result<CaptureFilterRevision, CaptureSourceError>
    ) -> [CaptureFilterWaiterAction] {
        let ids = waiters.compactMap { id, intent in predicate(intent) ? id : nil }
        return ids.compactMap { id in
            guard waiters.removeValue(forKey: id) != nil else { return nil }
            return .resume(id, result)
        }
    }
}

/// Serializes content-filter and frame-cadence transactions for one SCStream.
struct CaptureFilterCoordinator {
    private var generation: UInt64 = 1
    private var nextRevision: UInt64 = 0
    private var committed: CaptureStreamIntent?
    private var committedRevision: CaptureFilterRevision?
    private var desired: CaptureStreamIntent?
    private var inFlight: CaptureFilterUpdate?
    private var terminalFailure: CaptureStreamIntent?
    private var isStopped = false

    mutating func request(_ intent: CaptureStreamIntent) -> CaptureFilterUpdate? {
        guard !isStopped else { return nil }
        guard terminalFailure != intent else { return nil }
        if terminalFailure != nil {
            terminalFailure = nil
        }
        desired = intent
        guard inFlight == nil, committed != intent else { return nil }
        return begin(intent)
    }

    /// Rejects a liveness fallback when a newer transaction is already pending.
    mutating func requestFallback(
        _ intent: CaptureStreamIntent,
        matching revision: CaptureFilterRevision
    ) -> CaptureFilterUpdate? {
        guard !isStopped,
              inFlight == nil,
              committed != nil,
              committedRevision == revision else {
            return nil
        }
        return request(intent)
    }

    mutating func complete(
        _ update: CaptureFilterUpdate,
        result: Result<Void, CaptureSourceError>
    ) -> CaptureFilterUpdate? {
        guard !isStopped, inFlight == update else { return nil }
        inFlight = nil
        if case .success = result {
            committed = update.intent
            committedRevision = update.revision
            terminalFailure = nil
        }
        guard let desired else { return nil }
        if case .failure = result, desired == update.intent {
            terminalFailure = update.intent
            return nil
        }
        guard desired != committed else { return nil }
        return begin(desired)
    }

    func hasTerminalFailure(for intent: CaptureStreamIntent) -> Bool {
        terminalFailure == intent
    }

    func isCommittedAndIdle(_ intent: CaptureStreamIntent) -> Bool {
        inFlight == nil && committed == intent
    }

    mutating func stop() {
        isStopped = true
        generation &+= 1
        desired = nil
        inFlight = nil
    }

    private mutating func begin(_ intent: CaptureStreamIntent) -> CaptureFilterUpdate {
        nextRevision &+= 1
        let update = CaptureFilterUpdate(
            intent: intent,
            revision: CaptureFilterRevision(
                sessionGeneration: generation,
                revision: nextRevision
            )
        )
        inFlight = update
        return update
    }

}
