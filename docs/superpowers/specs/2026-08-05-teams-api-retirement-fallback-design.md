# Teams API Retirement Fallback Design

## Context

Microsoft retired the legacy Teams desktop third-party meeting and call
control integration on June 30, 2026. Local Meeting Recorder currently uses
that loopback WebSocket integration for two authoritative values:

- whether the signed-in Teams desktop client is in a meeting; and
- whether that Teams participant is muted.

The retirement does not affect ScreenCaptureKit capture, the Recorder mic
track, `Local Recorder Virtual Mic`, or macOS native input-mute handling. The
replacement therefore separates meeting detection from privacy mute instead
of trying to recreate the retired protocol.

## Goals

- Restore useful automatic recording without a Teams private API.
- Keep automatic ownership rules: only an automatically started recording may
  be automatically stopped.
- Make microphone privacy independent of the Teams mute icon.
- Remove pairing, token, retry, and connection-state UX that can no longer
  succeed.
- State clearly that window-based meeting detection is heuristic.
- Preserve manual recording, manual window selection, screen-capture toggle,
  native input mute, Recorder-local mute, and virtual-mic behavior.

## Non-Goals

- Reimplement or probe the retired `127.0.0.1:8124` protocol.
- Add a Microsoft Graph tenant application, webhook, bot, or cloud service.
- Add a TeamsJS meeting app.
- Read or click Teams controls through macOS Accessibility in this slice.
- Inject Teams keyboard shortcuts or attempt to keep the Teams mute icon in
  lockstep with Recorder.
- Auto-start recording merely because the Teams process is running.

## Approaches Considered

### 1. Local window presence with existing capture infrastructure — selected

Use the already-permitted Teams window inventory and existing
`TeamsMeetingWindowResolver` candidate rules to derive a local meeting
presence signal. This keeps the app local, works for meetings hosted by other
tenants, and reuses the established countdown and recording-ownership model.
It is not authoritative, so stability thresholds, visible confidence, manual
override, and conservative stop behavior are required.

### 2. Microsoft Graph meeting call notifications — rejected for this slice

Graph can emit call-started, call-ended, and roster events, but requires
application permissions, a known join URL, an internet-reachable webhook,
encrypted rich notifications, and subscription renewal. A meeting call being
active also does not prove that this Mac joined it. This conflicts with the
local personal-app boundary.

### 3. Teams Accessibility or keyboard automation — deferred

Read-only Accessibility inspection could strengthen presence or observe the
Teams mute button, but depends on Accessibility permission, localization, and
Teams UI structure. Clicking controls or injecting a toggle shortcut risks
state inversion. It may be prototyped later behind an Experimental label, but
is not part of the first fallback.

## Architecture

### `TeamsLocalMeetingDetector`

Add a focused, deterministic state machine that consumes window-resolution
observations rather than owning ScreenCaptureKit itself.

Inputs:

- `.ready(match)` when the existing Teams resolver identifies a visible,
  normal-layer, meeting-sized Teams window;
- `.ambiguous(candidates)` when multiple similarly credible windows exist;
- `.waiting` when there is no eligible visible candidate; and
- monotonic ticks supplied by the existing refresh loop.

Refactor `TeamsMeetingWindowResolver` so its window eligibility and ambiguity
resolution can run in local-detection mode without an externally supplied
`meetingActive` value. Preserve the existing meeting-generation scoring only
for callers that already possess an authoritative lifecycle signal; local
detection ranks visible eligible windows by the existing recency, manual
override, and area rules. This removes the current circular dependency where
the resolver refuses to resolve a window until the retired API first declares
the meeting active.

Outputs:

- `waiting`: no locally detected meeting;
- `candidate(secondsRemaining)`: one stable window is being confirmed;
- `detected(confidence)`: the same eligible window has remained stable for
  three consecutive refresh observations;
- `ending(secondsRemaining)`: the detected window is absent while an
  automatically owned recording may still be active; and
- `ambiguous`: manual window selection is required before auto-start.

The detector uses observation counts instead of wall-clock timers so tests
remain deterministic and the existing refresh cadence remains the single
polling owner. Three positive observations are required to enter `detected`.
Thirty consecutive missing observations are required to exit `detected`.
If the refresh cadence changes from one second, AppModel must translate the
desired three-second and thirty-second policy into counts at construction.

An ambiguous resolution never starts recording. A high-confidence manual
window selection may become the stable candidate. Window identity replacement
must follow the existing resolver's replacement behavior rather than being
implemented again in the detector.

### AppModel integration

When `Teams Window Auto Mode` is enabled, the existing Teams window refresh
loop remains active even when screen video capture is off. AppModel passes each
window resolution to `TeamsLocalMeetingDetector` and routes only confirmed
transitions into `TeamsAutoMeetingCoordinator.handleMeetingState`.

The existing coordinator retains:

- the silent cancellable five-second start countdown;
- manual-recording suppression;
- explicit automatic recording ownership;
- automatic-stop protection for manual recordings; and
- transfer-to-manual behavior when auto mode is disabled mid-recording.

