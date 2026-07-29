# Local Meeting Recorder Self-Service Installer Implementation Plan

> **Superseded on 2026-07-28. Do not execute this plan.**
> Local Meeting Recorder now uses native ScreenCaptureKit capture and a
> user-configured OpenAI-compatible provider. The application does not install
> BlackHole, oMLX, provider binaries, or models.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one ad-hoc-signed arm64 DMG whose Local Meeting Recorder app guides an M1/macOS 15+ administrator through BlackHole, oMLX, Qwen ASR, audio routing, permissions, and an end-to-end test without Terminal.

**Architecture:** Add a probe-driven setup domain beside the existing recorder domain. Small services own paths, release metadata, oMLX authentication, model download, audio checks, diagnostics, and setup actions; a `SetupCoordinator` exposes their state to a dedicated SwiftUI Setup Assistant and gates the existing recorder UI until required probes pass.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, CoreAudio, Foundation `URLSession`, Security/Keychain, CryptoKit, XCTest, Bash release scripts, `hdiutil`, ad-hoc `codesign`.

## Global Constraints

- Target Apple Silicon only and set the platform floor to macOS 15.0.
- Deliver exactly one end-user app named `Local Meeting Recorder.app` with bundle identifier `local.meeting.recorder`.
- Do not bundle or redistribute BlackHole; open only its pinned official source.
- Use oMLX from its pinned official GitHub release source.
- Use `mlx-community/Qwen3-ASR-1.7B-4bit` at revision `78a389c776a5483b2d0d4ea5494e11012e0d6159`.
- Never ship the development API key `1234`; generate a distinct random key on each Mac and store it in Keychain.
- Remove all runtime dependencies on `/Users/apple`, the source checkout, and `/Users/apple/Documents/AIA ASR`.
- Default recording and manual-import output remains the current user's `~/Downloads`.
- The first release is ad-hoc signed, not notarized, and has no automatic updater.
- Setup readiness comes from live probes, not persisted completion booleans.
- Setup and repair actions must be idempotent and must not delete recordings, transcripts, healthy models, or unrelated oMLX configuration.
- Use TDD for every behavior change and commit each task only after its focused tests and the full test suite pass.

---

## File Map

Create focused setup files under `Sources/RecorderApp/Setup/`:

- `AppPaths.swift`: current-user directories and bundled-resource resolution.
- `ReleaseManifest.swift`: pinned dependency/model metadata and validation.
- `SetupModels.swift`: step identifiers, phases, errors, and snapshots.
- `SetupService.swift`: service protocol used by the coordinator.
- `SetupCoordinator.swift`: ordered probes, actions, persistence, and gating.
- `SystemCompatibilityService.swift`: CPU, OS, disk, and network checks.
- `BlackHoleSetupService.swift`: BlackHole detection and official installer launch.
- `OMLXSettingsStore.swift`: preserving reads/writes of `~/.omlx/settings.json`.
- `KeychainSecretStore.swift`: per-Mac API key storage.
- `OMLXClient.swift`: authenticated health, model, and transcription probes.
- `OMLXSetupService.swift`: app/version/process/auth readiness and repair.
- `HuggingFaceModelDownloader.swift`: pinned model metadata, resumable files, hashes, and aggregate progress.
- `QwenModelSetupService.swift`: download destination and oMLX model readiness.
- `AudioRoutingSetupService.swift`: Multi-Output and permission probes/actions.
- `SetupVerificationService.swift`: end-to-end test orchestration.
- `SetupDiagnostics.swift`: redacted events and export bundle.
- `SetupAssistantView.swift`: setup and repair workflow UI.

Modify existing files only at their ownership boundary:

- `Package.swift`: macOS floor and Security linkage.
- `Sources/RecorderApp/ContentView.swift`: inject `AppModel` and expose setup entry points.
- `Sources/RecorderApp/AppModel.swift`: defer permission/ASR work until setup and use portable services.
- `Sources/RecorderApp/LocalMeetingRecorderApp.swift`: own shared models and switch setup/recorder roots.
- `scripts/transcribe-qwen-asr.sh`: remove developer Python/workspace assumptions.
- `scripts/prepare-qwen-asr.sh`: remove developer paths and become a portable diagnostic fallback.
- `scripts/build-app.sh`: release configuration, resource manifest, stable release bundle.
- `scripts/install-app.sh`: preserve the local developer install workflow without creating a second end-user identity.
- `scripts/build-dmg.sh`: create the distributable DMG and checksums.
- `README.md`: replace stale ASR and installation instructions.

---

### Task 1: Portable Paths and Release Manifest

**Files:**
- Create: `Sources/RecorderApp/Setup/AppPaths.swift`
- Create: `Sources/RecorderApp/Setup/ReleaseManifest.swift`
- Create: `Sources/RecorderApp/Resources/release-manifest.json`
- Create: `Tests/RecorderAppTests/AppPathsTests.swift`
- Create: `Tests/RecorderAppTests/ReleaseManifestTests.swift`
- Modify: `Package.swift`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `FileManager`, `Bundle`, and immutable release JSON.
- Produces: `AppPaths.live`, `AppPaths(homeDirectory:applicationSupportRoot:)`, `ReleaseManifest.load(from:)`, and `ReleaseManifest.validate()`.

- [ ] **Step 1: Write failing path tests**

