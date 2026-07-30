# UI and Feature Boundary Refactor Design

**Date:** 2026-07-30
**Status:** Approved direction; detailed specification under review
**Delivery:** Three sequential, bounded Draft pull requests
**Reference UI:** `codex/liquid-glass-recorder-ui` at `776837b`

## 1. Context

The recorder has reached a point where `AppModel` and `ContentView` are both
composition roots, lifecycle coordinators, presentation models, and UI
containers. This makes otherwise local changes risky:

- `AppModel` owns capture, permissions, recording, storage, Teams integration,
  virtual microphone state, playback, library operations, provider settings,
  transcription, and global status.
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
   state, playback runtime, provider storage, and transcription jobs.
7. Prevent high-frequency recording or meter updates from republishing
   unrelated library, settings, or transcription views.
8. Preserve all current recorder, Teams, playback, transcription, library,
   metadata, and recovery behavior.
9. Deliver the work in three independently reviewable and reversible PRs.

## 3. Non-goals

This program does not add:

- timestamped transcript UI;
- AI summaries, actions, or meeting intelligence;
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

## 4. Delivery Strategy

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

### PR B — Library, transcription, and playback presentation boundaries

PR B introduces:

- `LibraryFeatureModel`;
- `TranscriptionFeatureModel`;
- the focused playback model boundary around the existing
  `PlaybackPresentationModel` and playback coordinator;
- small state snapshots and command protocols consumed by the Recordings and
  transcript UI.

Library refresh and search-document rebuild remain automatic after recording
publication, successful transcription publication, and transcript editing.
Transcription continues to use one immutable provider snapshot per job and one
shared provider repository.

PR B introduces a typed save outcome for transcript and metadata publication.
It identifies which artifact succeeded and carries a user-facing failure.
Detail drafts may become clean only for artifacts confirmed as saved; partial
failure leaves the affected draft dirty.

The corresponding private state and task ownership must leave `AppModel` in
the same PR. Temporary `AppModel` forwarding APIs may exist only when they
delegate to the single feature owner.

### PR C — Record, integrations, settings, and composition boundary

PR C introduces:

- `RecordFeatureModel`;
- `IntegrationsFeatureModel`;
- `SettingsFeatureModel`;
- `AppCoordinator` as the explicit composition boundary.

`AppCoordinator` wires feature models, existing coordinators, repositories,
and presenters. It does not implement recording or Teams state machines.

At the end of PR C, one narrow `AppModel` compatibility adapter remains because
the current `AppRuntime.model`, application entry point, and floating
recording-panel presenter are typed to `AppModel`. The adapter contains no
duplicated tasks, generations, timers, lifecycle gates, persistence, or
business rules. Removing that concrete type coupling requires a later bounded
PR that changes the runtime and floating-panel presenter protocols together.

`AIProviderSettingsModel` is constructed exactly once by `AppCoordinator`
using the shared provider repository. `SettingsFeatureModel` owns its Settings
UI projection and delegates provider edits to that model.
`TranscriptionFeatureModel` reads only repository/job-coordinator results and
never creates or owns a second editable provider draft.

## 5. Target Architecture

