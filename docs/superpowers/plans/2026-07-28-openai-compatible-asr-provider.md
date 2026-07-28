# OpenAI-Compatible ASR Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hard-coded oMLX/Qwen transcription path with a user-configured OpenAI-compatible provider while preserving the validated long-recording pipeline and legacy recordings.

**Architecture:** Persist a provider-neutral profile in `UserDefaults`, keep its optional API key in Keychain, and snapshot both when a transcription job begins. Swift passes a one-shot JSON payload through a private stdin pipe to a provider-neutral Python long-form helper; that helper uses a standard-library multipart HTTP client and retains the existing chunk planning, rolling context, validation, retry, merge, and atomic publication behavior.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation URLSession, Security.framework, UserDefaults, Python 3 standard library, FFmpeg/FFprobe, XCTest, Python `unittest`.

## Global Constraints

- Complete `2026-07-28-secure-credentials-and-teams-migration.md` Task 1 before this plan.
- Minimum deployment target remains macOS 15.
- The saved API base URL ends in `/v1`.
- Accept HTTPS for any host; accept HTTP only for loopback.
- Reject URL user information, query strings, and fragments.
- Support arbitrary non-empty ASR and LLM model identifiers.
- Bearer authentication is optional.
- `GET /v1/models` is optional convenience and never a transcription prerequisite.
- Transcription multipart fields are `file`, `model`, optional `language`, optional `prompt`, and `response_format=json`.
- Do not send provider-specific `max_tokens` or other extra multipart fields.
- Require a JSON object with a string `text` response.
- Preserve silence-aware 120-second target chunks, 180-second maximum chunks, 1.5-second overlap padding, rolling context, retry without context, shorter-interval retry, repetition validation, and atomic publication.
- Provider settings edited during a running job affect only the next job.
- The app must not install, download, launch, or hard-code oMLX, Qwen, another provider, or any model in the normal path.
- Store no API key in `UserDefaults`, arguments, environment, logs, diagnostics, status, or persisted provider JSON.
- New canonical artifacts are `transcript.txt`, `transcript.raw.txt`, `transcription.json`, and `transcription.log`.
- Existing model-specific transcript and log files remain readable.
- `llmModel` is persisted but no chat-completion or summary call is added.
- Do not modify or install the running application.

---

## File Structure

- Create `Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift`
  - Profile schema, URL normalization, and validation.
- Create `Sources/RecorderApp/Transcription/ProviderProfileStore.swift`
  - Non-secret `UserDefaults` persistence.
- Create `Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift`
  - Profile and Keychain key access, snapshots, and explicit key removal.
- Create `Sources/RecorderApp/Transcription/LegacyOMLXSettingsReader.swift`
  - One-time legacy migration only.
- Create `Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift`
  - Optional model discovery and connection test.
- Create `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift`
  - MainActor settings state and commands.
- Create `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
  - Compact provider-neutral settings UI.
- Create `Sources/RecorderApp/Transcription/TranscriptionProtocolLineDecoder.swift`
  - Incremental status-line decoding.
- Modify `Sources/RecorderApp/Transcription/TranscriptionProcess.swift`
  - Private stdin payload transport.
- Modify `Sources/RecorderApp/AppModel.swift`
  - Provider snapshot and generic transcription wiring.
- Modify `Sources/RecorderApp/ContentView.swift`
  - Provider settings and generic button state/copy.
- Modify `Sources/RecorderApp/RecordingLibrary.swift`
  - Canonical and legacy transcript/log resolution.
- Rename `scripts/qwen_asr_longform.py` to `scripts/openai_asr_longform.py`.
- Rename `scripts/transcribe-qwen-asr.sh` to
  `scripts/transcribe-openai-compatible.sh`.
- Retain `scripts/transcribe-qwen-asr.sh` as a one-release wrapper.
- Delete `scripts/prepare-qwen-asr.sh`.
- Rename and expand the corresponding Python tests.
- Add focused Swift profile, migration, client, settings, process, and library
  tests.

### Task 1: Validated Provider Profile and Persistence

**Files:**
- Create: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift`
- Create: `Sources/RecorderApp/Transcription/ProviderProfileStore.swift`
- Create: `Tests/RecorderAppTests/OpenAICompatibleProviderProfileTests.swift`
- Create: `Tests/RecorderAppTests/ProviderProfileStoreTests.swift`

**Interfaces:**
- Produces: `OpenAICompatibleProviderProfile.validated(...)`
- Produces: `OpenAICompatibleProviderProfileStore`
- Produces: `ProviderProfileValidationError`
- Produces: defaults key `openAICompatibleProvider.activeProfile.v1`

- [ ] **Step 1: Write failing validation tests**

```swift
import XCTest
@testable import RecorderApp

final class OpenAICompatibleProviderProfileTests: XCTestCase {
    func testNormalizesRootURLToV1() throws {
        let profile = try makeProfile(
            baseURL: "https://api.example.com/"
        )
        XCTAssertEqual(
            profile.baseURL.absoluteString,
            "https://api.example.com/v1"
        )
    }

    func testPreservesCustomPrefixAndAddsOneV1Suffix() throws {
        let profile = try makeProfile(
            baseURL: "https://host.example/openai/"
        )
        XCTAssertEqual(
            profile.baseURL.absoluteString,
            "https://host.example/openai/v1"
        )
    }

    func testAllowsLoopbackHTTP() throws {
        XCTAssertNoThrow(
            try makeProfile(baseURL: "http://127.0.0.1:8000/v1")
        )
        XCTAssertNoThrow(
            try makeProfile(baseURL: "http://[::1]:8765/v1")
        )
    }

    func testRejectsRemoteHTTPAndCredentialBearingURL() {
        XCTAssertThrowsError(
            try makeProfile(baseURL: "http://api.example.com/v1")
        )
        XCTAssertThrowsError(
            try makeProfile(
                baseURL: "https://user:pass@example.com/v1"
            )
        )
    }

    func testRejectsQueryFragmentAndBlankModels() {
        XCTAssertThrowsError(
            try makeProfile(
                baseURL: "https://api.example.com/v1?key=value"
            )
        )
        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfile.validated(
                baseURLText: "https://api.example.com/v1",
                asrModel: " ",
                llmModel: "chat-model",
                language: "yue",
                prompt: ""
            )
        )
    }

    func testPreservesArbitraryModelIdentifiers() throws {
        let profile = try OpenAICompatibleProviderProfile.validated(
            baseURLText: "https://api.example.com/v1",
            asrModel: "vendor/custom-asr:2026-07",
            llmModel: "local/my-meeting-llm",
            language: " yue ",
            prompt: " Hong Kong meeting "
        )
        XCTAssertEqual(profile.asrModel, "vendor/custom-asr:2026-07")
        XCTAssertEqual(profile.llmModel, "local/my-meeting-llm")
        XCTAssertEqual(profile.language, "yue")
        XCTAssertEqual(profile.prompt, "Hong Kong meeting")
    }
}
```

The test helper supplies non-empty default ASR and LLM model identifiers.

- [ ] **Step 2: Run profile tests to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter OpenAICompatibleProviderProfileTests
```

Expected: compile failure because the profile does not exist.

- [ ] **Step 3: Implement profile validation and normalization**

```swift
import Foundation

struct OpenAICompatibleProviderProfile:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let baseURL: URL
    let asrModel: String
    let llmModel: String
    let language: String
    let prompt: String

    private init(
        schemaVersion: Int,
        baseURL: URL,
        asrModel: String,
        llmModel: String,
        language: String,
        prompt: String
    ) {
        self.schemaVersion = schemaVersion
        self.baseURL = baseURL
        self.asrModel = asrModel
        self.llmModel = llmModel
        self.language = language
        self.prompt = prompt
    }

    static func validated(
        baseURLText: String,
        asrModel: String,
        llmModel: String,
        language: String,
        prompt: String
    ) throws -> Self {
        let trimmedURL = baseURLText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard var components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ProviderProfileValidationError
                .unsupportedURLComponents
        }
        guard scheme == "https"
                || (scheme == "http" && isLoopback(host)) else {
            throw ProviderProfileValidationError.insecureRemoteURL
        }

        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" {
            path = "/v1"
        } else if !path.hasSuffix("/v1") {
            path += "/v1"
        }
        components.scheme = scheme
        components.host = host
        components.percentEncodedPath = path

        guard let normalizedURL = components.url else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        let asr = asrModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let llm = llmModel.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !asr.isEmpty else {
            throw ProviderProfileValidationError.missingASRModel
        }
        guard !llm.isEmpty else {
            throw ProviderProfileValidationError.missingLLMModel
        }

        return Self(
            schemaVersion: currentSchemaVersion,
            baseURL: normalizedURL,
            asrModel: asr,
            llmModel: llm,
            language: language.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            prompt: prompt.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.first == "127",
              octets.allSatisfy({
                  guard let value = UInt8($0) else { return false }
                  return String(value) == $0 || $0 == "0"
              }) else {
            return false
        }
        return true
    }
}

