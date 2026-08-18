# Per-job Transcription and Floating Panel Collapse Design

Date: 2026-08-18
Status: Approved design

## Objective

Replace the saved, universal ASR language and prompt interaction with a per-recording transcription sheet, and make the eye control on both floating panels collapse or expand the whole panel instead of merely hiding a red recording indicator.

## Scope

This design covers two bounded changes:

1. A per-job transcription sheet for recordings in the Recordings workspace.
2. A shared expanded/collapsed presentation for the recording controller and Teams automatic-recording countdown floating panels.

It does not change provider endpoints, model selection, API-key storage, Privacy Mode, transcription artifact schemas, publication behavior, recording lifecycle, Teams meeting detection, or native window minimization.

## Transcription Sheet

### User interaction

Selecting **Transcribe** for a canonical recording opens a modal sheet instead of immediately starting transcription. The sheet contains:

- A language picker with exactly `Cantonese`, `English`, and `Mandarin`.
- A multiline prompt editor.
- `Cancel` and `Transcribe` actions.

Every newly opened sheet defaults to Cantonese (`yue`) and a blank prompt. The prompt is optional. The sheet does not remember the prior selection or prompt.

`Cancel` closes and clears the draft without starting work or changing provider settings. `Transcribe` trims surrounding prompt whitespace, creates typed per-job options, revalidates the selected recording against the current canonical library snapshot, and starts the existing transcription pipeline only for the validated session.

### Data boundaries

The per-job options contain only:

- One typed `MeetingLanguage` value mapped to `yue`, `en`, or `zh`.
- The optional prompt text for that attempt.

The options flow from the Recordings sheet through `AppModel` and the transcription feature boundary to `TranscriptionJobCoordinator`. The coordinator continues to obtain one immutable provider snapshot from the existing repository. It then derives an ephemeral attempt snapshot by replacing only the snapshot language and prompt with the per-job values. Endpoint, provider kind, group ID, ASR model, API key, redirect policy, workspace fence, mutation gate, Privacy Mode admission, and artifact publication remain unchanged.

The per-job prompt is memory-only. It is not saved to UserDefaults, the provider profile, recording metadata, transcription diagnostics, or artifact logs.

### Provider Settings compatibility

The global ASR language and prompt controls are removed from Provider Settings. Existing profile storage retains its language and prompt fields for wire and stored-profile compatibility. Every subsequent Provider Settings save writes the compatibility values `yue` and an empty prompt. Loading an older profile does not mutate it until the user saves, and new transcription attempts never treat its stored prompt as a default or authority.

Meeting-intelligence prompts are outside this change and remain independently configurable.

### Admission and errors

Opening the sheet does not consume any admission or start a task. On confirmation, all existing gates remain authoritative:

- The recording must still resolve to the same canonical session.
- Privacy Mode must allow third-party processing.
- A provider profile must be saved and valid.
- Only one transcription may run at a time.

Failure uses the existing safe status-message path. A stale or removed recording closes the draft and does not dispatch transcription. Cancellation, failure, or successful dispatch clears the sheet draft so sensitive prompt text is not retained by the view.

## Floating Panel Collapse

### Shared state

Both floating panels use the same two-state presentation contract:

- `expanded`
- `collapsed`

The state belongs to the current panel episode and is not persisted. A new recording-controller episode or a new Teams countdown episode begins expanded.

### Expanded presentation

Expanded panels preserve their current controls and lifecycle behavior. The visible header uses the neutral word `Running` instead of `Recording`. Existing elapsed time, waveforms, microphone mute, screen capture, stop, countdown, and cancel controls remain available where applicable.

### Collapsed presentation

Activating the eye control while expanded resizes the panel to a `132 × 40` capsule. The collapsed panel displays only:

- The neutral text `Running`.
- The eye control used to expand the panel.

It does not display a red recording indicator, the word `Recording`, elapsed time, countdown, waveform, signal state, microphone state, screen-capture state, stop, or cancel controls.

Activating the eye again restores the original panel size and expanded content. Resizing preserves the panel's top-right screen anchor so it does not visibly jump. The existing native macOS minimize button remains available.

Collapse is presentation-only. It does not pause recording, cancel a countdown, alter microphone state, change screen capture, or affect lifecycle timers. If a countdown completes while collapsed, the existing controller transition still occurs normally.

This presentation reduces how obvious the panel is during screen sharing, but it does not claim to hide the window from macOS, third-party capture software, accessibility clients, or window enumeration.

### Accessibility

The eye action exposes state-specific labels and values:

- Expanded: `Collapse floating window`, value `Expanded`.
- Collapsed: `Expand floating window`, value `Collapsed`.

Collapsed accessibility output does not expose hidden recording-indicator or hidden control markers through the panel view hierarchy. Recording and countdown lifecycle state remains available in the main application where it already exists.

## Testing Strategy

Implementation follows focused TDD with failing tests before production changes.

Transcription coverage:

- A new draft defaults to Cantonese and a blank prompt.
- The language set contains exactly Cantonese, English, and Mandarin.
- Cancel does not start transcription or persist the draft.
- Confirm passes the trimmed per-job language and prompt to the existing job.
- A stale canonical session cannot start transcription.
- Stored universal language and prompt do not override per-job options.
- Provider Settings no longer renders the global ASR language and prompt controls.

Floating-panel coverage:

- Both panels render their existing expanded content.
- Both panels collapse to only `Running` and the eye control.
- No red recording-indicator marker or hidden action marker is rendered while collapsed.
- Toggling again restores expanded content and size.
- The top-right anchor remains stable across resize.
- A new panel episode starts expanded.
- Accessibility labels and values match the presentation state.

Verification is deliberately bounded to the directly affected model, coordinator, settings render, Recordings render, and floating-panel tests, followed by one production build. The full test suite is not required for this feature.

## Non-goals

- Persisting or remembering per-job transcription choices.
- Adding languages beyond Cantonese, English, and Mandarin.
- Changing meeting-intelligence prompts.
- Adding transcription templates or prompt history.
- Making floating panels undetectable to screen-capture or accessibility APIs.
- Changing native minimize behavior.
- Refactoring unrelated provider, recording, publication, or library architecture.
