# Meeting Intelligence Summary and Contextual Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add availability-gated automatic and explicit manual OpenAI-compatible meeting summaries and contextual titles while preserving ASR success, manual titles, bounded resources, and staging-only delivery.

**Architecture:** A single `MeetingIntelligenceJobCoordinator` owns every meeting-intelligence task, generation, attempt, and presentation. It consumes immutable, ownership-checked transcript-publication events, uses a secure transcript reader, an exact-model availability checker, a bounded `/chat/completions` pipeline, and a serialized session-mutation publisher. The existing `AppModel` constructs exactly one coordinator temporarily, forwards typed commands, and passes its read-only presentation source to SwiftUI without mirroring lifecycle state.

**Tech Stack:** Swift 5.9 package on macOS 26.0, Swift Concurrency, Combine/SwiftUI/AppKit, Foundation `URLSession`, CryptoKit SHA-256, Darwin file APIs, XCTest, JSON Schema fixtures, Python `unittest`, GitHub Actions `macos-26`.

**Plan checkpoint:** Commit this document as a path-limited docs-only commit
before Task 1. No production or test implementation may start from an
uncommitted plan.

## Global Constraints

- Work only in `/Users/apple/Documents/recorder/.worktrees/meeting-intelligence-summary-title` on `codex/meeting-intelligence-summary-title`.
- Design authority is `docs/superpowers/specs/2026-07-31-meeting-intelligence-summary-title-design.md` at commit `0ce451e678ed324a966ffe0ca30ba55733963426`.
- Minimum supported platform remains macOS 26.0; do not add pre-macOS-26 fallbacks.
- Keep `asrModel` and `llmModel` independent; every ASR upload uses only `asrModel`, and every chat request uses only `llmModel`.
- Provider Settings exposes exactly three meeting-language choices:
  Cantonese (`yue`), English (`en`), and Mandarin (`zh`). Saving a choice
  affects only future immutable ASR snapshots; an active transcription keeps
  its captured language.
- Automatic chat requires an exact `llmModel` match from a fresh `/models` response. Unsupported, unknown, failed, stale, or absent availability sends zero automatic chat requests.
- Manual Generate, Regenerate, and Retry Generation may bypass discovery because they are explicit user authorization. `legacy-unconfigured-llm` is never sent.
- LLM or title failure must never change a completed transcription to failed.
- One coordinator owns all meeting-intelligence tasks, generations, attempts, cancellation flags, and state dictionaries. `AppModel` must not mirror them.
- A manual title or manual clear is never overwritten automatically. Tag/Favorite-only saves preserve title origin.
- Canonical transcript revision means SHA-256 of exact `transcript.txt` bytes; no mtime/UUID revision source is permitted.
- Secure source reads must use exact-root/no-follow regular-file validation and pre/post device, inode, size, and link-count checks.
- Source read is capped at 4 MiB plus one overflow byte; chunk content at 64 KiB; JSON body at 96 KiB; HTTP response at 256 KiB; partial summary at 4 KiB; final summary at 48 KiB; title at 120 grapheme clusters; source chunks at 64; reduction fan-in at 12; depth at 4; total LLM requests at 71; request timeout at 90 seconds; job deadline at 30 minutes.
- Every LLM pipeline request has exactly one network attempt. Retry-After is a user-facing hint only; no automatic LLM resend is allowed.
- Redirects may follow only same-origin 307/308 with identical POST method, body, and normalized content type. Model-discovery GET rejects all redirects. Authorization is restored only after every validation passes.
- Do not persist or log credentials, Authorization, transcript content, prompts, provider bodies, full provider URLs, or full local paths.
- Do not add action items, `/responses`, timestamped transcripts, summary search, Windows changes, PR B/PR C refactors, or unrelated cleanup.
- Keep the non-staging application untouched. Rebuild only `/Applications/Local Meeting Recorder Staging.app` after the Draft PR and CI gates.
- Each implementation slice must show an observed RED, focused GREEN, `git diff --check`, and a rollback-safe commit.

---

## File and Responsibility Map

### Create

| File | Responsibility |
|---|---|
| `Sources/RecorderApp/Library/RecordingSessionMutationGate.swift` | One shared serialized mutation boundary for ASR publication, transcript/metadata edits, and meeting-intelligence publication. |
| `Sources/RecorderApp/Transcription/TranscriptPublication.swift` | Secure transcript snapshot/revision and immutable `TranscriptPublished` ownership event. |
| `Sources/RecorderApp/Transcription/ProviderRedirectPolicy.swift` | Shared multipart/JSON same-origin 307/308 policy; GET redirects rejected. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceModels.swift` | Intent, availability, generated content, artifact, state, presentation, typed errors. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceAvailability.swift` | Exact-model automatic eligibility using the existing bounded provider client. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceStores.swift` | Safe bounded success/state artifact loading, staging, atomic replacement, and compatibility projection. |
| `Sources/RecorderApp/MeetingIntelligence/OpenAICompatibleMeetingIntelligenceClient.swift` | Bounded `/chat/completions` JSON adapter, response validation, sanitation, and Retry-After hint parsing. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePipeline.swift` | UTF-8-safe chunking, partial summaries, bounded recursive reduction, deadline/progress/cancellation. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublisher.swift` | Publication-time digest/title compare, success artifact promotion, generated-title save, semantic outcome. |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceJobCoordinator.swift` | Single owner of automatic/manual lifecycle, immutable snapshots, stale gates, cancellation, reload projection. |
| `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift` | Transcript-sheet summary/title/status/actions and stable accessibility identifiers. |
| `Tests/RecorderAppTests/SecureTranscriptDocumentReaderTests.swift` | no-follow/bounds/digest/identity security tests. |
| `Tests/RecorderAppTests/MeetingIntelligenceStoreTests.swift` | artifact/state schema, unsafe file, forward-version, atomic replacement tests. |
| `Tests/RecorderAppTests/MeetingIntelligenceAvailabilityTests.swift` | exact-model, placeholder, discovery failure, and zero-chat eligibility tests. |
| `Tests/RecorderAppTests/OpenAICompatibleMeetingIntelligenceClientTests.swift` | request/response/cap/sanitizer/attempt-budget tests. |
| `Tests/RecorderAppTests/MeetingIntelligencePipelineTests.swift` | one-chunk, multi-pass, UTF-8 boundaries, global limits, cancellation/deadline tests. |
| `Tests/RecorderAppTests/MeetingIntelligencePublisherTests.swift` | Publication-time digest, lease, title ownership, and semantic-outcome barriers. |
| `Tests/RecorderAppTests/MeetingIntelligenceJobCoordinatorTests.swift` | automatic/manual lifecycle, immutable snapshots, stale events, cancellation, and session isolation. |
| `Tests/RecorderAppTests/AppModelMeetingIntelligenceTests.swift` | end-to-end AppModel callback/edit/trash/library/title integration. |
| `Tests/RecorderAppTests/MeetingIntelligencePresentationTests.swift` | Pure phase-to-actions presentation mapping. |
| `Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift` | actual transcript/intelligence sheet at 860×680 and wide phase layouts. |
| `contracts/fixtures/recording-info-v2-meeting-intelligence.json` | Recording metadata v2/title-origin fixture. |
| `contracts/meeting-intelligence.schema.json` | Successful result artifact schema. |
| `contracts/fixtures/meeting-intelligence-v1.json` | Successful result v1 fixture. |
| `Tests/ManualFixtures/meeting_intelligence_provider.py` | Development-only sanitized request-count/model-role acceptance server; never bundled. |
| `Tests/ScriptTests/test_meeting_intelligence_provider_fixture.py` | Synthetic provider endpoint, fault-mode, and privacy telemetry tests. |
| `docs/testing/2026-07-31-meeting-intelligence-uat.md` | Real/synthetic provider and staging manual acceptance record. |

### Modify

| File | Change |
|---|---|
| `Sources/RecorderApp/RecordingSession.swift` | Add checked `Sendable` conformance for the immutable session value carried by publication events. |
| `Sources/RecorderApp/RecordingLibrary.swift` | Add checked `Sendable` metadata conformance, metadata schema v2, `RecordingTitleOrigin`, typed title edit intent, upgrade-on-save. |
| `Sources/RecorderApp/Transcription/TranscriptionArtifactPublisher.swift` | Publish inside the injected shared mutation gate. |
| `Sources/RecorderApp/Transcription/TranscriptionService.swift` | Inject the mutation gate into native artifact publication. |
| `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift` | Emit immutable, digest-bearing `TranscriptPublished` after active ownership validation. |
| `Sources/RecorderApp/Transcription/OpenAICompatibleTranscriptionClient.swift` | Remove the in-file redirect policy and consume the shared policy without weakening multipart behavior. |
| `Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift` | Preserve capped `/models`; expose no new persistence and reject redirected GET. |
| `Sources/RecorderApp/AppModel.swift` | Construct one shared mutation gate/coordinator, route semantic events and typed commands, no mirrored lifecycle state. |
| `Sources/RecorderApp/UI/RecordingsLibraryView.swift` | Compose the coordinator-backed section into the existing transcript sheet and typed metadata edit. |
| `Sources/RecorderApp/Views/AIProviderSettingsView.swift` | Clarifying ASR/LLM copy and stable identifiers. |
| `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift` | Typed Cantonese/English/Mandarin UI selection and future-job persistence. |
| `Sources/RecorderApp/UI/RecorderActionID.swift` | Meeting-intelligence and provider interaction IDs. |
| `Sources/RecorderApp/Library/RecordingLibraryQuery.swift` | No summary indexing; only ensure refreshed generated title remains in metadata search. |
| `Tests/RecorderAppTests/RecordingLibraryTests.swift` | Metadata v1/v2 migration, manual/generated ownership, unknown-field tests. |
| `Tests/RecorderAppTests/TranscriptionArtifactPublisherTests.swift` | Shared mutation gate and ASR atomic-publication regressions. |
| `Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift` | Event identity/digest/late-attempt tests. |
| `Tests/RecorderAppTests/AppModelTranscriptionTests.swift` | Typed publication callback and existing search rebuild compatibility. |
| `Tests/RecorderAppTests/OpenAICompatibleProviderClientTests.swift` | Actual delegate-path JSON/multipart redirect and GET rejection regressions. |
| `Tests/RecorderAppTests/OpenAICompatibleTranscriptionClientTests.swift` | Preserve all current ASR redirect/auth/retry/cancellation behavior. |
| `Tests/RecorderAppTests/AIProviderSettingsModelTests.swift` | Same/different model selection plus typed language save/reload behavior. |
| `Tests/RecorderAppTests/RecorderActionIDTests.swift` | Exact unique interaction ID set. |
| `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift` | Same-session generated-title projection and AVPlayer isolation regression. |
| `contracts/recording-session.schema.json` | Accept compatible recording metadata v1 and v2. |
| `Tests/ScriptTests/test_recording_contract.py` | Validate v1/v2 and meeting-intelligence fixtures. |
| `Tests/ScriptTests/test_packaging_contract.py` | Assert the manual Python harness and raw fixtures are not bundled. |
| `README.md` | Explain separate models, availability gate, manual generation, artifacts, title protection. |

