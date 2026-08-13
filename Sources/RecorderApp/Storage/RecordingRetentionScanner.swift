import Darwin
import Foundation

/// A typed projection supplied by the publication owner.  It names only
/// retained pending sessions that have already been verified as published.
/// With the current coordinator there are no such retained sources, which is
/// intentionally safer than widening this scanner to the destination library.
struct RecordingRetentionPublicationSnapshot: Equatable, Sendable {
    let publishedSessionDirectoryNames: Set<String>

    init(publishedSessionDirectoryNames: Set<String> = []) {
        self.publishedSessionDirectoryNames = publishedSessionDirectoryNames
    }
}

struct RecordingRetentionAggregate: Equatable, Sendable {
    var eligible = 0
    var skipped = 0
    var deleted = 0
    var errors = 0
}

enum RecordingRetentionDeletionOutcome: Equatable, Sendable {
    case deleted
    case rejected
}

/// A candidate is descriptor-bound.  No URL or caller-supplied path is ever
/// accepted as deletion authority.
final class RecordingRetentionCandidate: @unchecked Sendable {
    let artifactClass: RetainableArtifactClass
    fileprivate let session: RecordingPendingSession
    fileprivate let name: String
    fileprivate let identity: RecordingPendingSessionIdentity

    fileprivate init(
        artifactClass: RetainableArtifactClass,
        session: RecordingPendingSession,
        name: String,
        identity: RecordingPendingSessionIdentity
    ) {
        self.artifactClass = artifactClass
        self.session = session
        self.name = name
        self.identity = identity
    }
}

struct RecordingRetentionScanResult: @unchecked Sendable {
    let candidates: [RecordingRetentionCandidate]
    let aggregate: RecordingRetentionAggregate
}

struct RecordingRetentionScanner: Sendable {
    func scan(
        policy: RecordingDataLifecyclePolicy,
        publicationSnapshot: RecordingRetentionPublicationSnapshot,
        pendingStore: RecordingPendingStore,
        now: Date
    ) -> RecordingRetentionScanResult {
        guard case let .enabled(eligibleClasses, olderThanDays) = policy.retention,
              olderThanDays > 0,
              !eligibleClasses.isEmpty else {
            return .init(candidates: [], aggregate: .init())
        }
        let cutoff = now.addingTimeInterval(-TimeInterval(olderThanDays) * 86_400)
        var aggregate = RecordingRetentionAggregate()
        var candidates: [RecordingRetentionCandidate] = []
        guard let sessionNames = try? pendingStore.scanSessionNames() else {
            aggregate.errors = 1
            return .init(candidates: [], aggregate: aggregate)
        }
        for sessionName in sessionNames {
            guard publicationSnapshot.publishedSessionDirectoryNames.contains(sessionName),
                  let session = try? pendingStore.openSession(for: sessionName),
                  let metadata = try? pendingStore.retentionMetadata(in: session),
                  !metadata.isFavorite,
                  metadata.recoveryState == .none else {
                aggregate.skipped += 1
                continue
            }
            let entries = regularEntries(in: session)
            aggregate.skipped += entries.skipped
            for entry in entries.entries {
                guard let artifactClass = artifactClass(for: entry.name),
                      eligibleClasses.contains(artifactClass),
                      entry.modificationDate < cutoff else {
                    continue
                }
                candidates.append(.init(
                    artifactClass: artifactClass,
                    session: session,
                    name: entry.name,
                    identity: entry.identity
                ))
            }
        }
        aggregate.eligible = candidates.count
        return .init(candidates: candidates, aggregate: aggregate)
    }

    func delete(_ candidate: RecordingRetentionCandidate) -> RecordingRetentionDeletionOutcome {
        guard (try? RecordingPendingStore(root: candidate.session.displayURL.deletingLastPathComponent())
            .validateRetainedSession(candidate.session)) != nil else {
            return .rejected
        }
        var observed = stat()
        guard fstatat(candidate.session.fileDescriptor, candidate.name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
              isEligibleRegularFile(observed),
              matches(observed, candidate.identity),
              unlinkat(candidate.session.fileDescriptor, candidate.name, 0) == 0 else {
            return .rejected
        }
        return .deleted
    }

    private func regularEntries(in session: RecordingPendingSession) -> (entries: [(name: String, identity: RecordingPendingSessionIdentity, modificationDate: Date)], skipped: Int) {
        let duplicated = dup(session.fileDescriptor)
        guard duplicated >= 0, let directory = fdopendir(duplicated) else {
            if duplicated >= 0 { Darwin.close(duplicated) }
            return ([], 1)
        }
        defer { closedir(directory) }
        var entries: [(String, RecordingPendingSessionIdentity, Date)] = []
        var skipped = 0
        while let pointer = readdir(directory) {
            let name = name(of: pointer.pointee)
            guard isSafeArtifactName(name) else { continue }
            var observed = stat()
            guard fstatat(session.fileDescriptor, name, &observed, AT_SYMLINK_NOFOLLOW) == 0,
                  isEligibleRegularFile(observed) else {
                skipped += 1
                continue
            }
            entries.append((
                name,
                .init(device: Int64(observed.st_dev), inode: Int64(observed.st_ino)),
                Date(timeIntervalSince1970: TimeInterval(observed.st_mtimespec.tv_sec))
            ))
        }
        return (entries, skipped)
    }

    private func artifactClass(for name: String) -> RetainableArtifactClass? {
        switch name {
        case "transcription.log": return .transcriptionLog
        case "transcription.failure.json": return .transcriptionFailureDiagnostic
        default:
            if name.hasPrefix("transcription.log.previous-") ||
                name.hasPrefix("transcription.failure.json.previous-") {
                return .transcriptionBackup
            }
            return nil
        }
    }

    private func name(of entry: dirent) -> String {
        withUnsafePointer(to: entry.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.d_name)) {
                String(cString: $0)
            }
        }
    }

    private func isSafeArtifactName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") &&
            !name.contains("/") && !name.contains("\\")
    }

    private func isEligibleRegularFile(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
    }

    private func matches(_ value: stat, _ identity: RecordingPendingSessionIdentity) -> Bool {
        Int64(value.st_dev) == identity.device && Int64(value.st_ino) == identity.inode
    }
}
