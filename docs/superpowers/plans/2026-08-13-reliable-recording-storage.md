# Reliable Recording Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finalize every recording in an owner-only local pending area, persist the user-selected destination with an adaptive bookmark catalog, and publish verified session folders to OneDrive without overwriting or losing the local source.

**Architecture:** `RecordingDestinationStore` owns an adaptive bookmark catalog and temporary access leases. `RecordingPendingStore` owns canonical containment and the durable queue manifest. A background `RecordingPublicationCoordinator` drives a single idempotent `RecordingSessionPublisher`; `AppModel` records into the pending root and admits a recording to the existing Library boundary only after verified destination publication.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, AVFoundation, CryptoKit, Darwin POSIX file APIs, UserDefaults, XCTest, Swift Package Manager.

## Global Constraints

- macOS deployment target remains 26.0.
- No new third-party dependency or OneDrive/Graph API.
- Do not change Developer ID signing, Hardened Runtime, notarization, or the current ad-hoc development release flow.
- Never overwrite an existing destination session or follow a symbolic link.
- Stop completes after local media finalization; destination publication runs afterward.
- Delete a local pending session only after destination inventory, size, SHA-256, and media validation succeed.
- Preserve `RecordingEngine`, `IncompleteSessionRecovery`, `RecordingStoragePolicy`, the Library feature, its mutation gate, and workspace fence as the existing owners of their domains.
- Use focused RED/GREEN commands per task; run the combined relevant suite once in Task 7 rather than a broad device/cloud matrix.
- Preserve unrelated untracked files and do not stage `.superpowers/brainstorm/`, `docs/assets/`, the setup tutorial, or prior UAT drafts.

---

## File Structure

- `Sources/RecorderApp/Storage/RecordingDestinationStore.swift`: adaptive bookmark catalog, restoration, destination history, identity, and balanced scoped access.
- `Sources/RecorderApp/Storage/RecordingPendingStore.swift`: pending-root creation, retained descriptor-relative session handles, permissions, and safe name scanning.
- `Sources/RecorderApp/Storage/RecordingPublicationManifest.swift`: versioned queue records and atomic manifest persistence.
- `Sources/RecorderApp/Storage/RecordingSessionPublisher.swift`: secure copy, inventory/digest/media verification, no-replace publication, and staging cleanup.
- `Sources/RecorderApp/Storage/RecordingPublicationCoordinator.swift`: one durable serial queue, retry transitions, relaunch reconciliation, and presentation state.
- `Sources/RecorderApp/Setup/AppPaths.swift`: canonical pending-recordings and queue-manifest paths.
- `Sources/RecorderApp/AppModel.swift`: destination selection, recording-to-pending routing, post-stop enqueue, status projection, startup resume, and shutdown.
- `Sources/RecorderApp/UI/RecordDashboardView.swift`: pending-publication banner.
- `Sources/RecorderApp/UI/RecorderSettingsView.swift`: destination/access/cache status and retry/open actions.
- `Sources/RecorderApp/UI/RecorderActionID.swift`: stable accessibility identifiers for storage publication actions.
- `Tests/RecorderAppTests/RecordingDestinationStoreTests.swift`: bookmark and stale-access contracts.
- `Tests/RecorderAppTests/RecordingPendingStoreTests.swift`: containment, permission, and manifest-recovery contracts.
- `Tests/RecorderAppTests/RecordingSessionPublisherTests.swift`: validation, copy, digest, collision, and cleanup contracts.
- `Tests/RecorderAppTests/RecordingPublicationCoordinatorTests.swift`: durable state machine and retry contracts.
- `Tests/RecorderAppTests/AppModelRecordingPublicationTests.swift`: capture/fence/library integration.
- `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`: bounded UI reachability and state projection.
- `Tests/RecorderAppTests/AppPathsTests.swift`: pending path derivation.

---

### Task 1: Persist and restore the recording destination

**Files:**
- Create: `Sources/RecorderApp/Storage/RecordingDestinationStore.swift`
- Create: `Tests/RecorderAppTests/RecordingDestinationStoreTests.swift`

**Interfaces:**
- Produces: `RecordingDestinationIdentity`, `RecordingDestinationState`, `RecordingDestinationSelection`, `RecordingDestinationAccess`, `RecordingDestinationStoring`, and `RecordingDestinationStore`.
- Consumers in later tasks use `restore(defaultURL:)`, `save(_:)`, `access(identity:)`, and `prune(keeping:)` only; bookmark bytes remain private.

- [ ] **Step 1: Write failing bookmark restoration tests**

