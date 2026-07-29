# P0 Product Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the production Python/FFmpeg transcription dependency, make all recordings discoverable and searchable, introduce a versioned cross-platform session contract, and move recording/transcription lifecycle state out of `AppModel`.

**Architecture:** Keep the existing native capture and media pipeline unchanged. Add a typed transcription service boundary whose production implementation uses AVFoundation and URLSession, retain the process implementation only as an injectable compatibility test adapter, and project coordinator state back through `AppModel`. Centralize capture gate, operation task, pending attempts, ownership, and automatic-stop state in one `@MainActor RecordingSessionCoordinator`. Treat the recording folder as source of truth while adding a pure search document/query layer and a root-level JSON contract.

**Tech Stack:** Swift 5.9, SwiftUI, AVFoundation, URLSession, XCTest, JSON Schema, Python `unittest` for packaging contracts.

## Global Constraints

- macOS deployment target remains `15.0`.
- Production app transcription must not require Python, FFmpeg, FFprobe, OpenCC, or PATH lookup.
- Remote provider URLs remain HTTPS-only; HTTP remains allowed only for loopback.
- API keys remain in Keychain and must never appear in logs, status text, manifests, or persisted errors.
- Recording folders remain the source of truth and `recording.mp4` remains preferred over recovery/audio-only `recording.m4a`.
- Existing capture, Teams Auto Meeting ownership, mute, media recovery, and playback behavior must remain unchanged.
- Every behavior change follows RED → GREEN and receives focused plus full-suite verification.
- Existing user-owned `.superpowers/` files in the main checkout are out of scope.

---

### Task 1: Versioned cross-platform recording-session contract

**Files:**
- Create: `contracts/recording-session.schema.json`
- Create: `contracts/fixtures/recording-info-v1.json`
- Modify: `Sources/RecorderApp/RecordingLibrary.swift`
- Modify: `Tests/RecorderAppTests/RecordingLibraryTests.swift`
- Create: `Tests/ScriptTests/test_recording_contract.py`

**Interfaces:**
- Produces: `RecordingSessionMetadata.currentSchemaVersion`, `schemaVersion`, `source`, `meetingType`, `participants`, and `extensionFields`.
- Produces: root-level schema and golden fixture shared by macOS and Windows implementations.
- Preserves: unknown JSON properties when metadata is loaded, edited, and saved by an older build.

- [x] **Step 1: Write failing Swift metadata migration tests**

```swift
func testLegacyMetadataDefaultsToCurrentSchemaVersion() throws {
    let metadata = try JSONDecoder().decode(
        RecordingSessionMetadata.self,
        from: Data(#"{"title":"Legacy"}"#.utf8)
    )
    XCTAssertEqual(metadata.schemaVersion, RecordingSessionMetadata.currentSchemaVersion)
}

func testUnknownCrossPlatformFieldsSurviveLoadEditAndSave() throws {
    let folder = try makeEmptySessionFolder(in: makeRoot(), named: "meeting-contract")
    try Data(#"{"schemaVersion":1,"title":"Old","windowsCapture":{"device":"default"}}"#.utf8)
        .write(to: RecordingSessionMetadataStore.fileURL(in: folder))
    var metadata = RecordingSessionMetadataStore.load(in: folder)
    metadata.title = "Edited"
    try RecordingSessionMetadataStore.save(metadata, in: folder)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: RecordingSessionMetadataStore.fileURL(in: folder))
        ) as? [String: Any]
    )
    XCTAssertNotNil(object["windowsCapture"])
}
```

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingLibraryTests
```

Expected: compile failure because `schemaVersion` and extension preservation do not exist.

- [x] **Step 3: Implement the Codable contract and root schema**

Implement a recursive `JSONValue: Codable, Equatable, Hashable`, decode known keys through a typed container, decode the complete object through a dynamic-key container, and retain only unknown keys in `extensionFields`. Encode `schemaVersion` and all known v1 fields, then re-emit extension fields without allowing them to overwrite known keys.

The schema must require:

```json
{
  "schemaVersion": 1,
  "tags": [],
  "isFavorite": false,
  "mediaKind": "audio",
  "screenIntervals": [],
  "recoveryState": "none",
  "source": "manual",
  "participants": []
}
```

and use `"additionalProperties": true` for forward-compatible platform extensions.

- [x] **Step 4: Add and run contract fixture validation**

`test_recording_contract.py` must parse the schema and fixture with the standard library, assert the schema version and required field types/enums, and assert both files remain valid JSON.

Run:

```bash
/usr/bin/python3 -m unittest Tests.ScriptTests.test_recording_contract -v
```

Expected: PASS.

- [x] **Step 5: Re-run focused Swift tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingLibraryTests
```

