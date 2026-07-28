# Secure Credentials and Teams Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store small recorder secrets in macOS Keychain, migrate the existing Teams pairing token without data loss, and make Teams mute sync fail closed when credential operations fail.

**Architecture:** Add one Security-framework-backed generic-password primitive, then build a Teams-specific migration store on top of it. `TeamsMuteSyncClient` continues to own socket lifecycle and absolute mute state, but credential reads, writes, and cleanup become throwing operations with redacted failures.

**Tech Stack:** Swift 5.9, Foundation, Security.framework, UserDefaults, XCTest, Microsoft Teams desktop Third-party app API.

## Global Constraints

- Minimum deployment target remains macOS 15.
- Use native Security.framework; add no Keychain package dependency.
- Store no token or API key in `UserDefaults`, process arguments, process environment, logs, diagnostics, or status text.
- Keychain service is `local.meeting.recorder.teams-third-party-api`.
- Keychain account is `pairing-token.v1`.
- Preserve legacy key `teamsThirdPartyAPIPairingToken` until Keychain save and read-back both succeed.
- Keychain wins if both stores already contain values.
- Invalid-token cleanup attempts both stores and stops reconnecting if cleanup fails.
- A credential failure must never be interpreted as an unmuted Teams state.
- Do not modify or install the running application.
- Do not touch the dirty main-checkout manifest drafts.

---

## File Structure

- Create `Sources/RecorderApp/Security/SecureValueStore.swift`
  - Generic-password Keychain backend and typed redacted errors.
- Create `Tests/RecorderAppTests/SecureValueStoreTests.swift`
  - Deterministic fake-backend tests for every `OSStatus` branch.
- Create `Sources/RecorderApp/Teams/KeychainTeamsPairingTokenStore.swift`
  - Teams token encoding, migration, verification, and cleanup.
- Create `Tests/RecorderAppTests/TeamsPairingTokenStoreTests.swift`
  - Keychain-first and lossless migration tests.
- Modify `Sources/RecorderApp/Teams/TeamsMuteSyncClient.swift`
  - Throwing token-store interface and fail-closed client behavior.
- Modify `Sources/RecorderApp/AppModel.swift`
  - Inject the Keychain-backed Teams store.
- Modify `Tests/RecorderAppTests/TeamsMuteSyncClientTests.swift`
  - Storage-failure and existing lifecycle regression coverage.

### Task 1: Generic Keychain Secure Value Store

**Files:**
- Create: `Sources/RecorderApp/Security/SecureValueStore.swift`
- Create: `Tests/RecorderAppTests/SecureValueStoreTests.swift`

**Interfaces:**
- Produces: `SecureValueStoring.load(service:account:) throws -> Data?`
- Produces: `SecureValueStoring.save(_:service:account:) throws`
- Produces: `SecureValueStoring.delete(service:account:) throws`
- Produces: `KeychainSecureValueStore`
- Produces: `SecureValueStoreError.operationFailed(operation:status:)`
- Produces: `SecureValueStoreError.missingResultData`

- [ ] **Step 1: Write failing add, update, read, delete, and error tests**

Create a fake backend that records only service, account, status, and data. It
must never stringify the secret in a failure:

```swift
import Security
import XCTest
@testable import RecorderApp

final class SecureValueStoreTests: XCTestCase {
    func testLoadReturnsNilForItemNotFound() throws {
        let backend = FakeKeychainBackend(readResult: .init(
            status: errSecItemNotFound,
            data: nil
        ))
        let store = KeychainSecureValueStore(backend: backend)

        XCTAssertNil(try store.load(service: "service", account: "account"))
    }

    func testSaveAddsNewValue() throws {
        let backend = FakeKeychainBackend(addStatus: errSecSuccess)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("do-not-log".utf8)

        try store.save(secret, service: "service", account: "account")

        XCTAssertEqual(backend.addedData, secret)
        XCTAssertEqual(backend.updateCount, 0)
    }

    func testDuplicateAddUpdatesExistingValue() throws {
        let backend = FakeKeychainBackend(
            addStatus: errSecDuplicateItem,
            updateStatus: errSecSuccess
        )
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("replacement".utf8)

        try store.save(secret, service: "service", account: "account")

        XCTAssertEqual(backend.updatedData, secret)
        XCTAssertEqual(backend.updateCount, 1)
    }

    func testDeleteTreatsMissingItemAsSuccess() {
        let backend = FakeKeychainBackend(deleteStatus: errSecItemNotFound)
        let store = KeychainSecureValueStore(backend: backend)

        XCTAssertNoThrow(
            try store.delete(service: "service", account: "account")
        )
    }

    func testUnexpectedStatusIsRedacted() {
        let backend = FakeKeychainBackend(addStatus: errSecAuthFailed)
        let store = KeychainSecureValueStore(backend: backend)
        let secret = Data("never-appear".utf8)

        XCTAssertThrowsError(
            try store.save(secret, service: "service", account: "account")
        ) { error in
            XCTAssertFalse(error.localizedDescription.contains("never-appear"))
            XCTAssertTrue(error.localizedDescription.contains("\(errSecAuthFailed)"))
        }
    }

    func testSuccessWithoutDataIsRejected() {
        let backend = FakeKeychainBackend(readResult: .init(
            status: errSecSuccess,
            data: nil
        ))

        XCTAssertThrowsError(
            try KeychainSecureValueStore(backend: backend)
                .load(service: "service", account: "account")
        )
    }
}
```