```swift
import Foundation
import XCTest
@testable import RecorderApp

final class RecordingDestinationStoreTests: XCTestCase {
    func testNoSavedSelectionUsesDefaultWithoutPersistingIt() throws {
        let defaults = UserDefaults(suiteName: #function + UUID().uuidString)!
        let codec = DestinationBookmarkCodecSpy()
        let store = RecordingDestinationStore(defaults: defaults, codec: codec.codec)
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)

        XCTAssertEqual(store.restore(defaultURL: downloads).state, .ready)
        XCTAssertEqual(store.restore(defaultURL: downloads).url, downloads)
        XCTAssertNil(defaults.data(forKey: RecordingDestinationStore.bookmarkKey))
    }

    func testValidBookmarkRestoresExactSelectedFolder() throws {
        let fixture = DestinationStoreFixture()
        let selected = URL(fileURLWithPath: "/Volumes/OneDrive/Meeting Recording", isDirectory: true)
        try fixture.store.save(selected)
        fixture.codec.resolvedURL = selected

        let restored = fixture.store.restore(defaultURL: fixture.downloads)

        XCTAssertEqual(restored.url, selected)
        XCTAssertEqual(restored.state, .ready)
        XCTAssertEqual(restored.identity, fixture.store.currentIdentity)
    }

    func testNonSandboxedScopedFailureFallsBackToStandardBookmark() throws {
        let fixture = DestinationStoreFixture()
        fixture.codec.scopedEncodeError = DestinationBookmarkTestError.scopedUnavailable
        try fixture.store.save(fixture.destination)

        XCTAssertEqual(fixture.store.savedBookmarkKind, .standard)
        XCTAssertEqual(fixture.codec.standardEncodeCount, 1)
        XCTAssertEqual(
            fixture.store.restore(defaultURL: fixture.downloads).url,
            fixture.destination
        )
    }

    func testStaleBookmarkNeedsFolderAccessAndDoesNotFallBackToDownloads() throws {
        let fixture = DestinationStoreFixture()
        let selected = URL(fileURLWithPath: "/Volumes/OneDrive/Meeting Recording", isDirectory: true)
        try fixture.store.save(selected)
        fixture.codec.resolvedURL = selected
        fixture.codec.isStale = true

        let restored = fixture.store.restore(defaultURL: fixture.downloads)

        XCTAssertEqual(restored.url, selected)
        XCTAssertEqual(restored.state, .needsFolderAccess)
        XCTAssertNotEqual(restored.url, fixture.downloads)
    }

    func testAccessBalancesSuccessfulSecurityScope() throws {
        let fixture = DestinationStoreFixture()
        fixture.codec.preferredKind = .securityScoped
        try fixture.store.save(fixture.destination)
        fixture.codec.resolvedURL = fixture.destination

        let access = try fixture.store.access(identity: fixture.store.currentIdentity!)
        XCTAssertEqual(access.url, fixture.destination)
        access.close()

        XCTAssertEqual(fixture.codec.startCount, 1)
        XCTAssertEqual(fixture.codec.stopCount, 1)
    }

    func testDestinationHistoryRemainsUntilNoQueueIdentityReferencesIt() throws {
        let fixture = DestinationStoreFixture()
        try fixture.store.save(fixture.destination)
        let oldIdentity = try XCTUnwrap(fixture.store.currentIdentity)
        try fixture.store.save(fixture.otherDestination)
        let currentIdentity = try XCTUnwrap(fixture.store.currentIdentity)

        fixture.store.prune(keeping: [oldIdentity, currentIdentity])
        XCTAssertNoThrow(try fixture.store.access(identity: oldIdentity))
        fixture.store.prune(keeping: [currentIdentity])
        XCTAssertThrowsError(try fixture.store.access(identity: oldIdentity))
    }
}
```

The fixture supplies an in-memory `UserDefaults` suite and a mutable codec spy
whose scoped/standard encode, resolve, start-accessing, and stop-accessing
closures are injected through `RecordingDestinationBookmarkCodec`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter RecordingDestinationStoreTests
```

Expected: compilation fails because `RecordingDestinationStore` and its value types do not exist.

- [ ] **Step 3: Implement the destination store**

```swift
import Foundation

struct RecordingDestinationIdentity: Codable, Equatable, Hashable, Sendable {
    let id: UUID
}

enum RecordingDestinationBookmarkKind: String, Codable, Equatable, Sendable {
    case securityScoped
    case standard
}

enum RecordingDestinationState: String, Codable, Equatable, Sendable {
    case ready
    case needsFolderAccess
    case unavailable
}

struct RecordingDestinationSelection: Equatable, Sendable {
    let identity: RecordingDestinationIdentity?
    let url: URL
    let state: RecordingDestinationState
}

final class RecordingDestinationAccess: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var closeOperation: (() -> Void)?

    init(url: URL, close: @escaping () -> Void) {
        self.url = url
        closeOperation = close
    }

    func close() {
        lock.lock()
        let operation = closeOperation
        closeOperation = nil
        lock.unlock()
        operation?()
    }

    deinit { close() }
}

struct RecordingDestinationBookmarkCodec: @unchecked Sendable {
    let encodeScoped: (URL) throws -> Data
    let encodeStandard: (URL) throws -> Data
    let resolve: (Data, RecordingDestinationBookmarkKind) throws -> (url: URL, stale: Bool)
    let startAccessing: (URL) -> Bool
    let stopAccessing: (URL) -> Void