---

## Design and Goal Coverage Audit

| Approved design / clarified goal | Implemented and proven by |
|---|---|
| Exact-model automatic availability and explicit manual bypass | Task 3 availability tests; Task 6 coordinator request-count tests |
| One owner, immutable snapshots, cancellation, stale callbacks | Tasks 1 and 6 event, lease, coordinator, and AppModel integration tests |
| Secure canonical transcript input and SHA-256 revision | Task 1 no-follow, hard-link, size, identity, and committed-revision tests |
| Bounded `/chat/completions`, privacy, redirect, one-attempt budget | Task 4 client, sanitizer, Retry-After, transport, and delegate-path tests |
| Complete bounded long-transcript handling | Task 5 UTF-8, fan-in, depth, request-count, deadline, and cancellation tests |
| Recoverable persistence and metadata/title provenance | Tasks 2 and 6 schema, safe-store, publication-barrier, and title-race tests |
| Automatic/manual title behavior and transcript-edit staleness | Tasks 2, 6, and 7 metadata intent, coordinator, and UI action tests |
| Transcript-sheet UI, 860×680 layout, and AVPlayer isolation | Task 7 pure presentation and actual AppKit-hosted render tests |
| Same or different ASR/LLM model selection | Tasks 3 and 7 availability, settings-model, and snapshot tests |
| Cantonese, English, and Mandarin ASR selection | Task 7 typed settings/picker tests and Task 8 documentation/manual UAT |
| Contracts, bundle exclusion, complete gates, and manual acceptance | Task 8 schemas, script tests, packaging, CI, Draft PR, and staging-only rebuild |
| Non-goals and Windows isolation | Global path/scope constraints, final diff audit, and independent review |

Every row above has both a production slice and explicit automated or manual
evidence. No design section depends on an intentionally failing committed
test, a second workspace source of truth, or an AppModel lifecycle mirror.

---

### Task 1: Secure Transcript Revision and Ownership-Checked Publication Event

**Files:**
- Create: `Sources/RecorderApp/Library/RecordingSessionMutationGate.swift`
- Create: `Sources/RecorderApp/Transcription/TranscriptPublication.swift`
- Create: `Tests/RecorderAppTests/SecureTranscriptDocumentReaderTests.swift`
- Modify: `Sources/RecorderApp/RecordingSession.swift:5-54`
- Modify: `Sources/RecorderApp/RecordingLibrary.swift:58-211`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionArtifactPublisher.swift:50-225`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionService.swift:121-239`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionProcess.swift:122-223`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift:5-380`
- Modify: `Sources/RecorderApp/AppModel.swift:306-418`
- Modify: `Tests/RecorderAppTests/TranscriptionArtifactPublisherTests.swift`
- Modify: `Tests/RecorderAppTests/TranscriptionProcessTests.swift`
- Modify: `Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`

**Interfaces:**
- Produces:

```swift
struct TranscriptDocumentRevision: Equatable, Sendable {
    let sha256: String
    let byteCount: Int
}

struct TranscriptDocumentSnapshot: Equatable, Sendable {
    let url: URL
    let data: Data
    let revision: TranscriptDocumentRevision
}

struct TranscriptPublicationIdentity: Equatable, Sendable {
    let coordinatorInstanceID: UUID
    let generation: UInt64
    let attemptID: UUID
}

struct TranscriptPublished: Sendable {
    let session: RecordingSession
    let canonicalURL: URL
    let revision: TranscriptDocumentRevision
    let normalizedSessionFolder: URL
    let identity: TranscriptPublicationIdentity
}

struct TranscriptionServiceResult: Equatable, Sendable {
    let transcriptURL: URL
    let rawTranscriptURL: URL?
    let manifestURL: URL?
    let logURL: URL?
    let committedTranscriptRevision: TranscriptDocumentRevision
}

protocol TranscriptDocumentReading: Sendable {
    func readCanonical(
        in sessionFolder: URL,
        allowLegacy: Bool
    ) throws -> TranscriptDocumentSnapshot
}

final class RecordingSessionMutationGate: @unchecked Sendable {
    func withMutation<T>(
        for sessionFolder: URL,
        _ operation: () throws -> T
    ) rethrows -> T
}
```

- Changes `TranscriptionJobCoordinator.onSuccessfulPublication` from
  `((RecordingSession) -> Void)?` to `((TranscriptPublished) -> Void)?`.
- Later tasks consume `TranscriptPublished`, `TranscriptDocumentReading`, and
  the exact shared `RecordingSessionMutationGate` instance.

- [ ] **Step 1: Write secure-reader RED tests**

Add tests that create an exact `transcript.txt`, a symlink, a directory, an
additional hard link, a 4 MiB + 1 byte file, and a controlled identity-changing
reader. The core expectations are:

```swift
func testReadsExactCanonicalFileAndProducesStableSHA256() throws {
    let fixture = try TranscriptReaderFixture()
    let bytes = Data("會議內容".utf8)
    try bytes.write(to: fixture.transcriptURL)

    let snapshot = try SecureTranscriptDocumentReader().readCanonical(
        in: fixture.folder,
        allowLegacy: false
    )
    let expectedDigest = SHA256.hash(data: bytes)
        .map { String(format: "%02x", $0) }
        .joined()

    XCTAssertEqual(snapshot.data, bytes)
    XCTAssertEqual(snapshot.revision.byteCount, bytes.count)
    XCTAssertEqual(
        snapshot.revision.sha256,
        "sha256:\(expectedDigest)"
    )
}

func testRejectsCanonicalSymlinkWithoutReadingOutsideBytes() throws {
    let fixture = try TranscriptReaderFixture()
    let outside = fixture.root.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: fixture.transcriptURL,
        withDestinationURL: outside
    )

    XCTAssertThrowsError(
        try SecureTranscriptDocumentReader().readCanonical(
            in: fixture.folder,
            allowLegacy: false
        )
    ) {
        XCTAssertEqual($0 as? SecureTranscriptReadError, .unsafeFile)
    }
}
```

Import `CryptoKit` in the test target and compute the expected digest from the
exact fixture bytes, as shown above.

In the same RED slice, extend `TranscriptionArtifactPublisherTests` and
`TranscriptionProcessTests` to require the native and legacy service paths to
return a `committedTranscriptRevision` matching the exact canonical bytes.

- [ ] **Step 2: Run the secure-reader tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter SecureTranscriptDocumentReaderTests
```

Expected: compilation fails because `SecureTranscriptDocumentReader`,
`TranscriptDocumentSnapshot`, `SecureTranscriptReadError`, and the committed
revision result field do not exist.

- [ ] **Step 3: Add the secure reader and shared mutation gate**

Implement `SecureTranscriptDocumentReader` with:

```swift
enum SecureTranscriptReadError: LocalizedError, Equatable, Sendable {
    case missing
    case empty
    case tooLarge
    case invalidUTF8
    case unsafeFile
    case identityChanged
}

struct SecureTranscriptDocumentReader: TranscriptDocumentReading {
    static let maximumBytes = 4 * 1_024 * 1_024

    func readCanonical(
        in sessionFolder: URL,
        allowLegacy: Bool
    ) throws -> TranscriptDocumentSnapshot
}
```

The method must:

1. require `sessionFolder.standardizedFileURL ==
   sessionFolder.resolvingSymlinksInPath().standardizedFileURL`;
2. open the folder and exact whitelisted filename with `O_NOFOLLOW`;
3. require `S_IFREG` and `st_nlink == 1`;
4. save pre-read `st_dev`, `st_ino`, `st_size`, and `st_nlink`;
5. read at most `maximumBytes + 1`;
6. repeat `fstat` and reject any identity/size/link change;
7. reject empty, overflow, and invalid UTF-8;
8. return lowercase `sha256:<hex>`.

Implement `RecordingSessionMutationGate` with one private `NSRecursiveLock`.
The lock covers only session-document read/write transactions, never network
waits.

Add checked `Sendable` conformance to the immutable `RecordingSession` and
`RecordingSessionMetadata` values. Their stored values already conform to
`Sendable`; do not use `@unchecked Sendable` for either value type.

Extend `PublishedTranscriptionArtifacts` and `TranscriptionServiceResult` with
the required `committedTranscriptRevision`. The native publisher computes it
from the exact canonical bytes while holding the mutation gate. The legacy
process adapter securely reads and hashes its validated canonical file before
returning. A service result without a committed revision is not representable.

- [ ] **Step 4: Run secure-reader/mutation focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'SecureTranscriptDocumentReaderTests|TranscriptionArtifactPublisherTests|TranscriptionProcessTests'
git diff --check
```

Expected: the secure reader, shared mutation gate, native committed revision,
and legacy committed revision tests pass before publication-event tests are
added.

- [ ] **Step 5: Add immutable publication-event RED tests**

Extend `TranscriptionJobCoordinatorTests` so a completed active attempt emits:

```swift
var events: [TranscriptPublished] = []
coordinator.onSuccessfulPublication = { events.append($0) }

coordinator.start(session: fixture.session)
await fixture.service.completeSuccessfully()

XCTAssertEqual(events.count, 1)
XCTAssertEqual(events[0].session.id, fixture.session.id)
XCTAssertEqual(events[0].revision, expectedRevision)
XCTAssertEqual(events[0].identity.generation, 1)
```