```swift
import Foundation
import XCTest
@testable import RecorderApp

final class AppPathsTests: XCTestCase {
    func testPathsAreDerivedFromCurrentUserInsteadOfDeveloperHome() {
        let home = URL(fileURLWithPath: "/Users/colleague", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let paths = AppPaths(homeDirectory: home, applicationSupportRoot: support)

        XCTAssertEqual(paths.recordingsDirectory.path, "/Users/colleague/Downloads")
        XCTAssertEqual(paths.appSupportDirectory.path, "/Users/colleague/Library/Application Support/Local Meeting Recorder")
        XCTAssertEqual(paths.setupLogURL.lastPathComponent, "setup.log")
        XCTAssertFalse(paths.appSupportDirectory.path.contains("/Users/apple"))
    }
}
```

- [ ] **Step 2: Run the path test and confirm the red state**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppPathsTests`

Expected: FAIL because `AppPaths` does not exist.

- [ ] **Step 3: Implement portable paths**

```swift
import Foundation

struct AppPaths: Sendable {
    let homeDirectory: URL
    let applicationSupportRoot: URL

    static let live = AppPaths(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportRoot: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    var recordingsDirectory: URL {
        homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    var appSupportDirectory: URL {
        applicationSupportRoot.appendingPathComponent("Local Meeting Recorder", isDirectory: true)
    }

    var setupLogURL: URL {
        appSupportDirectory.appendingPathComponent("setup.log")
    }

    var diagnosticsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    var omlxSettingsURL: URL {
        homeDirectory.appendingPathComponent(".omlx/settings.json")
    }

    var defaultOMLXModelDirectory: URL {
        homeDirectory.appendingPathComponent(".omlx/models", isDirectory: true)
    }
}
```

- [ ] **Step 4: Write failing manifest tests**

```swift
import Foundation
import XCTest
@testable import RecorderApp

final class ReleaseManifestTests: XCTestCase {
    func testBundledManifestPinsOfficialDependenciesAndModelRevision() throws {
        let manifest = try ReleaseManifest.bundled()
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(manifest.model.repository, "mlx-community/Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(manifest.model.revision, "78a389c776a5483b2d0d4ea5494e11012e0d6159")
        XCTAssertEqual(manifest.model.expectedOMLXIdentifier, "mlx-community--Qwen3-ASR-1.7B-4bit")
        XCTAssertEqual(manifest.omlx.version, "0.5.1")
        XCTAssertEqual(manifest.blackHole.version, "0.7.1")
    }

    func testManifestRejectsUnpinnedOrNonHTTPSSources() throws {
        var manifest = ReleaseManifest.fixture
        manifest.omlx.sourceURL = URL(string: "http://example.com/latest.dmg")!
        XCTAssertThrowsError(try manifest.validate())
    }
}

private extension ReleaseManifest {
    static var fixture: ReleaseManifest {
        ReleaseManifest(
            blackHole: .init(name: "BlackHole", version: "0.7.1", sourceURL: URL(string: "https://github.com/ExistentialAudio/BlackHole/releases/tag/v0.7.1")!, sha256: nil),
            omlx: .init(name: "oMLX", version: "0.5.1", sourceURL: URL(string: "https://github.com/jundot/omlx/releases/tag/v0.5.1")!, sha256: nil),
            model: .init(repository: "mlx-community/Qwen3-ASR-1.7B-4bit", revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159", expectedOMLXIdentifier: "mlx-community--Qwen3-ASR-1.7B-4bit", estimatedBytes: 1_728_724_336)
        )
    }
}
```

- [ ] **Step 5: Implement manifest decoding and validation**

```swift
import Foundation

struct ReleaseManifest: Codable, Sendable {
    struct Dependency: Codable, Sendable {
        let name: String
        let version: String
        var sourceURL: URL
        let sha256: String?
    }

    struct Model: Codable, Sendable {
        let repository: String
        let revision: String
        let expectedOMLXIdentifier: String
        let estimatedBytes: Int64
    }

    var blackHole: Dependency
    var omlx: Dependency
    let model: Model

    static func load(from url: URL) throws -> ReleaseManifest {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(contentsOf: url))
    }

    static func bundled() throws -> ReleaseManifest {
        guard let url = Bundle.module.url(forResource: "release-manifest", withExtension: "json") else {
            throw ManifestError.missingBundledManifest
        }
        return try load(from: url)
    }

    func validate() throws {
        for dependency in [blackHole, omlx] {
            guard dependency.sourceURL.scheme == "https",
                  !dependency.sourceURL.absoluteString.localizedCaseInsensitiveContains("latest") else {
                throw ManifestError.unpinnedSource(dependency.name)
            }
            if let sha256 = dependency.sha256,
               sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
                throw ManifestError.invalidHash(dependency.name)
            }
        }
        guard model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ManifestError.invalidRevision
        }
    }
}

enum ManifestError: LocalizedError {
    case missingBundledManifest
    case unpinnedSource(String)
    case invalidHash(String)
    case invalidRevision
}
```

Create `Sources/RecorderApp/Resources/release-manifest.json` with BlackHole `0.7.1` pointing to its official release page, oMLX `0.5.1` pointing to its exact GitHub release page, model revision `78a389c776a5483b2d0d4ea5494e11012e0d6159`, expected oMLX identifier `mlx-community--Qwen3-ASR-1.7B-4bit`, and estimated bytes `1728724336`. Source-page dependencies use `null` for `sha256`; downloaded binary artifacts must add a real SHA-256 before automatic opening is enabled.

- [ ] **Step 6: Package resources and raise the deployment floor**

Change `Package.swift` to `.macOS("15.0")`, add `resources: [.process("Resources/release-manifest.json")]` to `RecorderApp`, and link `Security`. Update `scripts/build-app.sh` to copy the manifest into `Contents/Resources` and set `LSMinimumSystemVersion` to `15.0`.

- [ ] **Step 7: Run focused and full tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS and no test path contains the developer home directory.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/RecorderApp/Resources/release-manifest.json Sources/RecorderApp/Setup/AppPaths.swift Sources/RecorderApp/Setup/ReleaseManifest.swift Tests/RecorderAppTests/AppPathsTests.swift Tests/RecorderAppTests/ReleaseManifestTests.swift scripts/build-app.sh
git commit -m "Add portable setup paths and release manifest"
```

### Task 2: Keychain Secret, oMLX Settings, and API Client

**Files:**
- Create: `Sources/RecorderApp/Setup/KeychainSecretStore.swift`
- Create: `Sources/RecorderApp/Setup/OMLXSettingsStore.swift`
- Create: `Sources/RecorderApp/Setup/OMLXClient.swift`
- Create: `Tests/RecorderAppTests/OMLXSettingsStoreTests.swift`
- Create: `Tests/RecorderAppTests/OMLXClientTests.swift`

**Interfaces:**
- Consumes: `AppPaths.omlxSettingsURL`, URLSession-compatible HTTP transport.
- Produces: `SecretStoring.loadOrCreateAPIKey()`, `OMLXSettingsStore.synchronizeAPIKey(_:)`, `OMLXClient.health()`, `OMLXClient.modelIsReady(_:)`, and `OMLXClient.transcribe(file:language:)`.

- [ ] **Step 1: Write failing settings preservation tests**

```swift
func testSynchronizeAPIKeyPreservesUnrelatedOMLXSettings() throws {
    let initial: [String: Any] = ["port": 8000, "model_dir": "/Users/colleague/models", "auth": ["api_key": "old"]]
    try JSONSerialization.data(withJSONObject: initial).write(to: settingsURL)

    try OMLXSettingsStore(url: settingsURL).synchronizeAPIKey("new-secret")

    let data = try Data(contentsOf: settingsURL)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(result["port"] as? Int, 8000)
    XCTAssertEqual(result["model_dir"] as? String, "/Users/colleague/models")
    XCTAssertEqual((result["auth"] as? [String: Any])?["api_key"] as? String, "new-secret")
}
```

- [ ] **Step 2: Run the settings test and confirm it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OMLXSettingsStoreTests`

Expected: FAIL because `OMLXSettingsStore` does not exist.

- [ ] **Step 3: Implement preserving settings writes**

Use `JSONSerialization` to read a mutable root dictionary, replace only `auth.api_key`, create the parent directory, write to a sibling temporary file with `.atomic`, and replace the original only after JSON encoding succeeds. Add `modelDirectory(default:)` that returns `model_dir` when present or the provided default.

```swift
struct OMLXSettingsStore {
    let url: URL