    static let live = RecordingDestinationBookmarkCodec(
        encodeScoped: { try $0.bookmarkData(options: [.withSecurityScope]) },
        encodeStandard: { try $0.bookmarkData(options: []) },
        resolve: { data, kind in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: kind == .securityScoped ? [.withSecurityScope] : [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        },
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

protocol RecordingDestinationStoring: AnyObject {
    var currentIdentity: RecordingDestinationIdentity? { get }
    func restore(defaultURL: URL) -> RecordingDestinationSelection
    func save(_ url: URL) throws
    func access(identity: RecordingDestinationIdentity) throws -> RecordingDestinationAccess
    func prune(keeping identities: Set<RecordingDestinationIdentity>)
}
```

`RecordingDestinationStore` writes a versioned catalog of identity, normalized
path, bookmark kind, and bookmark bytes plus a current identity. `save` first
tries `encodeScoped`; if the current non-sandboxed runtime rejects scoped
creation it uses `encodeStandard`. `restore` returns the default only when no
bookmark was ever configured. Decode failure, a stale bookmark, or path
mismatch returns the intended saved path with `.needsFolderAccess`; it never
rewrites the setting to Downloads. `access` starts/stops scope only for a
security-scoped entry and uses a no-op lease for a standard entry. `prune`
retains the current identity and every identity referenced by the queue.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: all `RecordingDestinationStoreTests` pass with zero failures.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/RecorderApp/Storage/RecordingDestinationStore.swift Tests/RecorderAppTests/RecordingDestinationStoreTests.swift
git commit -m "feat: persist recording destination access"
```

---

### Task 2: Create an owner-only pending store and durable manifest

**Files:**
- Modify: `Sources/RecorderApp/Setup/AppPaths.swift`
- Modify: `Sources/RecorderApp/RecordingModels.swift`
- Create: `Sources/RecorderApp/Storage/RecordingPendingStore.swift`
- Create: `Sources/RecorderApp/Storage/RecordingPublicationManifest.swift`
- Modify: `Tests/RecorderAppTests/AppPathsTests.swift`
- Create: `Tests/RecorderAppTests/RecordingPendingStoreTests.swift`

**Interfaces:**
- Consumes: `WorkspacePublicationFence` and `RecordingDestinationIdentity`.
- Produces: `RecordingPublicationItem`, `RecordingPublicationState`, `RecordingPublicationManifestStore`, and `RecordingPendingStore`.
- Later tasks open pending sessions only through
  `RecordingPendingStore.openSession(for:)` and retain the returned directory
  descriptor for the complete operation; a path-only pending-session API is
  intentionally absent.

- [ ] **Step 1: Write failing pending-root, containment, and recovery tests**

```swift
func testAppPathsOwnPendingRecordingsAndManifestUnderAppSupport() {
    let root = URL(fileURLWithPath: "/Users/test/Library/Application Support", isDirectory: true)
    let paths = AppPaths(
        homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
        applicationSupportRoot: root
    )
    XCTAssertEqual(
        paths.pendingRecordingsDirectory.path,
        "/Users/test/Library/Application Support/Local Meeting Recorder/Pending Recordings"
    )
    XCTAssertEqual(
        paths.recordingPublicationManifestURL.path,
        "/Users/test/Library/Application Support/Local Meeting Recorder/Pending Recordings/publication-queue-v1.json"
    )
}

func testCreateRootUsesOwnerOnlyPermissions() throws {
    let fixture = try PendingStoreFixture()
    try fixture.store.prepareRoot()
    XCTAssertEqual(try fixture.permissions(of: fixture.root) & 0o777, 0o700)
}

func testDirectChildIsAcceptedButSymlinkAndEscapeAreRejected() throws {
    let fixture = try PendingStoreFixture()
    let direct = try fixture.makeSession(named: "meeting-direct")
    let outside = try fixture.makeOutsideSession(named: "meeting-outside")
    let link = fixture.root.appendingPathComponent("meeting-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    XCTAssertEqual(try fixture.store.sessionURL(for: direct.lastPathComponent), direct)
    XCTAssertThrowsError(try fixture.store.sessionURL(for: link.lastPathComponent))
    XCTAssertThrowsError(try fixture.store.sessionURL(for: "../meeting-outside"))
}

func testCorruptManifestPreservesSessionsAndRebuildsNeedsAttentionItems() throws {
    let fixture = try PendingStoreFixture()
    let session = try fixture.makeSession(named: "meeting-recover")
    try Data("broken".utf8).write(to: fixture.manifestURL)

    let items = try fixture.manifest.loadOrRebuild(from: fixture.store)

    XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
    XCTAssertEqual(items.map(\.state), [.needsAttention])
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter 'AppPathsTests|RecordingPendingStoreTests'
```

Expected: compilation fails for missing pending paths and store types.

- [ ] **Step 3: Implement pending containment and manifest persistence**

Add to `AppPaths`:

```swift
var pendingRecordingsDirectory: URL {
    appSupportDirectory.appendingPathComponent("Pending Recordings", isDirectory: true)
}

var recordingPublicationManifestURL: URL {
    pendingRecordingsDirectory.appendingPathComponent("publication-queue-v1.json")
}
```

Define the durable item:

```swift
enum RecordingPublicationState: String, Codable, Equatable, Sendable {
    case pending
    case publishing
    case waitingForDestination
    case needsAttention
}

struct RecordingPublicationItem: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionDirectoryName: String
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFenceRevision: UInt64
    let recordingSource: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
    let createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var state: RecordingPublicationState
    var failureCategory: String?
}

struct RecordingPublicationManifest: Codable, Equatable, Sendable {
    let version: Int
    var items: [RecordingPublicationItem]
}
```

Add `Codable` to `RecordingHealthReport`; its focused manifest round-trip test
must assert every counter and timestamp survives relaunch.

`RecordingPendingStore.prepareRoot()` creates the root with `0o700` and verifies
it through `O_DIRECTORY | O_NOFOLLOW`. `openSession(for:)` rejects separators,
`.`/`..`, hidden names, symlinks, and non-direct children, then returns a handle
that retains the `openat` directory descriptor plus its `fstat` device/inode.
`scanSessionNames()` returns only names for which a retained handle can be
opened and skips the manifest and hidden publisher staging names.

`RecordingPublicationManifestStore.save(_:)` encodes `{version: 1, items: ...}` to an owner-only temporary sibling, synchronizes it, and renames it over the owned manifest. `loadOrRebuild(from:)` converts persisted `.publishing` to `.pending`. Decode/version failure scans valid session folders into `.needsAttention` items without deleting any file.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: `AppPathsTests` and `RecordingPendingStoreTests` pass.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/RecorderApp/Setup/AppPaths.swift Sources/RecorderApp/RecordingModels.swift Sources/RecorderApp/Storage/RecordingPendingStore.swift Sources/RecorderApp/Storage/RecordingPublicationManifest.swift Tests/RecorderAppTests/AppPathsTests.swift Tests/RecorderAppTests/RecordingPendingStoreTests.swift
git commit -m "feat: add durable pending recording store"
```

---

### Task 3: Verify and publish a session without replacement

**Files:**
- Create: `Sources/RecorderApp/Storage/RecordingSessionPublisher.swift`
- Modify: `Sources/RecorderApp/Recovery/IncompleteSessionRecovery.swift`
- Create: `Tests/RecorderAppTests/RecordingSessionPublisherTests.swift`
- Modify: `Tests/RecorderAppTests/IncompleteSessionRecoveryTests.swift`

**Interfaces:**
- Consumes: a `RecordingPublicationItem`, `RecordingPendingStore`, retained
  `RecordingPendingSession`, and `RecordingDestinationAccess`.
- Produces: `RecordingPublicationSuccess` through `RecordingSessionPublishing.publish(item:destination:) async throws`.
- The publisher does not mutate the queue manifest or AppModel.

- [ ] **Step 1: Write failing secure-publication tests**

```swift
final class RecordingSessionPublisherTests: XCTestCase {
    func testZeroByteMediaNeedsAttentionWithoutDestinationCopy() async throws {
        let fixture = try PublisherFixture(mediaBytes: Data())

        await XCTAssertThrowsErrorAsync(
            try await fixture.publisher.publish(
                item: fixture.item,
                destination: fixture.destinationAccess
            )
        ) { error in
            XCTAssertEqual(error as? RecordingPublicationError, .invalidMedia)
        }
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertTrue(fixture.destinationIsEmpty)
    }

    func testSymlinkInSessionTreeIsRejected() async throws {
        let fixture = try PublisherFixture(validMedia: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("transcript.txt"),
            withDestinationURL: fixture.outsideFile
        )
        await XCTAssertThrowsErrorAsync(
            try await fixture.publisher.publish(item: fixture.item, destination: fixture.destinationAccess)
        )
        XCTAssertTrue(fixture.sourceExists)
    }

    func testDigestMismatchKeepsSourceAndRemovesOnlyOwnedStaging() async throws {
        let fixture = try PublisherFixture(validMedia: true, mutateCopiedFileBeforeVerify: true)
        await XCTAssertThrowsErrorAsync(
            try await fixture.publisher.publish(item: fixture.item, destination: fixture.destinationAccess)
        )
        XCTAssertTrue(fixture.sourceExists)
        XCTAssertFalse(fixture.ownedStagingExists)
    }

    func testExistingAndLateDestinationEntriesAreNeverOverwritten() async throws {
        let fixture = try PublisherFixture(validMedia: true, createLateCollision: true)
        let existingData = Data("keep".utf8)
        try fixture.createExistingDestination(contents: existingData)

        _ = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destinationAccess)

        XCTAssertEqual(try fixture.existingDestinationData(), existingData)
        XCTAssertTrue(fixture.publishedURL.lastPathComponent.hasPrefix("meeting-"))
    }

    func testVerifiedPublicationReturnsCanonicalDestinationAndRemovesNoSource() async throws {
        let fixture = try PublisherFixture(validMedia: true)
        let success = try await fixture.publisher.publish(item: fixture.item, destination: fixture.destinationAccess)

        XCTAssertEqual(success.recordingURL.deletingLastPathComponent(), success.folderURL)
        XCTAssertEqual(try fixture.sourceDigest(), try fixture.publishedDigest())
        XCTAssertTrue(fixture.sourceExists, "Coordinator owns post-publication source removal")
    }

    func testRetryAfterPublishedRenameUsesMarkerAndDoesNotDuplicateDestination() async throws {
        let fixture = try PublisherFixture(validMedia: true)
        let first = try await fixture.publisher.publish(
            item: fixture.item,
            destination: fixture.destinationAccess
        )

        let second = try await fixture.publisher.publish(
            item: fixture.item,
            destination: fixture.destinationAccess
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(fixture.publishedSessionFolders.count, 1)
        XCTAssertTrue(fixture.sourceExists)
    }
}
```

The media validator is injected so unit tests can use deterministic fixture bytes; a separate focused test uses the live validator with a tiny valid M4A fixture already produced by the repository's AVFoundation test helpers.

- [ ] **Step 2: Run the publisher test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter RecordingSessionPublisherTests
```

Expected: compilation fails because the publisher interfaces do not exist.

- [ ] **Step 3: Implement secure copy and verified publication**

```swift
struct RecordingPublicationSuccess: Equatable, Sendable {
    let itemID: UUID
    let folderURL: URL
    let recordingURL: URL
}

enum RecordingPublicationError: Error, Equatable, Sendable {
    case invalidSource
    case unsafeEntry
    case invalidMedia
    case destinationUnavailable
    case verificationMismatch
    case destinationCollision
    case ioFailure(String)
}

protocol RecordingSessionPublishing: Sendable {
    func publish(
        item: RecordingPublicationItem,
        destination: RecordingDestinationAccess
    ) async throws -> RecordingPublicationSuccess
}
```

The production publisher must:

1. open and retain the source through
   `RecordingPendingStore.openSession(for:)`; all source enumeration, reads,
   hashing, and recovery are relative to this descriptor with
   `openat`/`fstatat(AT_SYMLINK_NOFOLLOW)` and `O_NOFOLLOW`;
2. add a descriptor-relative overload to `IncompleteSessionRecovery` and use
   it for pending sources. It may promote only the exact backup/final names
   inside the retained directory and must preserve the existing URL-based API
   for existing Library callers;
3. enumerate direct entries from a duplicated directory descriptor, accepting
   directories and regular files only and rejecting every symlink. Recursive
   descent opens each directory through `openat`; no source read reopens the
   display URL;
4. require exactly one supported finalized recording with non-zero bytes and finite duration greater than zero;
5. search only valid direct destination children for
   `.lmr-publication-v1.json`; a matching item UUID and source-inventory digest
   is the idempotent success from an earlier rename;
6. create `.<item-id>.lmr-publishing` beneath the destination with `0o700`;
7. copy each regular file with owner-only destination permissions;
8. build sorted `[relativePath, byteCount, SHA256]` inventories for source and staging and require equality;
9. write an owner-only `.lmr-publication-v1.json` containing version 1, item UUID,
   and the aggregate source-inventory digest; exclude only this marker from the
   content inventory comparison;
10. choose the original session name when free, otherwise `original-<item UUID>`;
11. publish using `renameatx_np(..., RENAME_EXCL)` and never `replaceItemAt`;
12. revalidate the published media and return its canonical URLs;
13. remove only the exact owned hidden staging directory on failure.

Use `CryptoKit.SHA256` with descriptor reads in 1,048,576-byte chunks so large
recordings are not loaded into memory. `displayURL` is for user presentation
only and must not be reopened for source I/O.

- [ ] **Step 4: Run publisher tests and verify GREEN**

Run the Step 2 command. Expected: all publisher tests pass with zero failures.

- [ ] **Step 5: Commit Task 3**

```bash
git add Sources/RecorderApp/Storage/RecordingSessionPublisher.swift Sources/RecorderApp/Recovery/IncompleteSessionRecovery.swift Tests/RecorderAppTests/RecordingSessionPublisherTests.swift Tests/RecorderAppTests/IncompleteSessionRecoveryTests.swift
git commit -m "feat: publish verified recording sessions"
```

---

### Task 4: Drive one durable retry queue

**Files:**
- Create: `Sources/RecorderApp/Storage/RecordingPublicationCoordinator.swift`
- Create: `Tests/RecorderAppTests/RecordingPublicationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `RecordingPublicationManifestStore`, `RecordingDestinationStoring`, `RecordingSessionPublishing`, and `RecordingPendingStore`.
- Produces: `RecordingPublicationPresentation`, `RecordingPublicationCompleted`, `enqueue`, `resume`, `retryNow`, and `shutdown`.
- AppModel observes completion and presentation callbacks on the main actor.

- [ ] **Step 1: Write failing queue transition tests**

```swift
func testOfflineAttemptRetainsSourceAndLaterRetryPublishesOnce() async throws {
    let fixture = try PublicationCoordinatorFixture(destinationAvailable: false)
    fixture.coordinator.enqueue(fixture.request)
    await fixture.waitForIdle()

    XCTAssertEqual(fixture.coordinator.presentation.waitingCount, 1)
    XCTAssertTrue(fixture.sourceExists)

    fixture.destinationAvailable = true
    fixture.coordinator.retryNow()
    await fixture.waitForIdle()

    XCTAssertEqual(fixture.publisher.publishedItemIDs, [fixture.request.id])
    XCTAssertEqual(fixture.completions.map(\.itemID), [fixture.request.id])
    XCTAssertFalse(fixture.sourceExists)
}

func testRelaunchResetsPublishingToPendingAndResumes() async throws {
    let fixture = try PublicationCoordinatorFixture(manifestState: .publishing)
    fixture.coordinator.resume()
    await fixture.waitForIdle()
    XCTAssertEqual(fixture.publisher.publishedItemIDs, [fixture.request.id])
}

func testInvalidMediaNeedsAttentionAndDoesNotAutoRetry() async throws {
    let fixture = try PublicationCoordinatorFixture(publisherError: .invalidMedia)
    fixture.coordinator.enqueue(fixture.request)
    await fixture.waitForIdle()
    fixture.coordinator.resume()
    await fixture.waitForIdle()

    XCTAssertEqual(fixture.publisher.attemptCount, 1)
    XCTAssertEqual(fixture.coordinator.presentation.needsAttentionCount, 1)
    XCTAssertTrue(fixture.sourceExists)
}

func testShutdownCancelsBackoffAndLateSuccessCannotDeleteSource() async throws {
    let fixture = try PublicationCoordinatorFixture(suspendedPublish: true)
    fixture.coordinator.enqueue(fixture.request)
    await fixture.publisher.waitUntilStarted()
    fixture.coordinator.shutdown()
    fixture.publisher.completeSuccessfully()
    await fixture.waitForIdle()

    XCTAssertTrue(fixture.sourceExists)
    XCTAssertTrue(fixture.completions.isEmpty)
}
```

- [ ] **Step 2: Run coordinator tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter RecordingPublicationCoordinatorTests
```

Expected: compilation fails because coordinator and presentation types do not exist.

- [ ] **Step 3: Implement the serial coordinator**

```swift
struct RecordingPublicationRequest: Equatable, Sendable {
    let id: UUID
    let localFolderURL: URL
    let destinationIdentity: RecordingDestinationIdentity
    let workspaceFence: WorkspacePublicationFence
    let source: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
}

struct RecordingPublicationCompleted: Equatable, Sendable {
    let itemID: UUID
    let folderURL: URL
    let recordingURL: URL
    let workspaceFence: WorkspacePublicationFence
    let source: RecordingSource
    let health: RecordingHealthReport
    let metadataWarning: String?
}

struct RecordingPublicationPresentation: Equatable, Sendable {
    let stateText: String
    let pendingCount: Int
    let waitingCount: Int
    let needsAttentionCount: Int
    var retainedLocalCount: Int { pendingCount + waitingCount + needsAttentionCount }
}

protocol RecordingPublicationCoordinating: AnyObject {
    var presentation: RecordingPublicationPresentation { get }
    var onPresentationChange: (@MainActor (RecordingPublicationPresentation) -> Void)? { get set }
    var onCompleted: (@MainActor (RecordingPublicationCompleted) -> Void)? { get set }
    func enqueue(_ request: RecordingPublicationRequest)
    func resume()
    func retryNow()
    func shutdown()
}
```

Implement one generation-fenced `Task` that serially drains eligible items.
Reconstruct completion health, source, warning, and fence from the persisted
item, not an in-memory request. Classify `destinationUnavailable` as
`waitingForDestination`; classify invalid source/media, unsafe entry, and
verification mismatch as `needsAttention`; classify transient I/O as `pending`
with bounded retry delays of 2, 10, 30, 60, then 300 seconds. Manual retry
immediately moves waiting and transient pending items to the drain head. Only
after a current-generation publish success does the coordinator emit
completion, remove the validated local direct child, remove the manifest item,
persist the manifest, and prune destination catalog entries not referenced by
the remaining queue or current selection. Shutdown increments the generation,
cancels the task, and rejects late completion.

- [ ] **Step 4: Run coordinator tests and verify GREEN**

Run the Step 2 command. Expected: all coordinator tests pass.

- [ ] **Step 5: Commit Task 4**

```bash
git add Sources/RecorderApp/Storage/RecordingPublicationCoordinator.swift Tests/RecorderAppTests/RecordingPublicationCoordinatorTests.swift
git commit -m "feat: resume pending recording publication"
```

---

### Task 5: Route recording and Library finalization through publication

**Files:**
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/RecordingEngine.swift`
- Create: `Tests/RecorderAppTests/AppModelRecordingPublicationTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelRecordingFinalizationTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelScreenCaptureTests.swift`

**Interfaces:**
- Consumes: all Task 1–4 interfaces.
- Produces AppModel properties/actions used by UI: `recordingDestinationState`, `recordingPublicationPresentation`, `retryPendingRecordings()`, and `openPendingRecordingsFolder()`.
- Maintains `outputFolder` as the selected destination and the Library workspace; `RecordingEngine.start` receives only `appPaths.pendingRecordingsDirectory`.

- [ ] **Step 1: Write failing AppModel integration tests**

```swift
func testRestoredDestinationIsLibraryWorkspaceButRecordingStartsInPendingRoot() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .ready)
    fixture.model.startRecording()
    await fixture.waitForRecorderStart()

    XCTAssertEqual(fixture.model.outputFolder, fixture.destination)
    XCTAssertEqual(fixture.recorder.startedBaseFolder, fixture.pendingRoot)
}

func testStopEnqueuesLocalResultAndDoesNotFinalizeLibraryBeforePublication() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .ready)
    fixture.recorder.stopResult = fixture.localResult

    await fixture.model.finishRecording(playAfterStop: false)

    XCTAssertEqual(fixture.publication.requests.count, 1)
    XCTAssertEqual(fixture.publication.requests[0].localFolderURL, fixture.localResult.folderURL)
    XCTAssertTrue(fixture.libraryFinalizations.isEmpty)
    XCTAssertEqual(fixture.model.statusMessage, "Recording saved locally; publishing")
}