Add a replacement-attempt barrier test whose old completion arrives after the
new attempt. Assert only the new `attemptID` is emitted. Add a
committed-revision mismatch test that emits zero event.

- [ ] **Step 6: Run event tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'TranscriptionJobCoordinatorTests|TranscriptionArtifactPublisherTests|TranscriptionProcessTests|AppModelTranscriptionTests'
```

Expected: compilation fails at the old callback type and missing event fields.

- [ ] **Step 7: Emit the event inside the existing ASR ownership gate**

Add injected defaults to `TranscriptionJobCoordinator.init`:

```swift
init(
    providerRepository: any OpenAICompatibleProviderManaging,
    audioPreparer: any TranscriptionAudioPreparing,
    service: any TranscriptionServicing,
    mutationGate: RecordingSessionMutationGate,
    transcriptReader: any TranscriptDocumentReading =
        SecureTranscriptDocumentReader(),
    coordinatorInstanceID: UUID = UUID()
)
```

After the existing `isActive(generation:attempt:)` and artifact-path checks,
enter the mutation gate, securely reread the canonical transcript, and require
its revision to equal `result.committedTranscriptRevision`. Build
`TranscriptPublished` from that committed revision and emit it before
`finishSuccess`. Do not emit on cancellation, stale ownership, unsafe file, or
revision mismatch.

Construct one gate in `AppModel`, inject that exact instance into
`TranscriptionJobCoordinator`, `TranscriptionArtifactPublisher`, and the default
`NativeOpenAICompatibleTranscriptionService`, wrapping only the existing atomic
publication block. Update AppModel's callback temporarily to use
`event.session` for the existing search-document rebuild.

- [ ] **Step 8: Run focused GREEN and regressions**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'SecureTranscriptDocumentReaderTests|TranscriptionJobCoordinatorTests|TranscriptionArtifactPublisherTests|TranscriptionProcessTests|AppModelTranscriptionTests|OpenAICompatibleTranscriptionClientTests'
git diff --check
```

Expected: all selected tests pass; current ASR redirect, cancellation, secret
redaction, publication, and search-refresh tests remain green.

- [ ] **Step 9: Commit Task 1**

```bash
git add \
  Sources/RecorderApp/Library/RecordingSessionMutationGate.swift \
  Sources/RecorderApp/RecordingLibrary.swift \
  Sources/RecorderApp/RecordingSession.swift \
  Sources/RecorderApp/Transcription/TranscriptPublication.swift \
  Sources/RecorderApp/Transcription/TranscriptionArtifactPublisher.swift \
  Sources/RecorderApp/Transcription/TranscriptionProcess.swift \
  Sources/RecorderApp/Transcription/TranscriptionService.swift \
  Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/SecureTranscriptDocumentReaderTests.swift \
  Tests/RecorderAppTests/TranscriptionArtifactPublisherTests.swift \
  Tests/RecorderAppTests/TranscriptionProcessTests.swift \
  Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift
git commit -m "feat: publish secure transcript revisions"
```

---

### Task 2: Metadata v2, Title Ownership, and Safe Result/State Stores

**Files:**
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceModels.swift`
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceStores.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligenceStoreTests.swift`
- Modify: `Sources/RecorderApp/RecordingLibrary.swift:58-321`
- Modify: `Tests/RecorderAppTests/RecordingLibraryTests.swift`

**Interfaces:**
- Produces:

```swift
enum RecordingTitleOrigin: String, Codable, Equatable, Hashable, Sendable {
    case unset
    case meetingIntelligence
    case manual
}

enum RecordingTitleEdit: Equatable, Sendable {
    case unchanged
    case manual(String?)
    case applyMeetingIntelligence(String)
}

struct MeetingIntelligenceArtifact: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let summary: String
    let suggestedTitle: String
    let sourceTranscriptSHA256: String
    let sourceTranscriptByteCount: Int
    let model: String
    let generatedAt: Date
    let intent: MeetingIntelligenceIntent
}

enum MeetingIntelligenceIntent: String, Codable, Equatable, Sendable {
    case automatic
    case generate
    case regenerate
    case retryGeneration
}

enum MeetingIntelligenceStatePhase: String, Codable, Equatable, Sendable {
    case checkingAvailability
    case generating
    case completed
    case failed
    case cancelled
    case interrupted
}

struct MeetingIntelligenceState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let phase: MeetingIntelligenceStatePhase
    let message: String
    let sourceTranscriptSHA256: String?
    let startedAt: Date
    let finishedAt: Date?
}

protocol MeetingIntelligenceArtifactStoring: Sendable {
    func load(in folder: URL) throws -> MeetingIntelligenceArtifact?
    func stage(
        _ artifact: MeetingIntelligenceArtifact,
        in folder: URL
    ) throws -> URL
    func promoteStaged(_ stagedURL: URL, in folder: URL) throws
}

protocol MeetingIntelligenceStateStoring: Sendable {
    func load(in folder: URL) throws -> MeetingIntelligenceState?
    func save(_ state: MeetingIntelligenceState, in folder: URL) throws
    func remove(in folder: URL) throws
}
```

- Adds `titleOrigin` to `RecordingSessionMetadata`.
- Later tasks consume the artifact/state stores and title edit semantics.

- [ ] **Step 1: Write metadata migration and ownership RED tests**

Add:

```swift
func testLegacyTitleDecodesAsManualAndMissingTitleAsUnset() throws {
    let withTitle = Data(#"{"title":"Customer migration"}"#.utf8)
    let withoutTitle = Data(#"{}"#.utf8)

    XCTAssertEqual(
        try JSONDecoder().decode(
            RecordingSessionMetadata.self,
            from: withTitle
        ).titleOrigin,
        .manual
    )
    XCTAssertEqual(
        try JSONDecoder().decode(
            RecordingSessionMetadata.self,
            from: withoutTitle
        ).titleOrigin,
        .unset
    )
}

func testTagOnlyEditPreservesGeneratedOriginAndManualClearIsProtected() throws {
    var metadata = RecordingSessionMetadata(
        title: "Generated context",
        titleOrigin: .meetingIntelligence
    )
    metadata.applyTitleEdit(.unchanged)
    XCTAssertEqual(metadata.titleOrigin, .meetingIntelligence)

    metadata.applyTitleEdit(.manual(nil))
    XCTAssertNil(metadata.title)
    XCTAssertEqual(metadata.titleOrigin, .manual)
}
```

Extend the existing nested unknown-field test to save metadata after a title
edit and compare every unknown array/object value.

- [ ] **Step 2: Run metadata tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingLibraryTests
```

Expected: compilation fails because `RecordingTitleOrigin`,
`RecordingTitleEdit`, `titleOrigin`, and `applyTitleEdit` do not exist.

- [ ] **Step 3: Add conservative v2 metadata behavior**

Add `titleOrigin` to `RecordingSessionMetadata.init`, `CodingKeys`, decoder, and
encoder. Decode a missing origin as `.manual` when normalized title is non-nil,
otherwise `.unset`.

Add:

```swift
mutating func applyTitleEdit(_ edit: RecordingTitleEdit) {
    switch edit {
    case .unchanged:
        break
    case .manual(let value):
        title = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
        titleOrigin = .manual
    case .applyMeetingIntelligence(let value):
        title = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).nilIfEmpty
        titleOrigin = .meetingIntelligence
    }
}
```

`RecordingSessionMetadataStore.save` must encode a copy whose schema is
`max(metadata.schemaVersion, 2)`, preserving a future version rather than
downgrading it. Existing unknown root/nested fields remain unchanged.

- [ ] **Step 4: Run metadata migration/ownership focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter RecordingLibraryTests
git diff --check
```

Expected: metadata v1/v2 migration, title ownership, manual clear, tag-only
edit, and nested unknown-field round-trip tests pass before store tests are
added.

- [ ] **Step 5: Write safe artifact/state store RED tests**

Cover valid v1, unknown v1 fields, unsupported future version, malformed JSON,
257 KiB response artifact, symlink, directory, atomic replacement failure, and
an active state projected as interrupted. Assert an existing valid result
remains byte-identical when staging or promotion fails.

Core expectation:

```swift
func testFutureArtifactIsPreservedAndNotDecodedAsCurrent() throws {
    let fixture = try MeetingIntelligenceStoreFixture()
    let future = Data(#"{"schemaVersion":2,"summary":"future"}"#.utf8)
    try future.write(to: fixture.artifactURL)

    XCTAssertThrowsError(
        try MeetingIntelligenceArtifactStore().load(in: fixture.folder)
    ) {
        XCTAssertEqual(
            $0 as? MeetingIntelligenceStoreError,
            .unsupportedSchemaVersion(2)
        )
    }
    XCTAssertEqual(try Data(contentsOf: fixture.artifactURL), future)
}
```

- [ ] **Step 6: Run store tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligenceStoreTests|RecordingLibraryTests'
```

Expected: compilation fails because artifact/state models and stores do not
exist.

- [ ] **Step 7: Implement bounded, safe stores**

Use concrete store types and exact filenames:

```swift
struct MeetingIntelligenceArtifactStore:
    MeetingIntelligenceArtifactStoring,
    Sendable
{
    static let fileName = "meeting-intelligence.json"
    static let maximumBytes = 256 * 1_024
}

struct MeetingIntelligenceStateStore:
    MeetingIntelligenceStateStoring,
    Sendable
{
    static let fileName = "meeting-intelligence-state.json"
    static let maximumBytes = 32 * 1_024
}
```

Reads must use the same no-follow regular-file identity checks as Task 1.
Version 1 ignores unknown fields on decode; a future version throws
`.unsupportedSchemaVersion` and is never automatically replaced. Staging uses a
unique same-folder `.meeting-intelligence-stage-<UUID>` regular file. Promotion
revalidates staged and destination identities and uses atomic replacement.
State contains only phase, sanitized message, digest, and start/finish dates.

- [ ] **Step 8: Run focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligenceStoreTests|RecordingLibraryTests'
git diff --check
```

Expected: all selected tests pass, including existing metadata unknown-field
round-trip and legacy decode tests.

- [ ] **Step 9: Commit Task 2**