Expected: all `RecordingLibraryTests` pass.

### Task 2: Complete recording list and transcript-aware search

**Files:**
- Create: `Sources/RecorderApp/Library/RecordingLibraryQuery.swift`
- Modify: `Sources/RecorderApp/RecordingSession.swift`
- Modify: `Sources/RecorderApp/ContentView.swift`
- Create: `Tests/RecorderAppTests/RecordingLibraryQueryTests.swift`

**Interfaces:**
- Produces: `RecordingLibrarySearchDocument(session:)`.
- Produces: `RecordingLibraryQuery(text:favoritesOnly:)` with `filter(_:)` and transcript snippets.
- Consumes: metadata fields from Task 1 and canonical/legacy transcript resolution from `TranscriptDocumentStore`.

- [x] **Step 1: Write failing query and completeness tests**

```swift
func testEmptyQueryReturnsAllThirteenSessions() {
    let sessions = (0..<13).map(makeSession)
    XCTAssertEqual(
        RecordingLibraryQuery(text: "", favoritesOnly: false).filter(sessions).count,
        13
    )
}

func testQueryMatchesTranscriptParticipantDateSourceAndMeetingType() throws {
    let session = try makeSearchSession(
        transcript: "Discuss ClearPass migration",
        participants: ["Alex Chan"],
        source: .teamsAutomatic,
        meetingType: "Technical Workshop"
    )
    for term in ["ClearPass", "Alex", "2026-07-29", "Teams", "Workshop"] {
        XCTAssertEqual(RecordingLibraryQuery(text: term).filter([session]).map(\.id), [session.id])
    }
}
```

- [x] **Step 2: Run focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingLibraryQueryTests
```

Expected: compile failure because the query types do not exist.

- [x] **Step 3: Implement background-built search documents**

When `RecordingSessionStore.load` constructs sessions on the existing library queue, read the canonical/legacy transcript with a bounded 4 MiB limit and build a normalized search document from title, tags, transcript, ISO date, source, meeting type, and participants. Do not perform transcript disk I/O from SwiftUI `body`.

- [x] **Step 4: Replace the 12-row cap with lazy full rendering**

Replace:

```swift
ForEach(filteredSessions.prefix(12))
```

with `LazyVStack` + `ForEach(filteredSessions)` and use `RecordingLibraryQuery` for filtering. Show a bounded transcript snippet when the text query matched transcript content.

- [x] **Step 5: Run focused tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingLibrary
```

Expected: all library query and storage tests pass.

### Task 3: Native AVFoundation and URLSession transcription engine

**Files:**
- Create: `Sources/RecorderApp/Transcription/TranscriptionService.swift`
- Create: `Sources/RecorderApp/Transcription/AVFoundationTranscriptionChunker.swift`
- Create: `Sources/RecorderApp/Transcription/OpenAICompatibleTranscriptionClient.swift`
- Create: `Sources/RecorderApp/Transcription/TranscriptionArtifactPublisher.swift`
- Create: `Tests/RecorderAppTests/AVFoundationTranscriptionChunkerTests.swift`
- Create: `Tests/RecorderAppTests/OpenAICompatibleTranscriptionClientTests.swift`
- Create: `Tests/RecorderAppTests/TranscriptionArtifactPublisherTests.swift`
- Modify: `Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift`