func testVerifiedCompletionFinalizesCanonicalDestinationThroughCapturedFence() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .ready)
    await fixture.model.finishRecording(playAfterStop: false)
    fixture.publication.complete(with: fixture.destinationCompletion)

    XCTAssertEqual(fixture.libraryFinalizations.count, 1)
    XCTAssertEqual(fixture.libraryFinalizations[0].folder, fixture.destinationCompletion.folderURL)
    XCTAssertEqual(fixture.libraryFinalizations[0].recordingURL, fixture.destinationCompletion.recordingURL)
    XCTAssertEqual(fixture.libraryFinalizations[0].workspaceFence, fixture.capturedFence)
}

func testDestinationChangeRejectsStaleCompletionFromCurrentLibraryProjection() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .ready)
    await fixture.model.finishRecording(playAfterStop: false)
    fixture.model.setOutputFolder(fixture.otherDestination)
    fixture.publication.complete(with: fixture.destinationCompletion)

    XCTAssertTrue(fixture.libraryFinalizations.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationCompletion.folderURL.path))
}

func testStaleBookmarkStillRecordsLocallyAndQueuesOriginalIdentity() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .needsFolderAccess)
    fixture.model.startRecording()
    await fixture.waitForRecorderStart()

    XCTAssertEqual(fixture.recorder.startedBaseFolder, fixture.pendingRoot)
    XCTAssertEqual(fixture.model.recordingDestinationState, .needsFolderAccess)
    await fixture.model.finishRecording(playAfterStop: false)
    XCTAssertEqual(
        fixture.publication.requests.single?.destinationIdentity,
        fixture.savedDestinationIdentity
    )
}