```bash
git add \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceModels.swift \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceStores.swift \
  Sources/RecorderApp/RecordingLibrary.swift \
  Tests/RecorderAppTests/MeetingIntelligenceStoreTests.swift \
  Tests/RecorderAppTests/RecordingLibraryTests.swift
git commit -m "feat: persist meeting intelligence ownership"
```

---

### Task 3: Exact-Model Automatic Availability Contract

**Files:**
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceAvailability.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligenceAvailabilityTests.swift`

**Interfaces:**
- Consumes: `OpenAICompatibleProviderSnapshot`,
  `ProviderConnectionTesting`, and `ProviderConnectionReport`.
- Produces:

```swift
enum MeetingIntelligenceAvailability: Equatable, Sendable {
    case confirmed
    case unconfirmed(MeetingIntelligenceUnavailableReason)
}

enum MeetingIntelligenceUnavailableReason: Equatable, Sendable {
    case missingProfile
    case placeholderModel
    case discoveryUnsupported
    case modelNotAdvertised
    case authenticationRejected
    case connectionFailed
    case unsafeTranscript
}

protocol MeetingIntelligenceAvailabilityChecking: Sendable {
    func availability(
        for snapshot: OpenAICompatibleProviderSnapshot
    ) async -> MeetingIntelligenceAvailability
}

struct OpenAICompatibleMeetingIntelligenceAvailabilityChecker:
    MeetingIntelligenceAvailabilityChecking
{
    init(client: any ProviderConnectionTesting)
}
```

- The checker never throws to the automatic orchestrator and never performs a
  chat request. It maps provider/discovery outcomes to typed local reasons.

- [ ] **Step 1: Write exact-match and zero-generation RED tests**

Create a recording `ProviderConnectionTesting` fake and cover:

```swift
func testExactLLMMatchConfirmsDifferentASRAndLLMModels() async throws {
    let snapshot = try providerSnapshot(
        asrModel: "asr-model",
        llmModel: "llm-model"
    )
    let client = StubProviderConnectionClient(
        result: .success(
            .init(
                supportsModelDiscovery: true,
                models: ["asr-model", "llm-model"]
            )
        )
    )

    let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
        client: client
    ).availability(for: snapshot)

    XCTAssertEqual(result, .confirmed)
    XCTAssertEqual(client.requestedProfiles.map(\.llmModel), ["llm-model"])
}

func testUnsupportedDiscoveryNeverConfirmsAutomaticGeneration() async throws {
    let snapshot = try providerSnapshot(llmModel: "manual-model")
    let client = StubProviderConnectionClient(
        result: .success(
            .init(supportsModelDiscovery: false, models: [])
        )
    )

    let result = await OpenAICompatibleMeetingIntelligenceAvailabilityChecker(
        client: client
    ).availability(for: snapshot)

    XCTAssertEqual(result, .unconfirmed(.discoveryUnsupported))
}
```

Add cases for exact case-sensitive mismatch, placeholder, 401/403, timeout,
malformed model list, too many models, and cancellation.

The cancellation case uses a `ControlledAvailabilityClient` with
`requestStarted` and `releaseResponse` async barriers. Wait for
`requestStarted`, cancel the owning task, release the response, and assert no
confirmed presentation or downstream generation signal is produced. Do not
poll or sleep.

- [ ] **Step 2: Run availability tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceAvailabilityTests
```

Expected: compilation fails because the availability types/checker do not
exist.

- [ ] **Step 3: Implement the pure availability adapter**

Implement:

```swift
func availability(
    for snapshot: OpenAICompatibleProviderSnapshot
) async -> MeetingIntelligenceAvailability {
    let model = snapshot.profile.llmModel
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty,
          model != "legacy-unconfigured-llm" else {
        return .unconfirmed(.placeholderModel)
    }
    do {
        let report = try await client.testConnection(
            profile: snapshot.profile,
            apiKey: snapshot.apiKey
        )
        guard report.supportsModelDiscovery else {
            return .unconfirmed(.discoveryUnsupported)
        }
        return report.models.contains(model)
            ? .confirmed
            : .unconfirmed(.modelNotAdvertised)
    } catch ProviderConnectionError.authenticationRejected {
        return .unconfirmed(.authenticationRejected)
    } catch {
        return .unconfirmed(.connectionFailed)
    }
}
```

Do not cache or persist the result. Do not add an optimistic chat probe.
Preserve the existing 1 MiB/1,000-model caps.

- [ ] **Step 4: Run Task 3 GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceAvailabilityTests
git diff --check
```

Expected: all availability tests pass and the branch contains no intentionally
failing checked-in test.

- [ ] **Step 5: Commit Task 3**

```bash
git add \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceAvailability.swift \
  Tests/RecorderAppTests/MeetingIntelligenceAvailabilityTests.swift
git commit -m "feat: gate automatic summaries by exact model"
```

---

### Task 4: Shared Redirect Policy and Bounded Chat-Completions Client

**Files:**
- Create: `Sources/RecorderApp/Transcription/ProviderRedirectPolicy.swift`
- Create: `Sources/RecorderApp/MeetingIntelligence/OpenAICompatibleMeetingIntelligenceClient.swift`
- Create: `Tests/RecorderAppTests/OpenAICompatibleMeetingIntelligenceClientTests.swift`
- Modify: `Sources/RecorderApp/Transcription/OpenAICompatibleTranscriptionClient.swift:37-190`
- Modify: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift:3-258`
- Modify: `Tests/RecorderAppTests/OpenAICompatibleProviderClientTests.swift`
- Modify: `Tests/RecorderAppTests/OpenAICompatibleTranscriptionClientTests.swift`

**Interfaces:**
- Consumes: `ProviderHTTPTransport`,
  `OpenAICompatibleProviderSnapshot`, and Task 2 models.
- Produces:

```swift
enum ProviderRedirectPolicy {
    static func redirectedRequest(
        from source: URLRequest,
        proposed: URLRequest,
        statusCode: Int
    ) -> URLRequest?
}

struct MeetingIntelligenceGeneratedContent: Equatable, Sendable {
    let title: String
    let summary: String
}

enum MeetingIntelligenceClientError:
    LocalizedError,
    Equatable,
    Sendable
{
    case requestTooLarge
    case responseTooLarge
    case invalidResponse
    case authenticationRejected
    case unsafeRedirect
    case transportUnavailable
    case cancelled
    case unsafeOutput
    case httpStatus(Int, retryAfter: TimeInterval?)
}

protocol MeetingIntelligenceRequesting: Sendable {
    func requestPartialSummary(
        input: String,
        snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> String

    func requestFinalResult(
        input: String,
        snapshot: OpenAICompatibleProviderSnapshot
    ) async throws -> MeetingIntelligenceGeneratedContent
}
```

- Each method sends exactly one HTTP request. Partial responses accept only the
  exact inner JSON object `{"summary":"non-empty bounded text"}`. Final
  responses accept only the exact inner JSON object
  `{"title":"non-empty bounded text","summary":"non-empty bounded text"}`.
  Unknown or missing keys are rejected before decoding. The partial summary
  uses the same Unicode/control sanitizer as the final summary and is limited
  to 4 KiB.

- [ ] **Step 1: Write request/response and one-attempt RED tests**

Use a recording `ProviderHTTPTransport` and assert:

```swift
func testFinalRequestUsesOnlyLLMModelAndOptionalBearer() async throws {
    let transport = RecordingProviderTransport(
        responses: [
            .success(
                httpResponse(
                    status: 200,
                    body: #"{"choices":[{"message":{"content":"{\"title\":\"ClearPass migration\",\"summary\":\"The team reviewed migration sequencing.\"}"}}]}"#
                )
            )
        ]
    )
    let client = OpenAICompatibleMeetingIntelligenceClient(
        transport: transport
    )

    let result = try await client.requestFinalResult(
        input: "bounded transcript",
        snapshot: try providerSnapshot(
            asrModel: "asr-only",
            llmModel: "llm-only",
            apiKey: "secret"
        )
    )

    XCTAssertEqual(result.title, "ClearPass migration")
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(
        decodedJSON(transport.requests[0])["model"] as? String,
        "llm-only"
    )
    XCTAssertEqual(
        transport.requests[0].value(
            forHTTPHeaderField: "Authorization"
        ),
        "Bearer secret"
    )
}
```

Add terminal 408/429/500/`URLError.timedOut` cases and assert exactly one
request for each. Parse Retry-After seconds and HTTP-date into a capped hint
without sleeping/resending. Map response overflow, unsafe redirect, cancellation,
and all other transport failures to the sanitized typed cases above; no
underlying body, URL, secret, prompt, transcript, or local path reaches the
public error.

- [ ] **Step 2: Write redirect-policy RED tests**

Extend the actual `ControlledURLProtocol` transport fixture so `/models`
proposes 307 and 308 same-origin redirects. Assert each GET finishes with
`ProviderHTTPTransportError.redirectRejected`, the redirected destination is
never loaded, and its captured Authorization is nil.

Add direct and actual delegate-path tests for JSON and multipart redirects:

- same-origin 307/308 with identical POST method, exact body, and normalized
  supported content type are accepted;
- cross-origin, HTTPS downgrade, effective-port change, 301/302/303, changed
  method, missing/changed body, and changed content type are rejected;
- every rejected destination observes zero Authorization.

- [ ] **Step 3: Write strict-output and sanitizer RED tests**

For partial output, cover exact `{"summary":"..."}`, blank summary, missing or
extra keys, fenced/prose output, unsafe controls, and 4 KiB + 1 byte. For final
output, cover empty/multiple choices, fenced JSON, prose outside JSON, missing
or extra fields, date-only/folder-shaped title, 121 graphemes, path separator,
bidi controls, C0/C1 controls, oversized summary, malicious transcript
instructions, and response cap propagation. Accepted summary newlines/tabs
remain plain text.

