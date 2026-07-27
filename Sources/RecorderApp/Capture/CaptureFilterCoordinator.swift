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
}

struct CaptureStreamIntent: Equatable, Sendable {
    let filter: CaptureFilterIntent
    let cadence: ScreenFrameCadence
}

/// Serializes content-filter and frame-cadence transactions for one SCStream.
struct CaptureFilterCoordinator {
    private var generation: UInt64 = 1
    private var nextRevision: UInt64 = 0
    private var committed: CaptureStreamIntent?
    private var committedRevision: CaptureFilterRevision?
    private var desired: CaptureStreamIntent?
    private var inFlight: CaptureFilterUpdate?
    private var isStopped = false

    mutating func request(_ intent: CaptureStreamIntent) -> CaptureFilterUpdate? {
        guard !isStopped else { return nil }
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
        }
        guard let desired, desired != committed else { return nil }
        return begin(desired)
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