func testChangingDestinationDuringRecordingDoesNotRetargetPendingItem() async throws {
    let fixture = try AppModelPublicationFixture(restoredDestination: .ready)
    fixture.model.startRecording()
    await fixture.waitForRecorderStart()
    let capturedIdentity = fixture.model.recordingDestinationIdentity
    fixture.model.setOutputFolder(fixture.otherDestination)

    await fixture.model.finishRecording(playAfterStop: false)

    XCTAssertEqual(fixture.publication.requests.single?.destinationIdentity, capturedIdentity)
    XCTAssertEqual(fixture.publication.requests.single?.workspaceFence, .initial)
}
```

- [ ] **Step 2: Run integration tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter 'AppModelRecordingPublicationTests|AppModelRecordingFinalizationTests|AppModelScreenCaptureTests'
```

Expected: new tests fail because AppModel still records into `outputFolder` and finalizes the local folder immediately.

- [ ] **Step 3: Integrate destination, pending recording, and publication**

Add injectable constructor parameters with live defaults:

```swift
recordingDestinationStore: (any RecordingDestinationStoring)? = nil,
recordingPublicationCoordinator: (any RecordingPublicationCoordinating)? = nil
```

Initialization order must be:

1. construct or accept the destination store;
2. if `initialOutputFolder` exists, keep it authoritative for the fixture;
3. otherwise restore the selected destination before constructing the PRB bridge;
4. construct pending/manifest/publisher/coordinator live dependencies;
5. install callbacks before `resume()`;
6. run startup recovery and queue resume only when `performStartupWork` is true.

