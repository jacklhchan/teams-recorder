# UI and Feature Boundary Refactor Design

**Date:** 2026-07-30
**Status:** Approved architecture baseline with approved macOS 26 PR A revision
and approved PR B/C Meeting Intelligence amendment
**Approved baseline SHA:** `8f110466093c9a3fabc5f5d1fad3c69afa849c53`
**Approval date:** 2026-07-30
**macOS 26 PR A revision approval:** 2026-07-31
**PR B/C amendment review:** Approved 2026-08-01
**Approved PR B/C amendment content SHA:**
`cf7c83a120610eb62bd9b32de75b02db169d4767`
**PR B stacked base:** Draft PR #7, `codex/meeting-intelligence-summary-title`
at `ab9395598505f1272f2efa7d8918b8ac69e96fd2`
**Revision dependency:** PR #5 merged at
`b84b79fefd915a97beaf8c97f667e774ef0d7ab7`
**Delivery:** Three sequential, bounded Draft pull requests
**Reference UI:** `codex/liquid-glass-recorder-ui` at `776837b`

## 1. Context

The recorder has reached a point where `AppModel` and `ContentView` are both
composition roots, lifecycle coordinators, presentation models, and UI
containers. This makes otherwise local changes risky:

- `AppModel` owns capture, permissions, recording, storage, Teams integration,
  virtual microphone state, playback, library operations, provider settings,
  transcription, Meeting Intelligence availability and job routing,
  summary/title presentation, and global status.
- `ContentView` contains the main workspace, recording controls, permissions,
  capture settings, Teams controls, virtual microphone controls, library,
  transcript editing, metadata editing, and provider settings.
- `SessionListView` receives a broad set of values and closures.
- feature-unrelated state can be observed and republished together.

The previous Liquid Glass branch established a useful presentation direction,
but it was built before the current native transcription, capture, runtime, and
P0 hardening work. Its UI contracts are a reference; its `AppModel`,
`ContentView`, application entry point, and older ASR assumptions are not safe
to merge.

## 2. Goals

1. Make `ContentView` a small workspace shell responsible for navigation,
   destination composition, and presenter lifetime only.
2. Decompose the current UI into feature-owned source files without changing
   recorder behavior.
3. Move UI-facing state and commands into focused feature models.
4. Keep lifecycle and business rules in the existing coordinators.
5. Keep persistence and credential handling in repositories.
6. Preserve exactly one owner for recording lifecycle, Teams auto-meeting
   state, playback runtime, provider storage, transcription jobs, and Meeting
   Intelligence jobs.
7. Prevent high-frequency recording or meter updates from republishing
   unrelated library, settings, or transcription views.
8. Preserve all current recorder, Teams, playback, transcription, Meeting
   Intelligence summary/title, title-origin, stale-result, library, metadata,
   and recovery behavior.
9. Deliver the work in three independently reviewable and reversible PRs.
10. Give PR B four independent UI-facing boundaries so ASR success remains
    durable and usable even when later LLM availability or generation fails.

## 3. Non-goals

This program does not add:

- timestamped transcript UI;
- new Meeting Intelligence outputs beyond the existing summary, suggested
  title, availability, regeneration, stale-result, and recovery contract,
  including action items, decisions, risks, questions, or follow-up drafts;
- new ASR providers or changes to native transcription transport;
- Windows migration or cross-platform UI work;
- recording/media format changes;
- new Teams automation behavior;
- transactional multi-artifact transcript publication;
- new local-server, MCP, or calendar integrations.

It also does not:

- create a second `AppModel`, `RecordingEngine`, or coordinator;
- replace the current runtime composition root;
- use one global `EnvironmentObject` as a renamed monolith;
- mirror mutable state between `AppModel` and a feature model;
- cherry-pick the previous Liquid Glass branch wholesale.

PR B and PR C also do not reopen the provider transport, retry limits,
artifact formats, title-origin policy, prompt contract, or automatic-generation
eligibility implemented by Draft PR #7. They move ownership without changing
those product semantics.

## 4. Delivery Strategy

The Meeting Intelligence ownership amendment considered three placements:

1. **Selected — a fourth PR B feature boundary.** This keeps ASR and LLM
   lifecycle, presentation, cancellation, and failure domains separate while
   allowing Library to remain the canonical session/search owner.
2. **Rejected — fold Meeting Intelligence into
   `TranscriptionFeatureModel`.** That would couple ASR success to LLM
   availability/generation state and recreate a large workflow feature.
3. **Rejected — leave Meeting Intelligence in `AppModel` until PR C.** That
   would make the PR B ownership cutover incomplete and force PR C to move
   live MI state while also changing the composition root.

The selected design keeps three delivery PRs. It changes the number of PR B
feature boundaries from three to four; it does not create a fourth delivery
PR.

### PR A — Workspace shell and UI source decomposition

PR A changes presentation structure only:

- selectively recreate the approved Liquid Glass navigation, style, glass,
  action-ID, and dashboard presentation primitives against current `main`;
- introduce the Record, Recordings, and Settings destinations;
- move existing UI sections out of `ContentView.swift`;
- keep all current `AppModel` state, command signatures, coordinators,
  presenters, and application runtime wiring unchanged;
- retain existing sheet-based transcript and metadata editing until their
  ownership moves in PR B;
- add pure presentation and navigation-state tests. `RecorderNavigationState`
  may define the future dirty-gate contract, but PR A does not wire that gate
  into the existing sheet editors or change their interaction semantics.

PR A must not change lifecycle ownership, provider behavior, session storage,
transcription publication, capture behavior, Teams behavior, or playback
window ownership.

### PR B — Library, transcription, Meeting Intelligence, and playback boundaries

PR B introduces:

- `LibraryFeatureModel`;
- `TranscriptionFeatureModel`;
- `MeetingIntelligenceFeatureModel`;
- the focused playback model boundary around the existing
  `PlaybackPresentationModel` and playback coordinator;
- small state snapshots and command protocols consumed by the Recordings and
  transcript UI.

During PR B, the existing single `AppModel` is the temporary construction
owner. It constructs and retains exactly one `LibraryFeatureModel`, exactly one
`TranscriptionFeatureModel`, exactly one `MeetingIntelligenceFeatureModel`, and
exactly one `PlaybackFeatureModel`. Each can also be injected as an already
constructed instance for tests and the later PR C handoff, but there is never
more than one live instance of any boundary. `AppModel` may expose read-only
projections and forwarding commands, but must not mirror those features'
mutable state, tasks, attempts, generations, leases, callback dictionaries, or
coordinator dictionaries.

`TranscriptionFeatureModel` is the ASR boundary only. It owns ASR job
presentation, Start/Cancel commands, transcription state and log projections,
and emission of the existing immutable `TranscriptPublished` event. Exactly
one injected `TranscriptionJobCoordinator` remains the lifecycle owner. The
feature neither imports Meeting Intelligence types nor invokes LLM work.

`MeetingIntelligenceFeatureModel` owns availability checking,
Generate/Regenerate/Retry/Cancel, summary and suggested-title presentation,
stale-transcript detection, and title-ownership commands. It is the sole
UI-facing boundary over exactly one injected
`MeetingIntelligenceJobCoordinator`; no sibling feature or `AppModel` retains
parallel MI attempts, tasks, generations, leases, presentations, or reload
dictionaries. “Owns availability checking” means the feature owns the
UI-facing Check command and availability presentation; the coordinator owns
the asynchronous endpoint-discovery attempt and its immutable provider
snapshot. No second provider model or editable provider state is introduced.