**Interfaces:**
- Produces: `TranscriptionServiceRequest`, `TranscriptionServiceResult`, `TranscriptionServiceProgress`, and `TranscriptionServicing`.
- Produces: `TranscriptionChunking`, returning 120-second M4A chunks made with AVFoundation.
- Produces: typed multipart upload client with `verbose_json` → `json` negotiation.
- Produces: bounded response/request sizes, same-origin secure redirect policy, transient retry policy, deterministic Hans-to-Hant conversion, atomic publication, and backup retention.

- [x] **Step 1: Write failing pure client policy tests**

Cover:

```swift
XCTAssertTrue(TranscriptionRetryPolicy().shouldRetry(statusCode: 429))
XCTAssertTrue(TranscriptionRetryPolicy().shouldRetry(statusCode: 503))
XCTAssertFalse(TranscriptionRetryPolicy().shouldRetry(statusCode: 400))
XCTAssertFalse(ProviderRedirectPolicy.allows(
    from: URL(string: "https://api.example/v1/audio/transcriptions")!,
    to: URL(string: "https://evil.example/steal")!
))
```

Also assert multipart field names, file body cap, response body cap, `Retry-After` handling, and that 400/422 response-format rejection falls back once from `verbose_json` to `json`.

- [x] **Step 2: Run client tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OpenAICompatibleTranscriptionClientTests
```

Expected: compile failure because the native client types do not exist.

- [x] **Step 3: Implement the bounded native client**

Use the existing capped `ProviderHTTPTransport`, add redirect validation in its delegate, cap an individual chunk at 32 MiB and a provider response at 2 MiB, and send:

```text
file
model
language
prompt
response_format
```

Retry 408, 429, and 5xx up to three attempts using `Retry-After` when valid, otherwise exponential backoff plus injected jitter. Never retry other 4xx responses. Parse only typed JSON and never include response bodies or Authorization values in user-facing errors.

- [x] **Step 4: Write failing chunker and publisher tests**

Create a 241-second synthetic AAC fixture and assert chunk durations are bounded and output is reopenable. Assert successful publication leaves only canonical transcript/raw/manifest/log files, removes its temporary workspace, expires `.transcription-runs` older than seven days, and retains at most three `.previous-*` backups per canonical artifact.

- [x] **Step 5: Implement native chunking and publication**

Use `AVURLAsset.load(.duration)` and `AVAssetExportSession` time ranges for chunks. Build chunks in a unique system temporary workspace and delete it in `defer` on success, failure, and cancellation. Convert Simplified Chinese to Traditional Chinese with Foundation ICU `Hans-Hant`, falling back to the raw text deterministically if the transform is unavailable.

- [x] **Step 6: Run native transcription component tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter Transcription
```

Expected: all chunker, client, publisher, audio preparation, and existing process compatibility tests pass.

### Task 4: Typed recording/transcription coordinators and AppModel integration

**Files:**
- Create: `Sources/RecorderApp/RecordingSessionCoordinator.swift`
- Create: `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift`
- Modify: `Sources/RecorderApp/Transcription/TranscriptionProcess.swift`
- Modify: `Sources/RecorderApp/AppModel.swift`
- Create: `Tests/RecorderAppTests/RecordingSessionCoordinatorTests.swift`
- Create: `Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift`
- Modify: `Tests/RecorderAppTests/AppModelTranscriptionTests.swift`

**Interfaces:**
- Produces: a single serialized `@MainActor TranscriptionJobCoordinator` that owns attempt identity, task/process cancellation, preparation cleanup, status projection, artifact validation, and terminal state.
- Produces: a single serialized `@MainActor RecordingSessionCoordinator` that owns capture lifecycle tokens, operation task, pending start attempts, Teams/manual ownership, and automatic-stop intent.
- Consumes: native `TranscriptionServicing` by default.
- Preserves: explicit `transcriptionScriptURL` injection through `LegacyProcessTranscriptionService` for compatibility tests only.
- Projects: `transcribingSessionID`, status, last result, state map, and artifact URL maps to `AppModel`.