The fake implements all four backend methods and exposes `addedData`,
`updatedData`, `updateCount`, and configured statuses.

- [ ] **Step 2: Run the focused test to verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter SecureValueStoreTests
```

Expected: compile failure because `KeychainSecureValueStore` and its backend
types do not exist.

- [ ] **Step 3: Implement the Security-framework backend**

Create the production file with these complete interfaces and status rules:

```swift
import Foundation
import Security

protocol SecureValueStoring: Sendable {
    func load(service: String, account: String) throws -> Data?
    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws
    func delete(service: String, account: String) throws
}

struct KeychainReadResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol KeychainBackend: Sendable {
    func read(service: String, account: String) -> KeychainReadResult
    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus
    func update(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

enum SecureValueStoreError: LocalizedError, Equatable {
    case operationFailed(operation: String, status: OSStatus)
    case missingResultData

    var errorDescription: String? {
        switch self {
        case .operationFailed(let operation, let status):
            "Keychain \(operation) failed with status \(status)."
        case .missingResultData:
            "Keychain returned success without credential data."
        }
    }
}

struct SystemKeychainBackend: KeychainBackend {
    func read(service: String, account: String) -> KeychainReadResult {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        return KeychainReadResult(status: status, data: result as? Data)
    }

    func add(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(
        _ data: Data,
        service: String,
        account: String
    ) -> OSStatus {
        SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class KeychainSecureValueStore:
    SecureValueStoring,
    @unchecked Sendable
{
    private let backend: any KeychainBackend

    init(backend: any KeychainBackend = SystemKeychainBackend()) {
        self.backend = backend
    }

    func load(service: String, account: String) throws -> Data? {
        let result = backend.read(service: service, account: account)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw SecureValueStoreError.missingResultData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SecureValueStoreError.operationFailed(
                operation: "read",
                status: result.status
            )
        }
    }

    func save(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        let addStatus = backend.add(
            data,
            service: service,
            account: account
        )
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw SecureValueStoreError.operationFailed(
                operation: "add",
                status: addStatus
            )
        }
        let updateStatus = backend.update(
            data,
            service: service,
            account: account
        )
        guard updateStatus == errSecSuccess else {
            throw SecureValueStoreError.operationFailed(
                operation: "update",
                status: updateStatus
            )
        }
    }

    func delete(service: String, account: String) throws {
        let status = backend.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureValueStoreError.operationFailed(
                operation: "delete",
                status: status
            )
        }
    }
}
```

- [ ] **Step 4: Complete the fake backend and run GREEN**

Implement `FakeKeychainBackend` as an `@unchecked Sendable` test double guarded
by `NSLock`, then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter SecureValueStoreTests
```

Expected: all secure-store tests pass; no test output contains fixture secret
values.

- [ ] **Step 5: Commit Task 1**

```bash
git add \
  Sources/RecorderApp/Security/SecureValueStore.swift \
  Tests/RecorderAppTests/SecureValueStoreTests.swift
git commit -m "Add Keychain secure value store"
```

### Task 2: Lossless Teams Migration and Fail-Closed Client

**Files:**
- Create: `Sources/RecorderApp/Teams/KeychainTeamsPairingTokenStore.swift`
- Create: `Tests/RecorderAppTests/TeamsPairingTokenStoreTests.swift`
- Modify: `Sources/RecorderApp/Teams/TeamsMuteSyncClient.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Tests/RecorderAppTests/TeamsMuteSyncClientTests.swift`

**Interfaces:**
- Consumes: Task 1 `SecureValueStoring`
- Produces: throwing `TeamsPairingTokenStoring`
- Produces: `KeychainTeamsPairingTokenStore`
- Produces: redacted `.failed(String)` on any load/save/clear failure
- Preserves: socket generation, heartbeat, pairing, stale-event rejection, and
  absolute mute-state behavior

- [ ] **Step 1: Write failing migration tests**

Cover Keychain priority, verified migration, failed write/read-back, invalid
UTF-8, and two-store cleanup:

```swift
final class TeamsPairingTokenStoreTests: XCTestCase {
    func testKeychainWinsAndDeletesDifferentLegacyToken() throws {
        let secure = InMemorySecureValueStore(
            stored: Data("keychain-token".utf8)
        )
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)
        let store = makeStore(secure: secure, defaults: defaults)

        XCTAssertEqual(try store.load(), "keychain-token")
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    func testLegacyTokenIsDeletedOnlyAfterVerifiedMigration() throws {
        let secure = InMemorySecureValueStore()
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)
        let store = makeStore(secure: secure, defaults: defaults)

        XCTAssertEqual(try store.load(), "legacy-token")
        XCTAssertEqual(secure.stored, Data("legacy-token".utf8))
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }

    func testFailedSavePreservesLegacyToken() {
        let secure = InMemorySecureValueStore(saveError: TestError.failed)
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        )
        XCTAssertEqual(
            defaults.string(forKey: Self.legacyKey),
            "legacy-token"
        )
    }

    func testReadBackMismatchPreservesLegacyToken() {
        let secure = InMemorySecureValueStore(
            readBackOverride: Data("different-token".utf8)
        )
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).load()
        )
        XCTAssertEqual(
            defaults.string(forKey: Self.legacyKey),
            "legacy-token"
        )
    }

    func testClearRemovesLegacyValueEvenWhenKeychainDeleteFails() {
        let secure = InMemorySecureValueStore(deleteError: TestError.failed)
        let defaults = makeDefaults()
        defaults.set("legacy-token", forKey: Self.legacyKey)

        XCTAssertThrowsError(
            try makeStore(secure: secure, defaults: defaults).clear()
        )
        XCTAssertNil(defaults.object(forKey: Self.legacyKey))
    }
}
```

Use a unique `UserDefaults(suiteName:)` per test and remove its persistent
domain in `tearDown`.

- [ ] **Step 2: Convert the client test double and add fail-closed tests**

Replace the in-memory token store with throwing `load/save/clear` methods and
injectable `loadError`, `saveError`, and `clearError`. Update existing
assertions from `tokenStore.token` to `try tokenStore.load()`.

Add:

```swift
func testCredentialLoadFailureDoesNotCreateSocket() async {
    let store = InMemoryTeamsPairingTokenStore()
    store.loadError = TestError.failed
    let factory = RecordingConnectionFactory()
    let recorder = TeamsEventRecorder()
    let client = makeClient(tokenStore: store, factory: factory)

    client.start(onEvent: recorder.record)
    await waitUntil {
        recorder.events.contains {
            guard case .status(.failed(let message)) = $0 else {
                return false
            }
            return message.contains("Keychain")
        }
    }

    XCTAssertTrue(factory.createdURLs.isEmpty)
}

func testTokenRefreshSaveFailureNeverReportsReady() async {
    let store = InMemoryTeamsPairingTokenStore()
    store.saveError = TestError.failed
    let fixture = makeConnectedClient(tokenStore: store)

    fixture.socket.pushIncoming(
        #"{"tokenRefresh":"secret-value"}"#
    )
    await fixture.waitForFailure()

    XCTAssertFalse(fixture.events.contains(.status(.ready)))
    XCTAssertFalse(
        fixture.events.description.contains("secret-value")
    )
}

func testInvalidTokenClearFailureStopsAutomaticReconnect() async {
    let store = InMemoryTeamsPairingTokenStore(token: "stale")
    store.clearError = TestError.failed
    let fixture = makeConnectedClient(tokenStore: store)

    fixture.socket.pushIncoming(#"{"errorMsg":"Invalid token"}"#)
    await fixture.waitForFailure()
    try? await Task.sleep(for: .milliseconds(30))

    XCTAssertEqual(fixture.factory.createdURLs.count, 1)
}

func testReconnectCannotAdvanceGenerationDuringTokenSave() async {
    let store = BlockingTeamsPairingTokenStore(token: nil)
    let fixture = makeConnectedClient(tokenStore: store)
    fixture.socket.pushIncoming(
        #"{"tokenRefresh":"fresh-token"}"#
    )
    await store.waitUntilSaveStarts()

    let reconnect = Task { fixture.client.reconnect() }
    try? await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(fixture.factory.createdURLs.count, 1)

    store.allowSaveToFinish()
    await reconnect.value
    await waitUntil {
        fixture.factory.createdURLs.count == 2
    }
    XCTAssertEqual(try? store.load(), "fresh-token")
}

func testReconnectCannotAdvanceGenerationDuringTokenClear() async {
    let store = BlockingTeamsPairingTokenStore(token: "stale")
    let fixture = makeConnectedClient(tokenStore: store)
    fixture.socket.pushIncoming(
        #"{"errorMsg":"Invalid token"}"#
    )
    await store.waitUntilClearStarts()

    let reconnect = Task { fixture.client.reconnect() }
    try? await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(fixture.factory.createdURLs.count, 1)

    store.allowClearToFinish()
    await reconnect.value
    await waitUntil {
        fixture.factory.createdURLs.count >= 2
    }
    XCTAssertNil(try? store.load())
}
```

`BlockingTeamsPairingTokenStore` uses test-only semaphores rather than timing
the mutation itself. Its `save` and `clear` methods signal a "started"
semaphore, wait on an "allow finish" semaphore, then mutate their lock-guarded
token while the async test observes factory counts.

- [ ] **Step 3: Run both focused suites to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsPairingTokenStoreTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsMuteSyncClientTests
```

Expected: compile failures because the new store and throwing protocol do not
exist.

- [ ] **Step 4: Implement the throwing store and migration**

Replace the protocol with:

```swift
protocol TeamsPairingTokenStoring: AnyObject {
    func load() throws -> String?
    func save(_ token: String) throws
    func clear() throws
}
```

Create:

```swift
enum TeamsPairingCredential {
    static let service =
        "local.meeting.recorder.teams-third-party-api"
    static let account = "pairing-token.v1"
    static let legacyDefaultsKey =
        "teamsThirdPartyAPIPairingToken"
}

enum TeamsPairingTokenStoreError: LocalizedError, Equatable {
    case invalidEncoding
    case migrationVerificationFailed
    case emptyToken

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "The saved Teams pairing credential is invalid."
        case .migrationVerificationFailed:
            "Teams pairing credential migration could not be verified."
        case .emptyToken:
            "Teams returned an empty pairing credential."
        }
    }
}