`LibraryFeatureModel` owns the canonical session list, search documents,
transcript and metadata refresh, imported-session publication, and move to
trash. It receives typed Transcription and Meeting Intelligence publication
events and performs only the affected session refresh/index update.

`PlaybackFeatureModel` owns playback loading, active-session identity, load and
snapshot generations, transport commands, and the existing
`PlaybackPresentationModel`. The AppKit playback-window presenter remains
owned only by `ContentView`.

Library refresh and search-document rebuild remain automatic after recording
publication, successful transcription publication, and transcript editing.
Transcription continues to use one immutable provider snapshot per job and one
shared provider repository. Meeting Intelligence availability and generation
also capture one immutable provider snapshot per attempt from that same
repository. Saving provider settings affects future ASR and MI jobs only.

PR B introduces a typed save outcome for transcript and metadata publication.
It identifies which artifact succeeded and carries a user-facing failure.
Detail drafts may become clean only for artifacts confirmed as saved; partial
failure leaves the affected draft dirty.

The corresponding private state, refresh generation, task, and lifecycle
ownership must leave `AppModel` in the same PR. Temporary `AppModel`
forwarding APIs may exist only when they delegate to the single feature owner.
`AppModel` temporarily owns the typed cross-feature bridge registrations in PR
B, not feature state. Those registrations have explicit start/stop and stale
event invalidation and are transferred once in PR C. The bridge may retain
only opaque subscription/admission tokens and a bridge-local stale-delivery
fence. These are not copied feature attempts, tasks, playback loads, session
refreshes, transcription generations, or MI generations and are inaccessible
outside the bridge.

On PR B runtime teardown, `AppModel` idempotently closes bridge admission and
unregisters its Transcription, Meeting Intelligence, Library, and Playback
callbacks before cancelling or releasing any PR B feature/coordinator. A
queued callback accepted after admission closes has no consumer-visible
effect.

PR B is a Draft stacked on Draft PR #7 so its review diff contains only the
four-boundary refactor and its tests. After PR #7 merges, PR B is rebased onto
the latest `main` and retargeted to `main`. It must never merge before its base.

### PR C — Record, integrations, settings, and composition boundary

PR C introduces:

- `RecordFeatureModel`;
- `IntegrationsFeatureModel`;
- `SettingsFeatureModel`;
- `AppCoordinator` as the explicit composition boundary;
- `WorkspaceFolderRepository` as the repository-level output/workspace-folder
  source of truth.

PR C migrates the existing `AppModel.outputFolder` and
`WorkspacePublicationFence` compatibility source into that one repository and
revision stream. The old source is removed before the repository stream is
enabled; there is no parallel live folder source.

`AppCoordinator` wires feature models, existing coordinators, repositories,
and platform adapters. It does not implement recording or Teams state machines
and does not construct AppKit presenter instances.

PR C moves construction of the four PR B feature boundaries from `AppModel`
to `AppCoordinator`. This is an ownership handoff, not a state migration:
PR C creates one instance of each feature at composition time, injects those
same instances into the narrow `AppModel` compatibility adapter, and removes
the corresponding `AppModel` construction. It never copies feature state or
allows parallel old/new instances.

At the end of PR C, one narrow `AppModel` compatibility adapter remains because
the current `AppRuntime.model`, application entry point, and floating
recording-panel presenter are typed to `AppModel`. The adapter contains no
duplicated tasks, generations, timers, lifecycle gates, persistence, or
business rules. Removing that concrete type coupling requires a later bounded
PR that changes the runtime and floating-panel presenter protocols together.

`AIProviderSettingsModel` is constructed exactly once: by `AppModel` during
PR B and by `AppCoordinator` after the PR C construction handoff, always using
the shared provider repository. `SettingsFeatureModel` owns its persisted
Settings UI projection and delegates provider edits to that model.
`TranscriptionFeatureModel` and `MeetingIntelligenceFeatureModel` read only
repository/job-coordinator results and never create or own a second editable
provider draft.

PR C is stacked on PR B while PR B remains open. After PR B merges, PR C is
rebased onto the latest `main` and retargeted. Neither PR adds product behavior
or bundles unrelated Windows work.

## 5. Target Architecture

```text
LocalMeetingRecorderApp / AppRuntime
                 |
                 v
          AppCoordinator
       |-- RecordFeatureModel
       |-- LibraryFeatureModel
       |-- TranscriptionFeatureModel
       |-- MeetingIntelligenceFeatureModel
       |-- PlaybackFeatureModel
       |-- IntegrationsFeatureModel
       `-- SettingsFeatureModel
                  |
                  v
      Existing lifecycle coordinators
   / capture / Teams / ASR / MI / playback /
                  |
                  v
      Repositories and platform adapters

 ContentView alone retains:
   playback-window presenter + Teams-countdown presenter
```

Dependency direction is one-way:

```text
SwiftUI views
  -> feature models / immutable presentations
    -> command protocols / coordinators
      -> repositories and platform adapters