- [ ] **Step 4: Run client and redirect tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'OpenAICompatibleMeetingIntelligenceClientTests|OpenAICompatibleProviderClientTests|OpenAICompatibleTranscriptionClientTests'
```

Expected: compilation fails because the client, protocol, generated-content,
typed errors, and shared redirect policy do not exist.

- [ ] **Step 5: Extract the content-type-aware redirect policy**

Move the existing policy out of
`OpenAICompatibleTranscriptionClient.swift`. Preserve all current multipart
requirements. For POST redirects:

```swift
guard statusCode == 307 || statusCode == 308,
      source.httpMethod == "POST",
      proposed.httpMethod == "POST",
      source.httpBody != nil,
      proposed.httpBody == source.httpBody,
      normalizedContentType(source) == normalizedContentType(proposed),
      isSupportedContentType(source),
      sameOrigin(source.url, proposed.url) else {
    return nil
}
```

For GET or any request without an exact body, return nil. Remove Authorization
from the proposed request before all checks and restore the source value only
after successful validation.

- [ ] **Step 6: Implement the one-request chat client**

Set:

```swift
static let maximumRequestBytes = 96 * 1_024
static let maximumResponseBytes = 256 * 1_024
static let maximumPartialSummaryBytes = 4 * 1_024
static let maximumFinalSummaryBytes = 48 * 1_024
static let maximumTitleGraphemes = 120
static let timeout: TimeInterval = 90
```

Encode `model`, non-streaming `messages`, deterministic temperature, and the
untrusted-transcript system instruction. Check encoded `Data.count` before
transport. Decode exactly one `choices[0].message.content`; validate the exact
partial or final key set, then decode the inner JSON. Normalize NFC and reject
blank/oversized/unsafe partials, and reject unsafe controls/path/date-only
titles in final output. Public errors must not include body, transcript,
prompt, key, URL, or path.

- [ ] **Step 7: Run focused GREEN and ASR regressions**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'OpenAICompatibleMeetingIntelligenceClientTests|OpenAICompatibleProviderClientTests|OpenAICompatibleTranscriptionClientTests'
git diff --check
```

Expected: every new client/redirect test and every existing multipart,
Authorization, retry, response-cap, and cancellation test passes.

- [ ] **Step 8: Commit Task 4**

```bash
git add \
  Sources/RecorderApp/Transcription/ProviderRedirectPolicy.swift \
  Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift \
  Sources/RecorderApp/Transcription/OpenAICompatibleTranscriptionClient.swift \
  Sources/RecorderApp/MeetingIntelligence/OpenAICompatibleMeetingIntelligenceClient.swift \
  Tests/RecorderAppTests/OpenAICompatibleMeetingIntelligenceClientTests.swift \
  Tests/RecorderAppTests/OpenAICompatibleProviderClientTests.swift \
  Tests/RecorderAppTests/OpenAICompatibleTranscriptionClientTests.swift
git commit -m "feat: add bounded meeting intelligence client"
```

---

### Task 5: Bounded Multi-Pass Long-Transcript Pipeline

**Files:**
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePipeline.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligencePipelineTests.swift`

**Interfaces:**
- Consumes: `MeetingIntelligenceRequesting`,
  `TranscriptDocumentSnapshot`, and immutable provider snapshot.
- Produces:

```swift
struct MeetingIntelligenceProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case summarizingChunks
        case reducingSummaries
        case generatingFinal
    }

    let stage: Stage
    let current: Int
    let total: Int
}

protocol MeetingIntelligenceGenerating: Sendable {
    func generate(
        transcript: TranscriptDocumentSnapshot,
        snapshot: OpenAICompatibleProviderSnapshot,
        onProgress: @escaping @Sendable (
            MeetingIntelligenceProgress
        ) -> Void
    ) async throws -> MeetingIntelligenceGeneratedContent
}

struct MeetingIntelligencePipeline: MeetingIntelligenceGenerating {
    typealias Now = @Sendable () -> ContinuousClock.Instant

    init(
        client: any MeetingIntelligenceRequesting,
        now: @escaping Now = { ContinuousClock().now }
    )
}
```

- Constants exactly match Global Constraints.

- [ ] **Step 1: Write one-chunk and multi-pass RED tests**

Use a scripted client that records every input and returns deterministic
partials:

```swift
func testMultiChunkInputReducesToOneFinalRequestWithoutTruncation()
    async throws
{
    let client = ScriptedMeetingIntelligenceClient()
    client.partialResult = { input in
        "partial:\(input.utf8.count)"
    }
    client.finalResult = .init(
        title: "Network migration review",
        summary: "All bounded partial summaries were combined."
    )
    let transcript = transcriptSnapshot(
        bytes: Data(repeating: 0x61, count: 130 * 1_024)
    )

    let result = try await MeetingIntelligencePipeline(
        client: client
    ).generate(
        transcript: transcript,
        snapshot: try providerSnapshot(llmModel: "llm"),
        onProgress: { _ in }
    )

    XCTAssertEqual(result.title, "Network migration review")
    XCTAssertEqual(
        client.partialInputs.reduce(0) { $0 + $1.utf8.count },
        transcript.data.count
    )
    XCTAssertEqual(client.finalInputs.count, 1)
}
```

Add one-chunk coverage proving it sends one final request and zero partial
requests.

- [ ] **Step 2: Write resource/cancellation/deadline RED tests**

Cover:

- multi-byte scalar exactly on the 64 KiB boundary;
- JSON-expansion feedback that forces a smaller chunk;
- 4 MiB + 1 source;
- 65 source chunks;
- partial output above 4 KiB;
- fan-in 13 grouped into 12 + 1;
- depth 5;
- request 72;
- cancellation at chunk 2, reduction, and before final;
- controlled clock reaching 30 minutes;
- malicious client output that grows rather than reduces.

For every failure assert zero final publication because the pipeline returns no
content object. Use a lock-protected `ControlledPipelineClock` whose `now`
closure advances only when the test directs it; do not use wall-clock sleeps.

`ScriptedMeetingIntelligenceClient` exposes deterministic async barriers:

```swift
func waitForPartialRequestStarted(index: Int) async
func waitForReductionRequestStarted(index: Int) async
func waitForFinalRequestStarted() async
func releaseResponse(for requestID: UUID)
```

Cancellation tests wait at the exact chunk, reduction, or final-request
barrier, cancel the pipeline task, then release the response. Assert the request
count stops, no later progress is emitted, and no final content is returned.

- [ ] **Step 3: Run pipeline tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligencePipelineTests
```

Expected: compilation fails because the pipeline/progress/generating protocol
do not exist.

- [ ] **Step 4: Implement deterministic UTF-8 planning**

Implement these exact limits:

```swift
private enum Limits {
    static let sourceBytes = 4 * 1_024 * 1_024
    static let chunkBytes = 64 * 1_024
    static let maximumChunks = 64
    static let partialBytes = 4 * 1_024
    static let reductionFanIn = 12
    static let maximumDepth = 4
    static let maximumRequests = 71
    static let maximumDuration = Duration.seconds(1_800)
}
```

Split preferentially at two newlines, one newline, sentence punctuation, then a
valid UTF-8 scalar boundary. Preserve every source byte in order. Before each
client call, check cancellation, deadline, request count, and progress. Validate
partial byte size before reduction. Group at most 12 partials. Stop when one
bounded final input remains; never publish partial content.

Capture `let deadline = now().advanced(by: Limits.maximumDuration)` once at
job start and compare `now()` against it at every boundary. The production
default reads `ContinuousClock().now`; tests inject the controlled closure.

- [ ] **Step 5: Run focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligencePipelineTests|OpenAICompatibleMeetingIntelligenceClientTests'
git diff --check
```

Expected: all pipeline and client tests pass; request counts and progress are
deterministic.

- [ ] **Step 6: Commit Task 5**

```bash
git add \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePipeline.swift \
  Tests/RecorderAppTests/MeetingIntelligencePipelineTests.swift
git commit -m "feat: summarize bounded long transcripts"
```

---

### Task 6: Coordinator, Publication Compare-and-Save, and AppModel Integration

**Files:**
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublisher.swift`
- Create: `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceJobCoordinator.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligencePublisherTests.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligenceJobCoordinatorTests.swift`
- Create: `Tests/RecorderAppTests/AppModelMeetingIntelligenceTests.swift`
- Modify: `Sources/RecorderApp/AppModel.swift:85-425,1162-1271,1340-1375,1659-1728`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelMuteTests.swift`

**Interfaces:**
- Consumes: every Task 1–5 interface.
- Produces:

```swift
struct MeetingIntelligencePresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case notGenerated
        case checkingAvailability
        case generating(MeetingIntelligenceProgress)
        case ready
        case stale
        case failed
        case cancelled
        case interrupted
    }

    let phase: Phase
    let summary: String?
    let suggestedTitle: String?
    let statusMessage: String
    let model: String?
    let titleIsProtected: Bool
    let unavailableReason: MeetingIntelligenceUnavailableReason?
}

final class MeetingIntelligenceAttemptLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.withLock { valid }
    }

    func invalidate() {
        lock.withLock { valid = false }
    }
}

struct MeetingIntelligencePublicationRequest: Sendable {
    let session: RecordingSession
    let sourceRevision: TranscriptDocumentRevision
    let capturedTitle: String?
    let capturedTitleOrigin: RecordingTitleOrigin
    let content: MeetingIntelligenceGeneratedContent
    let snapshot: OpenAICompatibleProviderSnapshot
    let intent: MeetingIntelligenceIntent
    let generatedAt: Date
    let lease: MeetingIntelligenceAttemptLease
}

struct MeetingIntelligencePublicationOutcome: Equatable, Sendable {
    let artifact: MeetingIntelligenceArtifact
    let titleWasApplied: Bool
    let titleWarning: String?
}

protocol MeetingIntelligencePublishing: Sendable {
    func publish(
        _ request: MeetingIntelligencePublicationRequest
    ) async throws -> MeetingIntelligencePublicationOutcome
}

@MainActor
final class MeetingIntelligenceJobCoordinator: ObservableObject {
    typealias DateNow = @Sendable () -> Date

    var onSuccessfulPublication: ((RecordingSession) -> Void)?

    init(
        providerRepository: any OpenAICompatibleProviderManaging,
        transcriptReader: any TranscriptDocumentReading,
        availabilityChecker:
            any MeetingIntelligenceAvailabilityChecking,
        generator: any MeetingIntelligenceGenerating,
        publisher: any MeetingIntelligencePublishing,
        artifactStore: any MeetingIntelligenceArtifactStoring,
        stateStore: any MeetingIntelligenceStateStoring,
        now: @escaping DateNow = { Date() }
    )