The detector's thirty-second negative confirmation replaces the coordinator's
old ten-second API disconnect debounce for local window mode. AppModel must not
apply both delays. A temporary ScreenCaptureKit inventory failure is an
unknown observation, not a meeting-end observation, and must not advance the
negative counter.

### Virtual Mic Privacy Mute

Remove Teams mute state as an input to `MicrophoneMuteGate`. Effective mute is
the logical OR of:

- Recorder-local mute; and
- macOS native input mute, including an accepted AirPods/input mute gesture.

The effective state continues to synchronously gate both the recorded mic path
and `Local Recorder Virtual Mic`. Teams may independently mute its own input;
the Teams icon is no longer represented as Recorder state.

Keep the persisted user preference only through a one-time compatibility
migration: an old `teamsMuteSyncEnabled` value must not start a retired client
or force a fail-closed mute. The new privacy-mute behavior is always available
when virtual mic/native input handling is available and therefore needs no
pairing toggle.

### Retired integration removal

Production composition must no longer instantiate, start, reconnect, pair, or
read tokens for `TeamsMuteSyncClient`. Delete the production WebSocket and
pairing-token implementation once no production reference remains. Tests may
retain small fixtures only while migrating behavior; no shipped UI or runtime
path may reference port `8124`, protocol version `2.0.0`, pairing approval, or
Teams API retry.

## User Interface

Recording settings:

- Rename `Teams Auto Recording` to `Teams Window Auto Mode`.
- Add a `Beta` label and this explanatory copy: `Detects a Teams meeting from
  its visible meeting window. Keep Recorder open and verify the countdown.`
- Statuses are `Waiting for Teams meeting window`, `Confirming Teams meeting`,
  `Teams meeting detected`, `Waiting for meeting window to return`, and
  `Choose a Teams meeting window`.

Audio settings:

- Replace the Teams API pairing/mute-sync section with `Virtual Mic Privacy
  Mute`.
- Explain that Recorder and native input mute silence the mic track and
  `Local Recorder Virtual Mic`, while the Teams mute icon may differ.
- Retain the existing Recorder mute control and native input/AirPods
  availability status.
- Remove `Pair`, `Retry`, `Connected`, and `Waiting for Allow` controls/copy.

Countdown panel title becomes `Teams Window Auto Recording` while retaining
the existing Cancel action and five-second countdown.

## Persistence and Migration

- Continue reading `teamsAutoMeetingEnabled` so existing users keep their
  auto-mode preference, but present it under the new name.
- Remove `teamsMuteSyncEnabled` from live behavior. On first launch of the new
  version, delete that preference and any stored pairing token through the
  existing token-store abstraction without exposing the token.
- Migration failure must not prevent recording; it produces a redacted local
  status and retries on a future launch.
- Do not modify capture selection, recording folders, or existing recordings.

## Error and Safety Behavior

- Window inventory permission denied: auto mode stays enabled but blocked with
  a permission-specific message and never starts recording.
- Inventory refresh error: preserve the previous detector state and do not
  infer meeting end.
- Ambiguous windows: require manual selection; do not guess.
- Candidate disappears before confirmation: return to waiting without issuing
  a recording command.
- Detected window disappears temporarily: keep an auto-owned recording active
  for the thirty-second grace period.
- Manual recording is never auto-stopped.
- Disabling auto mode during an auto-owned recording transfers ownership to
  manual, matching current behavior.
- Privacy mute state must be applied synchronously to audio paths before UI
  publication.

## Testing

TDD coverage must include:

- detector RED/GREEN tests for three-observation confirmation, candidate reset,
  ambiguity, identity change, unknown refresh, and thirty-observation exit;
- AppModel integration tests proving confirmed presence starts the existing
  countdown and confirmed absence stops only auto-owned recordings;
- tests proving a manual recording survives all local-detector transitions;
- tests proving enabling auto mode never starts the retired Teams client;
- mute-gate tests proving local and native input mute are the only production
  authorities and still gate the virtual mic;
- migration tests proving old pairing/mute-sync preferences cannot reconnect or
  mute the Recorder;
- render/accessibility tests for the new labels, statuses, Beta disclosure, and
  removal of pairing/retry controls;
- source-contract tests rejecting shipped `127.0.0.1:8124`, pairing, and legacy
  Teams API UI copy;
- focused tests, then the full Swift suite, release build, bundle verification,
  and `git diff --check`.

## Acceptance Boundaries

Automated tests and a successful build prove state-machine and composition
behavior. They do not prove that a future Teams UI exposes a suitable window.
Installed-app acceptance must separately demonstrate:

1. a real Teams meeting window reaches the five-second countdown;
2. cancelling suppresses that meeting only;
3. an auto-owned recording starts and survives a short pop-out/window switch;
4. closing/leaving the meeting stops it only after the grace period;
5. a manual recording is not stopped;
6. Recorder mute and native/AirPods mute produce near-silence from the actual
   `Local Recorder Virtual Mic`; and
7. the app makes no connection attempt to port `8124`.

Until those installed-app checks pass, label the feature Beta and describe the
result as a build candidate rather than accepted Teams behavior.
