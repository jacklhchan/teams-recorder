# PR B Library, Transcription, Meeting Intelligence, and Playback Boundaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` to implement this plan task by
> task. Every production slice starts with a focused failing test, reaches a
> focused green state, passes a separate spec and code-quality review, and is
> committed before the next slice starts.

**Goal:** Move Library, ASR Transcription, Meeting Intelligence, and Playback
UI-facing ownership out of `AppModel` into four independent `@MainActor`
feature boundaries without changing product behavior.

**Architecture:** Draft PR B remains stacked on Draft PR #7. `AppModel` is the
temporary construction and typed-bridge owner: it constructs or accepts
exactly one instance of each PR B feature, exposes only read-only compatibility
projections and command forwarding, and owns no parallel feature task,
generation, lease, callback dictionary, or mutable presentation. Existing
coordinators remain the lifecycle and business-rule owners. Library commits
canonical/search changes before a transcript event is admitted to Meeting
Intelligence. `ContentView` remains the only playback-window presenter owner.

**Tech stack:** Swift 5.9, SwiftUI, AppKit, Combine, XCTest, macOS 26+, existing
native ASR/LLM transports and repositories.

**Approved design:**
`cf7c83a120610eb62bd9b32de75b02db169d4767` (approved 2026-08-01).

**Stack base:** Draft PR #7, `codex/meeting-intelligence-summary-title`, at
`ab9395598505f1272f2efa7d8918b8ac69e96fd2`.

**Working branch:** `codex/refactor-library-transcription-mi-playback`.

**Baseline:**
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` passed
at the approved documentation checkpoint: 1,014 tests executed, 5 skipped,
0 failures. Existing `AVAssetExportSession` deprecation warnings are not a PR B
behavior change.

## Global Constraints

- This is a pure architecture refactor. Do not add providers, prompts,
  transcript formats, Meeting Intelligence outputs, timestamped transcript
  UI, recording behavior, Teams behavior, media behavior, or Windows work.
- Do not introduce `AppCoordinator`, `RecordFeatureModel`,
  `IntegrationsFeatureModel`, `SettingsFeatureModel`, or
  `WorkspaceFolderRepository`; those belong to PR C.
- Before PR C, `AppModel.outputFolder` and its existing
  `WorkspacePublicationFence` are the sole selected-workspace source and
  compatibility revision. Feature commands receive immutable folder/fence
  context; no feature creates a second mutable folder source or revision.
- `AppModel` may retain exactly one `LibraryFeatureModel`, one
  `TranscriptionFeatureModel`, one `MeetingIntelligenceFeatureModel`, and one
  `PlaybackFeatureModel`. An injected boundary replaces default construction;
  it never causes fallback construction.
- All four feature models are `@MainActor`. Blocking file/transport work stays
  behind the existing queues, actors, coordinators, and repositories.
- The existing one `OpenAICompatibleProviderManaging` repository is shared by
  provider settings, ASR, and Meeting Intelligence. An active job keeps its
  immutable snapshot; a saved profile affects future jobs only.
- The existing one `RecordingSessionMutationGate` is shared by transcript,
  metadata, Meeting Intelligence artifact/title, and Library mutations.
- Feature models expose immutable presentation/snapshot values and typed
  commands/events. They do not mutate sibling `@Published` properties.
- `TranscriptionFeatureModel` imports no Meeting Intelligence types and owns no
  LLM state. `MeetingIntelligenceFeatureModel` owns exactly one injected
  `MeetingIntelligenceJobCoordinator` and owns no ASR state.
- High-frequency ASR, MI, and playback updates publish only their feature
  presentation. `AppModel.objectWillChange` must not relay those updates.
- `ContentView` alone constructs and retains the playback and Teams-countdown
  presenters. Neither a feature model nor `AppModel` constructs an AppKit
  playback presenter.
- Each implementation commit is rollback-safe, compiles, and passes its
  focused tests. Do not leave an unused skeleton or a half-cut-over owner in a
  commit.
- Preserve root-worktree user files. In particular, never stage unrelated
  `.superpowers/`, `docs/Local-Meeting-Recorder-Setup-Tutorial-zh-Hant.md`,
  `docs/assets/`, Python caches, or Windows paths.

## Plan Acceptance Checkpoint

Before production or test implementation, review and commit only this plan:

```bash
git add docs/superpowers/plans/2026-08-01-pr-b-feature-boundaries.md
git diff --cached --check
git commit -m "docs: plan PR B feature boundaries"
```

## Exact Ownership and File Map

### Files to create

| File | Responsibility |
|---|---|
| `Sources/RecorderApp/Library/LibraryFeatureEvents.swift` | immutable workspace, mutation, save, import, removal, transcript-index, and Library refresh contracts |
| `Sources/RecorderApp/Library/LibraryFeatureModel.swift` | canonical sessions, refresh/recovery/search generations, transcript/metadata mutation, import, trash, targeted reload |
| `Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift` | immutable ASR presentation, Start/Cancel, transcript/log projections, one `TranscriptPublished` output |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublication.swift` | immutable MI publication identity, kind, title outcome, and semantic event |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceFeatureModel.swift` | availability, Generate/Regenerate/Retry/Cancel/Apply, stale presentation, one MI coordinator |
| `Sources/RecorderApp/Playback/PlaybackFeatureModel.swift` | playback load lifecycle, active session, transport, and existing presentation model |
| `Sources/RecorderApp/PRBFeatureEvents.swift` | phase-neutral workspace-change, provider-save, and recording-finalization semantic contracts reused by the bridge and later PR C |
| `Sources/RecorderApp/PRBFeatureBoundaries.swift` | aggregate injection seam containing exactly the four already-constructed boundaries |
| `Sources/RecorderApp/PRBFeatureBridge.swift` | phase-owned typed subscriptions/admission only; no feature lifecycle state |
| `Tests/RecorderAppTests/LibraryFeatureModelTests.swift` | Library owner, refresh/search/mutation/import/trash tests |
| `Tests/RecorderAppTests/TranscriptionFeatureModelTests.swift` | ASR-only boundary, projection, cancellation, snapshot, publication tests |
| `Tests/RecorderAppTests/MeetingIntelligenceFeatureModelTests.swift` | MI-only commands/presentation/publication and single-coordinator tests |
| `Tests/RecorderAppTests/PlaybackFeatureModelTests.swift` | load/snapshot/transport/shutdown/publication-scope tests |
| `Tests/RecorderAppTests/PRBFeatureBridgeTests.swift` | ordering, at-most-once admission, workspace, import, trash, provider, shutdown tests |
| `Tests/RecorderAppTests/AppModelPRBFeatureBoundaryTests.swift` | exact injection, no fallback construction, forwarder, and publication-scope tests |

### Files to modify

| File | PR B change |
|---|---|
| `Sources/RecorderApp/AppModel.swift` | construct/retain or inject four boundaries; retain/start/stop bridge; replace old mutable owners with read-only projections and command forwarding |
| `Sources/RecorderApp/RecordingModels.swift` | add value-semantic `Sendable` conformance to `RecordingHealthReport`/`RecordingResult` only as needed by the immutable finalization event |
| `Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift` | close UI projection setters and add narrow projection mutation methods used only by the ASR boundary; lifecycle remains here |
| `Sources/RecorderApp/Transcription/TranscriptPublication.swift` | add value-semantic `Hashable` conformance to transcript revision/workspace fence so typed bridge identities can be deduped without a parallel key |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceJobCoordinator.swift` | emit one typed durable publication, expose immutable presentation through the MI boundary, preserve tasks/generations/leases here |
| `Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublisher.swift` | return enough immutable durable outcome detail for the typed event; do not change artifact/title semantics |
| `Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift` | observe the one MI feature directly for presentation/commands; do not restore an AppModel publication relay |
| `Sources/RecorderApp/UI/RecordingsLibraryView.swift` | observe the four focused boundaries used by the Library destination; remove giant mutable `AppModel` observation dependency while keeping current action/UI parity |
| `Sources/RecorderApp/ContentView.swift` | observe playback feature active-session projection while retaining presenter construction/lifetime locally |
| `Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift` | emit a typed successful-save notification only after repository commit; do not change draft or active-profile semantics |
| `Tests/RecorderAppTests/AppModelPlaybackTests.swift` | retain command parity, whole-model publication, presenter, and `AVPlayerView` isolation regressions |
| `Tests/RecorderAppTests/AppModelTranscriptionTests.swift` and `Tests/RecorderAppTests/AppModelMuteTests.swift` | replace direct mutable ASR fixture writes with the sole feature/coordinator path |
| `Tests/RecorderAppTests/AppModelMeetingIntelligenceIntegrationTests.swift` and `Tests/RecorderAppTests/MeetingIntelligenceJobCoordinatorTests.swift` | retain publication ordering, cancellation, durable commit, and title behavior through the new feature/bridge |
| `Tests/RecorderAppTests/AIProviderSettingsModelTests.swift` | prove provider save event occurs once after commit and zero times after failure |
| `Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift` and `RecorderWorkspaceRenderTests.swift` | preserve detail actions, focused observation, 860×680 navigation, and presenter isolation |