    func presentation(
        for session: RecordingSession
    ) -> MeetingIntelligencePresentation

    func handleTranscriptPublished(_ event: TranscriptPublished)
    func checkAvailability(for session: RecordingSession)
    func generate(for session: RecordingSession)
    func regenerate(for session: RecordingSession)
    func retryGeneration(for session: RecordingSession)
    func cancel(sessionID: RecordingSession.ID)
    func transcriptDidSave(_ session: RecordingSession)
    func remove(sessionID: RecordingSession.ID)
    func reload(sessions: [RecordingSession])
    func applySuggestedTitle(for session: RecordingSession)
    func shutdown()
}
```

- `AppModel` exposes exactly one read-only property:

```swift
let meetingIntelligence: MeetingIntelligenceJobCoordinator
```

It forwards commands but has no task/generation/state dictionary.

- [ ] **Step 1: Write publisher compare-and-save RED tests**

Use injected barrier stores. Cover:

1. `unset` applies title;
2. generated title applies replacement only when current normalized title and
   origin equal the captured state;
3. manual title/manual clear during generation stores suggestion only;
4. transcript digest changes before staging, after staging, after promotion,
   and before metadata save;
5. metadata save failure leaves summary/suggestion and returns a warning;
6. Apply Suggested Title races with Regenerate/manual save;
7. exactly one semantic refresh after complete settlement.

Core assertion:

```swift
func testManualRenameAtMetadataBarrierCannotBeOverwritten() async throws {
    let fixture = try PublicationFixture(
        metadata: .init(
            title: nil,
            titleOrigin: .unset
        )
    )
    fixture.metadataStore.pauseBeforeLoad = true
    let task = Task {
        try await fixture.publisher.publish(fixture.request)
    }
    await fixture.metadataStore.waitUntilPaused()
    try fixture.writeManualTitle("Customer-owned title")
    fixture.metadataStore.resume()

    let outcome = try await task.value

    XCTAssertFalse(outcome.titleWasApplied)
    XCTAssertEqual(
        fixture.currentMetadata.title,
        "Customer-owned title"
    )
}
```

- [ ] **Step 2: Run publisher tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligencePublisherTests
```

Expected: compilation fails because publisher interfaces do not exist.

- [ ] **Step 3: Implement serialized publication**

Stage the success artifact first. Enter the shared mutation gate and:

1. check `request.lease.isValid`;
2. secure-read and compare digest;
3. promote the candidate;
4. check the lease and digest again;
5. reload metadata;
6. apply title only for eligible current title/origin;
7. save metadata;
8. return one semantic outcome.

Never hold the mutation gate across network work. Do not expose candidate
artifact paths in status. The coordinator invalidates the previous lease before
cancelling or replacing its task. The publisher reads only the lock-protected
lease; it never receives a closure that captures `@MainActor` state.

- [ ] **Step 4: Run publisher focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligencePublisherTests
git diff --check
```

Expected: every digest, lease, title-ownership, staged-promotion, metadata
warning, and semantic-outcome test passes before coordinator tests are added.

- [ ] **Step 5: Write coordinator automatic/manual/stale RED tests**

Use deterministic barriers for availability, pipeline, publisher, state store,
and provider repository. Cover:

- eligible `TranscriptPublished` -> one `/models`, one generation, one publish;
- ineligible, placeholder, stale/duplicate older event -> zero generation;
- newest event exactly once;
- LLM failure leaves ASR completed and previous result;
- manual Generate/Regenerate/Retry Generation bypass discovery;
- Check Again performs only `/models`;
- immutable profile/key/`llmModel`;
- same-session replacement cancellation and distinct-session isolation;
- cancellation during availability, response, reduction, decode, staging, and
  metadata publication;
- manual transcript save makes changed digest stale without auto generation;
- byte-identical save remains ready;
- relaunch active state -> interrupted;
- session trash and shutdown suppress late callbacks.

- [ ] **Step 6: Run coordinator tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligenceJobCoordinatorTests
```

Expected: publisher tests are green, while the new lifecycle tests fail because
`MeetingIntelligenceJobCoordinator` does not yet own the specified tasks,
generations, attempts, leases, and presentations.

- [ ] **Step 7: Implement coordinator ownership**

Use coordinator-owned:

```swift
private var tasksBySessionID:
    [RecordingSession.ID: Task<Void, Never>] = [:]
private var generationsBySessionID:
    [RecordingSession.ID: UInt64] = [:]
private var attemptsBySessionID:
    [RecordingSession.ID: UUID] = [:]
private var leasesBySessionID:
    [RecordingSession.ID: MeetingIntelligenceAttemptLease] = [:]
private var latestPublicationsBySessionID:
    [RecordingSession.ID: TranscriptPublicationIdentity] = [:]
@Published private var presentationsBySessionID:
    [RecordingSession.ID: MeetingIntelligencePresentation] = [:]
```

Every entry point increments or validates the session generation. Automatic
handling validates publication identity/digest before snapshot or availability.
Manual entry points validate a real non-placeholder `llmModel` but skip
discovery. Persist bounded state transitions. Do not write to transcription
state. Keep the coordinator and presentation mutations on `@MainActor`; perform
bounded transcript/artifact reads and network/pipeline work in owned child
tasks so no 4 MiB read or provider wait blocks the main thread.

- [ ] **Step 8: Run coordinator focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligencePublisherTests|MeetingIntelligenceJobCoordinatorTests'
git diff --check
```

Expected: publisher and coordinator lifecycle, barrier, immutable-snapshot,
session-isolation, cancellation, and stale-event tests pass before AppModel
integration tests are added.

- [ ] **Step 9: Write AppModel integration RED tests**

Cover:

```swift
func testSuccessfulTranscriptionRefreshesSearchAndStartsEligibleAutoOnce()
    async throws
{
    let fixture = try AppModelMeetingIntelligenceFixture(
        availability: .confirmed
    )

    fixture.model.transcribe(session: fixture.session)
    await fixture.completeTranscription(text: "ClearPass migration")
    await fixture.waitForMeetingIntelligenceCompletion()

    XCTAssertEqual(fixture.availability.requests.count, 1)
    XCTAssertEqual(fixture.pipeline.requests.count, 1)
    XCTAssertEqual(
        fixture.model.sessions.first?.displayName,
        "ClearPass migration review"
    )
    XCTAssertEqual(fixture.libraryRefreshCount, 1)
}
```

Add unconfirmed zero-pipeline, manual title protection, generated-title
replacement, explicit clear, tag-only edit, transcript edit stale/no-auto,
trash cancel, release/shutdown, and provider-save-during-job cases.

- [ ] **Step 10: Run AppModel integration tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'AppModelMeetingIntelligenceTests|AppModelTranscriptionTests|AppModelMuteTests'
```

Expected: existing transcription and mute regressions remain green, while the
new integration tests fail because AppModel has not yet routed the coordinator,
semantic refresh, typed title edits, transcript invalidation, trash, and
shutdown commands.

- [ ] **Step 11: Wire one coordinator and one mutation gate**

In `AppModel.init`, reuse the one shared mutation gate established in Task 1,
inject it into the meeting-intelligence publisher, then construct one
meeting-intelligence coordinator using the same provider repository.

Route:

```swift
transcriptionCoordinator.onSuccessfulPublication = {
    [weak self] event in
    self?.rebuildSearchDocument(for: event.session)
    self?.meetingIntelligence.handleTranscriptPublished(event)
}

meetingIntelligence.onSuccessfulPublication = {
    [weak self] session in
    self?.refreshSessionAfterMeetingIntelligence(session)
}
```

`refreshSessionAfterMeetingIntelligence` loads only that session off the main
thread and replaces it after a per-session generation check. Do not call full
`refreshSessions()` for each title completion.

Wrap existing transcript/metadata writes in the shared mutation gate. Replace
the metadata method with:

```swift
func saveMetadata(
    titleEdit: RecordingTitleEdit,
    tags: String,
    isFavorite: Bool,
    for session: RecordingSession
)
```

After transcript save, call `meetingIntelligence.transcriptDidSave(session)`.
Before trash, call `meetingIntelligence.remove(sessionID:)`. During shutdown,
call `meetingIntelligence.shutdown()`.

- [ ] **Step 12: Run focused GREEN and lifecycle regressions**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligencePublisherTests|MeetingIntelligenceJobCoordinatorTests|AppModelMeetingIntelligenceTests|AppModelTranscriptionTests|AppModelMuteTests|TranscriptionJobCoordinatorTests'
git diff --check
```

Expected: all selected tests pass; ASR completion/search, mute, metadata
preservation, cancellation, stale callback, and model-release tests remain
green.

- [ ] **Step 13: Commit Task 6**

```bash
git add \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublisher.swift \
  Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceJobCoordinator.swift \
  Sources/RecorderApp/AppModel.swift \
  Tests/RecorderAppTests/MeetingIntelligencePublisherTests.swift \
  Tests/RecorderAppTests/MeetingIntelligenceJobCoordinatorTests.swift \
  Tests/RecorderAppTests/AppModelMeetingIntelligenceTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift \
  Tests/RecorderAppTests/AppModelMuteTests.swift