enum ProviderProfileValidationError: LocalizedError, Equatable {
    case invalidBaseURL
    case unsupportedURLComponents
    case insecureRemoteURL
    case missingASRModel
    case missingLLMModel
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Enter a valid API base URL."
        case .unsupportedURLComponents:
            "The API URL cannot contain credentials, a query, or a fragment."
        case .insecureRemoteURL:
            "Remote providers must use HTTPS."
        case .missingASRModel:
            "Enter an ASR model identifier."
        case .missingLLMModel:
            "Enter an LLM model identifier."
        case .unsupportedSchemaVersion(let version):
            "Provider profile version \(version) is not supported."
        }
    }
}
```

Fix the loopback helper test if Swift preserves a normalized numeric octet
spelling differently; do not broaden HTTP to non-loopback hosts.

- [ ] **Step 4: Write failing profile-store tests**

```swift
final class ProviderProfileStoreTests: XCTestCase {
    func testRoundTripsProfileAsJSONData() throws {
        let defaults = makeDefaults()
        let store = OpenAICompatibleProviderProfileStore(
            defaults: defaults
        )
        let profile = try makeProfile()

        try store.save(profile)

        XCTAssertEqual(try store.load(), profile)
        XCTAssertNil(
            defaults.string(
                forKey: OpenAICompatibleProviderProfileStore.key
            )
        )
        XCTAssertNotNil(
            defaults.data(
                forKey: OpenAICompatibleProviderProfileStore.key
            )
        )
    }

    func testRejectsUnsupportedStoredSchema() throws {
        let defaults = makeDefaults()
        let data = Data(
            """
            {
              "schemaVersion": 99,
              "baseURL": "https://api.example.com/v1",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "yue",
              "prompt": ""
            }
            """.utf8
        )
        defaults.set(
            data,
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(
                defaults: defaults
            ).load()
        )
    }

    func testRejectsStoredRemoteHTTPBeforeCredentialUse() {
        let defaults = makeDefaults()
        defaults.set(
            storedProfileData(
                baseURL: "http://attacker.example/v1"
            ),
            forKey: OpenAICompatibleProviderProfileStore.key
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(
                defaults: defaults
            ).load()
        ) {
            XCTAssertEqual(
                $0 as? ProviderProfileValidationError,
                .insecureRemoteURL
            )
        }
    }

    func testSaveRevalidatesDecodedCredentialBearingURL() throws {
        let defaults = makeDefaults()
        let untrusted = try JSONDecoder().decode(
            OpenAICompatibleProviderProfile.self,
            from: storedProfileData(
                baseURL:
                    "https://user:pass@api.example.com/v1"
            )
        )

        XCTAssertThrowsError(
            try OpenAICompatibleProviderProfileStore(
                defaults: defaults
            ).save(untrusted)
        )
        XCTAssertNil(
            defaults.data(
                forKey: OpenAICompatibleProviderProfileStore.key
            )
        )
    }

    private func storedProfileData(
        baseURL: String
    ) -> Data {
        Data(
            """
            {
              "schemaVersion": 1,
              "baseURL": "\(baseURL)",
              "asrModel": "asr",
              "llmModel": "llm",
              "language": "yue",
              "prompt": ""
            }
            """.utf8
        )
    }
}
```

- [ ] **Step 5: Implement non-secret persistence**

```swift
protocol ProviderProfileStoring: Sendable {
    func load() throws -> OpenAICompatibleProviderProfile?
    func save(_ profile: OpenAICompatibleProviderProfile) throws
}

final class OpenAICompatibleProviderProfileStore:
    ProviderProfileStoring,
    @unchecked Sendable
{
    static let key =
        "openAICompatibleProvider.activeProfile.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> OpenAICompatibleProviderProfile? {
        try lock.withLock {
            guard let data = defaults.data(forKey: Self.key) else {
                return nil
            }
            let profile = try JSONDecoder().decode(
                OpenAICompatibleProviderProfile.self,
                from: data
            )
            guard profile.schemaVersion
                    == OpenAICompatibleProviderProfile
                        .currentSchemaVersion else {
                throw ProviderProfileValidationError
                    .unsupportedSchemaVersion(profile.schemaVersion)
            }
            return try validate(profile)
        }
    }

    func save(
        _ profile: OpenAICompatibleProviderProfile
    ) throws {
        let data = try JSONEncoder().encode(
            validate(profile)
        )
        lock.withLock {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func validate(
        _ profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderProfile {
        guard profile.schemaVersion
                == OpenAICompatibleProviderProfile
                    .currentSchemaVersion else {
            throw ProviderProfileValidationError
                .unsupportedSchemaVersion(profile.schemaVersion)
        }
        return try OpenAICompatibleProviderProfile.validated(
            baseURLText: profile.baseURL.absoluteString,
            asrModel: profile.asrModel,
            llmModel: profile.llmModel,
            language: profile.language,
            prompt: profile.prompt
        )
    }
}
```

- [ ] **Step 6: Run focused tests and commit Task 1**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter OpenAICompatibleProviderProfileTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter ProviderProfileStoreTests
git add \
  Sources/RecorderApp/Transcription/OpenAICompatibleProviderProfile.swift \
  Sources/RecorderApp/Transcription/ProviderProfileStore.swift \
  Tests/RecorderAppTests/OpenAICompatibleProviderProfileTests.swift \
  Tests/RecorderAppTests/ProviderProfileStoreTests.swift
git commit -m "Add validated OpenAI-compatible provider profiles"
```

Expected: both focused suites pass before the commit.

### Task 2: Provider Repository and One-Time Legacy Migration

**Files:**
- Create: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift`
- Create: `Sources/RecorderApp/Transcription/LegacyOMLXSettingsReader.swift`
- Create: `Tests/RecorderAppTests/OpenAICompatibleProviderRepositoryTests.swift`
- Create: `Tests/RecorderAppTests/LegacyOMLXSettingsReaderTests.swift`
- Modify: `Sources/RecorderApp/Setup/AppPaths.swift`

**Interfaces:**
- Consumes: Task 1 profile store
- Consumes: secure-value store from the credential plan
- Produces: `OpenAICompatibleProviderSnapshot`
- Produces: provider key service/account constants
- Produces: `migrateLegacyIfNeeded(settingsURL:)`

- [ ] **Step 1: Write failing repository tests**

```swift
final class OpenAICompatibleProviderRepositoryTests: XCTestCase {
    func testSnapshotCombinesProfileAndOptionalKey() throws {
        let profileStore = InMemoryProfileStore(profile: try makeProfile())
        let secure = InMemorySecureValueStore(
            stored: Data("secret-key".utf8)
        )
        let repository = makeRepository(
            profileStore: profileStore,
            secureStore: secure
        )

        XCTAssertEqual(
            try repository.snapshot(),
            OpenAICompatibleProviderSnapshot(
                profile: try XCTUnwrap(profileStore.profile),
                apiKey: "secret-key"
            )
        )
    }

    func testSavingProfileWithoutReplacementPreservesKey() throws {
        let secure = InMemorySecureValueStore(
            stored: Data("existing-key".utf8)
        )
        let repository = makeRepository(secureStore: secure)

        try repository.save(
            profile: try makeProfile(),
            replacementAPIKey: nil
        )

        XCTAssertEqual(secure.stored, Data("existing-key".utf8))
    }

    func testExplicitRemoveDeletesKey() throws {
        let secure = InMemorySecureValueStore(
            stored: Data("existing-key".utf8)
        )
        let repository = makeRepository(secureStore: secure)

        try repository.removeAPIKey()

        XCTAssertNil(secure.stored)
    }
}
```

- [ ] **Step 2: Implement repository and snapshot**

```swift
struct OpenAICompatibleProviderSnapshot:
    Codable,
    Equatable,
    Sendable
{
    let profile: OpenAICompatibleProviderProfile
    let apiKey: String?
}

enum OpenAICompatibleProviderCredential {
    static let service =
        "local.meeting.recorder.openai-compatible-provider"
    static let account = "active-profile-api-key.v1"
}

enum ProviderRepositoryError: LocalizedError, Equatable {
    case missingProfile
    case invalidAPIKeyEncoding
    case legacyCredentialMismatch
    case migrationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .missingProfile:
            "Configure an AI provider before starting transcription."
        case .invalidAPIKeyEncoding:
            "The saved provider API key is invalid."
        case .legacyCredentialMismatch:
            "The saved provider key differs from the legacy local key."
        case .migrationVerificationFailed:
            "Provider credential migration could not be verified."
        }
    }
}