Change both normal and 10-second test starts to check capacity at and pass `appPaths.pendingRecordingsDirectory`. Create the recording session folder with `0o700` in `RecordingEngine.start`.

Capture an immutable `ActiveRecordingPublicationContext` containing destination
identity and workspace fence before starting the recorder; clear it on failed or
cancelled start. After `recorder.stop()` and source metadata update, build
`RecordingPublicationRequest` from the local result and that captured context,
not current AppModel state. Do not call
`prbFeatureBridge.recordingDidFinalize` for the local pending URL. On a current
completion whose fence and destination still match the active workspace, emit
`RecordingFinalizationOutcome` using destination URLs and
`finalizationID: completion.itemID`; a stale completion
remains on disk but does not mutate the current Library projection.

Status copy:

```swift
"Recording saved locally; publishing"
"Recording saved locally; waiting for OneDrive"
"Recording saved locally; publication needs attention"
"Recording published: \(health.summary)"
```

`setOutputFolder` first saves the bookmark; only after a successful save does it update `outputFolder`, destination state, fence, and PRB workspace. `shutdown()` shuts down the publication coordinator before feature boundaries.

- [ ] **Step 4: Run AppModel integration tests and verify GREEN**

Run the Step 2 command. Expected: all three focused suites pass with zero failures.