```text
LocalMeetingRecorderApp / AppRuntime
                 |
                 v
          AppCoordinator
         /       |        \
        v        v         v
 RecordFeature  Library    Settings
 Model          Feature    Feature
        \        Model      Model
         \       |          |
          v      v          v
      Transcription     Integrations
      FeatureModel      FeatureModel
             \             /
              v           v
        Existing coordinators
      / capture / Teams / jobs /
             |
             v
        Repositories and
        platform adapters
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

## 6. State Ownership

| State or resource | Single owner after the program | Mutation path |
|---|---|---|
| App lifetime and shutdown | `AppRuntime` | application lifecycle only |
| Feature construction and wiring | `AppCoordinator` | initializer/composition only |
| Active capture attempt, lifecycle generation, and auto/manual recording ownership | `RecordingSessionCoordinator` | typed recording commands |
| `RecordingEngine` instance lifetime and construction | `AppCoordinator` | composition only; exactly one injected instance |
| `RecordingEngine` commands and UI projection | `RecordFeatureModel` | record commands only |
| Teams event ordering | `TeamsIntegrationIngress` | serialized ingress drain |
| Teams countdown, debounce, and automation intent | `TeamsAutoMeetingCoordinator` | Teams events and semantic recording-outcome callbacks |
| Teams UI connection/mute projections | `IntegrationsFeatureModel` | Teams adapters/coordinator events |
| Library sessions, refresh generation, search documents | `LibraryFeatureModel` | library commands and publication events |
| Active transcription task, generation, state, result publication | `TranscriptionJobCoordinator` exposed by `TranscriptionFeatureModel` | start/cancel and coordinator callbacks |
| Provider profile and secret persistence | one shared provider repository | repository methods only |
| Immutable provider job snapshot | `TranscriptionJobCoordinator` | captured before preparation starts |
| Playback loading/session generation | focused playback feature boundary | playback commands only |
| Playback UI snapshot | `PlaybackPresentationModel` | playback coordinator snapshots |
| Capture and user-preference UI projection | `SettingsFeatureModel` backed by existing repositories | settings commands only |
| Editable provider settings draft | one `AIProviderSettingsModel` constructed by `AppCoordinator` | delegated settings commands only |
| Floating recording-panel lifetime | `AppRuntime.recordingController` | recorder-state observation and runtime shutdown |
| Playback-window presenter lifetime | workspace shell (`ContentView`) | `playingSessionID` presentation events |
| Teams-countdown presenter lifetime | workspace shell (`ContentView`) | auto-meeting presentation events |

## 7. Cross-feature Commands and Events

Cross-feature communication is explicit:

```text
recording finalised
  -> LibraryFeatureModel.refresh()

transcription published
  -> LibraryFeatureModel.rebuildSearchDocument(for:)

transcript edited
  -> LibraryFeatureModel.rebuildSearchDocument(for:)

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
published property.

Disabling Auto Meeting may request the same ownership transfer without the
additional `manualRecordingStarted()` suppression callback.

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

- Glass is limited to navigation and primary chrome.
- `RecorderGlass` is the only macOS 26 `glassEffect` availability boundary.
- macOS 15–25 use material and border fallback.
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
  RecorderGlass.swift
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
| `startRecording` / `stopRecording` | Record primary control | `recorder.action.start-stop` |
| local/native/Teams mute | Record primary control | `recorder.action.mute-mic` plus explicit state value |
| `startTestRecording` | Record | `recorder.action.test-audio` |
| `chooseAudioFileForTranscription` | Recordings | `recorder.action.upload-audio` |
| `refreshSessions` | Recordings | `recorder.action.refresh-recordings` |
| session transcript open/edit | Recordings/session action | `recorder.action.open-transcript` plus session-specific label |
| `saveTranscript` | transcript editor | `recorder.action.save-transcript` |
| transcript/log open | Recordings/session action | session-specific Open Transcript/Open Log labels |
| metadata/favorite edit | Recordings/session action | explicit session-specific label |
| trash confirmation | Recordings/session action | destructive role and session-specific label |
| output-folder choose/open | Record or Settings storage | existing choose/open-folder identifiers |
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
| construction | the single instance created by `AppCoordinator` |
| callback cutover | unregister/replace old callback before enabling the new path |
| shutdown/cancel order | deterministic teardown with no callback into a released owner |
| temporary forwarder | read/command delegation only; no mirrored mutable state |
| removal condition | tests and reference search proving the old path is gone |

Each cutover adds a single-instance or single-publication assertion where
practical. `GlobalHotKeyManager`, `AppRuntime.shutdown`, Teams ingress,
recording finalization, playback snapshots, and transcription callbacks must
continue to enter one command path only.

PR B defines immutable feature snapshots with per-feature revisions. Observer
spies verify the allowed publication scope:

| Event | May publish | Must not publish |
|---|---|---|
| meter/recording health tick | Record | Library, Settings, Transcription |
| library refresh/search update | Library | Record, Settings, Playback |
| transcription job state | Transcription and affected Library session | Record, Settings |
| playback position snapshot | Playback | Record, Library, Settings, Transcription |
| provider draft edit | Settings | Record, Library |

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
- user-facing provider, permission, capture, Teams, playback, and storage
  errors.