final class OpenAICompatibleProviderRepository:
    @unchecked Sendable
{
    private let profiles: any ProviderProfileStoring
    private let secureStore: any SecureValueStoring
    private let lock = NSLock()

    init(
        profiles: any ProviderProfileStoring,
        secureStore: any SecureValueStoring
    ) {
        self.profiles = profiles
        self.secureStore = secureStore
    }

    func loadProfile() throws -> OpenAICompatibleProviderProfile? {
        try profiles.load()
    }

    func snapshot() throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            guard let profile = try profiles.load() else {
                throw ProviderRepositoryError.missingProfile
            }
            return OpenAICompatibleProviderSnapshot(
                profile: profile,
                apiKey: try loadAPIKey()
            )
        }
    }

    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot {
        try lock.withLock {
            OpenAICompatibleProviderSnapshot(
                profile: profile,
                apiKey: try loadAPIKey()
            )
        }
    }

    func save(
        profile: OpenAICompatibleProviderProfile,
        replacementAPIKey: String?
    ) throws {
        try lock.withLock {
            if let replacementAPIKey,
               !replacementAPIKey.isEmpty {
                try secureStore.save(
                    Data(replacementAPIKey.utf8),
                    service:
                        OpenAICompatibleProviderCredential.service,
                    account:
                        OpenAICompatibleProviderCredential.account
                )
            }
            try profiles.save(profile)
        }
    }

    func hasAPIKey() throws -> Bool {
        try loadAPIKey() != nil
    }

    func removeAPIKey() throws {
        try secureStore.delete(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        )
    }

    private func loadAPIKey() throws -> String? {
        guard let data = try secureStore.load(
            service: OpenAICompatibleProviderCredential.service,
            account: OpenAICompatibleProviderCredential.account
        ) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw ProviderRepositoryError.invalidAPIKeyEncoding
        }
        return value
    }
}
```

Use one lock only for repository ordering. Do not expose `loadAPIKey()` to the
UI; settings display only `hasAPIKey`.

- [ ] **Step 3: Write failing legacy-reader and migration tests**

```swift
final class LegacyOMLXSettingsReaderTests: XCTestCase {
    func testReadsHostPortAndAPIKeyWithoutProviderDefaults() throws {
        let file = try writeSettings(
            """
            {
              "server": {"host": "127.0.0.1", "port": 8765},
              "auth": {"api_key": "legacy-secret"}
            }
            """
        )

        let settings = try LegacyOMLXSettingsReader().read(from: file)

        XCTAssertEqual(settings.baseURL.absoluteString,
                       "http://127.0.0.1:8765/v1")
        XCTAssertEqual(settings.apiKey, "legacy-secret")
    }

    func testMapsWildcardBindHostToLoopbackClientHost() throws {
        let file = try writeSettings(
            """
            {
              "server": {"host": "0.0.0.0", "port": 8000},
              "auth": {"api_key": ""}
            }
            """
        )

        XCTAssertEqual(
            try LegacyOMLXSettingsReader()
                .read(from: file).baseURL.host,
            "127.0.0.1"
        )
    }
}

func testMigrationDoesNothingWithoutLegacyFile() throws {
    let repository = makeRepository()
    let result = try repository.migrateLegacyIfNeeded(
        settingsURL: missingURL
    )
    XCTAssertEqual(result, .notFound)
    XCTAssertNil(try repository.loadProfile())
}

func testMigrationUsesPriorModelOnlyAsLegacyDefault() throws {
    let result = try repository.migrateLegacyIfNeeded(
        settingsURL: settingsURL
    )
    XCTAssertEqual(result, .migrated)
    let profile = try XCTUnwrap(repository.loadProfile())
    XCTAssertEqual(
        profile.asrModel,
        "mlx-community--Qwen3-ASR-1.7B-4bit"
    )
    XCTAssertEqual(profile.language, "yue")
}

func testExistingDifferentKeyFailsWithoutMutation() throws {
    secure.stored = Data("already-saved".utf8)
    XCTAssertThrowsError(
        try repository.migrateLegacyIfNeeded(
            settingsURL: settingsURL
        )
    )
    XCTAssertNil(try repository.loadProfile())
    XCTAssertEqual(secure.stored, Data("already-saved".utf8))
}
```

- [ ] **Step 4: Implement the legacy settings reader**

```swift
struct LegacyOMLXSettings: Equatable, Sendable {
    let baseURL: URL
    let apiKey: String?
}

struct LegacyOMLXSettingsReader {
    private struct Document: Decodable {
        struct Server: Decodable {
            let host: String
            let port: Int
        }
        struct Auth: Decodable {
            let apiKey: String?

            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
            }
        }
        let server: Server
        let auth: Auth?
    }

    func read(from url: URL) throws -> LegacyOMLXSettings {
        let document = try JSONDecoder().decode(
            Document.self,
            from: Data(contentsOf: url)
        )
        let host = ["0.0.0.0", "::"].contains(document.server.host)
            ? "127.0.0.1"
            : document.server.host
        guard (1...65_535).contains(document.server.port),
              let baseURL = URL(
                string: "http://\(host):\(document.server.port)/v1"
              ) else {
            throw ProviderProfileValidationError.invalidBaseURL
        }
        let key = document.auth?.apiKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LegacyOMLXSettings(
            baseURL: baseURL,
            apiKey: key?.isEmpty == false ? key : nil
        )
    }
}
```

- [ ] **Step 5: Implement one-time migration and permission tightening**

Add:

```swift
enum LegacyProviderMigrationOutcome: Equatable {
    case notFound
    case alreadyConfigured
    case migrated
}

func migrateLegacyIfNeeded(
    settingsURL: URL
) throws -> LegacyProviderMigrationOutcome {
    try migrateLegacyIfNeeded(
        settingsURL: settingsURL,
        reader: LegacyOMLXSettingsReader(),
        fileManager: .default
    )
}

func migrateLegacyIfNeeded(
    settingsURL: URL,
    reader: LegacyOMLXSettingsReader,
    fileManager: FileManager
) throws -> LegacyProviderMigrationOutcome {
    try lock.withLock {
        if try profiles.load() != nil {
            return .alreadyConfigured
        }
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .notFound
        }
        let legacy = try reader.read(from: settingsURL)
        let existingKey = try loadAPIKey()
        if let existingKey,
           let legacyKey = legacy.apiKey,
           existingKey != legacyKey {
            throw ProviderRepositoryError.legacyCredentialMismatch
        }
        if existingKey == nil, let legacyKey = legacy.apiKey {
            let data = Data(legacyKey.utf8)
            try secureStore.save(
                data,
                service: OpenAICompatibleProviderCredential.service,
                account: OpenAICompatibleProviderCredential.account
            )
            guard try secureStore.load(
                service: OpenAICompatibleProviderCredential.service,
                account: OpenAICompatibleProviderCredential.account
            ) == data else {
                throw ProviderRepositoryError
                    .migrationVerificationFailed
            }
        }
        let profile = try OpenAICompatibleProviderProfile.validated(
            baseURLText: legacy.baseURL.absoluteString,
            asrModel:
                "mlx-community--Qwen3-ASR-1.7B-4bit",
            llmModel: "legacy-unconfigured-llm",
            language: "yue",
            prompt:
                "香港粵語商務會議，可能夾雜英文、人名、"
                + "公司名、產品名及技術縮寫。請忠實轉錄錄音"
                + "內容，不要翻譯或補寫沒有說出的內容。"
        )
        try profiles.save(profile)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath:
                settingsURL.deletingLastPathComponent().path
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsURL.path
        )
        return .migrated
    }
}
```

Do not delete or rewrite `~/.omlx/settings.json`; the external server owns it.
`legacy-unconfigured-llm` is deliberately invalid for future LLM work: no LLM
request exists in this milestone, and a later chat feature must require the
user to replace it before making a request.

- [ ] **Step 6: Keep only the legacy settings path in `AppPaths`**

Retain `omlxSettingsURL` for migration. Delete
`defaultOMLXModelDirectory`; production no longer manages provider models.
Update `AppPathsTests` to assert the migration path derives from the injected
home directory and contains no developer home path.

- [ ] **Step 7: Run focused tests and commit Task 2**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter OpenAICompatibleProviderRepositoryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter LegacyOMLXSettingsReaderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppPathsTests
git add \
  Sources/RecorderApp/Transcription/OpenAICompatibleProviderRepository.swift \
  Sources/RecorderApp/Transcription/LegacyOMLXSettingsReader.swift \
  Sources/RecorderApp/Setup/AppPaths.swift \
  Tests/RecorderAppTests/OpenAICompatibleProviderRepositoryTests.swift \
  Tests/RecorderAppTests/LegacyOMLXSettingsReaderTests.swift \
  Tests/RecorderAppTests/AppPathsTests.swift
git commit -m "Migrate legacy ASR settings to a generic provider"
```

Expected: all focused suites pass.

### Task 3: Provider Connection Test and Settings UI

**Files:**
- Create: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift`
- Create: `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift`
- Create: `Sources/RecorderApp/Views/AIProviderSettingsView.swift`
- Create: `Tests/RecorderAppTests/OpenAICompatibleProviderClientTests.swift`
- Create: `Tests/RecorderAppTests/AIProviderSettingsModelTests.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`

**Interfaces:**
- Consumes: Task 2 repository
- Produces: optional `/models` connection report
- Produces: editable settings and explicit key removal
- Produces: `AIProviderSettingsModel.hasSavedProfile`

- [ ] **Step 1: Write failing provider-client tests**

```swift
final class OpenAICompatibleProviderClientTests: XCTestCase {
    func testListsModelsWithOptionalBearerHeader() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(
                status: 200,
                body: #"{"data":[{"id":"asr-a"},{"id":"llm-b"}]}"#
            )
        )
        let report = try await OpenAICompatibleProviderClient(
            loader: loader
        ).testConnection(
            profile: try makeProfile(),
            apiKey: "secret"
        )

        XCTAssertEqual(report.models, ["asr-a", "llm-b"])
        XCTAssertEqual(
            loader.lastRequest?.value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer secret"
        )
    }

    func testNoAuthOmitsAuthorizationHeader() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(status: 200, body: #"{"data":[]}"#)
        )
        _ = try await OpenAICompatibleProviderClient(
            loader: loader
        ).testConnection(
            profile: try makeProfile(),
            apiKey: nil
        )
        XCTAssertNil(
            loader.lastRequest?.value(
                forHTTPHeaderField: "Authorization"
            )
        )
    }

    func testUnsupportedModelDiscoveryStillReportsReachable() async throws {
        let loader = RecordingProviderDataLoader(
            response: .success(status: 404, body: "")
        )
        let report = try await OpenAICompatibleProviderClient(
            loader: loader
        ).testConnection(
            profile: try makeProfile(),
            apiKey: nil
        )
        XCTAssertFalse(report.supportsModelDiscovery)
        XCTAssertTrue(report.models.isEmpty)
    }

    func testAuthenticationFailureIsTypedAndRedacted() async {
        let loader = RecordingProviderDataLoader(
            response: .success(status: 401, body: "secret")
        )
        do {
            _ = try await OpenAICompatibleProviderClient(
                loader: loader
            ).testConnection(
                profile: try! makeProfile(),
                apiKey: "never-log"
            )
            XCTFail("Expected failure")
        } catch {
            XCTAssertFalse(
                error.localizedDescription.contains("never-log")
            )
            XCTAssertFalse(
                error.localizedDescription.contains("secret")
            )
        }
    }
}
```

- [ ] **Step 2: Implement the provider client**

```swift
import Foundation