### Files intentionally unchanged

- `Package.swift`, workflows, Info.plist, entitlements, schemas, prompts, and
  transport retry/redirect code.
- `Sources/RecorderApp/Views/PlaybackWindow.swift` and
  `Sources/RecorderApp/Views/RecordingPlaybackView.swift` presenter ownership.
- Capture, RecordingEngine, Teams, virtual microphone, and Windows sources.
- `AppRuntime` floating recording-panel ownership, except a test-only
  initializer seam only if compilation proves it is strictly required.

## Source-to-Destination Ownership Matrix

| Current source in `AppModel` | New owner | Temporary AppModel surface |
|---|---|---|
| `sessions` mutable list | `LibraryFeatureModel.snapshot.sessions` | read-only computed projection |
| recording session loader/reloader/search loader/recovery/trash handler | `LibraryFeatureModel.Dependencies` | none |
| Library loading queue; refresh/search/MI-reload generations; recovered folders | `LibraryFeatureModel` private state | none |
| `refreshSessions`, affected search rebuild, canonical MI reload | `LibraryFeatureModel` commands | forwarding commands only |
| transcript read/save, metadata save/favorite, import mutation, trash mutation | `LibraryFeatureModel` using shared mutation gate/repositories | UI-adapter actions forward; AppKit panels remain outside feature |
| `transcriptionCoordinator` construction/reference | exactly one `TranscriptionFeatureModel` wrapping exactly one coordinator | read-only feature reference and command forwarding |
| ASR visible status/session/state/transcript/log projections | `TranscriptionFeatureModel.presentation` | read-only compatibility projections only |
| ASR projection writes after load/save/trash/workspace | typed Transcription feature commands | none |
| `meetingIntelligenceCoordinator` construction/reference | exactly one `MeetingIntelligenceFeatureModel` wrapping exactly one coordinator | read-only feature reference and command forwarding |
| MI availability/summary/title/stale presentation and commands | `MeetingIntelligenceFeatureModel` | read-only projection and command forwarding |
| MI affected-session Library reload generation | `LibraryFeatureModel` | none; it is Library lifecycle, not MI lifecycle |
| playback coordinator/load task/load generation/active session | `PlaybackFeatureModel` | read-only active session/presentation and command forwarding |
| playback window presenter | remains `ContentView` | no presenter stored by model/feature |
| ASR → Library → MI, MI → Library, import → ASR, trash fan-out callbacks | `PRBFeatureBridge` retained by AppModel | explicit start/stop/shutdown only |
| `outputFolder` and `workspacePublicationFence` | remains `AppModel` in PR B | emits one immutable `WorkspaceFolderChanged` into bridge |
| provider repository and `AIProviderSettingsModel` | remains one AppModel construction in PR B | typed save event; active job snapshots unchanged |
| global `statusMessage` and AppKit pick/open/copy/export adapters | remains `AppModel` compatibility surface | low-frequency typed status/adapters only |

## Typed Event Contracts

Names may be adjusted only to match existing domain vocabulary; identity and
delivery semantics may not be weakened.