No feature model may translate a cancellation into a retryable error or
replace a specific blocking state with an unrelated global status message.

## 14. Testing Strategy

### PR A focused tests

- navigation selection and the unused pure dirty-gate contract, without wiring
  it to existing sheets;
- dashboard Start/Stop presentation and compact-height policy;
- stable action identifiers;
- Glass availability/fallback boundary where testable;
- current playback window remains outside the main content hierarchy;
- current runtime constructs one model and one presenter;
- capture, Teams auto-meeting, mute, and floating-controller regressions.

Required existing focused suites include:

- `RecordingControllerPresentationTests`;
- `TeamsAutoMeetingPresentationTests`;
- `RecordingControllerPanelTests`;
- `AppRuntimeTests`;
- `AppModelPlaybackTests`, including periodic snapshot publication and
  non-embedded video playback regressions.

### PR B focused tests

- library-only publications do not republish playback/settings;
- transcription state changes do not republish recording controls;
- playback snapshots do not republish the whole workspace;
- successful transcription and transcript edits immediately rebuild the
  searchable document;
- favorites and transcript snippets remain available;
- current transcription cancellation, stale-callback, retention, provider
  snapshot, and error behavior remains unchanged.

Required existing focused suites also include
`AppModelTranscriptionTests`, `AppModelMuteTests`,
`RecordingLibraryTests`, and the transcription coordinator/service suites.

### PR C focused tests

- meter/health updates do not publish library/settings/transcription changes;
- Teams state enters through serialized ingress;
- automatic and manual recording ownership remains correct;
- exactly one recording coordinator, Teams auto-meeting coordinator, engine,
  provider repository, transcription coordinator, and playback coordinator
  exists per runtime;
- shutdown remains idempotent.

Required existing focused suites also include
`AppModelScreenCaptureTests`, `AppModelTeamsAutoMeetingTests`, and
`RecordingSessionCoordinatorTests`.

### Full automated gate for each PR

1. complete Swift test suite twice;
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

The existing GitHub 20-minute Swift cancellation is verification-unknown, not
a pass or product failure, and blocks merge until the same SHA obtains a
passing terminal result. Record the exact SHA, phase, and final output; rerun
the same SHA and use two full local runs with the same toolchain for diagnosis.
A repeated timeout requires a separate CI performance/sharding PR. Do not
weaken the second Swift pass or skip packaging/policy, and do not mix workflow
performance changes into the UI refactor.

## 15. Manual Acceptance

Each PR report distinguishes automated coverage from manual acceptance.

Required PR A smoke tests before merge:

- 860×680 and wide-window resizing;
- Record, Recordings, and Settings navigation;
- simultaneous visibility and operability of Start/Stop, Mute, meters, and
  health;
- Settings reachability for permission recovery, capture application,
  Teams screen, Teams Auto/Mute Sync, virtual microphone, and provider;
- manual start/stop and Mute command routing;
- independent playback and Teams-countdown presenters;
- light/dark appearance and material fallback;
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
- metadata/favorite edit and trash confirmation;
- 860×680 and wide-window resizing;
- light/dark appearance;
- keyboard traversal and physical shortcuts;
- VoiceOver labels;
- Reduce Transparency, Reduce Motion, and Increase Contrast;
- macOS 15 fallback and macOS 26 Glass where hardware/OS access is available.

Real-provider, notarized production artifact, live Teams, AirPods, physical
shortcut, and accessibility hardware/OS acceptance remain explicit manual
gates until performed.

## 16. Completion Criteria

The three-PR program is complete when:

- `ContentView` contains only shell, navigation, composition, and presenter
  lifetime;
- feature views do not receive giant value/closure initializer lists;
- feature models are the only UI-facing owners of their feature state;
- coordinators remain the only lifecycle/business-rule owners;
- repositories remain the only persistence/credential owners;
- high-frequency record/meter updates do not republish unrelated features;
- current behavior and full automated gates remain green;
- the PR descriptions document before/after architecture, state ownership,
  files moved, preserved invariants, tests, and any remaining `AppModel`
  responsibilities;
- no PR claims full production acceptance without completing the outstanding
  manual gates.