protocol ProviderHTTPDataLoading: Sendable {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionProviderHTTPDataLoader: ProviderHTTPDataLoading {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderConnectionError.invalidResponse
        }
        return (data, response)
    }
}

struct ProviderConnectionReport: Equatable, Sendable {
    let supportsModelDiscovery: Bool
    let models: [String]
}

protocol ProviderConnectionTesting: Sendable {
    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport
}

enum ProviderConnectionError: LocalizedError, Equatable {
    case invalidResponse
    case authenticationRejected
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The provider returned an invalid response."
        case .authenticationRejected:
            "The provider rejected the API key."
        case .httpStatus(let status):
            "The provider returned HTTP \(status)."
        }
    }
}

struct OpenAICompatibleProviderClient: ProviderConnectionTesting {
    private let loader: any ProviderHTTPDataLoading

    init(
        loader: any ProviderHTTPDataLoading =
            URLSessionProviderHTTPDataLoader()
    ) {
        self.loader = loader
    }

    func testConnection(
        profile: OpenAICompatibleProviderProfile,
        apiKey: String?
    ) async throws -> ProviderConnectionReport {
        var request = URLRequest(
            url: profile.baseURL
                .appendingPathComponent("models")
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        if let apiKey, !apiKey.isEmpty {
            request.setValue(
                "Bearer \(apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        let (data, response) = try await loader.data(for: request)
        switch response.statusCode {
        case 200..<300:
            let decoded = try? JSONDecoder().decode(
                ModelList.self,
                from: data
            )
            return ProviderConnectionReport(
                supportsModelDiscovery: decoded != nil,
                models: decoded?.data.map(\.id).sorted() ?? []
            )
        case 404, 405:
            return ProviderConnectionReport(
                supportsModelDiscovery: false,
                models: []
            )
        case 401, 403:
            throw ProviderConnectionError.authenticationRejected
        default:
            throw ProviderConnectionError
                .httpStatus(response.statusCode)
        }
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }
}
```

Do not store or return response bodies in errors.

- [ ] **Step 3: Write failing settings-model tests**

```swift
@MainActor
final class AIProviderSettingsModelTests: XCTestCase {
    func testBlankKeyOnSavePreservesStoredKey() throws {
        let repository = RecordingProviderRepository(
            hasAPIKey: true
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )
        model.baseURLText = "https://api.example.com/v1"
        model.asrModel = "asr"
        model.llmModel = "llm"
        model.apiKeyReplacement = ""

        model.save()

        XCTAssertNil(repository.lastReplacementAPIKey)
        XCTAssertTrue(model.hasStoredAPIKey)
    }

    func testRemoveKeyIsExplicit() {
        let repository = RecordingProviderRepository(
            hasAPIKey: true
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient()
        )

        model.removeAPIKey()

        XCTAssertEqual(repository.removeKeyCount, 1)
        XCTAssertFalse(model.hasStoredAPIKey)
    }

    func testConnectionFailureDoesNotDeleteManualModelValues() async {
        let model = makeModel(
            client: StubProviderClient(error: TestError.failed)
        )
        model.asrModel = "manual-asr"
        model.llmModel = "manual-llm"

        await model.testConnection()

        XCTAssertEqual(model.asrModel, "manual-asr")
        XCTAssertEqual(model.llmModel, "manual-llm")
    }

    func testStartupMigrationFailureIsRedactedAndLeavesManualSetupUsable() {
        let repository = RecordingProviderRepository(
            migrationError: NSError(
                domain: "legacy-secret",
                code: 1
            )
        )
        let model = AIProviderSettingsModel(
            repository: repository,
            client: StubProviderClient(),
            loadImmediately: false
        )

        model.performStartupMigration(
            settingsURL: URL(fileURLWithPath: "/tmp/settings.json")
        )

        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(
            model.status,
            "Legacy provider settings could not be migrated. "
                + "Configure the AI provider manually."
        )
        XCTAssertFalse(model.status.contains("legacy-secret"))
    }
}
```

- [ ] **Step 4: Implement settings state and commands**

Define a narrow repository protocol for tests:

```swift
protocol OpenAICompatibleProviderManaging: AnyObject {
    func loadProfile() throws -> OpenAICompatibleProviderProfile?
    func save(
        profile: OpenAICompatibleProviderProfile,
        replacementAPIKey: String?
    ) throws
    func snapshot() throws -> OpenAICompatibleProviderSnapshot
    func snapshot(
        overriding profile: OpenAICompatibleProviderProfile
    ) throws -> OpenAICompatibleProviderSnapshot
    func hasAPIKey() throws -> Bool
    func removeAPIKey() throws
    func migrateLegacyIfNeeded(
        settingsURL: URL
    ) throws -> LegacyProviderMigrationOutcome
}
```

Make the production repository conform. Implement:

```swift
@MainActor
final class AIProviderSettingsModel: ObservableObject {
    @Published var baseURLText = ""
    @Published var apiKeyReplacement = ""
    @Published var asrModel = ""
    @Published var llmModel = ""
    @Published var language = ""
    @Published var prompt = ""
    @Published private(set) var discoveredModels: [String] = []
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var hasSavedProfile = false
    @Published private(set) var isTesting = false
    @Published private(set) var status = "Not configured"
    @Published private(set) var statusIsError = false

    private let repository:
        any OpenAICompatibleProviderManaging
    private let client: any ProviderConnectionTesting

    init(
        repository:
            any OpenAICompatibleProviderManaging,
        client: any ProviderConnectionTesting =
            OpenAICompatibleProviderClient(),
        loadImmediately: Bool = true,
        initialErrorStatus: String? = nil
    ) {
        self.repository = repository
        self.client = client
        if loadImmediately {
            reload()
        }
        if let initialErrorStatus {
            status = initialErrorStatus
            statusIsError = true
        }
    }

    func save() {
        do {
            let profile = try draftProfile()
            try repository.save(
                profile: profile,
                replacementAPIKey:
                    apiKeyReplacement.isEmpty
                    ? nil
                    : apiKeyReplacement
            )
            apiKeyReplacement = ""
            hasStoredAPIKey = try repository.hasAPIKey()
            hasSavedProfile = true
            status = "Provider settings saved"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func removeAPIKey() {
        do {
            try repository.removeAPIKey()
            apiKeyReplacement = ""
            hasStoredAPIKey = false
            status = "API key removed"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func testConnection() async {
        isTesting = true
        defer { isTesting = false }
        do {
            let profile = try draftProfile()
            let snapshot = try repository.snapshot(
                overriding: profile
            )
            let report = try await client.testConnection(
                profile: profile,
                apiKey: snapshot.apiKey
            )
            discoveredModels = report.models
            status = report.supportsModelDiscovery
                ? "Connected; model list available"
                : "Connected; enter models manually"
            statusIsError = false
        } catch {
            present(error)
        }
    }

    func performStartupMigration(settingsURL: URL) {
        do {
            _ = try repository.migrateLegacyIfNeeded(
                settingsURL: settingsURL
            )
            reload()
        } catch {
            status =
                "Legacy provider settings could not be migrated. "
                + "Configure the AI provider manually."
            statusIsError = true
        }
    }
}
```

`reload()`, `draftProfile()`, and `present(_:)` contain no provider-specific
copy. `reload()` populates fields from the saved profile and only reports
redacted errors.

- [ ] **Step 5: Add the settings view and replace `ASRModelView`**

Create a compact un-nested settings section:

```swift
struct AIProviderSettingsView: View {
    @ObservedObject var model: AIProviderSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI Provider", systemImage: "server.rack")
                .font(.headline)

            TextField("API Base URL", text: $model.baseURLText)
                .textFieldStyle(.roundedBorder)
            SecureField(
                model.hasStoredAPIKey
                    ? "API Key (saved)"
                    : "API Key (optional)",
                text: $model.apiKeyReplacement
            )
            modelField("ASR Model", text: $model.asrModel)
            modelField("LLM Model", text: $model.llmModel)
            TextField("Language", text: $model.language)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $model.prompt)
                .frame(minHeight: 58, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                )

            HStack {
                Button("Save", systemImage: "square.and.arrow.down") {
                    model.save()
                }
                Button("Test", systemImage: "network") {
                    Task { await model.testConnection() }
                }
                .disabled(model.isTesting)
                Button(
                    "Remove Key",
                    systemImage: "key.slash",
                    role: .destructive
                ) {
                    model.removeAPIKey()
                }
                .disabled(!model.hasStoredAPIKey)
                Spacer()
                if model.isTesting {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(
                        model.statusIsError ? .orange : .secondary
                    )
            }
        }
        .padding(14)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55))
        )
    }

    private func modelField(
        _ title: String,
        text: Binding<String>
    ) -> some View {
        HStack {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
            if !model.discoveredModels.isEmpty {
                Menu {
                    ForEach(model.discoveredModels, id: \.self) {
                        value in
                        Button(value) { text.wrappedValue = value }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .help("Choose a discovered model")
            }
        }
    }
}
```

Add `providerRepository: (any OpenAICompatibleProviderManaging)? = nil` and
`appPaths: AppPaths = .live` to `AppModel.init`. Resolve the default once:

```swift
let activeProviderRepository =
    providerRepository
    ?? OpenAICompatibleProviderRepository(
        profiles: OpenAICompatibleProviderProfileStore(
            defaults: defaults
        ),
        secureStore: KeychainSecureValueStore()
    )
self.providerRepository = activeProviderRepository
self.aiProviderSettingsModel = AIProviderSettingsModel(
    repository: activeProviderRepository,
    loadImmediately: false
)
self.appPaths = appPaths
```

After the existing `guard performStartupWork else { return }`, replace ASR
model preparation with:

```swift
aiProviderSettingsModel.performStartupMigration(
    settingsURL: appPaths.omlxSettingsURL
)
```

This is the only automatic legacy migration call. Tests that use
`performStartupWork: false` do not access Keychain; transcription tests inject
`RecordingProviderRepository` explicitly.

Expose `let aiProviderSettingsModel` from `AppModel`, insert
`AIProviderSettingsView(model: model.aiProviderSettingsModel)` where
`ASRModelView` currently appears, and delete `ASRModelView`.

Remove startup calls to `refreshASRModelStatus()` and
`prepareASRModelIfNeeded()`, their process state, and all oMLX model-status
copy. The transcription button is enabled by `hasSavedProfile`, not by a
successful model-list request.

- [ ] **Step 6: Run focused UI/model tests and commit Task 3**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter OpenAICompatibleProviderClientTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AIProviderSettingsModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelTranscriptionTests
git add \
  Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift \
  Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift \
  Sources/RecorderApp/Views/AIProviderSettingsView.swift \
  Sources/RecorderApp/AppModel.swift \
  Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/OpenAICompatibleProviderClientTests.swift \
  Tests/RecorderAppTests/AIProviderSettingsModelTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift
git commit -m "Add OpenAI-compatible provider settings"
```

Expected: provider client and settings tests pass. Existing transcription tests
remain green through injected test configuration until Task 4 rewires the
process payload.

### Task 4: Private Stdin Payload and App Transcription Wiring

**Files:**
- Create: `Sources/RecorderApp/Transcription/TranscriptionProtocolLineDecoder.swift`
- Create: `Tests/RecorderAppTests/TranscriptionProtocolLineDecoderTests.swift`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionProcess.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Tests/RecorderAppTests/TranscriptionProcessTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`

**Interfaces:**
- Consumes: Task 2 provider snapshot
- Produces: `OpenAICompatibleTranscriptionLaunchPayload`
- Produces: `TranscriptionProcessRequest.configurationInput`
- Produces: private stdin write-and-close behavior
- Produces: stateful protocol-line decoding in both live callbacks and the
  final process result

- [ ] **Step 1: Write failing private-stdin process tests**

Create a shell fixture that writes stdin to one file and writes its arguments
and environment to another:

```swift
func testConfigurationArrivesOnlyThroughPrivateStdin() async throws {
    let secret = "private-api-key"
    let payload = Data(
        #"{"apiKey":"private-api-key","asrModel":"asr"}"#.utf8
    )
    let process = try FoundationTranscriptionProcessLauncher()
        .makeProcess(
            request: .init(
                scriptURL: fixture.scriptURL,
                audioURL: fixture.audioURL,
                folderURL: fixture.root,
                configurationInput: payload
            ),
            onOutput: { _ in }
        )

    try process.run()
    let result = await process.waitForExit()

    XCTAssertEqual(
        try Data(contentsOf: fixture.stdinCaptureURL),
        payload
    )
    let metadata = try String(
        contentsOf: fixture.metadataCaptureURL
    )
    XCTAssertFalse(metadata.contains(secret))
    XCTAssertFalse(result.output.contains(secret))
}
```

The fixture script runs:

```bash
#!/bin/bash
set -euo pipefail
OUTPUT_FOLDER="$2"
/bin/cat > "${OUTPUT_FOLDER}/stdin-capture"
/usr/bin/printf '%s\n' "$@" \
  > "${OUTPUT_FOLDER}/metadata-capture"
/usr/bin/env >> "${OUTPUT_FOLDER}/metadata-capture"
```

The fixture reads its capture paths from the existing non-secret output-folder
argument. Neither test nor production launcher adds a process environment
dictionary.

- [ ] **Step 2: Extend the request and implement stdin lifecycle**

```swift
struct TranscriptionProcessRequest: Equatable, Sendable {
    let scriptURL: URL
    let audioURL: URL
    let folderURL: URL
    let configurationInput: Data
}

struct TranscriptionProcessResult: Equatable, Sendable {
    let exitStatus: Int32
    let output: String
    let protocolLines: [String]
}

private final class FoundationTranscriptionProcess:
    TranscriptionProcessing,
    @unchecked Sendable
{
    private let inputPipe = Pipe()
    private let configurationInput: Data

    init(
        request: TranscriptionProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        configurationInput = request.configurationInput
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            request.scriptURL.path,
            request.audioURL.path,
            request.folderURL.path
        ]
        process.standardInput = inputPipe
        // Preserve the existing stdout/stderr drain setup.
    }

    func run() throws {
        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(
                contentsOf: configurationInput
            )
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }
}
```

Close the write handle in `terminate()` and `deinit` as an idempotent fallback.
Do not print or retain a string representation of `configurationInput`.

- [ ] **Step 3: Write failing incremental-line tests**

```swift
final class TranscriptionProtocolLineDecoderTests: XCTestCase {
    func testReassemblesLinesAcrossArbitraryByteChunks() {
        var decoder = TranscriptionProtocolLineDecoder()
        XCTAssertEqual(decoder.append(Data("STA".utf8)), [])
        XCTAssertEqual(
            decoder.append(Data("TUS=Uploading\nTRANS".utf8)),
            ["STATUS=Uploading"]
        )
        XCTAssertEqual(
            decoder.append(Data("CRIPT_PATH=/tmp/a.txt\n".utf8)),
            ["TRANSCRIPT_PATH=/tmp/a.txt"]
        )
        XCTAssertEqual(decoder.finish(), [])
    }

    func testPreservesUTF8ScalarSplitAcrossChunks() {
        var decoder = TranscriptionProtocolLineDecoder()
        let bytes = Data("STATUS=上載中\n".utf8)
        let split = bytes.index(bytes.startIndex, offsetBy: 9)

        XCTAssertEqual(
            decoder.append(bytes[..<split]),
            []
        )
        XCTAssertEqual(
            decoder.append(bytes[split...]),
            ["STATUS=上載中"]
        )
    }

    func testFinishPublishesFinalUnterminatedLineOnce() {
        var decoder = TranscriptionProtocolLineDecoder()
        _ = decoder.append(Data("LOG_PATH=/tmp/log".utf8))
        XCTAssertEqual(decoder.finish(), ["LOG_PATH=/tmp/log"])
        XCTAssertEqual(decoder.finish(), [])
    }
}
```

- [ ] **Step 4: Implement the decoder**

```swift
struct TranscriptionProtocolLineDecoder {
    private var pending = Data()
    private var finished = false

    mutating func append<S: DataProtocol>(
        _ chunk: S
    ) -> [String] {
        guard !finished else { return [] }
        pending.append(contentsOf: chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var bytes = Data(pending[..<newline])
            if bytes.last == 0x0D {
                bytes.removeLast()
            }
            lines.append(String(decoding: bytes, as: UTF8.self))
            pending.removeSubrange(
                pending.startIndex...newline
            )
        }
        return lines
    }

    mutating func finish() -> [String] {
        guard !finished else { return [] }
        finished = true
        guard !pending.isEmpty else { return [] }
        defer { pending.removeAll(keepingCapacity: false) }
        return [String(decoding: pending, as: UTF8.self)]
    }
}
```

Store the decoder and `protocolLines: [String]` in
`FoundationTranscriptionProcess`, beside `outputData`.
`consumeAvailableData` appends raw bytes and obtains complete lines under the
existing lock, then invokes `onOutput` once per line after releasing the lock:

```swift
let lines: [String] = lock.withLock {
    outputData.append(data)
    let lines = protocolDecoder.append(data)
    protocolLines.append(
        contentsOf: lines.filter(Self.isProtocolLine)
    )
    return lines
}
for line in lines {
    onOutput(line)
}
```

In `finish(exitStatus:)`, disable the readability handler, drain to EOF, call
`protocolDecoder.finish()`, append the recognized final lines, and copy the
ordered recognized lines into `TranscriptionProcessResult.protocolLines`.
Deliver the final live
callbacks before resuming `exitContinuation`, but do not rely on callback
ordering for correctness: MainActor delivery may still lag process completion.
`isProtocolLine` accepts only `STATUS=`, `TRANSCRIPT_PATH=`, `LOG_PATH=`, and
`ERROR=` prefixes, so ordinary child logs do not duplicate into the result.

- [ ] **Step 5: Write failing AppModel snapshot and validation tests**

Add:

```swift
func testProviderSnapshotIsCapturedBeforeAudioPreparation() async throws {
    let first = try makeSnapshot(asrModel: "first-model")
    let repository = RecordingProviderRepository(snapshot: first)
    let fixture = try TranscriptionFixture.make()
    let preparer = ControlledPreparer(.suspended(started: started))
    let launcher = ControlledLauncher()
    let model = makeModel(
        fixture: fixture,
        preparer: preparer,
        launcher: launcher,
        providerRepository: repository
    )

    model.transcribe(session: fixture.session)
    await fulfillment(of: [started])
    repository.snapshotValue =
        try makeSnapshot(asrModel: "second-model")
    preparer.resume(
        .success(.init(audioURL: fixture.temporaryAudioURL,
                       cleanupURL: nil))
    )
    _ = await launcher.nextProcess()

    let payload = try JSONDecoder().decode(
        OpenAICompatibleTranscriptionLaunchPayload.self,
        from: try XCTUnwrap(
            launcher.requests.last?.configurationInput
        )
    )
    XCTAssertEqual(payload.asrModel, "first-model")
}

func testMissingProfileFailsBeforeAudioPreparation() {
    let repository = RecordingProviderRepository(
        error: ProviderRepositoryError.missingProfile
    )
    let model = makeModel(providerRepository: repository)

    model.transcribe(session: fixture.session)

    XCTAssertTrue(preparer.requests.isEmpty)
    XCTAssertTrue(model.lastTranscriptionDidFail)
    XCTAssertTrue(model.lastTranscriptionStatus.contains("Configure"))
}

func testTranscriptPathOutsideSessionFolderIsRejected() async {
    process.complete(
        exitStatus: 0,
        output: "TRANSCRIPT_PATH=/tmp/untrusted.txt"
    )
    await waitForIdle(model)

    XCTAssertNil(model.transcriptURLsBySessionID[session.id])
    XCTAssertTrue(model.lastTranscriptionDidFail)
}

func testLogSymlinkEscapingSessionFolderIsRejected() async throws {
    let outside = fixture.root.appendingPathComponent("outside.log")
    try Data().write(to: outside)
    let link = fixture.session.folderURL
        .appendingPathComponent("transcription.log")
    try FileManager.default.createSymbolicLink(
        at: link,
        withDestinationURL: outside
    )

    process.complete(
        exitStatus: 0,
        output: "LOG_PATH=\(link.path)"
    )
    await waitForIdle(model)

    XCTAssertNil(model.transcriptionLogURLsBySessionID[session.id])
    XCTAssertTrue(model.lastTranscriptionDidFail)
}

func testFinalResultLinesPublishTranscriptEvenWhenLiveCallbackIsDelayed()
    async throws
{
    let transcript = fixture.session.folderURL
        .appendingPathComponent("transcript.txt")
    try "done".write(
        to: transcript,
        atomically: true,
        encoding: .utf8
    )
    process.complete(
        exitStatus: 0,
        output: "TRANSCRIPT_PATH=\(transcript.path)",
        deliverLiveCallbacks: false
    )
    await waitForIdle(model)

    XCTAssertEqual(
        model.transcriptURLsBySessionID[session.id],
        transcript
    )
    XCTAssertFalse(model.lastTranscriptionDidFail)
}
```

- [ ] **Step 6: Add the launch payload and wire generic transcription**

```swift
struct OpenAICompatibleTranscriptionLaunchPayload:
    Codable,
    Equatable,
    Sendable
{
    let schemaVersion: Int
    let baseURL: String
    let asrModel: String
    let language: String
    let prompt: String
    let apiKey: String?

    init(snapshot: OpenAICompatibleProviderSnapshot) {
        schemaVersion = 1
        baseURL = snapshot.profile.baseURL.absoluteString
        asrModel = snapshot.profile.asrModel
        language = snapshot.profile.language
        prompt = snapshot.profile.prompt
        apiKey = snapshot.apiKey
    }
}
```

At the start of `AppModel.transcribe(session:)`, before audio preparation:

```swift
let snapshot: OpenAICompatibleProviderSnapshot
let configurationInput: Data
do {
    snapshot = try providerRepository.snapshot()
    configurationInput = try JSONEncoder().encode(
        OpenAICompatibleTranscriptionLaunchPayload(
            snapshot: snapshot
        )
    )
} catch {
    lastTranscriptionSessionID = session.id
    lastTranscriptionStatus = error.localizedDescription
    lastTranscriptionDidFail = true
    statusMessage = error.localizedDescription
    return
}
```

Resolve `transcribe-openai-compatible.sh` from the injected URL or app
resources. Remove the `/Users/apple/Documents/recorder` fallback. Pass
`configurationInput` in the process request.

Validate both child-reported paths with one helper:

```swift
private func validatedTranscriptionArtifact(
    path: String,
    in sessionFolder: URL
) -> URL? {
    guard path.hasPrefix("/") else { return nil }
    let expectedParent = sessionFolder
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let candidate = URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard candidate.deletingLastPathComponent()
            == expectedParent else {
        return nil
    }
    guard let values = try? candidate.resourceValues(
        forKeys: [.isRegularFileKey]
    ), values.isRegularFile == true else {
        return nil
    }
    return candidate
}
```

After `waitForExit()` returns and before success/failure finalization or active
attempt cleanup, reduce `result.protocolLines` synchronously on MainActor and
apply the resulting final status, validated log URL, validated transcript URL,
and redacted error. Live callbacks remain a best-effort progress preview;
replaying the full ordered line list is idempotent and is the correctness
source for final artifacts.

Use one value reducer:

```swift
private struct TranscriptionProtocolSnapshot {
    var status: String?
    var transcriptPath: String?
    var logPath: String?
    var error: String?

    init(lines: [String]) {
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty else { continue }
            if line.hasPrefix("STATUS=") {
                status = String(line.dropFirst("STATUS=".count))
            } else if line.hasPrefix("TRANSCRIPT_PATH=") {
                transcriptPath = String(
                    line.dropFirst("TRANSCRIPT_PATH=".count)
                )
            } else if line.hasPrefix("LOG_PATH=") {
                logPath = String(
                    line.dropFirst("LOG_PATH=".count)
                )
            } else if line.hasPrefix("ERROR=") {
                error = String(line.dropFirst("ERROR=".count))
            }
        }
    }
}
```

If either reported path is present but fails
`validatedTranscriptionArtifact`, finish with a redacted invalid-artifact
failure. If exit status is zero but no valid transcript path exists, finish
with `"Transcription completed without a valid transcript file."`. An
`ERROR=` value may replace the generic nonzero-exit message, but it must be
bounded to 500 characters before display or persistence.

Update `ControlledProcess.complete` to decode `output` into
`TranscriptionProcessResult.protocolLines`. When
`deliverLiveCallbacks == true`, it invokes the captured callback before
resuming; when false, it withholds callbacks so the test above proves final
result processing closes the MainActor race.

- [ ] **Step 7: Run focused process and AppModel tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TranscriptionProcessTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TranscriptionProtocolLineDecoderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelTranscriptionTests
```

Expected: all pass, including cancellation, stale-attempt, final-output drain,
private stdin, provider snapshot, and untrusted-path tests.

- [ ] **Step 8: Commit Task 4**

```bash
git add \
  Sources/RecorderApp/Transcription/TranscriptionProcess.swift \
  Sources/RecorderApp/Transcription/TranscriptionProtocolLineDecoder.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/TranscriptionProcessTests.swift \
  Tests/RecorderAppTests/TranscriptionProtocolLineDecoderTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift
git commit -m "Send provider snapshots through private stdin"
```

### Task 5: Provider-Neutral Long-Form Python Helper

**Files:**
- Rename: `scripts/qwen_asr_longform.py` to `scripts/openai_asr_longform.py`
- Rename: `Tests/ScriptTests/test_qwen_asr_longform.py` to
  `Tests/ScriptTests/test_openai_asr_longform.py`
- Rename: `scripts/transcribe-qwen-asr.sh` to
  `scripts/transcribe-openai-compatible.sh`
- Create: `scripts/transcribe-qwen-asr.sh`
- Rename: `Tests/ScriptTests/test_transcribe_qwen_asr_entrypoint.py` to
  `Tests/ScriptTests/test_transcribe_openai_compatible_entrypoint.py`
- Delete: `scripts/prepare-qwen-asr.sh`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: Task 4 stdin JSON payload
- Preserves: existing long-form planning and validation functions
- Produces: direct OpenAI-compatible multipart requests
- Produces: canonical artifacts

- [ ] **Step 1: Rename implementation and tests without behavior changes**

```bash
git mv scripts/qwen_asr_longform.py scripts/openai_asr_longform.py
git mv \
  Tests/ScriptTests/test_qwen_asr_longform.py \
  Tests/ScriptTests/test_openai_asr_longform.py
git mv \
  scripts/transcribe-qwen-asr.sh \
  scripts/transcribe-openai-compatible.sh
git mv \
  Tests/ScriptTests/test_transcribe_qwen_asr_entrypoint.py \
  Tests/ScriptTests/test_transcribe_openai_compatible_entrypoint.py
```

Update only import/module path names, then run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_openai_asr_longform -v
```

Expected: the existing long-form tests pass before transport changes.

- [ ] **Step 2: Write failing provider-neutral transport tests**

Replace curl argument assertions with a recording client:

```python
class RecordingTranscriptionClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def transcribe(
        self,
        *,
        audio,
        model,
        language,
        prompt,
    ):
        self.requests.append({
            "audio": audio,
            "model": model,
            "language": language,
            "prompt": prompt,
        })
        return self.responses.pop(0)


def test_transcription_does_not_require_models_endpoint(self):
    client = RecordingTranscriptionClient(
        [{"text": "valid transcript"}]
    )
    output = LongformTranscriber(
        self.make_config(),
        runner=self.runner(duration=10.0),
        client=client,
        emit=lambda _: None,
    ).run()
    self.assertTrue(output.is_file())
    self.assertEqual(len(client.requests), 1)


def test_standard_request_omits_empty_language_and_prompt(self):
    client = RecordingHTTPTransport(
        response_status=200,
        response_body=b'{"text":"ok"}',
    )
    OpenAICompatibleTranscriptionClient(
        base_url="https://example.test/v1",
        api_key=None,
        transport=client,
    ).transcribe(
        audio=self.chunk,
        model="custom-asr",
        language="",
        prompt="",
    )
    body = client.last_request.body
    self.assertIn(b'name="file"', body)
    self.assertIn(b'name="model"', body)
    self.assertIn(b'name="response_format"', body)
    self.assertNotIn(b'name="language"', body)
    self.assertNotIn(b'name="prompt"', body)
    self.assertNotIn(b"max_tokens", body)
    self.assertNotIn(b"Authorization", body)
```

Also cover optional Bearer header, 401, 404, timeout, malformed JSON, and
non-string `text`.

- [ ] **Step 3: Add stdin payload parsing**

```python
@dataclass(frozen=True)
class LaunchPayload:
    schema_version: int
    base_url: str
    asr_model: str
    language: str
    prompt: str
    api_key: Optional[str]


def read_launch_payload(stream) -> LaunchPayload:
    document = json.load(stream)
    if document.get("schemaVersion") != 1:
        raise TranscriptionError(
            "Unsupported provider payload version"
        )
    base_url = str(document.get("baseURL", "")).rstrip("/")
    model = str(document.get("asrModel", "")).strip()
    if not base_url or not model:
        raise TranscriptionError(
            "Provider base URL and ASR model are required"
        )
    return LaunchPayload(
        schema_version=1,
        base_url=base_url,
        asr_model=model,
        language=str(document.get("language", "")).strip(),
        prompt=str(document.get("prompt", "")).strip(),
        api_key=(
            str(document["apiKey"])
            if document.get("apiKey")
            else None
        ),
    )
```

Remove `--omlx-url`, environment API-key reads, model defaults, and provider
defaults from the CLI. Keep only audio path, output folder, publish mode, and
rolling-context character limit as non-secret arguments.

- [ ] **Step 4: Implement standard-library multipart transport**

```python
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional
from urllib import error, request
import json
import mimetypes
import uuid


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes


class URLTransport:
    def send(
        self,
        url: str,
        *,
        headers: Mapping[str, str],
        body: bytes,
        timeout: float,
    ) -> HTTPResult:
        http_request = request.Request(
            url,
            data=body,
            headers=dict(headers),
            method="POST",
        )
        try:
            with request.urlopen(
                http_request,
                timeout=timeout,
            ) as response:
                return HTTPResult(
                    status=response.status,
                    body=response.read(),
                )
        except error.HTTPError as http_error:
            return HTTPResult(
                status=http_error.code,
                body=http_error.read(2048),
            )


def encode_multipart(
    *,
    fields: Mapping[str, str],
    file_path: Path,
) -> tuple[str, bytes]:
    boundary = f"lmr-{uuid.uuid4().hex}"
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(
            (
                "Content-Disposition: form-data; "
                f'name="{name}"\r\n\r\n'
            ).encode()
        )
        body.extend(value.encode("utf-8"))
        body.extend(b"\r\n")
    content_type = (
        mimetypes.guess_type(file_path.name)[0]
        or "application/octet-stream"
    )
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(
        (
            "Content-Disposition: form-data; "
            f'name="file"; filename="{file_path.name}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode()
    )
    body.extend(file_path.read_bytes())
    body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode())
    return (
        f"multipart/form-data; boundary={boundary}",
        bytes(body),
    )


class OpenAICompatibleTranscriptionClient:
    def __init__(
        self,
        *,
        base_url: str,
        api_key: Optional[str],
        transport=None,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.transport = transport or URLTransport()

    def transcribe(
        self,
        *,
        audio: Path,
        model: str,
        language: str,
        prompt: str,
    ) -> dict:
        fields = {
            "model": model,
            "response_format": "json",
        }
        if language:
            fields["language"] = language
        if prompt:
            fields["prompt"] = prompt
        content_type, body = encode_multipart(
            fields=fields,
            file_path=audio,
        )
        headers = {
            "Accept": "application/json",
            "Content-Type": content_type,
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        result = self.transport.send(
            f"{self.base_url}/audio/transcriptions",
            headers=headers,
            body=body,
            timeout=7200,
        )
        if result.status != 200:
            raise TranscriptionError(
                f"Provider transcription failed with HTTP "
                f"{result.status}"
            )
        try:
            payload = json.loads(result.body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise TranscriptionError(
                "Provider returned malformed transcription JSON"
            ) from exc
        if not isinstance(payload, dict) or not isinstance(
            payload.get("text"), str
        ):
            raise TranscriptionError(
                "Provider response did not contain string text"
            )
        return payload
```

Do not include HTTP response bodies in user-facing errors. Persist each
successful raw JSON response in the existing private run directory for
diagnostics.

- [ ] **Step 5: Preserve long-form behavior while replacing its boundary**

Rename `TranscriptionConfig.omlx_url` to `base_url`, remove `curl` and
`api_key`, and inject `OpenAICompatibleTranscriptionClient` into
`LongformTranscriber`. Delete `_check_model()` and its startup call. Replace
the curl block in `_transcribe_interval()` with:

```python
payload = self.client.transcribe(
    audio=chunk_path,
    model=self.config.model,
    language=self.config.language,
    prompt=prompt,
)
response_path.write_text(
    json.dumps(payload, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
text = payload["text"]
```

Keep all existing validation, rolling-context retry, bisection, merge,
silence, and staging-manifest logic unchanged. Change status text from oMLX to
provider-neutral wording.

- [ ] **Step 6: Publish canonical artifacts atomically**

Replace model-specific publication with:

```python
def _publish(self, raw_candidate, final_candidate):
    names = {
        "raw": "transcript.raw.txt",
        "final": "transcript.txt",
        "manifest": "transcription.json",
    }
    if self.config.publish_mode == "candidate":
        outputs = {
            key: self.config.output_folder
            / value.replace(".", ".candidate.", 1)
            for key, value in names.items()
        }
    else:
        outputs = {
            key: self.config.output_folder / value
            for key, value in names.items()
        }
        for output in outputs.values():
            self._backup_existing(output)
    self._atomic_copy(raw_candidate, outputs["raw"])
    self._atomic_copy(final_candidate, outputs["final"])
    self._atomic_copy(self.manifest_path, outputs["manifest"])
    return outputs["final"]
```

The Python entry point owns `transcription.log`; before truncating a canonical
log, it backs up the prior file with the same UTC suffix convention.

Add one emitter and inject it into `LongformTranscriber`:

```python
from datetime import datetime, timezone
import shutil


def backup_existing(path: Path) -> None:
    if not path.exists():
        return
    stamp = datetime.now(timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    shutil.copy2(
        path,
        path.with_name(f"{path.name}.previous-{stamp}"),
    )


class StatusEmitter:
    def __init__(self, log_path: Path):
        self.log_path = log_path
        self.stream = log_path.open(
            "w",
            encoding="utf-8",
            buffering=1,
        )

    def emit(self, line: str) -> None:
        print(line, flush=True)
        self.stream.write(f"{line}\n")
        self.stream.flush()

    def close(self) -> None:
        self.stream.close()
```

After parsing non-secret CLI arguments, create the output folder, back up an
existing log, create `StatusEmitter`, and emit
`LOG_PATH=<absolute canonical path>` before reading stdin. Replace every
provider-status `print` in the helper with `emitter.emit`. On a known
`TranscriptionError`, emit only its already-redacted message. On any other
exception, emit only `ERROR=Unexpected <ExceptionClass>`; never append an
exception `repr`, HTTP response body, launch payload, or request headers.

- [ ] **Step 7: Make the generic shell entry point and compatibility wrapper**

`scripts/transcribe-openai-compatible.sh` becomes:

```bash
#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

if [[ $# -lt 2 ]]; then
  echo "Usage: transcribe-openai-compatible.sh <audio-file> <output-folder>" >&2
  exit 64
fi

AUDIO_FILE="$1"
OUTPUT_FOLDER="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-/usr/bin/python3}"
HELPER="${LONGFORM_HELPER:-${SCRIPT_DIR}/openai_asr_longform.py}"
PUBLISH_MODE="${TRANSCRIPTION_PUBLISH_MODE:-replace}"
LOG_OUTPUT="${OUTPUT_FOLDER}/transcription.log"

if [[ ! -f "$AUDIO_FILE" ]]; then
  echo "Missing audio file: $AUDIO_FILE" >&2
  exit 66
fi
if [[ ! -x "$PYTHON" ]]; then
  echo "Missing Python runtime: $PYTHON" >&2
  exit 69
fi
if [[ ! -f "$HELPER" ]]; then
  echo "Missing long-form transcription helper: $HELPER" >&2
  exit 69
fi

mkdir -p "$OUTPUT_FOLDER"
exec "$PYTHON" "$HELPER" \
  --audio "$AUDIO_FILE" \
  --output-folder "$OUTPUT_FOLDER" \
  --publish-mode "$PUBLISH_MODE" \
  --log "$LOG_OUTPUT"
```

There is no shell pipeline. `exec` makes Python the process receiving
termination, and its exit status is the transcription process exit status.

The one-release wrapper contains no defaults:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/transcribe-openai-compatible.sh" "$@"
```

Delete `prepare-qwen-asr.sh`.

- [ ] **Step 8: Update entrypoint tests and bundle copies**

The real entrypoint test passes JSON through `subprocess.run(input=...)`:

```python
result = subprocess.run(
    [
        "/bin/bash",
        str(ENTRYPOINT),
        str(self.audio),
        str(self.output_dir),
    ],
    input=json.dumps({
        "schemaVersion": 1,
        "baseURL": "http://127.0.0.1:1/v1",
        "asrModel": "test-model",
        "language": "yue",
        "prompt": "meeting context",
        "apiKey": "secret-test-key",
    }),
    text=True,
    capture_output=True,
    env=environment,
    check=False,
)
self.assertNotIn(
    "secret-test-key",
    result.stdout + result.stderr,
)
```

Update `scripts/build-app.sh` to copy and chmod:

```text
transcribe-openai-compatible.sh
transcribe-qwen-asr.sh
openai_asr_longform.py
```

Remove copies of `prepare-qwen-asr.sh`, `qwen_asr_longform.py`, and
provider-specific defaults.

- [ ] **Step 9: Run all Python tests and commit Task 5**

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_openai_asr_longform -v
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_transcribe_openai_compatible_entrypoint -v
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
git add -A \
  scripts \
  Tests/ScriptTests \
  scripts/build-app.sh
git commit -m "Generalize long-form ASR provider"
```

Expected: all existing long-form cases plus no-auth, bearer, standard
multipart, typed HTTP failure, malformed response, stdin, and canonical output
cases pass.

### Task 6: Canonical Transcript and Legacy Recording Compatibility

**Files:**
- Modify: `Sources/RecorderApp/RecordingLibrary.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Modify: `Tests/RecorderAppTests/RecordingLibraryTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`

**Interfaces:**
- Produces: `TranscriptDocumentStore.resolvedURL(in:)`
- Produces: `TranscriptDocumentStore.logURL(in:)`
- Preserves: known Qwen 8-bit transcript and log fallback

- [ ] **Step 1: Write failing canonical and legacy resolution tests**

```swift
func testCanonicalTranscriptWinsOverLegacyFile() throws {
    try "canonical".write(
        to: folder.appendingPathComponent("transcript.txt"),
        atomically: true,
        encoding: .utf8
    )
    try "legacy".write(
        to: folder.appendingPathComponent(
            "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
        ),
        atomically: true,
        encoding: .utf8
    )

    XCTAssertEqual(
        try TranscriptDocumentStore.read(in: folder),
        "canonical"
    )
}

func testLegacyProviderSpecificTranscriptRemainsReadable() throws {
    let legacy = folder.appendingPathComponent(
        "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
    )
    try "legacy".write(
        to: legacy,
        atomically: true,
        encoding: .utf8
    )
    XCTAssertEqual(
        TranscriptDocumentStore.resolvedURL(in: folder),
        legacy
    )
}

func testCanonicalLogWinsAndLegacyLogFallsBack() throws {
    let legacy = folder.appendingPathComponent(
        "transcription_qwen_asr.log"
    )
    try Data().write(to: legacy)
    XCTAssertEqual(
        TranscriptDocumentStore.logURL(in: folder),
        legacy
    )
    let canonical = folder.appendingPathComponent(
        "transcription.log"
    )
    try Data().write(to: canonical)
    XCTAssertEqual(
        TranscriptDocumentStore.logURL(in: folder),
        canonical
    )
}
```

- [ ] **Step 2: Implement deterministic canonical and fallback lookup**

```swift
enum TranscriptDocumentStore {
    static let editableFileName = "transcript.txt"
    static let rawFileName = "transcript.raw.txt"
    static let manifestFileName = "transcription.json"
    static let logFileName = "transcription.log"
    static let legacyTranscriptFileNames = [
        "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
    ]
    static let legacyLogFileNames = [
        "transcription_qwen_asr.log"
    ]

    static func resolvedURL(in folder: URL) -> URL? {
        firstExisting(
            [editableFileName] + legacyTranscriptFileNames,
            in: folder
        )
    }

    static func logURL(in folder: URL) -> URL? {
        firstExisting(
            [logFileName] + legacyLogFileNames,
            in: folder
        )
    }

    static func read(in folder: URL) throws -> String {
        guard let url = resolvedURL(in: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func save(_ text: String, in folder: URL) throws {
        try text.write(
            to: editableURL(in: folder),
            atomically: true,
            encoding: .utf8
        )
    }

    static func editableURL(in folder: URL) -> URL {
        folder.appendingPathComponent(editableFileName)
    }

    private static func firstExisting(
        _ names: [String],
        in folder: URL
    ) -> URL? {
        names.lazy
            .map(folder.appendingPathComponent)
            .first {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: $0.path,
                    isDirectory: &isDirectory
                ) && !isDirectory.boolValue
            }
    }
}
```

- [ ] **Step 3: Route all App/UI checks through the store**

Replace direct `qwenURL` and `transcription_qwen_asr.log` checks in
`AppModel.openTranscript`, `AppModel.openTranscriptLog`,
`SessionListView.hasTranscript`, and `SessionListView.hasTranscriptLog` with
`resolvedURL(in:)` and `logURL(in:)`.

Generic help copy:

```swift
.help(
    providerConfigured
        ? "Transcribe with the configured AI provider"
        : "Configure an AI provider first"
)
```

No visible production string may claim that oMLX or Qwen is required.

- [ ] **Step 4: Run focused Swift and Python regression suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingLibraryTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelTranscriptionTests
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
```

Expected: zero failures.

- [ ] **Step 5: Scan active code for provider hard-coding**

```bash
rg -n \
  'open -a "oMLX"|OMLX_API_KEY|OMLX_URL|OMLX_ASR_MODEL|max_tokens=|Checking oMLX|Transcribe with oMLX|prepare-qwen' \
  Sources scripts
```

Expected: no matches in production source or scripts. Legacy migration fixture
text may remain in tests.

- [ ] **Step 6: Commit Task 6**

```bash
git add \
  Sources/RecorderApp/RecordingLibrary.swift \
  Sources/RecorderApp/AppModel.swift \
  Sources/RecorderApp/ContentView.swift \
  Tests/RecorderAppTests/RecordingLibraryTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift
git commit -m "Adopt canonical transcript artifacts"
```

### Task 7: Provider Vertical-Slice Verification

**Files:**
- Verify only; no installed-app replacement.

**Interfaces:**
- Verifies: generic local no-auth and bearer-compatible configuration
- Verifies: long-form behavior and legacy recording access

- [ ] **Step 1: Run all focused Swift provider suites**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter OpenAICompatibleProvider
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AIProviderSettingsModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TranscriptionProcessTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter TranscriptionProtocolLineDecoderTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter AppModelTranscriptionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingLibraryTests
```

Expected: zero failures.

- [ ] **Step 2: Run all Python script tests**

```bash
/usr/bin/python3 -m unittest discover \
  -s Tests/ScriptTests -p 'test_*.py' -v
```

Expected: zero failures and no API key in captured output.

- [ ] **Step 3: Run the complete Swift suite twice**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected on both runs: all tests pass with only the existing intentional skip.
The approved baseline before implementation was 636 tests, 1 skipped, and 0
failures on the clean branch.

- [ ] **Step 4: Build the staging bundle without installing it**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/build-app.sh
```

Expected: build succeeds and returns the staging `.app` path. Do not run
`install-app.sh`.

- [ ] **Step 5: Inspect bundle resources and secret policy**

```bash
test -x \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/transcribe-openai-compatible.sh"
test -x \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/openai_asr_longform.py"
test ! -e \
  "build/Local Meeting Recorder Staging.app/Contents/Resources/prepare-qwen-asr.sh"
rg -n \
  '/Users/apple|OMLX_API_KEY|open -a "oMLX"|max_tokens=' \
  "build/Local Meeting Recorder Staging.app/Contents/Resources"
```

Expected: helper checks pass and the final `rg` has no matches.

- [ ] **Step 6: Review final diff**

```bash
git diff --check c201cc1..HEAD
git status --short
git log --oneline c201cc1..HEAD
```

Expected: no whitespace errors, a clean worktree, and only the planned
provider/credential commits.