- [x] **Step 1: Write failing coordinator lifecycle tests**

Cover one active owner, cancellation during preparation, cancellation after launch, stale output rejection, cleanup exactly once, provider snapshot captured before preparation, artifact path confinement, secret redaction, and completed/failed/cancelled persisted state.

- [x] **Step 2: Run coordinator tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptionJobCoordinatorTests
```

Expected: compile failure because the coordinator does not exist.

- [x] **Step 3: Move recording and transcription orchestration state out of AppModel**

Move the current generation/attempt/process/task fields and transcription protocol parsing into the transcription coordinator. Move the capture gate, lifecycle task, pending start attempts, ownership, and automatic-stop tokens into the recording coordinator. `AppModel` keeps commands and UI projection names source-compatible for `ContentView` and tests.

- [x] **Step 4: Make native service the production default**

If no explicit compatibility script URL is injected, construct `NativeOpenAICompatibleTranscriptionService`. Do not inspect `Bundle.main.resourceURL` and do not spawn a subprocess in the production path.

- [x] **Step 5: Run focused AppModel and coordinator tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter AppModelTranscriptionTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TranscriptionJobCoordinatorTests
```

Expected: both suites pass.

### Task 5: Packaging, documentation, and final contract verification

**Files:**
- Modify: `scripts/build-app.sh`
- Modify: `Tests/ScriptTests/test_build_app_contract.py`
- Modify: `Tests/ScriptTests/test_packaging_contract.py`
- Modify: `README.md`
- Modify: `Package.swift` only if a linker/resource declaration is required.

**Interfaces:**
- Removes: production copying and verification of `transcribe-openai-compatible.sh`, `transcribe-qwen-asr.sh`, and `openai_asr_longform.py`.
- Documents: MP4 primary output, M4A audio/recovery fallback, All System Audio/Selected App modes, native provider flow, complete Library behavior, session schema version, and artifact retention.

- [x] **Step 1: Change packaging tests first and verify RED**

Assert the built app does not contain Python/shell transcription helpers and README no longer instructs users to install Python, FFmpeg, FFprobe, or OpenCC.

Run:

```bash
/usr/bin/python3 -m unittest Tests.ScriptTests.test_build_app_contract Tests.ScriptTests.test_packaging_contract -v
```

Expected: FAIL while `build-app.sh` still copies the helpers and README still describes the old contract.

- [x] **Step 2: Remove bundled runtime helpers from production packaging**

Delete only the three transcription helper copy/chmod lines and their bundle-verification expectations. Keep release/build Python helpers that run on the developer machine; the self-contained requirement applies to installed app transcription.

- [x] **Step 3: Correct README contract drift**

Document:

```text
recording.mp4              primary completed media
recording.m4a              audio-only or recovery output
recording-info.json        schemaVersion 1 metadata
transcript.txt             editable Traditional Chinese transcript
transcript.raw.txt         raw provider transcript
transcription.json         compact run manifest
transcription.log          sanitized status log
```

Replace “Mic Only” QA instructions with the actual All System Audio/Selected App + microphone flow.

- [x] **Step 4: Run packaging and script suites**

Run:

```bash
/usr/bin/python3 -m unittest discover -s Tests/ScriptTests -v
Tests/PackagingTests/run-tests.sh
```

Expected: all tests pass.

- [x] **Step 5: Run full Swift verification and build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
scripts/build-app.sh
```

Expected: Swift suite has zero failures, build exits 0, and the app bundle builds without transcription runtime helpers.

- [x] **Step 6: Review final requirements and working tree**

Run:

```bash
git diff --check
git status --short
git diff --stat
```

Confirm all four P0 acceptance lines are represented by tests and no main-checkout `.superpowers/` content was touched.