```swift
struct LibraryWorkspaceSnapshot: Equatable, Sendable {
    let folder: URL
    let fence: WorkspacePublicationFence
}

struct WorkspaceFolderChanged: Equatable, Sendable {
    let workspace: LibraryWorkspaceSnapshot
}

struct LibraryMutationIdentity: Hashable, Sendable {
    let librarySourceID: UUID
    let mutationID: UUID
    let sessionID: RecordingSession.ID
    let normalizedSessionFolder: URL
    let transcriptRevision: TranscriptDocumentRevision?
    let workspaceFence: WorkspacePublicationFence
}

struct LibraryTranscriptProjectionCommitted: Sendable {
    let identity: LibraryMutationIdentity
    let publication: TranscriptPublished
    let canonicalSession: RecordingSession
}

struct TranscriptEdited: Sendable {
    let identity: LibraryMutationIdentity
    let canonicalSession: RecordingSession
}

struct ImportedAudioSessionReady: Sendable {
    let identity: LibraryMutationIdentity
    let canonicalSession: RecordingSession
}

struct SessionRemoved: Sendable {
    let identity: LibraryMutationIdentity
}

enum LibraryEditableArtifact: Hashable, Sendable {
    case transcript
    case metadata
}

struct LibrarySaveOutcome: Equatable, Sendable {
    let sessionID: RecordingSession.ID
    let savedArtifacts: Set<LibraryEditableArtifact>
    let failures: [LibrarySaveFailure]
}

struct LibrarySaveFailure: Equatable, Sendable {
    let artifact: LibraryEditableArtifact
    let userMessage: String
}

enum MeetingIntelligencePublicationKind: Hashable, Sendable {
    case artifactAndAutomaticTitle
    case explicitSuggestedTitle
}

enum MeetingIntelligenceTitleOutcome: Equatable, Sendable {
    case applied
    case preserved
    case warning(String)
    case explicitApplied
}

struct MeetingIntelligencePublicationIdentity: Hashable, Sendable {
    let coordinatorInstanceID: UUID
    let sessionID: RecordingSession.ID
    let normalizedSessionFolder: URL
    let generation: UInt64
    let attemptID: UUID
    let transcriptRevision: TranscriptDocumentRevision
    let workspaceFence: WorkspacePublicationFence
    let kind: MeetingIntelligencePublicationKind
}

struct MeetingIntelligencePublished: Sendable {
    let identity: MeetingIntelligencePublicationIdentity
    let canonicalSession: RecordingSession
    let artifact: MeetingIntelligenceArtifact?
    let titleOutcome: MeetingIntelligenceTitleOutcome
}

struct ProviderSettingsSaved: Equatable, Sendable {
    let profileRevision: UUID
}

enum RecordingSourceMetadataPublicationOutcome: Equatable, Sendable {
    case saved
    case warning(String)
}

struct RecordingFinalizationOutcome: Equatable, Sendable {
    let finalizationID: UUID
    let folder: URL
    let workspaceFence: WorkspacePublicationFence
    let recordingURL: URL
    let health: RecordingHealthReport
    let metadataOutcome: RecordingSourceMetadataPublicationOutcome
    let source: RecordingSource
}
```

Rules:

1. `TranscriptPublished` stays the one ASR durable event produced by the
   existing coordinator. The bridge validates source, session/folder,
   transcript revision, and workspace fence, then admits each identity once.
2. Library emits `LibraryTranscriptProjectionCommitted` only after the
   canonical session and bounded search document are committed. Only then may
   the bridge pass the original ASR publication to MI once.
3. A successful transcript edit emits `TranscriptEdited` only after persistence
   and the affected search rebuild. MI marks stale and starts zero automatic
   jobs.
4. A generated MI artifact and automatic-title result emit one combined event.
   Explicit Apply emits a later event only when metadata actually changes.
5. MI cancellation/failure before durable commit emits zero events. If durable
   commit wins a cancellation race, exactly one event is emitted even if UI
   presentation remains cancelled.
6. Library tombstones a successfully trashed session before emitting
   `SessionRemoved`; a failed trash emits none. Queued ASR/MI events for that
   tombstone are rejected.
7. Import emits `ImportedAudioSessionReady` only after one canonical current-
   workspace session exists. The bridge asks Transcription to start once;
   provider ineligibility retains the session and starts zero jobs.
8. `ProviderSettingsSaved` occurs only after repository save. The event never
   replaces an active ASR/MI snapshot; the next attempt captures the repository
   state normally. `profileRevision` is an opaque event/commit identity created
   after a successful save; it is not persisted and is not a second provider
   repository or mutable provider-state authority.
9. `AppModel.finishRecording` adapts a non-nil existing `RecordingResult` only
   after the source-metadata write attempt settles into one immutable
   `RecordingFinalizationOutcome`. Library accepts each `finalizationID` once,
   refreshes only a selected matching fence, and treats a metadata warning as
   part of the same one refresh. A nil/no-active result emits no outcome.

## Cross-feature Flow and Ordering Matrix

| Producer | Bridge order | Named consumer/result |
|---|---|---|
| Transcription durable publication | validate/dedupe → Library commit → receive Library committed event | MI automatic admission once; ASR success remains independent of MI result |
| Library transcript edit | persist → index once → emit | MI stale once; zero automatic generation |
| MI durable publication | validate/dedupe → Library targeted reload/index once | no ASR restart and no second transcript/finalization event |
| successful audio import | canonical Library insert → emit | Transcription eligibility/start once or provider recovery/zero start |
| successful trash | Library tombstone → emit | stop active playback, remove ASR projection, cancel/remove MI |
| workspace change | AppModel advances sole fence → bridge event | Library clears/invalidates/refreshes once; ASR advances same fence; MI resets old workspace |
| provider save | repository commit → typed notification | future attempts only; active snapshots unchanged |
| recording finalization | `AppModel.finishRecording` waits for existing media result + source-metadata attempt → one immutable outcome | Library accepts matching fence/ID once; metadata warning is still one refresh; nil result is zero |

## Construction and Callback Cutover

The final `AppModel` initializer accepts an optional aggregate:

```swift
@MainActor
struct PRBFeatureBoundaries {
    let library: LibraryFeatureModel
    let transcription: TranscriptionFeatureModel
    let meetingIntelligence: MeetingIntelligenceFeatureModel
    let playback: PlaybackFeatureModel
}
```

- With an injected aggregate, `AppModel` retains those exact four instances
  and executes no default feature/coordinator factories.
- Without one, AppModel builds the shared provider repository and mutation
  gate once, then the ASR and MI coordinators once, then the four features.
- The MI default factory is called only after the Transcription feature exists,
  so `expectedPublicationSourceID` is exactly
  `transcriptionFeature.publicationSourceID`.
- If an intermediate test seam permits either an injected MI feature or an MI
  factory, they are mutually exclusive by precondition; the old coordinator
  factory is removed rather than retained as a second construction path.
- `PRBFeatureBridge.start()` replaces old callback registrations before it
  accepts events. `shutdown()` first closes admission, then unregisters
  producer callbacks/subscriptions, then features/coordinators are cancelled.
- The bridge may retain cancellables, callback replacement handles, an
  admission epoch, and bounded accepted semantic identities. It owns no
  session list, job, playback load, feature generation, workspace URL, or
  mutable feature presentation.

## Task 1: Playback Feature Boundary

**Files:** create `Playback/PlaybackFeatureModel.swift` and
`PlaybackFeatureModelTests.swift`; modify `AppModel.swift`, `ContentView.swift`,
and `AppModelPlaybackTests.swift`.

