import Darwin
import Foundation

enum RecordingPendingStoreError: Error, Equatable, Sendable {
    case rootIsNotDirectory
    case invalidSessionName
    case unsafeSession
}

struct RecordingPendingStore: Sendable {
    let root: URL
    let manifestURL: URL

    init(root: URL, manifestURL: URL? = nil) {
        self.root = root
        self.manifestURL = manifestURL ?? root.appendingPathComponent("publication-queue-v1.json")
    }

    func prepareRoot() throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, !isSymbolicLink(root) else {
                throw RecordingPendingStoreError.rootIsNotDirectory
            }
        } else {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard chmod(root.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func sessionURL(for directoryName: String) throws -> URL {
        try prepareRoot()
        guard isSafeDirectoryName(directoryName) else {
            throw RecordingPendingStoreError.invalidSessionName
        }

        let candidate = root.appendingPathComponent(directoryName, isDirectory: true)
        guard candidate.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              !isSymbolicLink(candidate) else {
            throw RecordingPendingStoreError.unsafeSession
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            throw RecordingPendingStoreError.unsafeSession
        }
        return candidate
    }

    func scanSessions() throws -> [URL] {
        try prepareRoot()
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.lastPathComponent != manifestURL.lastPathComponent }
            .compactMap { url in try? sessionURL(for: url.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isSafeDirectoryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") &&
            !name.hasPrefix(".")
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