    func synchronizeAPIKey(_ key: String) throws {
        var root = try readRoot()
        var auth = root["auth"] as? [String: Any] ?? [:]
        auth["api_key"] = key
        root["auth"] = auth
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Implement Keychain-backed random keys**

Define `SecretStoring` so tests use an in-memory implementation. The live store uses Security framework generic-password records with service `local.meeting.recorder.omlx` and account `api-key`. Generate 32 random bytes with `SecRandomCopyBytes` and encode them as lowercase hexadecimal. Never accept `1234` as a generated value.

```swift
protocol SecretStoring: Sendable {
    func loadOrCreateAPIKey() throws -> String
}

struct KeychainSecretStore: SecretStoring {
    let service = "local.meeting.recorder.omlx"
    let account = "api-key"

    func loadOrCreateAPIKey() throws -> String {
        if let existing = try load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError.randomGenerationFailed
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try save(value)
        return value
    }
}
```

- [ ] **Step 5: Write failing authenticated client tests**

Use a `URLProtocol` stub and assert that `GET /v1/models` receives `Authorization: Bearer test-key`, a 401 maps to `.authenticationFailed`, and a JSON model entry with id `mlx-community--Qwen3-ASR-1.7B-4bit` returns `true`.

- [ ] **Step 6: Implement the oMLX client**

```swift
struct OMLXClient: Sendable {
    let baseURL: URL
    let apiKey: String
    let session: URLSession

    func modelIsReady(_ identifier: String) async throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OMLXError.invalidResponse }
        guard http.statusCode != 401 else { throw OMLXError.authenticationFailed }
        guard http.statusCode == 200 else { throw OMLXError.http(http.statusCode) }
        let payload = try JSONDecoder().decode(ModelList.self, from: data)
        return payload.data.contains { $0.id == identifier }
    }
}
```

Implement `transcribe(file:language:)` using multipart form data and return decoded `{ "text": String }`; keep it behind the same HTTP transport so Task 6 can replace shell-process transcription.

- [ ] **Step 7: Run focused and full tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS; HTTP test output contains no API key.

- [ ] **Step 8: Commit**

```bash
git add Sources/RecorderApp/Setup/KeychainSecretStore.swift Sources/RecorderApp/Setup/OMLXSettingsStore.swift Sources/RecorderApp/Setup/OMLXClient.swift Tests/RecorderAppTests/OMLXSettingsStoreTests.swift Tests/RecorderAppTests/OMLXClientTests.swift
git commit -m "Add secure oMLX configuration and API client"
```

### Task 3: Setup Domain and Probe Services

**Files:**
- Create: `Sources/RecorderApp/Setup/SetupModels.swift`
- Create: `Sources/RecorderApp/Setup/SetupService.swift`
- Create: `Sources/RecorderApp/Setup/SystemCompatibilityService.swift`
- Create: `Sources/RecorderApp/Setup/BlackHoleSetupService.swift`
- Create: `Sources/RecorderApp/Setup/OMLXSetupService.swift`
- Create: `Sources/RecorderApp/Setup/AudioRoutingSetupService.swift`
- Create: `Tests/RecorderAppTests/SetupProbeTests.swift`
- Modify: `Sources/RecorderApp/AudioDevice.swift`

**Interfaces:**
- Consumes: manifest, paths, audio inventory, process/app workspace, oMLX settings and client.
- Produces: `SetupStepID`, `SetupStepStatus`, `SetupService.check()`, and `SetupService.performPrimaryAction()`.

- [ ] **Step 1: Write failing probe mapping tests**

Test these exact cases: app launched outside `/Applications` -> `.waitingForUser`; Intel CPU -> failed system step; macOS 14 -> failed system step; less than `model.estimatedBytes + 2_147_483_648` free bytes -> failed system step; missing BlackHole -> `.notInstalled`; installed BlackHole -> `.ready`; missing `/Applications/oMLX.app` -> `.notInstalled`; port 8000 answering non-oMLX data -> `.failed(.portConflict)`; denied microphone -> `.failed(.microphoneDenied)`; valid Multi-Output default -> `.ready`.

- [ ] **Step 2: Run probe tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SetupProbeTests`

Expected: FAIL because setup types and services do not exist.

- [ ] **Step 3: Define the setup state model**

```swift
enum SetupStepID: String, CaseIterable, Codable, Sendable {
    case system, blackHole, omlx, qwenModel, audioRouting, microphone, verification
}

enum SetupFailure: Equatable, Sendable {
    case unsupportedArchitecture
    case unsupportedOS
    case insufficientDisk(required: Int64, available: Int64)
    case networkUnavailable
    case portConflict
    case authenticationFailed
    case microphoneDenied
    case modelDownload(String)
    case modelLoadTimedOut
    case verification(String)
}

enum SetupPhase: Equatable, Sendable {
    case notInstalled
    case checking
    case downloading(progress: Double, bytesPerSecond: Int64)
    case waitingForUser
    case restartRequired
    case startingService
    case loadingModel
    case ready
    case failed(SetupFailure)
}

struct SetupStepStatus: Equatable, Identifiable, Sendable {
    let id: SetupStepID
    let title: String
    let detail: String
    let phase: SetupPhase
    let primaryActionTitle: String?
}

protocol SetupService: Sendable {
    var id: SetupStepID { get }
    func check() async -> SetupStepStatus
    func performPrimaryAction() async -> SetupStepStatus
}
```

- [ ] **Step 4: Implement dependency-injected probes**

Use protocols for `SystemFactsProviding`, `AudioInventoryProviding`, `WorkspaceOpening`, and `OMLXProbing`. Live implementations read `ProcessInfo`, `Bundle.main.bundleURL`, `URLResourceValues.volumeAvailableCapacityForImportantUsage`, existing `AudioDeviceManager`, `NSWorkspace`, and `OMLXClient`. Tests use value fixtures. `SystemCompatibilityService` returns `.waitingForUser` until the running bundle is under `/Applications`, so microphone permission is never requested from the mounted DMG copy.

BlackHole actions open the exact official URL from the manifest. oMLX actions open its exact release URL when absent, open `/Applications/oMLX.app` when present, synchronize the Keychain key into settings, and then probe the server. Audio actions open `/System/Applications/Utilities/Audio MIDI Setup.app` and the microphone privacy pane.

- [ ] **Step 5: Make Core Audio inventory reusable**

Add `AudioDeviceManager.allDevices()`, keep existing `inputDevices()` and `outputDevices()`, and expose default input/output/system-output IDs through `AudioInventoryProviding`. Do not change recording behavior.

- [ ] **Step 6: Run focused and full tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS, including existing manual import tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/Setup/SetupModels.swift Sources/RecorderApp/Setup/SetupService.swift Sources/RecorderApp/Setup/SystemCompatibilityService.swift Sources/RecorderApp/Setup/BlackHoleSetupService.swift Sources/RecorderApp/Setup/OMLXSetupService.swift Sources/RecorderApp/Setup/AudioRoutingSetupService.swift Sources/RecorderApp/AudioDevice.swift Tests/RecorderAppTests/SetupProbeTests.swift
git commit -m "Add live setup dependency probes"
```

### Task 4: Probe-Driven Setup Coordinator

**Files:**
- Create: `Sources/RecorderApp/Setup/SetupCoordinator.swift`
- Create: `Tests/RecorderAppTests/SetupCoordinatorTests.swift`

**Interfaces:**
- Consumes: ordered `[any SetupService]` from Task 3.
- Produces: `SetupCoordinator.steps`, `isSetupComplete`, `currentStepID`, `refreshAll()`, `performPrimaryAction(for:)`, and `showRecorder()`.

- [ ] **Step 1: Write failing coordinator tests**

```swift
@MainActor
func testCoordinatorDoesNotTrustPersistedCompletionWhenProbeFails() async {
    let services = SetupStepID.allCases.map { StubSetupService(id: $0, result: .ready($0)) }
    services[1].result = .notInstalled(.blackHole)
    let coordinator = SetupCoordinator(services: services, preferences: InMemorySetupPreferences(lastStep: .verification))

    await coordinator.refreshAll()

    XCTAssertFalse(coordinator.isSetupComplete)
    XCTAssertEqual(coordinator.currentStepID, .blackHole)
}

@MainActor
func testOnlyOnePrimaryActionRunsAtATime() async {
    let service = BlockingSetupService(id: .omlx)
    let coordinator = SetupCoordinator(services: [service], preferences: InMemorySetupPreferences())
    async let first: Void = coordinator.performPrimaryAction(for: .omlx)
    async let second: Void = coordinator.performPrimaryAction(for: .omlx)
    _ = await (first, second)
    XCTAssertEqual(service.actionCount, 1)
}
```

- [ ] **Step 2: Run coordinator tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SetupCoordinatorTests`

Expected: FAIL because `SetupCoordinator` does not exist.

- [ ] **Step 3: Implement ordered checks and action serialization**

```swift
@MainActor
final class SetupCoordinator: ObservableObject {
    @Published private(set) var steps: [SetupStepStatus] = []
    @Published private(set) var currentStepID: SetupStepID = .system
    @Published private(set) var isPerformingAction = false
    @Published var isShowingRecorder = false

    private let services: [any SetupService]

    var isSetupComplete: Bool {
        SetupStepID.allCases.allSatisfy { id in
            steps.first(where: { $0.id == id })?.phase == .ready
        }
    }

    func refreshAll() async {
        var results: [SetupStepStatus] = []
        for service in services {
            let status = await service.check()
            results.append(status)
        }
        steps = results
        currentStepID = results.first(where: { $0.phase != .ready })?.id ?? .verification
    }

    func performPrimaryAction(for id: SetupStepID) async {
        guard !isPerformingAction, let service = services.first(where: { $0.id == id }) else { return }
        isPerformingAction = true
        replace(await service.performPrimaryAction())
        isPerformingAction = false
        await refreshAll()
    }

    var selectedStep: SetupStepStatus? {
        steps.first { $0.id == currentStepID }
    }

    func select(_ id: SetupStepID) {
        currentStepID = id
    }
}
```

Persist only the last viewed step and whether the user intentionally opened Repair Setup. Never persist `isSetupComplete`.

- [ ] **Step 4: Add cancellation and relaunch tests**

Verify cancellation returns a recoverable status, the last step reloads, and a newly missing dependency blocks recorder entry after `refreshAll()`.

- [ ] **Step 5: Run focused and full tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/RecorderApp/Setup/SetupCoordinator.swift Tests/RecorderAppTests/SetupCoordinatorTests.swift
git commit -m "Add probe-driven setup coordinator"
```

### Task 5: Pinned Qwen Model Download and Readiness

**Files:**
- Create: `Sources/RecorderApp/Setup/HuggingFaceModelDownloader.swift`
- Create: `Sources/RecorderApp/Setup/QwenModelSetupService.swift`
- Create: `Tests/RecorderAppTests/HuggingFaceModelDownloaderTests.swift`
- Create: `Tests/RecorderAppTests/QwenModelSetupServiceTests.swift`

**Interfaces:**
- Consumes: manifest model revision, oMLX model directory, authenticated `OMLXClient`.
- Produces: `ModelDownloading.download(_:to:progress:)`, resumable `.partial` files, and `QwenModelSetupService` as `SetupService`.

- [ ] **Step 1: Write failing immutable-revision and resume tests**

Use a URLProtocol fixture for Hugging Face metadata. Assert metadata requests include `revision=78a389c776a5483b2d0d4ea5494e11012e0d6159`, every file URL contains that revision, an existing 1,024-byte `.partial` file sends `Range: bytes=1024-`, and a mismatched SHA-256 deletes only the invalid partial file.

- [ ] **Step 2: Run downloader tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HuggingFaceModelDownloaderTests`

Expected: FAIL because the downloader does not exist.

- [ ] **Step 3: Implement pinned metadata and file planning**

```swift
struct HuggingFaceModelReference: Sendable {
    let repository: String
    let revision: String
}

struct ModelFile: Decodable, Sendable {
    struct LFS: Decodable, Sendable { let oid: String; let size: Int64 }
    let rfilename: String
    let size: Int64?
    let lfs: LFS?
}

protocol ModelDownloading: Sendable {
    func download(
        _ reference: HuggingFaceModelReference,
        to directory: URL,
        progress: @escaping @Sendable (Double, Int64) -> Void
    ) async throws
}
```

Build the metadata URL as `https://huggingface.co/api/models/\(reference.repository)?revision=\(reference.revision)&blobs=true`, reject a response whose `sha` differs from the pinned revision, ignore `.gitattributes`, and build each file URL as `https://huggingface.co/\(reference.repository)/resolve/\(reference.revision)/\(file.rfilename)`.

- [ ] **Step 4: Implement resumable and verified downloads**

Write each response to a sibling path made with `destination.appendingPathExtension("partial")`. Resume with a Range request when partial data exists. Accept `206` for resumed responses and restart that file when the server returns `200`. For LFS files, strip a leading `sha256:` from `oid`, hash the completed file with CryptoKit, compare lowercase hex, then atomically rename to the final path. Aggregate progress across known file sizes and calculate bytes per second over a rolling two-second window.

- [ ] **Step 5: Write failing Qwen readiness tests**

Assert: missing model directory -> `.notInstalled`; active download emits `.downloading`; finished files but absent `/v1/models` entry -> `.loadingModel`; expected oMLX ID present -> `.ready`; cancellation preserves partial files; low space performs no network request.

- [ ] **Step 6: Implement Qwen setup service**

Resolve the oMLX model directory from `OMLXSettingsStore.modelDirectory(default:)`, then append `mlx-community/Qwen3-ASR-1.7B-4bit`. After a successful download, ask `OMLXSetupService` to start/restart the server only when it is idle, poll `/v1/models` for up to 120 seconds, and map timeout to a recoverable model-load error. Opening `http://127.0.0.1:8000/admin` is the secondary help action.

- [ ] **Step 7: Run focused and full tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS without downloading the real 1.61 GB model.

- [ ] **Step 8: Commit**

```bash
git add Sources/RecorderApp/Setup/HuggingFaceModelDownloader.swift Sources/RecorderApp/Setup/QwenModelSetupService.swift Tests/RecorderAppTests/HuggingFaceModelDownloaderTests.swift Tests/RecorderAppTests/QwenModelSetupServiceTests.swift
git commit -m "Add resumable pinned Qwen model setup"
```

### Task 6: Portable In-App Transcription

**Files:**
- Create: `Sources/RecorderApp/TranscriptionService.swift`
- Create: `Tests/RecorderAppTests/TranscriptionServiceTests.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `scripts/transcribe-qwen-asr.sh`
- Modify: `scripts/prepare-qwen-asr.sh`

**Interfaces:**
- Consumes: `OMLXClient.transcribe(file:language:)`, session recording URL, `AppPaths`.
- Produces: `TranscriptionServicing.transcribe(session:progress:)` and portable diagnostic-only fallback scripts.

- [ ] **Step 1: Write failing transcription output tests**

Stub the client to return simplified Chinese text and assert the service writes JSON, raw text, and Traditional Chinese text into the selected session folder; assert no output path contains `/Users/apple`; assert an HTTP error is written to `transcription_qwen_asr.log` and surfaced to `AppModel`.

- [ ] **Step 2: Run transcription tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptionServiceTests`

Expected: FAIL because `TranscriptionService` does not exist.

- [ ] **Step 3: Implement the service and output contract**

```swift
protocol TranscriptionServicing: Sendable {
    func transcribe(
        session: RecordingSession,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL
}

struct TranscriptionService: TranscriptionServicing {
    let client: OMLXClient
    let traditionalChineseConverter: @Sendable (String) -> String

    func transcribe(session: RecordingSession, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        progress("Uploading audio to local oMLX...")
        let response = try await client.transcribe(file: session.recordingURL, language: "yue")
        let rawURL = session.folderURL.appendingPathComponent("transcript_qwen3_asr_1_7b_4bit_yue.txt")
        let tradURL = session.folderURL.appendingPathComponent("transcript_qwen3_asr_1_7b_4bit_yue_trad.txt")
        try response.text.write(to: rawURL, atomically: true, encoding: .utf8)
        try traditionalChineseConverter(response.text).write(to: tradURL, atomically: true, encoding: .utf8)
        progress("Transcript saved: \(tradURL.lastPathComponent)")
        return tradURL
    }
}
```

Use the existing OpenCC behavior only when a portable converter is bundled; otherwise preserve the ASR result and label it accurately instead of requiring `/Users/apple/Documents/AIA ASR/.venv`.

- [ ] **Step 4: Refactor AppModel to use async service injection**

Add `init(transcriptionService:paths:)`, replace `Process` ownership with a `Task`, preserve all current status fields, and gate transcription through the coordinator's model-ready probe. Resource fallbacks may resolve from `Bundle.main`, never from the source checkout.

- [ ] **Step 5: Make fallback scripts portable**

Change shell defaults to `${HOME}/Library/Application Support/Local Meeting Recorder`, use `/usr/bin/python3` only for JSON extraction when available, and remove every `/Users/apple` literal. The app's primary path is the native Swift client; scripts remain packaged only for diagnostics until removed in a later release.

- [ ] **Step 6: Scan and run tests**

Run: `rg -n "/Users/apple|Documents/AIA ASR" Sources scripts Assets`

Expected: no matches.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/RecorderApp/TranscriptionService.swift Sources/RecorderApp/AppModel.swift Tests/RecorderAppTests/TranscriptionServiceTests.swift scripts/transcribe-qwen-asr.sh scripts/prepare-qwen-asr.sh
git commit -m "Make oMLX transcription portable across users"
```

### Task 7: Setup Assistant UI and Recorder Gating

**Files:**
- Create: `Sources/RecorderApp/Setup/SetupAssistantView.swift`
- Create: `Sources/RecorderApp/Setup/SetupVerificationService.swift`
- Create: `Tests/RecorderAppTests/SetupVerificationServiceTests.swift`
- Modify: `Sources/RecorderApp/LocalMeetingRecorderApp.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`

**Interfaces:**
- Consumes: `SetupCoordinator`, existing `AppModel.runTestRecording()`, health report, and transcription service.
- Produces: first-run root selection, repair entry point, and verified setup completion.

- [ ] **Step 1: Write failing verification orchestration tests**

Assert the verification service requires system signal, microphone signal, a created M4A, successful playback initialization, and a non-empty Qwen transcript. Assert each failure maps back to `.audioRouting`, `.microphone`, or `.qwenModel` with a concrete action.

- [ ] **Step 2: Run verification tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SetupVerificationServiceTests`

Expected: FAIL because `SetupVerificationService` does not exist.

- [ ] **Step 3: Implement verification service**

Expose an async `RecordingTestRunning` adapter around `RecordingEngine` so tests do not wait ten seconds. Production uses the existing ten-second duration and returns `RecordingHealthReport`, recording URL, playback result, and transcript URL. Delete only the generated setup test session when the user explicitly chooses `Remove Test Recording`; otherwise keep it with other test sessions.

- [ ] **Step 4: Build the Setup Assistant view**

Use a two-column SwiftUI layout: a fixed-width step list and an unframed detail pane. Each row uses the existing semantic green/orange/red status colors, SF Symbols, and stable dimensions. The detail pane shows one primary button, optional `Help`/`Open Settings` button, determinate download progress, selectable error details, and `Retry`. It must not use cards inside cards or explanatory marketing copy.

```swift
struct SetupAssistantView: View {
    @ObservedObject var coordinator: SetupCoordinator

    var body: some View {
        NavigationSplitView {
            List(
                coordinator.steps,
                selection: Binding(
                    get: { Optional(coordinator.currentStepID) },
                    set: { if let id = $0 { coordinator.select(id) } }
                )
            ) { step in
                SetupStepRow(step: step)
            }
            .navigationTitle("Setup")
        } detail: {
            SetupStepDetail(
                step: coordinator.selectedStep,
                isBusy: coordinator.isPerformingAction,
                perform: { id in Task { await coordinator.performPrimaryAction(for: id) } }
            )
        }
        .task { await coordinator.refreshAll() }
    }
}
```

- [ ] **Step 5: Gate permission requests and root UI**

Remove microphone permission requests and ASR preparation from `AppModel.init()`. `LocalMeetingRecorderApp` owns one `AppModel` and one `SetupCoordinator`; it shows `SetupAssistantView` until probes pass and the user chooses `Open Recorder`. `ContentView` receives `@ObservedObject var model` instead of creating a second model. Add a toolbar/settings action `Repair Setup` that returns to setup without constructing another app model.

- [ ] **Step 6: Verify layout and behavior manually**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/run-app.sh`

Expected: only the staging app launches; setup displays at 860x680 and 1200x800 without overlap; download progress does not resize rows; denied microphone shows a System Settings action; healthy fixtures allow recorder entry.

- [ ] **Step 7: Run full tests and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS.

```bash
git add Sources/RecorderApp/Setup/SetupAssistantView.swift Sources/RecorderApp/Setup/SetupVerificationService.swift Sources/RecorderApp/LocalMeetingRecorderApp.swift Sources/RecorderApp/ContentView.swift Sources/RecorderApp/AppModel.swift Tests/RecorderAppTests/SetupVerificationServiceTests.swift
git commit -m "Add self-service setup assistant"
```

### Task 8: Privacy-Safe Diagnostics and Repair

**Files:**
- Create: `Sources/RecorderApp/Setup/SetupDiagnostics.swift`
- Create: `Tests/RecorderAppTests/SetupDiagnosticsTests.swift`
- Modify: `Sources/RecorderApp/Setup/SetupCoordinator.swift`
- Modify: `Sources/RecorderApp/Setup/SetupAssistantView.swift`

**Interfaces:**
- Consumes: setup snapshots, sanitized service errors, app/system/audio metadata.
- Produces: `SetupDiagnostics.record(_:)`, `export(to:)`, `Run Full Check`, `Repair Setup`, and a Finder-openable diagnostics folder.

- [ ] **Step 1: Write failing redaction and exclusion tests**

Feed diagnostics an event containing `Authorization: Bearer 1234`, a 64-character generated key, a recording path, and transcript text. Assert exported JSON replaces secrets with `[REDACTED]`, records only the parent output folder, and includes no M4A, transcript body, or authorization header.

- [ ] **Step 2: Run diagnostics tests and confirm they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SetupDiagnosticsTests`

Expected: FAIL because `SetupDiagnostics` does not exist.

- [ ] **Step 3: Implement structured diagnostics**

```swift
struct SetupDiagnosticEvent: Codable, Sendable {
    let timestamp: Date
    let component: SetupStepID
    let level: String
    let message: String
}

actor SetupDiagnostics {
    let paths: AppPaths
    let secretProvider: @Sendable () throws -> [String]

    func record(_ event: SetupDiagnosticEvent) async throws {
        let sanitized = sanitize(event)
        try appendJSONLine(sanitized, to: paths.setupLogURL)
    }

    func export(to destination: URL, snapshot: SetupSnapshot) async throws -> URL {
        let folder = destination.appendingPathComponent("Local Meeting Recorder Diagnostics-\(Self.timestamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sanitizedLogData().write(to: folder.appendingPathComponent("setup.log"))
        try JSONEncoder.pretty.encode(snapshot.redacted()).write(to: folder.appendingPathComponent("system.json"))
        return folder
    }
}
```

Sanitize known keys, bearer tokens, 32/64-byte hexadecimal secrets, and transcript fields before persistence, not only during export.

- [ ] **Step 4: Wire repair commands**

`Run Full Check` invokes `refreshAll()`. `Repair Setup` opens the first non-ready step. `Export Diagnostics` chooses a destination with `NSOpenPanel`, exports a folder, and reveals it in Finder. Disable export while its snapshot is being generated.

- [ ] **Step 5: Run full tests and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: all tests PASS and the fixture secret does not appear in `.build` test output.

```bash
git add Sources/RecorderApp/Setup/SetupDiagnostics.swift Sources/RecorderApp/Setup/SetupCoordinator.swift Sources/RecorderApp/Setup/SetupAssistantView.swift Tests/RecorderAppTests/SetupDiagnosticsTests.swift
git commit -m "Add setup repair and redacted diagnostics"
```

### Task 9: Ad-Hoc DMG Release Pipeline

**Files:**
- Create: `scripts/build-dmg.sh`
- Create: `Tests/Release/test-release-package.sh`
- Modify: `scripts/build-app.sh`
- Modify: `scripts/install-app.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: clean source tree, Xcode toolchain, app icon, bundled manifest.
- Produces: `dist/Local-Meeting-Recorder-0.2.0-arm64.dmg`, `dist/SHA256SUMS.txt`, and a release package verification result.

- [ ] **Step 1: Write a failing release-package test**

```bash
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="$1"
test -d "$APP_PATH"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")" = "local.meeting.recorder"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist")" = "15.0"
test -x "$APP_PATH/Contents/MacOS/LocalMeetingRecorder"
test -f "$APP_PATH/Contents/Resources/release-manifest.json"
test ! -e "$APP_PATH/Contents/Resources/BlackHole2ch.pkg"
test ! -e "$APP_PATH/Contents/Resources/oMLX.app"
! rg -a "/Users/apple|Documents/AIA ASR|1234" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
```

- [ ] **Step 2: Run the release test and confirm the current build fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh release && Tests/Release/test-release-package.sh "build/Local Meeting Recorder Staging.app"`

Expected: FAIL because the current build script has no release mode and runtime artifacts still contain developer paths.

- [ ] **Step 3: Add deterministic release app building**

Make `scripts/build-app.sh release` run `swift build -c release --arch arm64`, copy the release binary, resources, icon, and manifest into `build/Local Meeting Recorder.app`, set version fields from `APP_VERSION` and `BUILD_NUMBER`, set bundle id `local.meeting.recorder`, and finish with `codesign --force --deep --sign -`. Keep the default no-argument staging path and staging identifier for local development.

- [ ] **Step 4: Create the DMG builder**

`scripts/build-dmg.sh` accepts version and build number, builds the release app, creates a temporary image folder with the app and an Applications symlink, runs `hdiutil create -format UDZO -volname "Local Meeting Recorder"`, writes the DMG into `dist/`, and runs `shasum -a 256` into `dist/SHA256SUMS.txt`. Use `mktemp -d` and a trap that removes only that exact temporary directory.

- [ ] **Step 5: Update end-user documentation**

Rewrite README installation and ASR sections to cover Finder `Open`, administrator password only in Apple's Installer, setup steps, the 1.61 GB model download, `~/Downloads`, repair/diagnostics, and DMG checksum verification. Remove statements claiming direct `mlx_audio.stt.generate`, the 8-bit model, or `/Users/apple/Documents/AIA ASR`.

- [ ] **Step 6: Build and inspect the real artifact**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-dmg.sh 0.2.0 2`

Expected: DMG and checksum exist in `dist/`; `hdiutil verify` succeeds; mounting the DMG shows exactly the recorder app and Applications shortcut.

- [ ] **Step 7: Run tests and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Run: `Tests/Release/test-release-package.sh "build/Local Meeting Recorder.app"`

Expected: all tests PASS.

```bash
git add scripts/build-dmg.sh scripts/build-app.sh scripts/install-app.sh Tests/Release/test-release-package.sh README.md
git commit -m "Add self-service DMG release pipeline"
```

### Task 10: Clean-Mac Acceptance and Release Candidate

**Files:**
- Create: `docs/self-service-install-checklist.md`
- Modify: files implicated by acceptance failures only.

**Interfaces:**
- Consumes: Task 9 DMG on an M1 MacBook running macOS 15+ with an administrator account.
- Produces: recorded pass/fail evidence and a release-candidate commit.

- [ ] **Step 1: Run automated verification from a clean build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-dmg.sh 0.2.0 2
hdiutil verify dist/Local-Meeting-Recorder-0.2.0-arm64.dmg
shasum -a 256 -c dist/SHA256SUMS.txt
```

Expected: all commands exit 0.

- [ ] **Step 2: Perform first-launch acceptance on the colleague-equivalent account**

Follow the DMG through Finder only. Verify Finder `Open`, official BlackHole installer, oMLX install/start, random Keychain API key, pinned Qwen download/resume, Multi-Output guidance, microphone permission, ten-second recording, playback, manual import, and transcription. Record each result and the tested app/oMLX/BlackHole/model versions in `docs/self-service-install-checklist.md`.

- [ ] **Step 3: Exercise failure recovery**

Temporarily test offline download, low-space simulation through an injected debug probe, oMLX stopped, port 8000 conflict, API-key mismatch, microphone denial, and model partial file. Confirm each case names the component, preserves user data, and recovers through `Retry` or `Repair Setup` without Terminal.

- [ ] **Step 4: Inspect exported diagnostics**

Export diagnostics into `/Users/Shared/RecorderAcceptanceDiagnostics`, then run:

```bash
DIAGNOSTICS_DIR="$(find /Users/Shared/RecorderAcceptanceDiagnostics -maxdepth 1 -type d -name 'Local Meeting Recorder Diagnostics-*' -print -quit)"
test -n "$DIAGNOSTICS_DIR"
rg -n "1234|Authorization:|Bearer |transcript_qwen|recording\.m4a" "$DIAGNOSTICS_DIR"
```

Expected: no matches. Replace the quoted path with the exact folder selected during the GUI test; do not use a broad home-directory glob.

- [ ] **Step 5: Reinstall over the existing app**

Replace the app from the same DMG and verify recordings, setup state, oMLX settings, downloaded model, and output folder remain. Note whether macOS asks for microphone permission again, since ad-hoc signatures cannot guarantee TCC persistence across binary changes.

- [ ] **Step 6: Final review and release-candidate commit**

Run: `git diff --check`

Run: `git status --short`

Expected before commit: only the acceptance checklist is changed. If acceptance exposed a code failure, return to the owning task, add a failing regression test, fix it, rerun that task, and make a focused fix commit before resuming Task 10.

```bash
git add docs/self-service-install-checklist.md
git commit -m "Verify self-service recorder release candidate"
```

After the commit, rerun Task 10 Step 1 against the committed SHA and require a clean `git status --short` before distributing the DMG.
