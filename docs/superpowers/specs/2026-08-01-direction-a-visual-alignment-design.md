# Direction A Visual Alignment Design

**Status:** Approved by the user on 2026-08-01 after interactive browser review

**Implementation base:** `2313be2e40fbf6108c294d248596a6a0fcdaa053`
(`codex/refactor-library-transcription-mi-playback`, Draft PR #8)

**Delivery branch:** `codex/pr7-direction-a-visual-alignment`

## 1. Purpose and authority

This specification records the approved production interpretation of the six
PR #7 Image Gen frames and the accepted Direction A interactive prototype. It
is a presentation-only amendment to
`2026-08-01-post-prb-liquid-glass-motion-ui-design.md`.

Where the older specification calls the custom sidebar, second-level Settings
navigation, gradients, exact spacing, or transcript page composition merely
illustrative, this amendment supersedes that wording. The following are now
normative production direction:

- the branded blue sidebar;
- the deep-navy Recordings workspace;
- the two-level Settings composition with a dedicated AI Provider surface;
- the transcript detail hierarchy within the Recordings destination;
- adaptive light and dark transcript/Meeting Intelligence surfaces;
- opaque content cards, restrained Liquid Glass, and Apple-native motion.

The implementation remains native SwiftUI and AppKit. Raster mockup controls,
fake window chrome, fake media data, and browser-preview controls do not ship.

## 2. Scope boundary

This branch may change SwiftUI composition, presentation-only routing, visual
tokens, accessibility markers, and render tests. It must not change:

- `AppModel` feature ownership, composition, tasks, generations, or storage;
- `LibraryFeatureModel`, `TranscriptionFeatureModel`,
  `MeetingIntelligenceFeatureModel`, or `PlaybackFeatureModel` behavior;
- PR B bridges, repositories, mutation gates, publication, persistence,
  provider transport, Keychain, or search indexing;
- capture, recording, Teams, virtual microphone, media, or Windows paths;
- product actions, retry semantics, title ownership, or editor save lifetime.

The branch is stacked on Draft PR #8. It does not merge or mark PR #8 Ready,
does not start PR C, and does not modify the active PR #8 worktree.

## 3. Production data and ownership

Every screen renders only canonical data from the existing owners:

- Library: capture one `LibraryFeatureModel.snapshot` per body and derive
  visible sessions from `snapshot.sessions`;
- ASR: capture one `TranscriptionFeatureModel.presentation` per body;
- Meeting Intelligence: capture one
  `MeetingIntelligenceFeatureModel.snapshot` per body and use
  `snapshot.presentation(for:)` with the canonical Library session;
- playback: observe the existing `PlaybackFeatureModel`; `ContentView` remains
  the sole owner of the external playback presenter;
- provider settings: observe the one injected `AIProviderSettingsModel` and
  its repository-backed draft.

The provider view must consume the existing
`AppModel.aiProviderSettingsModel` instance. Provider Settings, ASR, Meeting
Intelligence, and `AppModel` must continue to share the exact same active
`OpenAICompatibleProviderManaging` repository instance validated by
`PRBFeatureBoundaries`. Production composition and render fixtures must not
construct a second provider repository or silently replace the injected
settings model.

The UI never reconstructs `MeetingIntelligenceSessionPresentationIdentity`,
normalizes a second session identity, or mirrors mutable feature state in
`AppModel` or a view model. A view-local route may retain only the selected
canonical session ID and must re-resolve the session from the current Library
snapshot.

## 4. Shared workspace and branded sidebar

- Preserve `NavigationSplitView` and the existing
  `RecorderNavigationState`/`RecorderDestination` route contract.
- Use a 232–278 point branded sidebar at wide sizes and 185 points at the
  accepted 860×680 minimum.
- Sidebar gradient: `#132452` → `#244F9E` → `#112B63`.
- Show the Local Meeting Recorder brand, app version, Record/Recordings/Settings
  rows, and the existing stable navigation accessibility identifiers.
- Selection uses a restrained blue/cyan treatment; keyboard focus and native
  selection semantics remain available.
- The bottom storage card may show the real selected output folder and current
  storage warning. It must not invent available-space numbers or a progress
  fraction that no repository currently publishes.
- Keep system-owned traffic lights and window chrome. Do not reproduce the
  prototype's raster traffic-light row inside the sidebar.
- The workspace minimum stays 860×680; the wide validation target is 1280×800,
  with a 1536×1024 visual comparison capture where practical.

## 5. Visual tokens and appearance

Shared accents:

- cyan `#19C3DC`;
- action blue `#1678EE`;
- success `#25B773`;
- warning `#F06A1B`;
- destructive `#FB605A`.

Recordings and Provider Settings use an intentionally dark, opaque hierarchy.
Transcript and Meeting Intelligence follow the macOS `colorScheme`:

| Token | Light | Dark |
| --- | --- | --- |
| canvas | `#FBFBFD` | `#121824` |
| card | `#FFFFFF` | `#181F2C` |
| editor | `#FFFFFF` | `#141B27` |
| primary text | `#101527` | `#F2F5FB` |
| secondary text | `#565F78` | `#ADB6C7` |
| hairline | `#DFE3EA` | `#343D4E` |

Use an 8-point spacing base, 9–12 point content/control radii, and an 18-point
outer workspace radius only where system window composition permits it.
Forms, transcript text, summaries, and status remain opaque. Liquid Glass is
limited to navigation and selected primary control clusters through
`RecorderGlass`; Reduce Transparency retains the existing material plus
separator fallback.

There is no new application theme preference. The companion's Light/Dark
buttons only demonstrated the two system appearances. Production responds to
the environment automatically.

## 6. Recordings destination

- Use the deep-navy canvas and opaque bordered recording cards.
- Preserve search, Favorites, Upload Audio, Refresh, Play, Open Folder, Edit
  Details, Transcribe/Cancel, View Transcript, Open Log, and Trash.
- Compute the visible session array once per body from the captured Library
  snapshot. Preserve transcript snippets and favorites filtering.
- Rows show only real title, created date, duration, file size, tags, favorite,
  and real ASR status.
- A selected row expands one action strip. Preserve the existing
  session-specific `RecorderActionID` identifiers and expose `Expanded` or
  `Collapsed` as the row's VoiceOver value; do not introduce a second action
  marker namespace.
- Trash stays visually subordinate and keeps confirmation.
- Do not show a fabricated waveform, seek position, transcription percentage,
  speaker name, participant, or timestamp.

## 7. Transcript detail

Selecting View Transcript transitions within the Recordings destination to a
detail composition with a Back action. This replaces the older default of a
modal transcript sheet for the primary path while remaining presentation-only:
the selected route stores only a session ID and re-resolves the canonical
session. Metadata editing may remain a native sheet.

If that session ID no longer resolves after Trash, workspace change, or a
Library reload, the view must atomically clear the detail route and draft,
return to the Recordings list, and admit no stale transcript, Meeting
Intelligence, playback, save, or metadata command. A session with the same
display name is never treated as the missing session.

The detail contains:

1. Back, Open Folder, Copy, and Export actions;
2. canonical title, favorite, and Edit Details action;
3. a compact playback command that opens the existing external playback
   window;
4. Meeting Intelligence;
5. the existing draft-safe transcript editor;
6. a fixed footer with real duration/size, Cancel, Save, in-flight state, and
   save failure feedback.

The transcript draft remains stable while Library metadata or Meeting
Intelligence snapshots update. Save remains duplicate-safe and dismisses only
for the expected session/artifact. `AVPlayerView`/`VideoPlayer` never enters the
workspace hierarchy.

Cancel discards the current unsaved draft and returns to the Recordings list.
A successful Save publishes through the existing async save path and returns
to the list exactly once for the expected session and transcript artifact. A
failed or stale-session Save keeps the detail open, retains the draft, and
shows the existing accessible `LibrarySaveFailure.userMessage`.

## 8. Meeting Intelligence

Render the existing product states and commands without invented progress:

- availability not confirmed: published status plus Check Again and explicit
  Generate where the existing presentation admits it;
- checking/generating: native indeterminate progress and Cancel;
- ready/stale: summary, suggested title, and Regenerate;
- failed/cancelled/interrupted: published recovery status and Retry;
- manually protected title: existing protection copy and Apply Suggested
  Title.

Completion/title feedback uses the existing immutable snapshot revision,
canonical session presentation identity, phase, title, and title ownership.
Applying a suggested title must immediately re-resolve the canonical session
so protection and Apply disappear without reopening the detail.

No action items, decisions, risks, calendar actions, chat, speaker
diarization, timestamps, token count, stage count, or percentage is added.

## 9. Settings and Provider

The Settings destination composes a secondary navigation rail and one selected
section. The visual categories are Audio, Recording, Transcription, AI
Provider, and Storage & Shortcuts. They are presentation-only destinations
backed by the existing `AppModel` and the same provider settings model; no
`SettingsFeatureModel` is introduced before PR C.

Existing controls retain exact action parity and identifiers:

| New section | Existing controls | Existing command / binding and identifier |
| --- | --- | --- |
| Audio | system/screen-audio permission | `requestSystemAudioPermission()` or `openScreenCaptureSettings()`; `recorder.settings.capture-section` remains reachable |
| Audio | microphone permission | `requestMicrophonePermission()` or `openMicrophoneSettings()`; existing permission row semantics remain |
| Audio | microphone device | `selectMicrophone(_:)`; `recorder.settings.microphone-picker` |
| Audio | Virtual Mic identity/status | existing `recorder` and `virtualMicInstallationState` projections; `recorder.settings.audio-integration-section` |
| Recording | capture mode | `selectCaptureMode(_:)`; `capture-mode-picker` |
| Recording | selected application | `selectCaptureApplication(bundleIdentifier:)`; `recorder.settings.capture-application-picker` |
| Recording | refresh/reconnect app | `refreshCaptureApplications()` / `reconnectSelectedApplication()`; `recorder.settings.capture-refresh` / `reconnect-selected-application` |
| Recording | Teams screen capture/window | `setTeamsScreenCaptureRequested(_:)` / `selectTeamsScreenCaptureWindow(_:)`; `teams-screen-capture-toggle`, `teams-screen-capture-status`, `teams-screen-window-menu` |
| Recording | Teams Auto Recording | `setTeamsAutoMeetingEnabled(_:)` / `cancelTeamsAutoMeetingCountdown()`; `teams-auto-recording-toggle`, `teams-auto-recording-status`, `teams-auto-recording-cancel` |
| Recording | Teams Mute Sync/pairing | `setTeamsMuteSyncEnabled(_:)`, `retryTeamsMuteSync()`, `requestTeamsPairing()`; `teams-mute-sync-status` and existing control labels |
| Transcription | ASR explanatory/profile context | existing transcription section projection; no new ASR job command or settings owner |
| AI Provider | provider profile and connection | the single `AppModel.aiProviderSettingsModel`; all existing `RecorderActionID.provider*` identifiers |
| Storage & Shortcuts | selected output folder and existing shortcuts | existing `AppModel.outputFolder`, `chooseOutputFolder()`, and `setOutputFolder(_:)`; no second workspace source or revision |

No existing permission, capture, Teams, mute-sync, virtual-mic, provider, or
workspace control may be dropped or duplicated by the new composition.

AI Provider uses the approved dark surface and supports exactly:

- HKT GenAI Platform: Group ID plus read-only resolved endpoint;
- OpenAI-compatible API: editable API Base URL;
- API-key replacement/removal;
- ASR model, LLM model, language, prompt, discovered-model selection;
- Save, Test, Remove Key, and real status/error presentation.

Save continues to affect future jobs only. Active ASR and Meeting Intelligence
snapshots remain unchanged. Connection success is shown only from a real model
state; no decorative “verified” state is fabricated.

## 10. Motion, floating windows, and accessibility

- Reuse `RecorderMotionPolicy`, `RecorderMotionButtonStyle`,
  `RecorderStatusTransition`, and `RecorderObservedTransition`.
- Reduce Motion removes scale, movement, pulse, shimmer, and draw-on effects;
  text and command availability remain unchanged.
- Preserve every existing `RecorderActionID` and destination/panel marker.
- Preserve VoiceOver names, keyboard activation, focus rings, and visible
  focus transfer for Back/navigation.
- Keep the recording controller at 390×112 and Teams countdown at 360×94.
- Do not change their presenter ownership, AppKit level, non-activation,
  cross-Space behavior, dragging, placement, close/cancel semantics, or exact
  action routing.
- Recording remains visible while finalizing and its Stop/screen controls stay
  disabled exactly as currently published.

## 11. Automated acceptance

TDD must cover:

- 860×680 and 1280×800 workspace renders with the branded sidebar;
- repeated Record → Recordings → Settings → Recordings/detail switching;
- deep-navy Recordings cards and session-specific actions without duplicate
  filtering;
- HKT and OpenAI Provider composition at both supported sizes;
- Transcript/Meeting Intelligence in light and dark environments with visibly
  distinct surface markers/tokens;
- Trash, workspace change, or Library reload removing the selected session
  atomically returns to the list, clears the draft, and admits no stale detail
  action;
- every existing Meeting Intelligence state and manual-title protection;
- transcript draft/save failure/in-flight behavior after the route change;
- `AVPlayerView` remains outside the main content hierarchy;
- Reduce Motion/Transparency and increased-contrast-compatible markers;
- unchanged floating panel dimensions, identifiers, and command admission.

Avoid brittle pixel-color assertions. Use stable accessibility/diagnostic
markers for semantic surfaces, then perform manual visual comparison.

## 12. Manual acceptance and non-goals

Manual staging checks:

- compare Recordings, HKT Provider, OpenAI Provider, and every Meeting
  Intelligence state with the checked-in PR #7 frames;
- check 860×680, 1280×800, Light, Dark, Reduce Motion, Reduce Transparency,
  increased contrast, keyboard, and VoiceOver;
- exercise repeated detail open/back/save/failure, external playback, and
  floating-panel behavior on multiple Spaces;
- verify Stop, Cancel, Save, Retry, and navigation remain immediate.

This is UI acceptance only. It does not establish real HKT/provider, Teams,
TCC, AirPods, media, notarized-artifact, or production acceptance.

The prototype's sample titles, dates, tags, durations, storage values, Group
ID, API key, model names, transcript, summary, and status are illustrative and
must never ship as factual defaults.