- [ ] **Step 5: Commit Task 5**

```bash
git add Sources/RecorderApp/AppModel.swift Sources/RecorderApp/RecordingEngine.swift Tests/RecorderAppTests/AppModelRecordingPublicationTests.swift Tests/RecorderAppTests/AppModelRecordingFinalizationTests.swift Tests/RecorderAppTests/AppModelScreenCaptureTests.swift
git commit -m "feat: finalize recordings locally before publication"
```

---

### Task 6: Present destination and retained-local status

**Files:**
- Modify: `Sources/RecorderApp/UI/RecordDashboardView.swift`
- Modify: `Sources/RecorderApp/UI/RecorderSettingsView.swift`
- Modify: the existing source file that declares `RecorderActionID`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`

**Interfaces:**
- Consumes AppModel's destination/publication state and two actions from Task 5.
- Produces stable accessibility identifiers: `recorder.storage.pending-banner`, `recorder.storage.retry`, `recorder.storage.open-local`, `recorder.storage.destination-status`, and `recorder.storage.pending-status`.

- [ ] **Step 1: Write failing render and action-reachability tests**

```swift
func testRecordWorkspaceShowsPendingPublicationBannerActions() throws {
    let fixture = try makeWorkspaceFixture(
        publication: .init(
            stateText: "Waiting for OneDrive",
            pendingCount: 0,
            waitingCount: 2,
            needsAttentionCount: 0
        )
    )
    let hierarchy = fixture.renderRecordWorkspace()

    XCTAssertTrue(hierarchy.containsAccessibilityIdentifier("recorder.storage.pending-banner"))
    XCTAssertTrue(hierarchy.containsAccessibilityIdentifier("recorder.storage.retry"))
    XCTAssertTrue(hierarchy.containsAccessibilityIdentifier("recorder.storage.open-local"))
    XCTAssertTrue(hierarchy.containsText("2 recordings retained locally"))
}

func testStorageSettingsExposeDestinationAccessAndNeedsAttention() throws {
    let fixture = try makeWorkspaceFixture(
        destinationState: .needsFolderAccess,
        publication: .init(
            stateText: "Publish failed",
            pendingCount: 0,
            waitingCount: 0,
            needsAttentionCount: 1
        )
    )
    let hierarchy = fixture.renderStorageSettings()

    XCTAssertTrue(hierarchy.containsText("Needs folder access"))
    XCTAssertTrue(hierarchy.containsText("1 recording needs attention"))
    XCTAssertTrue(hierarchy.containsAccessibilityIdentifier("recorder.storage.destination-status"))
    XCTAssertTrue(hierarchy.containsAccessibilityIdentifier("recorder.storage.pending-status"))
}

func testReadyWithNoRetainedSessionsDoesNotRenderPendingBanner() throws {
    let fixture = try makeWorkspaceFixture(publication: .emptyReady)
    XCTAssertFalse(
        fixture.renderRecordWorkspace().containsAccessibilityIdentifier(
            "recorder.storage.pending-banner"
        )
    )
}
```

- [ ] **Step 2: Run render tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter RecorderWorkspaceRenderTests
```

Expected: assertions fail because the new identifiers and status copy are absent.

- [ ] **Step 3: Add compact Storage and Record presentations**

In the Record workspace, render a compact warning-material banner only when `retainedLocalCount > 0`. Show the count, `stateText`, **Retry Now**, and **Open Local Copies**. Do not block Start.