**Rollback commit:** `refactor: add playback feature boundary`

- [ ] Write focused RED tests before production changes:
  - `testPlaybackFeatureAcceptsOnlyCurrentLoadAndSnapshotGeneration`
  - `testFailedLoadClearsOnlyTheOwnedActiveSession`
  - `testStopIfActiveIgnoresAnotherSessionAndStopsMatchingSession`
  - `testShutdownIsIdempotentAndSuppressesLateSnapshots`
  - `testContentViewAloneRetainsPlaybackPresenter`
  - preserve `testVideoPlaybackIsNotEmbeddedInMainContentHierarchy`.
- [ ] In `AppModelPlaybackTests`, write the integration RED
  `testPeriodicSnapshotsPublishPlaybackPresentationWithoutRepublishingAppModel`;
  the feature unit suite observes only the feature/presentation publisher and
  does not import an artificial AppModel dependency.
- [ ] Prove RED:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter PlaybackFeatureModelTests
  ```

  Expected first failure: `PlaybackFeatureModel` is not in scope.
- [ ] Implement the minimum `@MainActor PlaybackFeatureModel`:
  - retain exactly one existing `PlaybackCoordinating` instance;
  - own the load task/generation and active session identity;
  - own/use the existing `PlaybackPresentationModel`;
  - expose `play`, `toggle`, `seek`, `stop`, `stopIfActive`, and idempotent
    `shutdown` commands;
  - accept only owned snapshots and never create an AppKit presenter.
- [ ] Replace AppModel playback stored state/task/generation with one feature
  reference and read-only/command forwarders. Do not subscribe AppModel to
  periodic feature changes.
- [ ] Make `ContentView` observe the same Playback feature for active-session
  presentation while it remains the sole presenter factory/retainer.
- [ ] Run focused GREEN:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'PlaybackFeatureModelTests|AppModelPlaybackTests|AppRuntimeTests|RecordingControllerPanelTests'
  git diff --check
  ```

- [ ] Get separate spec-compliance and code-quality reviews, fix findings,
  stage only Task 1 paths, run `git diff --cached --check`, and commit.

## Task 2: Transcription Feature Boundary

**Files:** create `TranscriptionFeatureModel.swift` and tests; modify
`TranscriptionJobCoordinator.swift`, `AppModel.swift`,
`AppModelTranscriptionTests.swift`, and any fixture that writes old mutable ASR
projections directly.

**Rollback commit:** `refactor: add transcription feature boundary`

- [ ] Write focused RED tests before production changes:
  - `testUnconfiguredProviderPublishesRecoveryWithoutStartingAJob`
  - `testStartUsesInjectedCoordinatorAndOneImmutableProviderSnapshot`
  - `testSecondStartWhileActiveTakesNoSecondSnapshot`
  - `testSuccessProjectsStateTranscriptAndLogAndEmitsOnePublication`
  - `testCancelDuringPreparationRoutesToCoordinatorAndSettlesCancelled`
  - `testLoadedStatesInterruptPersistedWorkButPreserveLiveAttempt`
  - `testWorkspaceChangeUsesThePassedFenceAndClearsOldProjections`
  - `testRemoveProjectionRemovesOnlyTheRequestedSession`
  - `testShutdownIsIdempotentAndSuppressesLatePublication`.
- [ ] Prove RED:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter TranscriptionFeatureModelTests
  ```

  Expected first failure: `TranscriptionFeatureModel` is not in scope.
- [ ] Add narrow coordinator projection mutation methods; keep active task,
  attempt/generation, immutable provider snapshot, artifact publication, state
  persistence, and `TranscriptPublished` construction inside the coordinator.
- [ ] Implement the feature as a thin observation/command boundary with an
  immutable `TranscriptionFeaturePresentation`, `publicationSourceID`, one
  coordinator callback chain, and no `Task`, generation, attempt, provider
  draft, or MI reference.
- [ ] AppModel constructs or retains one feature, forwards Start/Cancel,
  workspace fence, loaded state, transcript/log resolution, transcript-save
  projection synchronization, removal, and shutdown. Transcript persistence
  and indexing remain Library-owned; the post-commit synchronization only
  updates the ASR URL/state presentation and must never emit a second
  `TranscriptPublished`.
- [ ] Preserve the existing provider admission recovery string and ensure the
  job coordinator remains the only owner that captures the provider snapshot
  before preparation.
- [ ] Run focused GREEN:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'TranscriptionFeatureModelTests|TranscriptionJobCoordinatorTests|AppModelTranscriptionTests|AppModelMuteTests|AppModelMeetingIntelligenceIntegrationTests'
  git diff --check
  ```

- [ ] Review, fix, stage only Task 2 paths, run cached diff check, and commit.

## Task 3: Library Feature Boundary

**Files:** create `LibraryFeatureEvents.swift`, `LibraryFeatureModel.swift`,
`LibraryFeatureModelTests.swift`, and
`AppModelLibraryFeatureIntegrationTests.swift`; modify `AppModel.swift`,
`RecordingsLibraryView.swift`, and affected existing Library/UI tests.

**Review-bounded implementation deviation:** moving audio import behind the
asynchronous Library boundary exposed the existing second-granularity folder
collision as an ownership hazard. Task 3 therefore also modifies
`RecordingSession.swift` to create one UUID-owned, no-replace import folder and
to roll back only that newly created folder after copy or metadata failure.
This preserves the existing import product behavior; it does not add a new
user-facing capability.

**Rollback commit:** `refactor: move library state into feature model`

- [ ] Cycle 3.1 RED — owner and canonical snapshot:
  - `testAppModelRetainsExactlyTheInjectedLibraryFeatureInstance`
  - `testAppModelSessionsIsReadOnlyProjectionOfLibrarySnapshot`
  - `testLibraryPublicationDoesNotRepublishAppModel`
  - `testRefreshPublishesCanonicalSessionsFromTheLoadingQueue`.
- [ ] Run Cycle 3.1 focused tests and observe the missing-model/owner RED;
  implement only the unique owner/snapshot path, then rerun the same focused
  test cases to GREEN before writing Cycle 3.2 tests.
- [ ] Cycle 3.2 RED — refresh/search/workspace:
  - `testLatestRefreshGenerationWins`
  - `testRecoveryRunsOncePerWorkspaceFence`
  - `testWorkspaceChangeClearsOldProjectionBeforeOneRefresh`
  - `testOldWorkspaceRefreshAndTranscriptCompletionAreRejected`
  - `testSearchRebuildUsesCurrentCanonicalMetadataForAStaleInputSession`.
