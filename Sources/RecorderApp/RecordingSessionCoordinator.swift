import Combine
import Foundation

struct RecordingStartAttempt: Equatable {
    let id: UUID
    var ownership: RecordingOwnership
    let lifecycleToken: CaptureLifecycleToken
}

@MainActor
final class RecordingSessionCoordinator: ObservableObject {
    @Published private(set) var isWorking = false
    @Published var ownership: RecordingOwnership?

    var task: Task<Void, Never>?
    var pendingAttempt: RecordingStartAttempt?
    var cancelledAttemptStops: [UUID: CaptureLifecycleToken] = [:]
    var independentlyFinalizedAttempts: Set<UUID> = []
    var automaticStopIntentToken: CaptureLifecycleToken?

    private var gate = CaptureLifecycleGate()

    deinit {
        task?.cancel()
    }

    var activeOperation: CaptureLifecycleOperation? {
        gate.activeOperation
    }

    func begin(
        _ operation: CaptureLifecycleOperation
    ) -> CaptureLifecycleToken? {
        guard let token = gate.begin(operation) else { return nil }
        isWorking = true
        return token
    }

    func cancelAndBeginStop() -> CaptureLifecycleToken? {
        guard let token = gate.cancelAndBeginStop() else { return nil }
        isWorking = true
        return token
    }

    func accepts(_ token: CaptureLifecycleToken) -> Bool {
        gate.accepts(token)
    }

    @discardableResult
    func finish(_ token: CaptureLifecycleToken) -> Bool {
        guard gate.finish(token) else { return false }
        task = nil
        isWorking = false
        return true
    }
}