In Storage settings, show destination path, one of `Ready`, `Needs folder access`, or `Unavailable`, pending root path, pending/waiting/needs-attention counts, and the same actions when relevant. Rename **Choose Output Folder** to **Restore Folder Access** only while state is `.needsFolderAccess`.

Wire buttons exclusively to:

```swift
Button("Retry Now", action: model.retryPendingRecordings)
Button("Open Local Copies", action: model.openPendingRecordingsFolder)
```

Do not expose bookmark bytes, hashes, captured content, or detailed filesystem errors in accessibility values.

- [ ] **Step 4: Run render tests and verify GREEN**

Run the Step 2 command. Expected: `RecorderWorkspaceRenderTests` passes.

- [ ] **Step 5: Commit Task 6**

```bash
git add Sources/RecorderApp/UI/RecordDashboardView.swift Sources/RecorderApp/UI/RecorderSettingsView.swift Sources/RecorderApp/UI/RecorderActionID.swift Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git diff --cached --name-only
git commit -m "feat: show pending recording publication"
```

Confirm `git diff --cached --name-only` contains only the two views,
`RecorderActionID.swift`, and the render test.

---

### Task 7: Verify the complete storage boundary and stage it on OneDrive

**Files:**
- Modify only if a genuine product defect is found by the specified verification.
- Create: `docs/testing/2026-08-13-reliable-recording-storage-uat.md`

**Interfaces:**
- Verifies all Task 1–6 interfaces as one release candidate.

- [ ] **Step 1: Run the combined relevant automated suite once**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
test --disable-sandbox --filter 'RecordingDestinationStoreTests|RecordingPendingStoreTests|RecordingSessionPublisherTests|RecordingPublicationCoordinatorTests|AppModelRecordingPublicationTests|AppModelRecordingFinalizationTests|RecordingStoragePolicyTests|IncompleteSessionRecoveryTests|RecorderWorkspaceRenderTests'
```

Expected: all selected tests pass with zero failures. Do not run a broader device/cloud matrix unless this command exposes a cross-suite defect.

- [ ] **Step 2: Build and verify staging candidate 0.2.0 (346)**

```bash
CLANG_MODULE_CACHE_PATH=/tmp/recorder-clang-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/recorder-swiftpm-module-cache \
scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 346 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Staging" \
  --sign ad-hoc

scripts/verify-app-bundle.sh \
  "build/Local Meeting Recorder Staging.app" \
  local.meeting.recorder.staging 0.2.0 346 ad-hoc

codesign --verify --deep --strict "build/Local Meeting Recorder Staging.app"
```

Expected: build exits 0, bundle verifier reports both manifests OK, and codesign verification exits 0.

- [ ] **Step 3: Install with a recoverable exact replacement**

Quit the running Staging app. Move the exact existing bundle to a uniquely named directory under `/private/tmp`, move the verified build to `/Applications/Local Meeting Recorder Staging.app`, and rerun the Step 2 verifier against `/Applications`. Do not remove the previous bundle until UAT passes.

- [ ] **Step 4: Perform bounded OneDrive acceptance**

Use the exact destination:

`/Users/apple/Library/CloudStorage/OneDrive-pccw.com/Work/Meeting Recording`

Verify and record evidence for:

1. choose the folder, quit/relaunch, and confirm the exact path restores;
2. record a short local microphone sample with OneDrive available; Stop returns after local finalization, publication completes, media is non-zero/readable, and no pending copy remains;
3. temporarily choose an unavailable test destination through an injected/test seam rather than altering OneDrive security settings; record/stop and confirm the local retained banner;
4. restore the real folder and press **Retry Now**; confirm verified destination publication then local cleanup;
5. create a controlled pending item, relaunch, and confirm resume;
6. create a controlled zero-byte pending artifact and confirm **Needs attention** without deletion or a false success message.

Do not record real meeting content for this UAT. Use a short spoken test phrase and delete only UAT artifacts explicitly identified by their generated test session names after evidence is captured.

- [ ] **Step 5: Write and commit the UAT record**

The Markdown record must include candidate version/commit, exact automated command and totals, bundle verification, each acceptance result, generated test session names, cleanup outcome, and any remaining limitation. Then:

```bash
git add docs/testing/2026-08-13-reliable-recording-storage-uat.md
git commit -m "docs: record reliable storage acceptance"
```

- [ ] **Step 6: Remove the prior app backup only after acceptance**

After the installed 346 bundle and all UAT rows pass, remove only the exact uniquely named prior Staging backup from `/private/tmp`. Report that this backup is no longer recoverable. If any UAT row fails, retain the backup and report the exact blocker instead.

---

## Plan Self-Review Checklist

- Every approved design requirement maps to Tasks 1–7.
- Destination restoration never silently falls back after a saved bookmark fails.
- Capture writes only to local pending storage; Library admission uses only the verified destination copy.
- Source deletion belongs only to the generation-fenced coordinator after publisher success.
- Publisher tests cover zero-byte, symlink, hash mismatch, existing destination, late collision, and successful verification.
- Queue tests cover offline retry, crash resume, needs-attention non-retry, and stale completion after shutdown.
- Publisher retry after destination rename is idempotent through an exact marker.
- Publisher source and pending recovery use only retained descriptor-relative
  operations; pending display URLs are never reopened for source I/O.
- Queue manifests preserve health, source, warning, destination identity, and fence across relaunch.
- AppModel tests cover pending routing, no premature Library admission, captured fence, and destination changes.
- UI tests cover retained-local visibility without blocking recording.
- Verification is focused and includes one bounded OneDrive UAT.
- Developer ID, Hardened Runtime, notarization, and App Sandbox changes are absent.