- [ ] Run Cycle 3.2 cases and observe stale/latest-generation failures;
  implement refresh, recovery, search, and immutable workspace admission only,
  then rerun those cases to GREEN before writing Cycle 3.3 tests.
- [ ] Cycle 3.3 RED — transcript/metadata/MI refresh:
  - `testTranscriptPublicationEmitsCommittedOnlyAfterSearchRebuild`
  - `testTranscriptEditPersistsAndReindexesBeforeEmittingEdited`
  - `testTranscriptFailureEmitsNoEditedEventAndReturnsFailure`
  - `testMetadataSaveReloadsCanonicalTitleTagsFavoriteAndSearchDocument`
  - `testMetadataSavePreservesExistingTitleOriginWhenTitleIsUnchanged`
  - `testLatestMeetingIntelligenceTargetedReloadWins`
  - `testOldWorkspaceMeetingIntelligencePublicationIsIgnored`.
- [ ] Run Cycle 3.3 cases and observe missing/early typed outcomes; implement
  mutation-gated transcript/metadata and targeted MI reload only, then rerun
  those cases to GREEN before writing Cycle 3.4 tests.
- [ ] Cycle 3.4 RED — import/trash:
  - `testCurrentWorkspaceImportPublishesOneCanonicalReadyEvent`
  - `testObsoleteOrFailedImportPublishesNoReadyEvent`
  - `testTrashTombstonesBeforeOneRemovalEvent`
  - `testTrashFailureKeepsCanonicalSessionAndEmitsNothing`.
- [ ] Run Cycle 3.4 cases and observe missing canonical ready/tombstone events;
  implement import/trash only, then rerun them to GREEN.
- [ ] The focused command for every Cycle 3.x RED and GREEN is:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter LibraryFeatureModelTests
  ```

- [ ] Move the exact Library dependencies, loading queue, refresh/search and
  targeted-reload generations, recovered-folder admission, canonical list,
  transcript/metadata persistence, import, and trash state into one feature.
  The feature receives immutable current workspace context; AppModel still
  owns and advances the only fence.
- [ ] Preserve the shared mutation gate and current canonical-session checks.
  Search rebuilds use current metadata and bounded transcript content.
- [ ] Expose async typed save outcomes. The transcript/metadata editor
  dismisses or clears only the artifact confirmed saved; a failure preserves
  the draft and shows its existing user-facing recovery.
- [ ] `RecordingsLibraryView` observes Library directly for sessions/search
  revisions, and receives the other three boundaries only for their focused
  projections/commands. It does not regain a monolithic observation relay.
- [ ] Remove mutable Library state/generations/tasks from AppModel; retain only
  read-only session projection and UI-adapter/command forwarding.
- [ ] Run focused GREEN after each cycle, then the combined gate:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'LibraryFeatureModelTests|AppModelLibraryFeatureIntegrationTests|RecordingLibraryTests|RecordingLibraryQueryTests|ManualTranscriptionImporterTests|MeetingIntelligenceSheetRenderTests'
  git diff --check
  ```

- [ ] Review, fix, stage only Task 3 paths, cached diff check, and commit.

## Task 4: Typed Meeting Intelligence Publication and Feature Boundary

**Files:** create `MeetingIntelligencePublication.swift`,
`MeetingIntelligenceFeatureModel.swift`, and tests; modify
`TranscriptPublication.swift`, the MI coordinator, publisher, `AppModel.swift`,
`MeetingIntelligenceSectionView.swift`, and related coordinator/integration
tests.

**Rollback commits:**

1. `refactor: type meeting intelligence publication`
2. `refactor: add meeting intelligence feature boundary`

- [ ] Cycle 4.1 RED — durable typed publication:
  - `testAutomaticPublicationCarriesCoordinatorSessionAttemptTranscriptWorkspaceAndKind`
  - `testArtifactAndAutomaticTitleEmitOneCombinedPublication`
  - `testProtectedAutomaticTitleIsOnePreservedOutcomeNotASecondEvent`
  - `testExplicitApplyEmitsOnlyWhenMetadataActuallyChanges`
  - `testCancellationBeforeDurableCommitEmitsNothing`
  - `testCancellationAfterDurableCommitStillEmitsExactlyOnce`
  - `testFailureOrNoOpBeforeCommitEmitsNothing`.
- [ ] Add a compile-time value-contract test proving
  `TranscriptDocumentRevision`, `WorkspacePublicationFence`, and both new
  semantic identities satisfy `Hashable & Sendable`; add those conformances in
  `TranscriptPublication.swift` rather than creating a parallel dedupe key.
- [ ] Prove RED in the existing coordinator suite, then minimally add typed
  identity/outcome. The coordinator generates one instance ID and includes the
  current ticket generation/attempt. Automatic work inherits the originating
  ASR workspace fence; manual commands receive an immutable current fence at
  admission. Do not add a mutable workspace owner to MI.
- [ ] Keep publisher linearization semantics unchanged. A successful publisher
  return remains the durable boundary; typed event delivery cannot be
  suppressed by later cancellation ownership checks.
- [ ] Focused GREEN for publication:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter MeetingIntelligenceJobCoordinatorTests
  ```

- [ ] Cycle 4.2 RED — feature wrapper:
  - `testFeatureRetainsAndCommandsExactlyOneInjectedCoordinator`
  - `testAvailabilityGenerateRegenerateRetryCancelAndApplyDelegateOnce`
  - `testPresentationIsAnImmutableCoordinatorProjection`
  - `testTranscriptPublishedStartsOnlyTheCoordinatorAutomaticPath`
  - `testTranscriptEditedMarksStaleAndStartsNoAutomaticGeneration`
  - `testWorkspaceChangeResetsTheOnlyCoordinator`
  - `testRemoveAndShutdownAreIdempotentAndSuppressLateEvent`.
- [ ] Implement a thin MI boundary; keep coordinator tasks, generations,
  attempts, leases, sessions, publication identities, and persistence in the
  coordinator. Move UI-facing commands and presentation access to the feature.
- [ ] AppModel uses exactly one mutually exclusive path: injected MI feature or
  one factory/default creation after Transcription source identity is known.
  Remove the old direct MI coordinator factory/reference.
- [ ] Run focused GREEN:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'MeetingIntelligenceFeatureModelTests|MeetingIntelligenceJobCoordinatorTests|MeetingIntelligenceSuggestedTitleApplierTests|MeetingIntelligenceSheetRenderTests|AppModelMeetingIntelligenceIntegrationTests'
  git diff --check
  ```

