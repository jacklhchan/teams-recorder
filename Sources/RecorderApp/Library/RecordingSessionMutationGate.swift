import Foundation

final class RecordingSessionMutationGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let mutationAttemptObserver: (() -> Void)?

    init(mutationAttemptObserver: (() -> Void)? = nil) {
        self.mutationAttemptObserver = mutationAttemptObserver
    }

    func withMutation<T>(for sessionFolder: URL, _ operation: () throws -> T) rethrows -> T {
        mutationAttemptObserver?()
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