```

Feature models may communicate only through typed commands or events. They
must not read or mutate a sibling feature model's private tasks, generations,
timers, or coordinator dictionaries.

The diagram is the PR C target. PR B uses `AppModel` as the temporary
construction shell and typed-event bridge owner for the four PR B feature
boundaries; it does not introduce `AppCoordinator` early.

All UI-facing feature models and `AppCoordinator` are `@MainActor`.
Long-running or blocking work remains behind existing asynchronous
coordinators, repositories, and worker queues and returns immutable results to
the main actor.

## 6. State Ownership

| State or resource | Single owner after the program | Mutation path |
|---|---|---|
| App lifetime and shutdown | `AppRuntime` | application lifecycle only |
| Feature construction and wiring | PR B: single `AppModel`; PR C: `AppCoordinator` | initializer/composition only; never parallel instances |
| Cross-feature callback registrations and bridge-admission token | PR B: single `AppModel`; PR C: `AppCoordinator` | one phase-owned bridge; token invalidates queued delivery without mirroring any feature generation; old callbacks removed before replacement |
| Active capture attempt, lifecycle generation, and auto/manual recording ownership | `RecordingSessionCoordinator` | typed recording commands |
| Stop orchestration, media/metadata finalization settlement, and semantic finalization outcome | `RecordingSessionCoordinator` using injected engine/repository operations | one typed stop/finalize command and one outcome |
| `RecordingEngine` instance lifetime and construction | PR A/B: single `AppModel`; PR C: `AppCoordinator` | composition only; exactly one injected instance |
| Runtime capture selection, resolved application, selected microphone, permissions, source-control gating, recording commands, meters, health, storage warnings, and effective recorder-mute presentation | `RecordFeatureModel` | typed record/capture commands and recorder/coordinator events |
| Teams event ordering | `TeamsIntegrationIngress` | serialized ingress drain |
| Teams countdown, debounce, and automation intent | `TeamsAutoMeetingCoordinator` | Teams events and semantic recording-outcome callbacks |
| Teams connection, pairing, Auto Meeting, and mute-sync integration projections | `IntegrationsFeatureModel` | Teams adapters, ingress, and coordinator events |
| Library sessions, refresh generation, search documents | `LibraryFeatureModel` | library commands and publication events |
| Active transcription task, generation, state, result publication | `TranscriptionJobCoordinator` exposed by `TranscriptionFeatureModel` | start/cancel and coordinator callbacks |
| ASR presentation, Start/Cancel routing, transcript/log projections | `TranscriptionFeatureModel` | typed ASR commands and immutable coordinator snapshots |
| Canonical `TranscriptPublished` identity | `TranscriptionJobCoordinator` | one durable publication event per accepted attempt |
| Meeting Intelligence active attempts, generations, leases, and semantic publication identity | one `MeetingIntelligenceJobCoordinator` exposed by `MeetingIntelligenceFeatureModel` | availability/generate/regenerate/retry/cancel/title commands and coordinator callbacks |
| Meeting Intelligence summary/title/stale/availability presentation | `MeetingIntelligenceFeatureModel` | immutable coordinator snapshots and typed commands; no copied lifecycle dictionary |
| Meeting Intelligence artifact and recovery persistence | injected MI artifact/state repositories | repository methods only; not feature-model dictionaries |
| Transcript, metadata, MI artifact, and title mutation serialization | one shared `RecordingSessionMutationGate` | injected into every session-artifact publisher/editor that mutates the same session |
| Title-origin metadata mutation | session metadata repository behind the shared mutation gate | compare-and-save title command only |
| Provider profile and secret persistence | one shared provider repository | repository methods only |
| Immutable provider job snapshot | the active ASR or MI coordinator attempt | captured before preparation/availability/generation starts; never replaced in flight |
| Playback loading/session generation | `PlaybackFeatureModel` | playback commands only |
| Playback UI snapshot | `PlaybackPresentationModel` | playback coordinator snapshots |
| Persisted preference and provider UI projection | `SettingsFeatureModel` backed by existing repositories | settings commands only; no duplicated runtime capture state |
| Editable provider settings draft | one `AIProviderSettingsModel`; PR B constructed by `AppModel`, PR C by `AppCoordinator` | delegated settings commands only |
| Selected output/workspace folder and folder revision | PR B: existing `AppModel` compatibility source; PR C onward: one `WorkspaceFolderRepository` | one phase-specific source only; repository command and change stream after PR C |
| Floating recording-panel lifetime | `AppRuntime.recordingController` | recorder-state observation and runtime shutdown |
| Playback-window presenter lifetime | workspace shell (`ContentView`) | `playingSessionID` presentation events |
| Teams-countdown presenter lifetime | workspace shell (`ContentView`) | auto-meeting presentation events |

The Settings destination is a composition surface, not a state owner. It may
render sections backed by `RecordFeatureModel`, `IntegrationsFeatureModel`,
`SettingsFeatureModel`, and `TranscriptionFeatureModel`. A section sends typed
commands to the feature that owns the state it displays.

`SettingsFeatureModel` does not retain a second live capture selection,
resolved application, microphone choice, permission state, source readiness,
Teams connection, or recorder-mute state. It renders immutable snapshots from
the owning feature only when those values are needed in Settings.

`IntegrationsFeatureModel` owns only the Teams-facing UI projection and typed
commands for connection, pairing, Auto Meeting, and mute sync. Existing Teams
adapters, transport, authorization, serialized `TeamsIntegrationIngress`,
relay callbacks, and `TeamsAutoMeetingCoordinator` retain their integration
and lifecycle ownership. The feature may invoke a narrow microphone-gate
command and publish an immutable meeting/mute context for Record.
Teams-window refresh remains a Record command consuming that context; Teams
meeting state is not mirrored inside Record.

`WorkspaceFolderRepository` is the repository-level source of truth for the
selected output/workspace folder. It publishes a monotonically increasing
folder revision. Record reads the current folder when starting or finalizing;
Library scopes loading, recovery, and search indexes to the same revision; and
Settings sends folder-selection commands. No feature maintains an independent
mutable folder URL. Before PR C introduces this repository, the existing
single `AppModel.outputFolder` remains the compatibility source of truth and
its existing `WorkspacePublicationFence` remains the only compatibility
revision. PR B must not add a second workspace-folder source or revision.

Meeting Intelligence has no AppKit presenter. Its section is part of the
Library-owned transcript-detail presentation and receives only immutable MI
presentation plus typed commands. It does not own a window, controller, or
detail-sheet lifetime.

## 7. Cross-feature Commands and Events

Cross-feature communication is explicit:

```text
TranscriptionFeatureModel emits TranscriptPublished(identity, session,
                                                     transcriptRevision,
                                                     workspaceFence)
  -> phase-owned bridge validates producer and workspace identity
  -> LibraryFeatureModel.acceptTranscriptPublication(event)
       refresh canonical session + rebuild search document exactly once
  -> LibraryTranscriptProjectionCommitted(event.identity)
  -> MeetingIntelligenceFeatureModel.handleTranscriptPublished(event)
       availability eligible -> start exactly one automatic MI attempt
       unavailable/ineligible -> start zero attempts; ASR remains successful

LibraryFeatureModel saves transcript successfully
  -> rebuild affected search document exactly once
  -> TranscriptEdited(libraryMutationIdentity, session,
                      transcriptRevision, workspaceFence)
  -> MeetingIntelligenceFeatureModel.markTranscriptChanged(event)
       mark an existing result stale; start zero automatic attempts

MeetingIntelligenceFeatureModel emits MeetingIntelligencePublished(
    publicationIdentity, session, publicationOutcome
)
  -> LibraryFeatureModel.refreshAfterMeetingIntelligence(event)
       reload canonical metadata/artifact projection and search index once
  -> never emits a second TranscriptPublished or recording-finalization event

LibraryFeatureModel.importAudio(url:, workspaceRevision:)
  -> ImportedAudioSessionReady(session, workspaceRevision)
  -> TranscriptionFeatureModel.requestStart(session:)
       provider eligible -> start exactly one job
       provider ineligible -> retain session, start zero jobs, publish recovery

PR B: AppModel.setOutputFolder(url:)
  -> advance the one existing WorkspacePublicationFence
  -> phase bridge emits WorkspaceFolderChanged(folder, advancedFence)
  -> LibraryFeatureModel tombstones the old projection, then invalidates
     and refreshes the new folder once
  -> TranscriptionFeatureModel advances the same publication fence
  -> MeetingIntelligenceFeatureModel cancels/resets the old workspace
  -> existing Record compatibility projection receives the new folder

PR C: SettingsFeatureModel.selectWorkspaceFolder(url:)
  -> WorkspaceFolderRepository.setFolder(url:)
  -> WorkspaceFolderChanged(folder, revision)
       -> the same Library tombstone/invalidation sequence
       -> RecordFeatureModel.invalidateFolderDependentReadiness(revision:)
       -> TranscriptionFeatureModel.advancePublicationFence(revision:)
       -> MeetingIntelligenceFeatureModel.cancelAndResetOldWorkspace(revision:)

PR B: AIProviderSettingsModel.save(...)
PR C: SettingsFeatureModel.saveProviderSettings(...)
  -> ProviderSettingsSaved(profileRevision)
       -> future TranscriptionFeatureModel and
          MeetingIntelligenceFeatureModel jobs use the new revision
       -> active ASR, availability, and LLM snapshots remain unchanged

LibraryFeatureModel moves a session to trash successfully
  -> tombstone session admission in Library
  -> SessionRemoved(libraryMutationIdentity, sessionIdentity,
                    workspaceRevision)
       -> TranscriptionFeatureModel.removeProjection(sessionID:)
       -> MeetingIntelligenceFeatureModel.cancelAndRemove(sessionID:)
       -> PlaybackFeatureModel.stopIfActive(sessionID:)