- [ ] Review and commit the typed-publication and feature slices separately so
  either can be reverted without leaving two owners.

## Task 5: Aggregate Injection and Typed PR B Feature Bridge

**Files:** create `PRBFeatureEvents.swift`, `PRBFeatureBoundaries.swift`,
`PRBFeatureBridge.swift`, and their tests; modify `RecordingModels.swift`,
`AppModel.swift`, `AIProviderSettingsModel.swift`,
`ContentView.swift`, `RecordingsLibraryView.swift`, and integration tests.

**Rollback commit:** `refactor: connect PR B feature boundaries`

- [ ] Write aggregate/injection RED tests:
  - `testAppModelConstructsExactlyOneOfEachPRBFeature`
  - `testAppModelRetainsTheFourInjectedInstancesExactly`
  - `testInjectedAggregateConstructsNoFallbackFeatureOrCoordinator`.
- [ ] Write bridge ordering/dedupe RED tests:
  - `testTranscriptPublicationCommitsLibraryBeforeOneMIAdmission`
  - `testDuplicateForgedStaleAndOldWorkspaceASREventsReachNoConsumerTwice`
  - `testMIFailureOrUnavailabilityLeavesCompletedASRAndIndexedTranscript`
  - `testTranscriptEditIndexesOnceMarksMIStaleOnceAndStartsZeroJobs`
  - `testMIDurablePublicationReloadsLibraryOnceAndNeverRestartsASR`
  - `testEligibleImportStartsOneASRAndIneligibleImportRetainsSessionWithZeroJobs`
  - `testTrashFanoutRunsOnlyAfterLibraryTombstone`
  - `testWorkspaceChangeUsesOnlyAppModelFolderAndExistingFence`
  - `testOldWorkspaceASRMayFinishOnDiskButCannotUpdateVisibleLibrary`
  - `testWorkspaceChangeCancelsMIAndRejectsDelayedVisibleCallback`
  - `testProviderSaveDuringActiveASRAndMIAffectsOnlyLaterAttempts`
  - `testProviderSaveEmitsOnceOnlyAfterRepositoryCommit`
  - `testFailedProviderSaveEmitsNoEvent`
  - `testRecordingFinalizationRefreshesLibraryExactlyOnceAfterMediaAndMetadataSettle`
  - `testNoActiveRecordingEmitsNoFinalizationAndNoRefresh`
  - `testObsoleteWorkspaceFinalizationDoesNotChangeVisibleLibrary`
  - `testMetadataWarningRemainsOneFinalizationAndOneRefresh`
  - `testRecordingFinalizationOutcomeIsAnImmutableSendableValue`.
- [ ] Prove RED:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'PRBFeatureBridgeTests|AppModelPRBFeatureBoundaryTests'
  ```

- [ ] Implement the aggregate injection seam and one bridge. Replace old
  callback wiring before bridge admission opens. Use bounded at-most-once
  semantic identity admission and typed commands only.
- [ ] Route the existing AppModel actions exactly:

  | Current action | Final PR B route |
  |---|---|
  | `refreshSessions()` | `library.refresh()` |
  | `chooseAudioFileForTranscription()` | AppKit picker → `library.importAudio(...)`; bridge owns the one ASR request |
  | `transcribe(session:)` / `cancelTranscription()` | `transcription.requestStart` / `transcription.cancel` |
  | `transcriptText`, `saveTranscript`, `saveMetadata`, `moveSessionToTrash` | Library typed query/commands |
  | `play`, `playbackToggle`, `stopPlayback`, `seekPlayback` | Playback feature commands |
  | MI check/generate/regenerate/retry/cancel/apply title | Meeting Intelligence feature commands |
  | `setOutputFolder` | advance existing fence once → one typed workspace flow |
  | recording completion callback | existing semantic completion → Library refresh once |

- [ ] Ensure successful provider save sends a typed event only after repository
  commit and a failed save sends none. `profileRevision` is generated as an
  opaque successful-save event identity, not stored as another provider
  revision. Do not change picker draft behavior and do not cancel/replace
  active job snapshots; the next job must take a fresh repository snapshot.
- [ ] Ensure recording finalization remains in its existing Record/AppModel
  compatibility path. Adapt the non-nil `RecordingResult` in
  `AppModel.finishRecording` into the required immutable outcome after its
  source-metadata write attempt settles. Library dedupes by finalization ID,
  admits only the selected immutable fence, and refreshes once even with a
  metadata warning. A nil result emits none. Do not introduce PR C feature
  types or change media/metadata semantics.
- [ ] Add `Sendable` only to the existing value-semantic
  `RecordingHealthReport`/`RecordingResult` types needed by the immutable
  outcome. Do not move health ownership or add a second live health model.
- [ ] Run bridge and cross-feature GREEN:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'PRBFeatureBridgeTests|AppModelPRBFeatureBoundaryTests|LibraryFeatureModelTests|TranscriptionFeatureModelTests|MeetingIntelligenceFeatureModelTests|PlaybackFeatureModelTests|AppModelTranscriptionTests|AppModelMeetingIntelligenceIntegrationTests|AppModelPlaybackTests'
  git diff --check
  ```

- [ ] Review, fix, stage only Task 5 paths, cached diff check, and commit.

## Task 6: Shutdown, Publication Scope, UI Cutover, and Debt Removal

**Files:** all PR B boundary/bridge/UI files and focused tests; no new product
surface.

**Rollback commit:** `refactor: complete PR B ownership cutover`

- [ ] Write lifecycle/publication-scope RED tests:
  - `testBridgeStartRegistersEachProducerOnceAndIsIdempotent`
  - `testShutdownClosesAdmissionBeforeFeatureCancellation`
  - `testQueuedCallbackAfterShutdownHasNoConsumerVisibleEffect`
  - `testDurablePublicationAdmittedBeforeShutdownSettlesAtMostOnce`
  - `testAppModelShutdownIsIdempotent`
  - `testLibraryRefreshPublishesOnlyLibrary`
  - `testASRProgressPublishesOnlyTranscription`
  - `testMIProgressPublishesOnlyMeetingIntelligence`
  - `testPlaybackPositionPublishesOnlyPlayback`
  - `testRecordingsDestinationObservesFocusedFeaturesNotAppModelChanges`
  - retain the AppKit-hosted 860×680 repeated navigation/render test and
    `AVPlayerView` isolation regression from PR A.