final class KeychainTeamsPairingTokenStore:
    TeamsPairingTokenStoring,
    @unchecked Sendable
{
    private let secureStore: any SecureValueStoring
    private let defaults: UserDefaults
    private let legacyKey: String
    private let lock = NSLock()

    init(
        secureStore: any SecureValueStoring =
            KeychainSecureValueStore(),
        defaults: UserDefaults = .standard,
        legacyKey: String =
            TeamsPairingCredential.legacyDefaultsKey
    ) {
        self.secureStore = secureStore
        self.defaults = defaults
        self.legacyKey = legacyKey
    }

    func load() throws -> String? {
        try lock.withLock {
            if let data = try secureStore.load(
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            ) {
                let value = try decode(data)
                defaults.removeObject(forKey: legacyKey)
                return value
            }
            guard let legacy = defaults.string(forKey: legacyKey),
                  !legacy.isEmpty else {
                return nil
            }
            let data = Data(legacy.utf8)
            try secureStore.save(
                data,
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            )
            guard try secureStore.load(
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            ) == data else {
                throw TeamsPairingTokenStoreError
                    .migrationVerificationFailed
            }
            defaults.removeObject(forKey: legacyKey)
            return legacy
        }
    }

    func save(_ token: String) throws {
        guard !token.isEmpty else {
            throw TeamsPairingTokenStoreError.emptyToken
        }
        try lock.withLock {
            try secureStore.save(
                Data(token.utf8),
                service: TeamsPairingCredential.service,
                account: TeamsPairingCredential.account
            )
        }
    }

    func clear() throws {
        try lock.withLock {
            var deletionError: Error?
            do {
                try secureStore.delete(
                    service: TeamsPairingCredential.service,
                    account: TeamsPairingCredential.account
                )
            } catch {
                deletionError = error
            }
            defaults.removeObject(forKey: legacyKey)
            if let deletionError {
                throw deletionError
            }
        }
    }

    private func decode(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw TeamsPairingTokenStoreError.invalidEncoding
        }
        return value
    }
}
```

Add a private throwing `NSLock.withLock` extension in the new file.

- [ ] **Step 5: Snapshot one token per connection and classify errors**

At the top of each `run` loop iteration, before URL/socket creation:

```swift
let token: String?
do {
    token = try tokenStore.load()
} catch {
    emitCredentialFailure(generation: generation)
    return
}
var activeToken = token
```

Use `activeToken != nil` for meeting-update decisions instead of repeated
Keychain reads. Add:

```swift
private func emitCredentialFailure(generation: UInt64) {
    emit(
        .status(.failed(
            "Teams pairing credential is unavailable in Keychain. "
            + "Retry after allowing Keychain access."
        )),
        generation: generation
    )
}
```

Serialize generation validation and each credential mutation under the
client's existing lock:

```swift
private func mutateCredentialIfInstalled(
    socket: any TeamsWebSocketConnection,
    generation: UInt64,
    operation: () throws -> Void,
    onSuccess: () -> Void = {}
) -> Result<Void, Error>? {
    lock.withLock {
        guard self.generation == generation,
              onEvent != nil,
              let socketTask,
              connectionsMatch(socketTask, socket) else {
            return nil
        }
        do {
            try operation()
            onSuccess()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
```

Holding this lock across the synchronous Keychain operation is intentional:
`restart` cannot advance generation between validation and mutation. Do not
emit events or call socket methods while the lock is held.

For token refresh:

```swift
let saved = mutateCredentialIfInstalled(
    socket: socket,
    generation: generation,
    operation: { try tokenStore.save(token) },
    onSuccess: { pairingPhase = .idle }
)
switch saved {
case nil:
    return
case .failure:
    emitCredentialFailure(generation: generation)
    clear(socket: socket, generation: generation)
    socket.cancel(with: .goingAway, reason: nil)
    return
case .success:
    activeToken = token
    emit(.status(.ready), generation: generation)
}
```

For invalid-token cleanup, use the same helper with
`operation: { try tokenStore.clear() }`. On success set `activeToken = nil`
and reconnect immediately. On failure emit the redacted failure, cancel/clear
the socket, and return without automatic reconnecting.

- [ ] **Step 6: Inject the Keychain store and remove the old implementation**

Construct:

```swift
TeamsMuteSyncClient(
    tokenStore: KeychainTeamsPairingTokenStore(defaults: defaults)
)
```

Delete `UserDefaultsTeamsPairingTokenStore`. Only the migration store may read
the legacy defaults key.

- [ ] **Step 7: Run migration, client, and neighboring tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsPairingTokenStoreTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsMuteSyncClientTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelTeamsAutoMeetingTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelMuteTests
```

Expected: all pass. Existing stale token-refresh tests still prove that an old
socket cannot overwrite the current token.

- [ ] **Step 8: Commit Task 2**

```bash
git add \
  Sources/RecorderApp/Teams/KeychainTeamsPairingTokenStore.swift \
  Sources/RecorderApp/Teams/TeamsMuteSyncClient.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/TeamsPairingTokenStoreTests.swift \
  Tests/RecorderAppTests/TeamsMuteSyncClientTests.swift
git commit -m "Migrate Teams pairing token to Keychain"
```

### Task 3: Credential Regression Gate

**Files:**
- Verify only; no production edits.

**Interfaces:**
- Verifies: Keychain migration, Teams socket behavior, and no secret-bearing
  UserDefaults implementation remains

- [ ] **Step 1: Run all credential-focused suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter SecureValueStoreTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsPairingTokenStoreTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TeamsMuteSyncClientTests
```

Expected: zero failures.

- [ ] **Step 2: Scan active sources for the legacy storage implementation**

Run:

```bash
rg -n \
  'UserDefaultsTeamsPairingTokenStore|defaults\\.set\\(token|var token: String' \
  Sources/RecorderApp
```

Expected: no matches. The legacy key may appear only inside
`KeychainTeamsPairingTokenStore.swift` migration constants and tests.

- [ ] **Step 3: Run the complete Swift suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: all tests pass with the existing single intentional skip.

- [ ] **Step 4: Inspect the commit range**

```bash
git diff --check c201cc1..HEAD
git status --short
```

Expected: no whitespace errors and no uncommitted production changes.