RecordFeatureModel requests stop/finalization
  -> RecordingSessionCoordinator settles media finalization
     and the source-metadata publication attempt
  -> RecordingFinalizationOutcome(
       folder, workspaceRevision, recordingURL, health, metadataOutcome, source
     )
  -> RecordFeatureModel projects outcome and user-facing status
  -> LibraryFeatureModel.refreshAfterFinalization(outcome:)
     exactly once

TeamsAutoMeetingCoordinator.onCommand(.startRecording)
  -> RecordFeatureModel.start(source: .automatic)

TeamsAutoMeetingCoordinator.onCommand(.stopRecording)
  -> RecordFeatureModel.stopIfAutomaticOwner()

TeamsAutoMeetingCoordinator.onCommand(.transferRecordingToManual)
  -> RecordFeatureModel.transferOwnership(to: .manual)
  -> TeamsAutoMeetingCoordinator.manualRecordingStarted()
     only when the user takes control of a pending automatic start
```

An event must not be implemented by a feature mutating another feature's
published property. In PR B, `AppModel` owns the bridge registrations shown
above; in PR C, `AppCoordinator` replaces them only after the PR B callbacks
are unregistered. The bridge calls typed commands and never reads a sibling
feature's private state.

Every semantic event carries enough immutable identity to reject stale or
duplicate delivery: producer instance/source ID, producer generation and
attempt ID where applicable, normalized session folder, session ID,
transcript revision, and workspace fence/revision. Each named consumer accepts
a given identity at most once. Producer progress changes are presentation
updates, not semantic publication events.

`MeetingIntelligencePublicationIdentity` contains the MI coordinator instance
ID, session ID and normalized folder, MI ticket generation and attempt UUID,
source `TranscriptDocumentRevision`, captured workspace fence/revision, and
publication kind (`artifactAndAutomaticTitle` or `explicitSuggestedTitle`).
Automatic work inherits the originating `TranscriptPublished.workspaceFence`.
Manual Generate, Regenerate, Retry, and Apply Suggested Title capture the
current workspace fence in an immutable command context at command admission;
`MeetingIntelligenceFeatureModel` does not store a second workspace source.

`MeetingIntelligencePublicationOutcome` distinguishes the combined durable
artifact result and its automatic-title metadata result (`applied`,
`preserved`, or `warning`) from an explicit suggested-title mutation. The
combined artifact/automatic-title commit emits one event. Explicit Apply emits
one later event only when metadata actually changes; a stale compare-and-save,
failure, or no-op emits none. Automatic protection of a manual or deliberately
empty title does not emit a second title event; it is represented by the
combined artifact event's metadata outcome.

`LibraryMutationIdentity` contains the Library feature instance/source ID, a
mutation UUID, session ID and normalized folder, resulting transcript revision
when applicable, and workspace fence/revision. `TranscriptEdited` is emitted
only after transcript persistence and its affected search rebuild succeed.
`SessionRemoved` is emitted only after the physical trash mutation succeeds
and Library first tombstones that session identity. The tombstone rejects any
already queued ASR or MI callback before cancellation/removal fans out to the
other features.

The transcript-publication ordering deliberately preserves the Draft PR #7
behavior: the current Library projection and bounded search document commit
before automatic Meeting Intelligence admission. That ordering is coordinated
by the phase-owned bridge, not by either feature importing or owning the other.
Once `TranscriptPublished` is durable, an availability or LLM failure changes
only Meeting Intelligence presentation; it cannot roll back ASR success,
remove the transcript, or replace transcription state.

`ImportedAudioSessionReady` is emitted only after the file import has
successfully created a valid session in the current workspace revision.
Transcription is not started by the view. When provider eligibility is
satisfied, the typed request starts exactly one job. Without a saved eligible
provider, the imported session remains in Library, no job starts, and the
existing configure-and-save-provider recovery is shown. An import failure
creates no session and emits no start request.

`WorkspaceFolderChanged` is the only folder-change invalidation event. Record
must reject a pending start that has not begun capture and captured an obsolete
folder revision. An active recording retains an immutable
`RecordingWorkspaceSnapshot(folder, revision)` through media and metadata
finalization, so a folder change cannot redirect or discard its output.
Library clears folder-scoped sessions, transcript-detail caches, recovery
state, and search generations before one refresh for the new revision.
Transcription advances its publication fence and clears old-workspace
per-session state/log projections without replacing the immutable snapshot of
an active job. Meeting Intelligence cancels and invalidates old-workspace
attempts and presentations through its sole coordinator. In PR B this flow
originates from the existing `AppModel.outputFolder` and
`WorkspacePublicationFence`; only PR C replaces that source with
`WorkspaceFolderRepository`.

An active transcription continues against its original session folder and
immutable provider snapshot. Its publication event carries the originating
workspace revision. Library accepts it only while that revision remains
selected; otherwise the durable old-folder artifact remains on disk and is
discovered on a later refresh if the user selects that folder again. PR B/PR C
do not add a hidden multi-workspace index. An active Meeting Intelligence
attempt is cancelled on selected-workspace change. A durable old-folder
artifact that won a publication race remains on disk, but its event cannot
update the newly selected Library projection.

`ProviderSettingsSaved` is emitted only after the shared repository commits
the profile and credential reference. It affects only ASR and MI jobs started
after that save. An active transcription, availability check, or generation
continues with its immutable endpoint, authentication, model, credential, and
prompt snapshot, even if the user changes or removes the saved settings.

`RecordingFinalizationOutcome` is semantic and emitted once after media
finalization and the source-metadata write attempt have both settled. A
metadata warning remains part of the outcome and user-facing status, but does
not trigger a second Library refresh. Library performs exactly one targeted
refresh/index update for the outcome's immutable workspace revision and
changes the visible list only if that revision is selected. A
no-active-recording result emits no Library refresh.

`MeetingIntelligencePublished` is a separate semantic outcome. A generated
artifact and any automatically applied title form one combined publication
and cause one targeted Library reload/search-index update. An explicit Apply
Suggested Title is a later distinct publication and also causes one targeted
update. Neither causes a second recording-finalization refresh or a second
transcript-publication event. Cancellation, unavailability, or generation
failure before any durable artifact/title metadata commit causes zero Library
publication events. If cancellation races with publication and the durable
commit wins, the coordinator still emits exactly one immutable
`MeetingIntelligencePublished`; Library performs its one targeted update even
if the terminal MI presentation subsequently remains cancelled. That event
does not restart ASR or MI.

`RecordFeatureModel` never performs media or metadata finalization itself. It
issues the typed stop command and projects the coordinator outcome. The
`RecordingSessionCoordinator` remains the business-rule owner and uses the
injected engine and metadata repository operations; the cross-feature bridge
forwards its single semantic outcome to Library.

Disabling Auto Meeting may request the same ownership transfer without the
additional `manualRecordingStarted()` suppression callback.

### Presenter and concurrency lifetime

`ContentView` alone calls the playback-window and Teams-countdown presenter
factories and retains those two presenter instances for the workspace
lifetime. `AppCoordinator` exposes the presentation state and typed
playback/countdown commands consumed by the shell, but never constructs,
retains, dismisses, or passes through either presenter instance.

`AppRuntime` remains the owner of the separate floating recording-panel
coordinator. Runtime shutdown dismisses that floating panel; the workspace
shell dismisses playback and countdown presenters on disappearance and
application termination and clears their action closures before releasing
feature references.

Meeting Intelligence adds no presenter lifetime. Its transcript-detail
section is rendered by the Library destination and disappears with that
detail surface. MI work may continue after that sheet closes, but the feature
and its sole coordinator never outlive `AppModel` shutdown in PR B or
`AppCoordinator` shutdown in PR C.

All UI feature models and `AppCoordinator` are `@MainActor`.
`AppCoordinator` owns every cross-feature subscription, event bridge, and
callback registration that it creates. Its shutdown is explicit and
idempotent:

1. stop accepting cross-feature events and invalidate subscription
   generations;
2. cancel cross-feature tasks and subscriptions;
3. unregister or replace playback, transcription publication, Meeting
   Intelligence publication, Teams coordinator, and Teams ingress callbacks;
4. tear down feature models and then their coordinators/adapters;
5. allow `AppRuntime` and `ContentView` to dismiss only the presenters they
   respectively own.

`AppRuntime.shutdown()` first shuts down the floating recording-controller
observer, then calls `AppCoordinator.shutdown()` exactly once after PR C.
No queued Teams ingress event, playback snapshot, transcription callback,
Meeting Intelligence callback, or folder-change event may target a feature or
compatibility adapter after its teardown begins. Bridge admission closes
before MI and ASR cancellation begins, so cancellation persistence cannot
re-enter a released consumer.

## 8. Recording Ownership Contract

The existing auto/manual ownership rules are invariants:

- manual recordings are never auto-stopped by Teams state;
- only auto-owned recordings may be stopped by the auto-meeting coordinator;
- disabling Auto Meeting during an active automatic recording transfers that
  recording to manual ownership;
- manual stop suppresses automatic restart for the same meeting episode;
- `isInMeeting == false` is debounced;
- a Teams API disconnect is not proof that the meeting ended;
- no refactor may add a second ownership flag outside
  `RecordingSessionCoordinator`;
- the Teams coordinator may request transfer or stop, but never stores or
  mutates `RecordingOwnership` directly.

## 9. UI Design Contract

PR A recreates the approved workspace against current APIs.

### Information architecture

- **Record** — operational console.
- **Recordings** — searchable library, favorites, playback, transcript and
  metadata actions.
- **Settings** — capture, Teams, virtual microphone, and provider settings.

Diagnostics remains represented by existing health/status surfaces during PR
A. A dedicated Diagnostics destination is deferred until it can be separated
without moving lifecycle behavior.

### Record priority

At the minimum supported 860×680 window size, the user must be able to see:

- current recording state and elapsed time;
- Start/Stop;
- microphone mute with the existing local, native-input, and Teams mute
  presentation;
- system-audio and microphone meters;
- immediate capture health;
- a direct recovery action, or deep link to the exact Settings section, for a
  denied/not-determined permission, disconnected selected application, or
  other blocking capture state.

Secondary capture, Teams, and provider settings must not push Stop or Mute out
of the operational region.

Start, Test 10s, source controls, and Mute retain the current
`isCaptureLifecycleWorking` and recording-state disable policies. Moving a
control to another source file must not weaken its disabled reason or allow a
capture source mutation during start/finalization.

### Visual rules

- Glass is limited to system-provided navigation and primary chrome.
- The native `NavigationSplitView` owns the sidebar material. PR A does not
  wrap the sidebar in a custom Glass modifier, material, border, overlay, or
  manually composed divider.
- The repository supports macOS 26 and later only. PR A contains no
  pre-macOS-26 UI availability or material fallback.
- meters, lists, warnings, transcripts, and forms use stable content surfaces.
- system audio uses cyan/blue semantics;
- microphone uses mint/green semantics;
- red is reserved for active recording and destructive actions.

### Interaction and accessibility

- preserve dirty-navigation confirmation for transcript/metadata edits when
  detail editing moves into navigation;
- explicit Cancel means discard; accidental navigation uses the dirty gate;
- preserve stable automation identifiers in `RecorderActionID`;
- preserve current identifiers for capture mode, selected-application
  reconnect, Teams auto recording, and existing primary recorder actions;
- repeated row actions have session-specific accessibility labels;
- icon-only actions have explicit VoiceOver labels;
- preserve `Command+Shift+R` and `Option+Shift+M`;
- preserve independent playback and auto-meeting countdown presenters.

## 10. PR A Source Decomposition

Expected new presentation files:

```text
Sources/RecorderApp/UI/
  RecorderNavigation.swift
  RecorderActionID.swift
  RecorderVisualStyle.swift
  RecordDashboardPresentation.swift
  RecorderSidebar.swift
  RecordDashboardView.swift
  RecordingsLibraryView.swift
  RecorderSettingsView.swift