- [ ] Implement deterministic shutdown order:
  1. close bridge admission and advance its stale-delivery epoch;
  2. unregister/clear ASR, MI, Library, Playback, and provider callbacks;
  3. cancel bridge subscriptions;
  4. shut down feature models in deterministic order;
  5. let their existing coordinators cancel/settle work;
  6. preserve `AppRuntime` floating-panel shutdown before model shutdown.
- [ ] Remove the last old mutable owners from AppModel. Read-only computed
  compatibility projections and command forwarding may remain for PR C, but
  no Library refresh/search/MI-reload generations, ASR maps/tasks, MI
  presentation/lifecycle dictionaries, or playback task/generation/session
  storage may remain.
- [ ] Confirm views observe each focused feature directly where periodic state
  is displayed. Keep global low-frequency status and AppKit adapter actions on
  the compatibility model.
- [ ] Run focused GREEN:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --filter 'PRBFeatureBridgeTests|AppModelPRBFeatureBoundaryTests|RecorderWorkspaceRenderTests|AppModelPlaybackTests|AppModelTranscriptionTests|AppModelMeetingIntelligenceIntegrationTests|AppRuntimeTests|RecordingControllerPanelTests'
  git diff --check
  ```

- [ ] Run reference audits as review evidence, not brittle source-layout unit
  tests:

  ```bash
  rg -n 'recordingSessionRefreshGeneration|meetingIntelligenceSessionReloadGenerations|playbackLoadTask|playbackLoadGeneration|private let transcriptionCoordinator|private let meetingIntelligenceCoordinator' Sources/RecorderApp/AppModel.swift
  rg -n 'MeetingIntelligence|meetingIntelligence' Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift
  rg -n 'PlaybackWindowPresent|AVPlayerView' Sources/RecorderApp/Playback Sources/RecorderApp/AppModel.swift
  rg -n 'AppCoordinator|RecordFeatureModel|IntegrationsFeatureModel|SettingsFeatureModel|WorkspaceFolderRepository' Sources Tests
  ```

  Expected: first three audits have no forbidden owner/presenter matches; the
  fourth has no PR C implementation matches (approved design text is outside
  these searched paths).
- [ ] Review, fix, stage only Task 6 paths, cached diff check, and commit.

## Required Behavior Matrix Before Final Validation

| Behavior | Required automated evidence |
|---|---|
| Library canonical list, favorites, snippets | existing query/render tests plus Library snapshot tests |
| transcript publication/search | exactly one affected search commit before MI admission |
| transcript edit/search/stale MI | edited text searchable immediately; one stale projection; zero auto generation |
| provider snapshot | save changes future ASR/MI only; active attempt uses captured endpoint/auth/model |
| ASR cancellation/stale callback | existing preparation/upload/retry/response cancellation and stale-attempt suites remain green |
| MI failure isolation | unavailable/cancel/failure cannot roll back completed ASR/transcript |
| MI durable cancellation race | pre-commit zero event; post-commit exactly one Library update |
| workspace change | sole AppModel fence, old visible callback rejection, no hidden multi-workspace index |
| import | canonical session first, one eligible ASR request or zero with recovery |
| trash | physical success/tombstone before fan-out; failure changes nothing |
| playback | 10 Hz snapshots stay in playback presentation; presenter remains outside main hierarchy |
| recording finalization | one Library refresh after media and metadata attempt settle |
| teardown | callback admission closes before cancellation and no released consumer is called |

## Complete PR B Validation

Run on the final implementation SHA, after all focused suites are green. The
pull request runs the full Swift suite once; the main-only stability loop is
not duplicated here.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter OpenAICompatibleTranscriptionClientTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
/usr/bin/python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py' -v
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_packaging_contract \
  Tests.ScriptTests.test_workflow_contract -v
Tests/PackagingTests/run-tests.sh
Tests/VirtualMicDriverTests/run-tests.sh
Tests/VirtualMicDriverTests/run-bundle-tests.sh
Tests/VirtualMicDriverTests/run-script-tests.sh
git diff --check codex/meeting-intelligence-summary-title...HEAD
git diff --name-only codex/meeting-intelligence-summary-title...HEAD
if git diff --name-only codex/meeting-intelligence-summary-title...HEAD | \
  rg -q '(^|/)(Windows|windows)(/|$)|\.(cs|csproj|sln)$'; then
  echo "Windows implementation path entered PR B" >&2
  exit 1
fi
if rg -n '(^|[^A-Za-z])(AppCoordinator|RecordFeatureModel|IntegrationsFeatureModel|SettingsFeatureModel|WorkspaceFolderRepository)([^A-Za-z]|$)' \
  Sources Tests; then
  echo "PR C implementation entered PR B" >&2
  exit 1
fi
while IFS= read -r changed_path; do
  case "$changed_path" in
    docs/superpowers/specs/2026-07-30-ui-feature-boundaries-design.md|\
    docs/superpowers/plans/2026-08-01-pr-b-feature-boundaries.md|\
    Sources/RecorderApp/AppModel.swift|\
    Sources/RecorderApp/ContentView.swift|\
    Sources/RecorderApp/RecordingSession.swift|\
    Sources/RecorderApp/RecordingModels.swift|\
    Sources/RecorderApp/PRBFeatureEvents.swift|\
    Sources/RecorderApp/PRBFeatureBoundaries.swift|\
    Sources/RecorderApp/PRBFeatureBridge.swift|\
    Sources/RecorderApp/Library/LibraryFeatureEvents.swift|\
    Sources/RecorderApp/Library/LibraryFeatureModel.swift|\
    Sources/RecorderApp/Playback/PlaybackCoordinator.swift|\
    Sources/RecorderApp/Playback/PlaybackFeatureModel.swift|\
    Sources/RecorderApp/Transcription/AIProviderSettingsModel.swift|\
    Sources/RecorderApp/Transcription/TranscriptPublication.swift|\
    Sources/RecorderApp/Transcription/TranscriptionFeatureModel.swift|\
    Sources/RecorderApp/Transcription/TranscriptionJobCoordinator.swift|\
    Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceFeatureModel.swift|\
    Sources/RecorderApp/MeetingIntelligence/MeetingIntelligenceJobCoordinator.swift|\
    Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublication.swift|\
    Sources/RecorderApp/MeetingIntelligence/MeetingIntelligencePublisher.swift|\
    Sources/RecorderApp/UI/MeetingIntelligenceSectionView.swift|\
    Sources/RecorderApp/UI/RecordingsLibraryView.swift|\
    Tests/RecorderAppTests/AIProviderSettingsModelTests.swift|\
    Tests/RecorderAppTests/AppModelLibraryFeatureIntegrationTests.swift|\
    Tests/RecorderAppTests/AppModelMeetingIntelligenceIntegrationTests.swift|\
    Tests/RecorderAppTests/AppModelMuteTests.swift|\
    Tests/RecorderAppTests/AppModelPlaybackTests.swift|\
    Tests/RecorderAppTests/AppModelPRBFeatureBoundaryTests.swift|\
    Tests/RecorderAppTests/AppModelTranscriptionTests.swift|\
    Tests/RecorderAppTests/LibraryFeatureModelTests.swift|\
    Tests/RecorderAppTests/ManualTranscriptionImporterTests.swift|\
    Tests/RecorderAppTests/MeetingIntelligenceFeatureModelTests.swift|\
    Tests/RecorderAppTests/MeetingIntelligenceJobCoordinatorTests.swift|\
    Tests/RecorderAppTests/MeetingIntelligenceSheetRenderTests.swift|\
    Tests/RecorderAppTests/PlaybackFeatureModelTests.swift|\
    Tests/RecorderAppTests/PRBFeatureBridgeTests.swift|\
    Tests/RecorderAppTests/RecorderWorkspaceRenderTests.swift|\
    Tests/RecorderAppTests/RecordingLibraryQueryTests.swift|\
    Tests/RecorderAppTests/RecordingLibraryTests.swift|\
    Tests/RecorderAppTests/TranscriptionFeatureModelTests.swift|\
    Tests/RecorderAppTests/TranscriptionJobCoordinatorTests.swift)
      ;;
    *)
      echo "Unplanned path entered PR B: $changed_path" >&2
      exit 1
      ;;
  esac
done < <(git diff --name-only codex/meeting-intelligence-summary-title...HEAD)
```

