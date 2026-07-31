import Foundation

final class RecordingSessionMutationGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withMutation<T>(for sessionFolder: URL, _ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