git commit -m "feat: coordinate automatic meeting intelligence"
```

---

### Task 7: Transcript-Sheet UI, Provider Clarity, Accessibility, and Render Tests

**Files:**
- Create: `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligencePresentationTests.swift`
- Create: `Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift`
- Modify: `Sources/RecorderApp/UI/RecordingsLibraryView.swift:1-358`
- Modify: `Sources/RecorderApp/Views/AIProviderSettingsView.swift:1-82`
- Modify: `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift:1-209`
- Modify: `Sources/RecorderApp/UI/RecorderActionID.swift`
- Modify: `Tests/RecorderAppTests/AIProviderSettingsModelTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`
- Modify: `Tests/RecorderAppTests/RecorderActionIDTests.swift`
- Modify: `Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift`

**Interfaces:**
- Consumes: `MeetingIntelligencePresentation`, the one observed
  `MeetingIntelligenceJobCoordinator`, and AppModel typed command forwarders.
- Produces:

```swift
struct MeetingIntelligenceSectionView: View {
    let presentation: MeetingIntelligencePresentation
    let generate: () -> Void
    let regenerate: () -> Void
    let checkAgain: () -> Void
    let retryGeneration: () -> Void
    let cancel: () -> Void
    let applySuggestedTitle: () -> Void
}
```

- `TranscriptEditorView` becomes internal for actual AppKit-hosted tests and
  receives one immutable presentation plus typed action closures.

- [ ] **Step 1: Write pure state-to-action RED tests**

Write tests that require a pure `MeetingIntelligenceSectionPresentation` value
and `static make(presentation:)` builder. Verify:

| Phase | Visible primary actions |
|---|---|
| not generated | Generate |
| checking availability | Cancel |
| generating | Cancel |
| ready | Regenerate |
| stale | Regenerate |
| availability unconfirmed | Check Again + Generate |
| failed/interrupted | Retry Generation |
| protected title + suggestion | Apply Suggested Title |

Core test:

```swift
func testUnconfirmedAvailabilitySeparatesCheckFromExplicitGeneration() {
    let view = MeetingIntelligenceSectionPresentation.make(
        presentation: .fixture(
            phase: .notGenerated,
            unavailableReason: .discoveryUnsupported
        )
    )

    XCTAssertTrue(view.showsCheckAgain)
    XCTAssertTrue(view.showsGenerate)
    XCTAssertFalse(view.showsRetryGeneration)
}
```

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligencePresentationTests
git diff --check
```

Expected: compilation fails because the section presentation value and builder
do not exist.

- [ ] **Step 3: Implement the pure section presentation**

Add `MeetingIntelligenceSectionPresentation` and its deterministic builder to
`MeetingIntelligenceSectionView.swift`. Implement exactly the action matrix
above without constructing or retaining a task, model, presenter, or session.
Rerun:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MeetingIntelligencePresentationTests
git diff --check
```

Expected: the pure presentation suite passes.

- [ ] **Step 4: Write metadata-intent and provider-settings RED tests**

Add focused tests requiring:

- an unchanged editor title to send `.unchanged`;
- an edited or cleared title to send `.manual(value)` or `.manual(nil)`;
- save and reload of each `yue`, `en`, and `zh` meeting-language choice;
- independent ASR and LLM IDs, including the same ID selected for both roles;
- a language save during an active ASR job to leave that job's immutable
  `snapshot.profile.language` unchanged and affect only the next job.

- [ ] **Step 5: Run settings and metadata-intent tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'AIProviderSettingsModelTests|AppModelTranscriptionTests|MeetingIntelligencePresentationTests'
```

Expected: existing tests and the pure presentation suite remain green, while
the new tests fail because typed language selection and editor title-intent
projection do not exist.

- [ ] **Step 6: Implement metadata intent and typed language state**

`RecordingMetadataEditorView` stores `originalNormalizedTitle` on appear.
Add a pure `RecordingMetadataEditorIntent.titleEdit(current:original:)` helper
in `RecordingsLibraryView.swift`; when Save is pressed, call that helper:

```swift
let normalized = title.trimmingCharacters(
    in: .whitespacesAndNewlines
)
let edit: RecordingTitleEdit =
    normalized == originalNormalizedTitle
        ? .unchanged
        : .manual(normalized.isEmpty ? nil : normalized)
save(edit, tags, isFavorite)
```

This keeps generated origin for tag/Favorite-only changes and protects a real
manual clear.

Add a typed setting:

```swift
enum MeetingLanguage: String, CaseIterable, Identifiable, Sendable {
    case cantonese = "yue"
    case english = "en"
    case mandarin = "zh"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cantonese: "Cantonese"
        case .english: "English"
        case .mandarin: "Mandarin"
        }
    }
}
```

`AIProviderSettingsModel` exposes
`@Published var meetingLanguage: MeetingLanguage = .cantonese` with a `didSet`
that invalidates stale connection-test results. It replaces, rather than
mirrors, the old mutable `language: String` field.

`draftProfile()` passes only `meetingLanguage.rawValue` to
`OpenAICompatibleProviderProfile.validated`. `reload()` maps the stored
profile's exact `yue`, `en`, or `zh` value back to the enum. A legacy empty or
unsupported value is projected as `.cantonese`, sets a local explanatory
status, and is not persisted until the user presses Save. The provider profile
and immutable job snapshot continue storing the wire value as `String`; no
second persisted language source is introduced.

- [ ] **Step 7: Run metadata-intent/settings focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'AIProviderSettingsModelTests|AppModelTranscriptionTests|MeetingIntelligencePresentationTests'
git diff --check
```

Expected: title-intent, three-language save/reload, same/different model, active
snapshot isolation, existing transcription, and pure presentation tests pass
before sheet/provider render tests are added.

- [ ] **Step 8: Write actual 860×680 sheet and provider UI RED tests**

Host the real `TranscriptEditorView` in `NSHostingView` and `NSWindow` with an
860×680 content rect. For each phase assert fixed markers/actions are inside
the window content rect. Programmatically scroll to summary and transcript
editor markers and assert accessibility reachability.

Repeat close/reopen and:

```text
Record -> Recordings -> open transcript sheet -> close
Settings -> Recordings -> open transcript sheet -> close
```

Assert the same-session generated-title projection updates exactly one row,
draft text survives an unrelated model publication, and no `AVPlayerView`
exists under the main workspace. Render Settings and assert separate ASR/LLM
fields plus the Meeting Language picker with exactly three choices and its
stable accessibility identifier.

- [ ] **Step 9: Run UI tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligencePresentationTests|MeetingIntelligenceSheetRenderTests|AIProviderSettingsModelTests|RecorderActionIDTests|RecorderWorkspaceRenderTests|AppModelTranscriptionTests'
```

Expected: new section/render/ID assertions fail before UI composition.

- [ ] **Step 10: Complete UI composition and wiring**

Build `MeetingIntelligenceSectionView` with:

- fixed status/header and action footer;
- one scrollable summary/transcript content area;
- plain-text summary;
- generated/suggested title;
- protected-title explanation;
- sanitized status copy;
- mutually correct buttons from the table;
- `ProgressView` for checking/generating;
- no extra dense session-row command cluster.

Add exact interaction IDs:

```swift
static let meetingIntelligenceGenerate =
    "recorder.meeting-intelligence.generate"
static let meetingIntelligenceRegenerate =
    "recorder.meeting-intelligence.regenerate"
static let meetingIntelligenceCancel =
    "recorder.meeting-intelligence.cancel"
static let meetingIntelligenceCheckAgain =
    "recorder.meeting-intelligence.check-again"
static let meetingIntelligenceRetryGeneration =
    "recorder.meeting-intelligence.retry-generation"
static let meetingIntelligenceApplyTitle =
    "recorder.meeting-intelligence.apply-title"
```

Keep non-interactive status markers out of the action registry while giving
them the exact accessibility identifiers from the design.

In `AIProviderSettingsView`, add:

```swift
Text("ASR transcribes audio. LLM creates summaries and contextual titles. Automatic generation requires the selected LLM model in Test results; manual Generate can still try providers without model discovery.")
    .font(.caption)
    .foregroundStyle(.secondary)
```

Replace the free-text Language field with a `Picker("Meeting Language", ...)`
containing exactly Cantonese, English, and Mandarin. Add identifiers for base
URL, key, ASR model, LLM model, meeting-language picker, prompt, Save, Test,
Remove Key, and status. Relabel the existing generic Prompt field as
`ASR Prompt` so it cannot be mistaken for the fixed meeting-summary system
instruction. Keep all other existing bindings and commands.

Pass `model.meetingIntelligence` as the one observed presentation source from
`RecordingsLibraryView`; resolve presentations by session and call only typed
AppModel forwarders. Do not copy coordinator dictionaries into `@State` or
AppModel.

- [ ] **Step 11: Run focused GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligencePresentationTests|MeetingIntelligenceSheetRenderTests|AIProviderSettingsModelTests|RecorderActionIDTests|RecorderWorkspaceRenderTests|AppModelMeetingIntelligenceTests|AppModelTranscriptionTests|AppModelPlaybackTests'
git diff --check
```

Expected: all selected tests pass at 860×680 and wide sizes; playback remains
outside the main hierarchy.

- [ ] **Step 12: Commit Task 7**

```bash
git add \
  Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift \
  Sources/RecorderApp/UI/RecordingsLibraryView.swift \
  Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift \
  Sources/RecorderApp/Views/AIProviderSettingsView.swift \
  Sources/RecorderApp/UI/RecorderActionID.swift \
  Tests/RecorderAppTests/AIProviderSettingsModelTests.swift \
  Tests/RecorderAppTests/AppModelTranscriptionTests.swift \
  Tests/RecorderAppTests/MeetingIntelligencePresentationTests.swift \
  Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift \
  Tests/RecorderAppTests/RecorderActionIDTests.swift \
  Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift
git commit -m "feat: present summaries and contextual titles"
```

---

### Task 8: Contracts, Documentation, Synthetic Acceptance Harness, and Complete Gates

**Files:**
- Create: `contracts/fixtures/recording-info-v2-meeting-intelligence.json`
- Create: `contracts/meeting-intelligence.schema.json`
- Create: `contracts/fixtures/meeting-intelligence-v1.json`
- Create: `Tests/ManualFixtures/meeting_intelligence_provider.py`
- Create: `Tests/ScriptTests/test_meeting_intelligence_provider_fixture.py`
- Create: `docs/testing/2026-07-31-meeting-intelligence-uat.md`
- Modify: `contracts/recording-session.schema.json`
- Modify: `Tests/ScriptTests/test_recording_contract.py`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`
- Modify: `README.md`

**Interfaces:**
- Consumes: finalized metadata/artifact JSON encodings and exact staging bundle
  contract.
- Produces: versioned repository contracts, a development-only request telemetry
  harness, and acceptance evidence template.

- [ ] **Step 1: Write contract RED tests**

Extend Python tests to assert:

```python
def test_v2_fixture_declares_title_origin_and_valid_intelligence(self):
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
    fixture = json.loads(V2_FIXTURE.read_text(encoding="utf-8"))
    intelligence_schema = json.loads(
        INTELLIGENCE_SCHEMA.read_text(encoding="utf-8")
    )
    intelligence = json.loads(
        INTELLIGENCE_FIXTURE.read_text(encoding="utf-8")
    )

    self.assertEqual(fixture["schemaVersion"], 2)
    self.assertIn(
        fixture["titleOrigin"],
        {"unset", "meetingIntelligence", "manual"},
    )
    self.assertEqual(intelligence["schemaVersion"], 1)
    self.assertEqual(
        intelligence_schema["properties"]["schemaVersion"]["const"],
        1,
    )
    self.assertNotIn("apiKey", intelligence)
    self.assertNotIn("baseURL", intelligence)
    self.assertNotIn("transcript", intelligence)
```

Add packaging assertions that `Tests/ManualFixtures`, `.py`, raw contract
fixtures, API keys, and meeting transcript content are absent from a built app.

Add synthetic-provider tests that start the fixture on a loopback ephemeral
port and verify `/v1/models`, `/v1/audio/transcriptions`, and
`/v1/chat/completions`; advertised/missing model modes; delayed/forced-status
outcomes; exact request counts; and clean shutdown. Send a canary Authorization
value, prompt, transcript, response body, full URL, and local path, then assert
none appears in the captured JSON-lines telemetry.

- [ ] **Step 2: Run script tests and verify RED**

Run:

```bash
python3 -m unittest \
  Tests.ScriptTests.test_recording_contract \
  Tests.ScriptTests.test_packaging_contract \
  Tests.ScriptTests.test_meeting_intelligence_provider_fixture \
  -v
```

Expected: failures for missing v2/artifact schema, missing synthetic provider,
and harness exclusion assertions.

- [ ] **Step 3: Add v1/v2 and artifact schemas**

Change recording schema version from one `const` to a v1/v2-compatible
`oneOf`. Require `titleOrigin` only for v2. Keep `additionalProperties: true`
and every existing v1 fixture valid.

The artifact schema requires:

```json
{
  "schemaVersion": 1,
  "summary": "The team reviewed the migration sequence.",
  "suggestedTitle": "ClearPass migration review",
  "sourceTranscriptSHA256": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "sourceTranscriptByteCount": 4096,
  "model": "llm-model",
  "generatedAt": "2026-07-31T03:00:00Z",
  "intent": "automatic"
}
```

Do not add secrets, raw prompt, transcript, provider response, base URL, or
full path fields.

- [ ] **Step 4: Add the development-only synthetic provider**

Use Python standard library `http.server`. Support:

- `GET /v1/models`;
- `POST /v1/audio/transcriptions`;
- `POST /v1/chat/completions`;
- configurable advertised/missing LLM;
- delayed response and forced HTTP status;
- sanitized JSON-lines telemetry containing timestamp, endpoint class,
  request count, model role (`asr`/`llm`), and terminal outcome only.

Reject any attempt to log Authorization, prompt/messages, multipart body,
response body, full URL, or local path. Keep the harness under
`Tests/ManualFixtures`; packaging tests prove it is not bundled.

- [ ] **Step 5: Document behavior and manual UAT**

README must state:

- ASR/LLM can be the same or different models;
- Meeting Language offers Cantonese (`yue`), English (`en`), and Mandarin
  (`zh`), and a saved change applies to future ASR jobs only;
- exact `/models` match is required only for automatic generation;
- unknown availability sends zero automatic chat;
- Generate/Regenerate is explicit;
- successful summary and state artifact filenames;
- generated vs manual title rules;
- transcript edit stale behavior;
- no Python/FFmpeg runtime helper in the app.

The UAT document includes fields for date, app SHA, staging bundle hash,
provider, ASR model, LLM model, request counts, result, screenshot paths, and
outstanding real-provider/notarized/Teams/AirPods gates. It contains the exact
14 manual acceptance steps from the design, followed by these clarified
language checks:

15. select Cantonese, save, start a new transcription, and record the result;
16. select English, save, start a new transcription, and record the result;
17. select Mandarin, save, start a new transcription, and record the result;
18. change the saved language while a controlled transcription is active and
    confirm that active job finishes with its original snapshot while the next
    job uses the newly saved choice.

- [ ] **Step 6: Run contract GREEN**

Run:

```bash
python3 -m unittest discover \
  -s Tests/ScriptTests \
  -p 'test_*.py' \
  -v
git diff --check
```

Expected: all Python/script, policy, schema, workflow, and packaging-contract
tests pass.

- [ ] **Step 7: Run focused Swift suites**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter 'MeetingIntelligence|OpenAICompatibleProvider|OpenAICompatibleTranscription|TranscriptionJobCoordinator|AppModelTranscription|RecordingLibrary|RecorderWorkspaceRender|AppModelPlayback'
```

Expected: all new and affected focused suites pass.

- [ ] **Step 8: Run the complete Swift suite once**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: complete suite passes with zero failures. Do not run an identical
second PR stability pass; the workflow reserves that for pushes to `main`.

- [ ] **Step 9: Run packaging, strict codesign, bundle-content, and virtual-mic gates**

Run:

```bash
Tests/PackagingTests/run-tests.sh
Tests/VirtualMicDriverTests/run-tests.sh
Tests/VirtualMicDriverTests/run-bundle-tests.sh
Tests/VirtualMicDriverTests/run-script-tests.sh
```

Expected: all scripts pass; the staging bundle is ad-hoc signed and strict
codesign verification passes; no Python/FFmpeg/manual-fixture runtime helper is
present.

- [ ] **Step 10: Run final repository checks**

Run:

```bash
git diff --check origin/main...HEAD
git status --short
git diff --stat origin/main...HEAD
```

Expected: no whitespace errors; only intended branch files; no Windows paths;
no built bundle, credentials, transcript, provider response, or local
acceptance secret is tracked.

- [ ] **Step 11: Commit Task 8**

```bash
git add \
  contracts/recording-session.schema.json \
  contracts/meeting-intelligence.schema.json \
  contracts/fixtures/recording-info-v2-meeting-intelligence.json \
  contracts/fixtures/meeting-intelligence-v1.json \
  Tests/ScriptTests/test_recording_contract.py \
  Tests/ScriptTests/test_packaging_contract.py \
  Tests/ScriptTests/test_meeting_intelligence_provider_fixture.py \
  Tests/ManualFixtures/meeting_intelligence_provider.py \
  docs/testing/2026-07-31-meeting-intelligence-uat.md \
  README.md
git commit -m "docs: validate meeting intelligence delivery"
```

- [ ] **Step 12: Independent implementation review**

Dispatch separate architecture/security and lifecycle/UI reviewers. They must
inspect the complete diff and test evidence, with special focus on:

- zero automatic chat for unconfirmed availability;
- ASR/LLM model separation;
- Authorization confinement and request/response caps;
- exact one-attempt LLM behavior;
- stale transcript/publication/title race rejection;
- manual title/manual clear protection;
- coordinator single ownership and AppModel no-mirroring;
- 860×680 actual sheet and AVPlayer isolation;
- bundle exclusion and Windows separation.

Resolve all Critical and Important findings with new RED→GREEN evidence before
submission.

- [ ] **Step 13: Rebase, rerun complete gates, push, and create Draft PR**

Fetch and rebase onto latest `origin/main`. Resolve only in-scope conflicts.
Rerun Steps 6–10 after rebase. Push
`codex/meeting-intelligence-summary-title` and create a Draft PR against
`main`.

The PR description maps each design requirement to implementation files,
tests, and outstanding manual gates. It explicitly says production
notarization, real-provider quality, Teams, and AirPods hardware acceptance
remain outstanding.

- [ ] **Step 14: Rebuild only the staging app after Draft PR CI is green**

Use `build-app.sh` directly with an explicit staging output. Do not run
`scripts/install-app.sh`, because that script intentionally targets the
non-staging `/Applications/Local Meeting Recorder.app`.

Run this single shell block so the pre/post production hash comparison uses the
same captured value:

```bash
STAGING_APP_PATH='/Applications/Local Meeting Recorder Staging.app'
PRODUCTION_APP_PATH='/Applications/Local Meeting Recorder.app'
PRODUCTION_EXECUTABLE_PATH="$PRODUCTION_APP_PATH/Contents/MacOS/LocalMeetingRecorder"
STAGING_BUILD_NUMBER="$(git rev-list --count HEAD)"

if test -x "$PRODUCTION_EXECUTABLE_PATH"; then
  PRODUCTION_STATE_BEFORE='present'
  PRODUCTION_HASH_BEFORE="$(
    shasum -a 256 "$PRODUCTION_EXECUTABLE_PATH" | awk '{print $1}'
  )"
  test "$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$PRODUCTION_APP_PATH/Contents/Info.plist"
  )" = 'local.meeting.recorder'
else
  PRODUCTION_STATE_BEFORE='absent'
  PRODUCTION_HASH_BEFORE=''
  test ! -e "$PRODUCTION_APP_PATH"
fi

if test -e "$STAGING_APP_PATH"; then
  test "$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$STAGING_APP_PATH/Contents/Info.plist"
  )" = 'local.meeting.recorder.staging'
  test "$(
    tr -d '\n' \
      < "$STAGING_APP_PATH/Contents/Resources/.lmr-build-owner"
  )" = 'local.meeting.recorder.build-app.v1'
fi

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number "$STAGING_BUILD_NUMBER" \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name 'Local Meeting Recorder Staging' \
  --output "$STAGING_APP_PATH" \
  --sign ad-hoc

./scripts/verify-app-bundle.sh \
  "$STAGING_APP_PATH" \
  local.meeting.recorder.staging \
  0.2.0 \
  "$STAGING_BUILD_NUMBER" \
  ad-hoc
codesign --verify --deep --strict "$STAGING_APP_PATH"

if test "$PRODUCTION_STATE_BEFORE" = 'present'; then
  PRODUCTION_HASH_AFTER="$(
    shasum -a 256 "$PRODUCTION_EXECUTABLE_PATH" | awk '{print $1}'
  )"
  test "$PRODUCTION_HASH_BEFORE" = "$PRODUCTION_HASH_AFTER"
else
  test ! -e "$PRODUCTION_APP_PATH"
fi
```

Report the Draft PR URL, head SHA, CI run, staging bundle
version/build/signature, unchanged production executable hash, manual UAT path,
and outstanding real-provider gates. Do not merge.