Build and validate a fresh isolated staging artifact (do not install it into
`/Applications` as part of the automated gate):

```bash
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lmr-pr-b.XXXXXX")"
Scripts/build-app.sh \
  --configuration release \
  --version 0.2.0 \
  --build-number 2 \
  --bundle-id local.meeting.recorder.staging \
  --bundle-name "Local Meeting Recorder Staging" \
  --output "$STAGING_ROOT/Local Meeting Recorder Staging.app" \
  --sign ad-hoc
Scripts/verify-app-bundle.sh \
  "$STAGING_ROOT/Local Meeting Recorder Staging.app" \
  local.meeting.recorder.staging 0.2.0 2 ad-hoc
codesign --verify --deep --strict --verbose=2 \
  "$STAGING_ROOT/Local Meeting Recorder Staging.app"
if find "$STAGING_ROOT/Local Meeting Recorder Staging.app/Contents/Resources" \
  \( -iname '*.py' -o -iname '*.pyc' -o -iname '__pycache__' \
     -o -iname 'python*' -o -iname '*ffmpeg*' -o -iname '*ffprobe*' \) \
  -print -quit | rg -q .; then
  echo "Forbidden runtime helper found in staging bundle" >&2
  exit 1
fi
```

`Scripts/verify-app-bundle.sh` is the authoritative bundle-content contract;
the final assertion is an additional explicit clean-resource proof and must
produce no match. Record every command, exit status, test count, and artifact
path in the PR description. Do not call an ad-hoc signature notarized
acceptance.

The complete gate must prove:

- one unflagged full Swift suite passes on macOS 26;
- Python/script and policy tests pass;
- packaging tests pass;
- virtual microphone unit, bundle, and script suites pass;
- a freshly built staging `.app` passes strict codesign verification;
- clean bundle-content verification finds no Python, FFmpeg/FFprobe, or legacy
  runtime helper, including case variants;
- `git diff --check` passes;
- `git status --short` contains only intentional branch artifacts;
- `git diff --name-only codex/meeting-intelligence-summary-title...HEAD`
  contains no Windows implementation,
  PR C feature, workflow, package, entitlement, or unrelated documentation
  path.

Turn the final path listing into a failing scope audit rather than a visual-only
check. Allow only the approved PR B source/test/design-plan paths; fail on any
path under Windows implementation directories and on any implementation of
`AppCoordinator`, `RecordFeatureModel`, `IntegrationsFeatureModel`,
`SettingsFeatureModel`, or `WorkspaceFolderRepository`. Workflows,
`Package.swift`, entitlements, Info.plist, schemas, prompts, and provider
transport files are also outside this PR unless an approved design correction
is recorded before implementation.

Developer ID signing, Hardened Runtime, notarization, stapling,
`spctl --assess`, real-provider, live Teams, AirPods, and other hardware
acceptance remain `not run` unless actually performed with the required
authorization/environment. This PR is architecture hardening, not full
production acceptance.

## Manual Acceptance

Before marking PR B ready for approval, use the staging app at 860×680 and a
wide layout to smoke:

- Record → Recordings → Settings repeated navigation and stable selection;
- library search, favorites, and transcript snippets;
- playback open/pause/seek/close in its independent window;
- transcript edit immediately searchable without manual Refresh;
- ASR Start/Cancel and log/transcript access using an available test provider;
- MI Check/Generate/Regenerate/Retry/Cancel and summary/title presentation when
  a test provider is available;
- unavailable MI leaves transcript usable and manual generation available for
  later;
- metadata edit/favorite/trash and workspace folder switch;
- `AVPlayerView` remains absent from the main workspace hierarchy.

If provider/hardware access is unavailable, mark the exact item `not run`;
automated mocks do not convert it to a manual pass.

## PR and Stack Completion

1. Keep PR B Draft and target Draft PR #7 while #7 remains open.
2. Push only the PR B branch after all gates pass and a final independent
   scope/code review has no unresolved Critical or Important finding.
3. PR description maps each old AppModel owner to its new file, lists tests,
   validation commands/results, remaining compatibility adapter surface, and
   manual gates.
4. Do not merge PR B before PR #7. After #7 merges, fetch, rebase PR B onto the
   latest `main`, rerun the complete gate, force-push with lease, and retarget
   to `main`.
5. Only after PR B is reviewable, create PR C from PR B head. PR C has its own
   plan, branch, tests, commits, and Draft PR; it does not amend this PR.

## Rollback-safe Commit Sequence

1. `docs: plan PR B feature boundaries`
2. `refactor: add playback feature boundary`
3. `refactor: add transcription feature boundary`
4. `refactor: move library state into feature model`
5. `refactor: type meeting intelligence publication`
6. `refactor: add meeting intelligence feature boundary`
7. `refactor: connect PR B feature boundaries`
8. `refactor: complete PR B ownership cutover`

Each implementation commit must be independently green and revertible. If a
slice cannot be completed without temporarily duplicating ownership, keep the
changes unstaged, revise the slice, and do not commit the half-state.