```

Existing `ContentView` sections move as follows:

| Existing responsibility | Destination |
|---|---|
| root navigation and presenter lifetime | `ContentView` |
| header, timer, meters, controls, health, folder footer | `RecordDashboardView` |
| permissions and capture source/application controls | Settings capture section |
| Teams screen capture, Auto Meeting, mute sync | Settings Teams section |
| virtual microphone controls | Settings audio integration section |
| provider profile | Settings transcription section |
| session search, favorites, actions | `RecordingsLibraryView` |
| transcript and metadata sheets | library-owned presentation files, behavior unchanged |

The Settings extraction preserves, without simplification:

- permission request and System Settings recovery paths;
- `sourceControlsEnabled` gating while recording or lifecycle work is active;
- all-system versus selected-application capture;
- application search, refresh, selection, and reconnect;
- Teams screen-capture selection and enable/disable behavior;
- virtual-microphone status and actions;
- Teams pairing, retry, cancel, Auto Meeting, and mute-sync behavior;
- the existing shared `AIProviderSettingsModel`.

PR A uses an action-parity matrix during implementation and review:

| Existing action or state | Destination | Stable accessibility contract |
|---|---|---|
| `AppModel.startOrStop()` | Record primary control | `recorder.action.start-stop` |
| `AppModel.toggleRecorderMicMute()` plus local/native/Teams state | Record primary control | `recorder.action.mute-mic` plus explicit state value |
| `AppModel.runTestRecording()` | Record | `recorder.action.test-audio` |
| `AppModel.chooseAudioFileForTranscription()` | Recordings | `recorder.action.upload-audio` |
| `AppModel.refreshSessions()` | Recordings | `recorder.action.refresh-recordings` |
| session transcript open/edit | Recordings/session action | `recorder.action.open-transcript` plus session-specific label |
| `saveTranscript` | transcript editor | `recorder.action.save-transcript` |
| transcript/log open | Recordings/session action | session-specific Open Transcript/Open Log labels |
| metadata/favorite edit | Recordings/session action | explicit session-specific label |
| trash confirmation | Recordings/session action | destructive role and session-specific label |
| `AppModel.chooseOutputFolder()` / `openRecordingFolder()` | Record or Settings storage | existing choose/open-folder identifiers |
| capture mode/application reconnect | Settings capture | existing capture-mode and reconnect identifiers |
| Teams Auto Meeting/mute sync | Settings Teams | existing Teams identifiers and state values |

Copy/export remains available wherever it exists on current `main`; PR A does
not silently invent a new export contract or remove an existing action.

PR A may pass the existing single injected `AppModel` into destination views
as a temporary compatibility boundary. It must not construct another model,
move presenter ownership, or introduce an environment-wide mutable model.

This temporary observation boundary means PR A does not claim to solve
feature-specific publication or unrelated redraws. Those measurable
publication contracts belong to PR B and PR C.

## 11. Feature-owner Cutover Rules for PR B and PR C

Every ownership migration is documented in the implementation plan and PR
description with:

| Required field | Meaning |
|---|---|
| old owner | exact `AppModel` state, task, generation, callback, or resource |
| new owner | one feature model or existing coordinator |
| construction owner by phase | PR B: the existing single `AppModel` constructs and retains the sole Library, Transcription, Meeting Intelligence, and Playback feature instances. PR C: `AppCoordinator` constructs the sole instances and injects them into the narrow `AppModel` adapter after removing the PR B construction path. No state is copied and no parallel instance exists. |
| event identity and delivery rule | producer instance/source ID, generation and attempt where applicable, session/folder identity, transcript revision, workspace fence/revision, named consumers, and an at-most-once assertion |
| callback cutover | unregister/replace the old callback before enabling the new path; one producer has one phase-owned registration |
| subscription owner by phase | PR B: `AppModel` temporarily owns exactly one transcription-publication bridge and one Meeting Intelligence-publication bridge plus the other bridges needed by the PR B features. PR C: `AppCoordinator` owns all cross-feature subscriptions and cancels them before feature/coordinator teardown. |
| shutdown/cancel order | deterministic teardown with no callback into a released owner |
| temporary forwarder | read/command delegation only; no mirrored mutable state |
| removal condition | tests and reference search proving the old path is gone |

Each cutover adds a single-instance or single-publication assertion where
practical. `GlobalHotKeyManager`, `AppRuntime.shutdown`, Teams ingress,
recording finalization, playback snapshots, and transcription callbacks must
continue to enter one command path only. Meeting Intelligence publication,
title application, transcript editing, session removal, and workspace change
also enter one typed path only.

PR B assertions prove `AppModel` retains one instance of each PR B feature and
contains no parallel mutable state, task, generation, or dictionary for that
feature. In particular, after the Library and MI cutovers, `AppModel` contains
no session refresh/search generations, MI reload generations, MI lifecycle
dictionary, or parallel playback/transcription state. PR C assertions prove
construction and subscription ownership moved to `AppCoordinator` and the
narrow adapter references those same instances.

PR B defines immutable feature snapshots with per-feature revisions. Observer
spies verify the allowed publication scope:

| Event | May publish | Must not publish |
|---|---|---|
| meter/recording health tick | Record | Library, Settings, Transcription, Meeting Intelligence |
| library refresh/search update | Library | Record, Settings, Playback, Meeting Intelligence |
| transcription job phase/progress/log state | Transcription | Record, Settings, Playback, Library, Meeting Intelligence |
| canonical transcript publication | Transcription semantic event, then affected Library projection and MI admission once each | Record, Settings, Playback, duplicate consumer delivery |
| Meeting Intelligence phase/progress | Meeting Intelligence | Record, Settings, Playback, Transcription, Library |
| Meeting Intelligence semantic publication/title application | Meeting Intelligence semantic event and one affected Library refresh/index update | Record, Settings, Playback, Transcription, duplicate Library refresh |
| playback position snapshot | Playback | Record, Library, Settings, Transcription, Meeting Intelligence |
| provider draft edit | Settings | Record, Library, Transcription, Meeting Intelligence |
| provider settings saved | Settings and future ASR/MI job eligibility | active ASR/availability/LLM snapshots, Record, Library |
| workspace folder changed | Record folder readiness, Library folder scope, Transcription publication fence, and MI old-workspace reset | Integrations, active immutable ASR provider snapshot, old-workspace visible projection |
| recording finalization outcome | Record status and one Library refresh | Settings, Integrations, duplicate Library refresh |

## 12. Runtime Wiring That Must Not Change in PR A

- `ContentView(model: appDelegate.runtime.model)`;
- one `AppRuntime` and one model instance;
- termination cleanup;
- main-window identity;
- floating recording controller ownership;
- Teams screen viability-probe entry path;
- playback-window and Teams-countdown presenter factories;
- global hotkey and application command routing;
- capture, recording, mixer, media writer, Teams, provider, library, playback,
  and transcription implementation types;
- current action method signatures.

## 13. Error and Cancellation Semantics

Refactoring must preserve:

- typed capture lifecycle blocking/finalizing states;
- transcription cancellation during preparation, upload, retry delay, and
  response processing;
- stale callback rejection after cancellation or a newer transcription
  attempt;
- bounded retry and upload/response behavior;
- transcript publication and legacy-artifact cleanup;
- library search-document rebuild after transcription or editing;
- Meeting Intelligence cancellation during availability, generation,
  retry/backoff, response processing, artifact publication, and title apply;
- stale MI callback rejection after cancellation, a newer same-session
  attempt, transcript edit, session trash, workspace switch, or shutdown;
- one active MI attempt per session, while different sessions may progress
  independently;
- persisted MI recovery, transcript-revision stale detection, manual-title and
  deliberate-empty-title protection, and compare-and-save title application;
- user-facing provider, permission, capture, Teams, playback, and storage
  errors.

No feature model may translate a cancellation into a retryable error or
replace a specific blocking state with an unrelated global status message.
An MI unavailability, cancellation, or failure must not change a successfully
published transcript or its completed ASR state. Provider save/switch does not
cancel an active ASR or MI attempt; workspace change, session removal, explicit
Cancel, replacement, and shutdown do. A late callback after bridge shutdown is
ignored and emits no Library refresh unless it represents a durable commit
that the bridge admitted before shutdown; that already-admitted identity may
settle exactly once before teardown completes. Cancellation before durable MI
commit emits zero semantic publication; cancellation after a winning durable
commit cannot suppress its one Library update.

## 14. Testing Strategy

### PR A focused tests

- navigation selection and the unused pure dirty-gate contract, without wiring
  it to existing sheets;
- dashboard Start/Stop presentation and compact-height policy;
- stable action identifiers;
- native sidebar, toolbar, search, list, and form behavior;
- current playback window remains outside the main content hierarchy;
- current runtime constructs one model and one presenter;
- capture, Teams auto-meeting, mute, and floating-controller regressions.

PR A adds `RecorderWorkspaceRenderTests` where the supported macOS
XCTest/AppKit runtime can create a hosting window:

1. construct a deterministic, startup-disabled fixture `AppModel`;
2. host the actual workspace in an `NSHostingView` and `NSWindow` with an
   860×680 content rect, disable animations, and force main-actor layout;
3. assert the initial Record viewport renders recording state/timer,
   Start-or-Stop, both audio meters, and immediate capture health;
4. drive the internal workspace navigation boundary through Record,
   Recordings, and Settings for a small repeated route cycle, asserting each
   destination renders and selection remains stable;
5. repeat the structural layout at a representative wide size;
6. after exercising video playback and the destination-switching cycle,
   recursively assert that no `AVPlayerView` exists in the main workspace
   hierarchy. Playback remains in its independent window presenter.

The render regression uses stable accessibility identifiers or explicit layout
probes. It may attach a PNG on failure for diagnosis, but PR A does not add a
pixel-golden comparison for OS-dependent Glass, material, font, or dynamic
meter rendering.

If the test target cannot create the AppKit host on a supported CI/runtime, the
PR report records `not run` with the concrete host limitation and includes the
focused pure layout/navigation results. This does not replace the mandatory
manual 860×680 smoke before merge.

`RecorderNavigationTests` also repeat the pure
Record → Recordings → Settings → Record transition at least 100 times and
cover clean navigation, pending dirty navigation, Keep Editing, and one-time
Discard application without an engine, presenter, or filesystem dependency.

Required existing focused suites include:

- `RecordingControllerPresentationTests`;
- `TeamsAutoMeetingPresentationTests`;
- `RecordingControllerPanelTests`;
- `AppRuntimeTests`;
- `AppModelPlaybackTests`, including periodic snapshot publication and
  `testVideoPlaybackIsNotEmbeddedInMainContentHierarchy`, updated to retain the
  rendered 860×680 workspace and destination-switching coverage.

### PR B focused tests

- `AppModel` constructs or accepts exactly one Library, Transcription, Meeting
  Intelligence, and Playback feature and retains no parallel feature state;
- library-only publications do not republish playback/settings;
- transcription state changes do not republish recording controls;
- Meeting Intelligence phase/progress changes publish only the MI boundary and
  do not republish Library, Transcription, Record, Settings, or Playback;
- playback snapshots do not republish the whole workspace;
- successful transcription emits one canonical event, refreshes/rebuilds the
  affected Library search document once, and only then admits the same event
  to Meeting Intelligence once;
- duplicate, forged-source, stale-attempt, old-transcript, and old-workspace
  events produce zero duplicate Library deliveries and zero extra model/chat
  requests;
- automatic and manual MI publication identities carry the expected
  coordinator/session/folder/attempt/transcript/workspace/kind fields, and
  manual commands capture rather than retain the current workspace fence;
- ASR success remains published when MI is unavailable, cancelled, or fails;
- transcript editing rebuilds search once, marks existing MI stale once, and
  starts zero automatic generation attempts;
- MI artifact publication, automatic title publication, and explicit Apply
  Suggested Title each cause one semantic targeted Library reload/search
  update, while progress and pre-commit failure/cancellation cause zero
  Library refreshes;
- cancellation before a durable MI commit causes zero Library refreshes;
  cancellation after the durable commit wins still delivers exactly one
  targeted refresh and cannot deliver a second event;
- an artifact plus its automatic-title outcome emits one combined event;
  automatic protected-title/no-op produces no second event, and explicit
  Apply emits one event only when metadata actually changes;
- manual and deliberately cleared titles remain protected by the existing
  title-origin compare-and-save rules;
- successful eligible imported-audio publication starts exactly one
  transcription job; successful ineligible import retains one Library session
  and starts zero jobs with provider recovery; failed import creates no session
  and starts no job;
- provider settings saved during active ASR and MI jobs affect future jobs
  only and do not mutate either active snapshot;
- one MI coordinator permits at most one active attempt per session while
  preserving independent work for different sessions;
- workspace change, trash, replacement, explicit cancel, and shutdown cancel
  or invalidate the intended MI work; delayed callbacks update no wrong
  workspace/session and publish no duplicate refresh;
- successful trash tombstones Library admission before cancellation fan-out;
  failed trash creates no tombstone or removal event;
- callbacks queued after PR B bridge shutdown produce zero Library or MI
  delivery, while a durable publication admitted before shutdown settles at
  most once;
- favorites and transcript snippets remain available;
- current transcription cancellation, stale-callback, retention, provider
  snapshot, and error behavior remains unchanged.

Required existing focused suites also include
`AppModelTranscriptionTests`, `AppModelMuteTests`,
`AppModelMeetingIntelligenceIntegrationTests`,
`MeetingIntelligenceJobCoordinatorTests`, `RecordingLibraryTests`, and the
transcription and Meeting Intelligence coordinator/service suites.

### PR C focused tests

- meter/health updates do not publish
  library/settings/transcription/Meeting Intelligence changes;
- Teams state enters through serialized ingress;
- automatic and manual recording ownership remains correct;
- workspace-folder changes invalidate Record readiness and Library
  folder-scoped caches once, while active recording/transcription snapshots
  remain bound to their originating folder revision;
- each semantic recording-finalization outcome triggers exactly one targeted
  Library refresh after media and metadata finalization settle;
- exactly one recording coordinator, Teams auto-meeting coordinator, engine,
  provider repository, shared session mutation gate, transcription
  coordinator, Meeting Intelligence coordinator, and playback coordinator
  exists per runtime;
- the four PR B feature instances injected into the `AppModel` compatibility
  adapter are the exact instances constructed by `AppCoordinator`;
- the PR B publication callbacks are unregistered before `AppCoordinator`
  installs its one replacement registration;
- callbacks racing the PR B-to-PR C registration handoff are accepted by at
  most one bridge and never reach both owners;
- shutdown remains idempotent;
- runtime shutdown while floating-panel observation is active;
- playback-window close during feature teardown;
- countdown cancel while Teams callbacks are being replaced;
- delayed Teams ingress, playback snapshot, transcription callback, Meeting
  Intelligence callback, and workspace-folder event after coordinator teardown
  are ignored.

Required existing focused suites also include
`AppModelScreenCaptureTests`, `AppModelTeamsAutoMeetingTests`, and
`RecordingSessionCoordinatorTests`.

### Full automated gate for each PR

1. complete Swift test suite once;
2. Python/script tests;
3. policy checks;
4. `Tests/PackagingTests/run-tests.sh`, including the staging app bundle
   contract and ad-hoc strict codesign verification;
5. virtual microphone unit, bundle, and script tests;
6. clean staging bundle-content verification, including no Python or FFmpeg
   runtime helper;
7. `git diff --check`.

Developer ID signing, Hardened Runtime, notarization, stapling, and
`spctl --assess` are production-release gates. They run only with explicit
release authorization on an eligible ref with production secrets. If they are
not run, the PR report says `not run`; an ad-hoc staging signature must never
be described as notarized production-artifact acceptance.

The main-only stability step runs
`RECORDER_STABILITY=1 swift test --filter RecorderWorkspaceStabilityTests`.
Pull requests run one unflagged full suite, where loop-based stability tests
are skipped, and do not repeat the identical full Swift suite. A GitHub timeout
remains verification-unknown and blocks merge until the same SHA obtains a
passing terminal result; do not increase timeouts or skip deterministic
cancellation, packaging, or policy coverage.

## 15. Manual Acceptance

Each PR report distinguishes automated coverage from manual acceptance.

Required PR A smoke tests before merge:

- 860×680 and wide-window resizing. At exactly 860×680, with Record selected
  and without scrolling, the initial operational region visibly contains
  recording state/timer, Start or Stop, microphone mute, both audio meters,
  and capture health. Record `passed` with tester, OS version, date, and
  screenshot/window evidence; `not run` is not `passed`;
- Record, Recordings, and Settings navigation;
- simultaneous visibility and operability of Start/Stop, Mute, meters, and
  health;
- Settings reachability for permission recovery, capture application,
  Teams screen, Teams Auto/Mute Sync, virtual microphone, and provider;
- manual start/stop and Mute command routing;
- independent playback and Teams-countdown presenters;
- light/dark appearance and native macOS 26 material;
- keyboard traversal, current shortcuts, and VoiceOver labels where the local
  OS/hardware permits.

Live Teams, real-provider, TCC reset, AirPods, macOS 26 Glass, or accessibility
mode checks not performed in PR A are listed explicitly as `not run`; they are
not inferred from automated tests.

Required final program smoke tests:

- manual record, Test 10s, stop, and saved-file playback;
- selected Teams application capture and optional Teams-window video;
- Teams auto-start, manual ownership transfer, debounced auto-stop;
- local microphone mute and Teams mute sync;
- playback window open, seek, pause, resume, and close;
- provider transcription, cancellation, publication, and log access;
- transcript edit followed by immediate library search;
- saved eligible provider followed by availability-gated automatic Meeting
  Intelligence generation; unavailable discovery starts no automatic
  generation and preserves manual Generate for later;
- Generate, Regenerate, Retry, and Cancel preserve their Draft PR #7 behavior;
- summary/suggested-title display, manual-title and deliberately-cleared-title
  protection, and Apply Suggested Title;
- transcript edit marks existing intelligence stale without automatic
  regeneration;
- workspace switch during generation accepts no stale visible callback;
- metadata/favorite edit and trash confirmation;
- 860×680 and wide-window resizing;
- light/dark appearance;
- keyboard traversal and physical shortcuts;
- VoiceOver labels;
- Reduce Transparency, Reduce Motion, and Increase Contrast;
- macOS 26 native sidebar, toolbar, search, and accessibility appearances.

Real-provider, notarized production artifact, live Teams, AirPods, physical
shortcut, and accessibility hardware/OS acceptance remain explicit manual
gates until performed.

## 16. Completion Criteria

The three-PR program is complete when:

- `ContentView` contains only shell, navigation, composition, and presenter
  lifetime;
- feature views do not receive giant value/closure initializer lists;
- feature models are the only UI-facing owners of their feature state;
- the four PR B boundaries have one live instance each, exactly one
  `MeetingIntelligenceJobCoordinator` exists, and `AppModel` owns no parallel
  Library, Transcription, Meeting Intelligence, or Playback lifecycle state;
- coordinators remain the only lifecycle/business-rule owners;
- repositories remain the only persistence/credential owners;
- each semantic publication has a named producer, immutable identity, named
  consumers, and at-most-once assertions;
- provider saves affect only future ASR/MI snapshots, and workspace switch or
  shutdown accepts no stale MI callback into the selected Library projection;
- high-frequency record/meter updates do not republish unrelated features;
- current behavior and full automated gates remain green;
- the PR descriptions document before/after architecture, state ownership,
  files moved, preserved invariants, tests, and any remaining `AppModel`
  responsibilities;
- no PR claims full production acceptance without completing the outstanding
  manual gates.

## 17. Approved macOS 26 Liquid Glass PR A Revision

This section supersedes earlier PR A presentation and test details where they
conflict. It does not override the later PR B/C Meeting Intelligence amendment
in Sections 1–16.

### Apple design principles

- Prefer standard SwiftUI navigation, toolbars, controls, lists, forms, and
  search fields so macOS 26 supplies the current appearance and behavior.
- Treat Liquid Glass as a functional layer for navigation, controls, and
  transient or floating functional elements, not as a general content-card
  surface.
- Let the system render the sidebar. Remove custom sidebar Glass, material
  backgrounds, overlays, and manual navigation chrome.
- Keep meters, recording health, recording rows, transcript content, and
  settings sections in the content layer using standard surfaces, spacing,
  typography, and separators.
- Use custom `glassEffect`, Glass button styles, or `GlassEffectContainer` only
  for a genuinely custom floating control. The separately owned floating
  recording controller is the only current candidate; PR A does not restyle
  or move it.

The design authority is Apple's *Adopting Liquid Glass*, *Applying Liquid
Glass to custom views*, Human Interface Guidelines for *Materials*,
*Designing for macOS*, *Sidebars*, *Toolbars*, *Search fields*, and *Buttons*,
and WWDC25 *Build a SwiftUI app with the new design*.

### Before and after component mapping

| Area | Rebased PR A before revision | Approved revision |
|---|---|---|
| Workspace | Manual `HStack`, sidebar `List`, and `Divider` | Native `NavigationSplitView` with the same Record, Recordings, and Settings selection |
| Sidebar | Fixed frame plus `.recorderGlass()` and hidden list background | System sidebar appearance and native show/hide behavior |
| Compatibility | `RecorderGlass` compiler, availability, and material fallback | Delete the obsolete pre-macOS-26 UI fallback and its tests |
| Record | Dense action grid and a disabled shortcut pseudo-button | Status, elapsed time, meters, health, and one prominent Start/Stop action; existing secondary commands move to the native toolbar or More menu |
| Recordings | Scroll/card rows with inline search | Native toolbar search and list presentation while preserving existing row actions, sheets, dialog, playback presenter, and persistence |
| Settings | Custom stacked card sections | Native `Form` and `Section` grouping with all existing bindings and gates |
| Toolbar | Destination actions embedded in content | Destination-specific toolbar items calling existing `AppModel` commands only |

### PR A scope

In scope:

- `NavigationSplitView`, native sidebar show/hide, and destination-specific
  toolbar composition;
- removal of PR A's custom sidebar Glass and pre-macOS-26 fallback;
- presentation-only hierarchy changes for Record, Recordings, and Settings;
- moving existing actions without changing their command, disabled-state, or
  ownership semantics;
- native `List`, `searchable`, `Form`, and `Section` where they preserve
  current behavior;
- behavior-focused test rationalization.

Out of scope:

- feature models, `AppCoordinator`, state ownership migration, or a second
  workspace-folder source;
- sorting behavior, new AppCommands, new keyboard shortcuts, or responder
  chain changes;
- list-detail selection ownership, transcript/metadata detail panes, or
  replacing their existing sheets;
- recording, transcription, Teams, mute-sync, storage, playback, provider,
  persistence, or Windows behavior.

### Test retention and removal

Retain focused required-PR coverage for:

- Record, Recordings, and Settings navigation;
- Start/Stop and effective recorder-mute presentation and gates;
- permission recovery navigation;
- recordings rendering, transcript snippets, favorites filtering, and
  metadata rename projection;
- Settings enabled/disabled gates;
- core accessibility identifiers and session-specific labels;
- one 860×680 smoke, one wide/resizable smoke, and a small route-switch cycle;
- playback/countdown presenter lifetime and `AVPlayerView` isolation.

Remove or replace:

- source-file searches and tests requiring exact private struct/file placement;
- exact compiler-directive or availability-source spelling;
- visual-style-token caller counts;
- pre-macOS-26 fallback tests;
- duplicate exact-frame/no-scroll assertions;
- 25- and 100-cycle loops from required pull-request checks.

Loop-based navigation/render stress moves to a main-only or scheduled
stability test. Deterministic transcription cancellation tests remain in the
required suite because they protect a real lifecycle contract and are not
stress loops.

### Manual macOS 26 acceptance

Automated AppKit tests do not prove real Liquid Glass rendering, system
accessibility settings, or VoiceOver interaction. Before merge, manually
inspect Record, Recordings, and Settings in light and dark appearance, one
Reduce Transparency example, minimum and large window sizes, sidebar shown
and hidden, keyboard-only navigation, and idle/active recording states.
Increase Contrast, Reduce Motion, non-default accent color, and VoiceOver
focus/labels are recorded as passed or explicitly outstanding; they are never
inferred from source or snapshot tests.
