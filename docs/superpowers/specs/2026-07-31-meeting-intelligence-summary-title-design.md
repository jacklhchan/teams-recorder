# Meeting Intelligence Summary and Contextual Title Design

**Date:** 2026-07-31

**Status:** Approved design; written spec independently reviewed

**Approved product decision:** 2026-07-31

**Approved provider-preset amendment:** 2026-07-31, from the user's explicit
request after the original approval

**Baseline:** `main` at `c7f1aeb6a0ca6833e6af6cd01febbc1cbfc2a5cf`

**Branch:** `codex/meeting-intelligence-summary-title`

**Platform:** macOS 26.0 and later

## 1. Context

The recorder already stores one OpenAI-compatible provider profile with
separate `asrModel` and `llmModel` values. This feature replaces that
single-overwrite settings experience with two saved provider presets:
`HKT GenAI Platform` and `OpenAI-compatible API`. Each preset retains its own
non-secret configuration and Keychain credential. The two model identifiers
may be identical or different according to the provider. Only `asrModel` is
currently used at runtime. `llmModel` is persisted and editable, but no LLM
request, summary artifact, contextual title generation, or
meeting-intelligence job lifecycle exists.

The library displays `metadata.title` when present and otherwise falls back to
the timestamp-shaped session folder name. A successful transcription publishes
the canonical `transcript.txt` and rebuilds the affected search document.
Editing the transcript also rebuilds that document. These are the authoritative
events from which meeting intelligence must derive.

This feature adds a separate, failure-isolated LLM workflow. It does not turn
transcription into a combined ASR-and-LLM transaction: a successful transcript
remains successful even if availability checking, summary generation, title
publication, cancellation, or persistence later fails.

The later user-approved feature request supersedes only the earlier UI
feature-boundary document's Meeting Intelligence non-goal for this dedicated
pull request. It does not reopen PR A, combine PR B/PR C, or weaken their
single-owner and construction-handoff rules.

## 2. Goals

1. Continue allowing users to select independent ASR and LLM model identifiers
   under the same OpenAI-compatible provider profile.
2. After successful canonical transcript publication, automatically generate a
   meeting summary and contextual title only when the configured LLM model is
   confirmed by the provider's model inventory.
3. Send no automatic LLM request when availability is unsupported, unknown,
   failed, or does not contain the exact configured `llmModel`.
4. Allow an explicit user-initiated Generate or Regenerate attempt even when
   model discovery is unsupported or inconclusive.
5. Replace timestamp/folder fallback titles with contextual generated titles
   while never silently overwriting a title the user has edited or cleared.
6. Persist successful summaries, suggestions, provenance, transcript revision,
   and title ownership across app launches.
7. Make transcript edits invalidate old intelligence deterministically and
   reject every stale or cancelled callback.
8. Support long transcripts with a bounded multi-pass pipeline rather than
   silently truncating input.
9. Preserve existing provider security, bounded transport, cancellation,
   redirect, credential, library-search, and unknown-metadata-field guarantees.
10. Provide focused lifecycle, integration, UI render, contract, packaging, and
    real-provider acceptance evidence.
11. Let users switch between saved `HKT GenAI Platform` and
    `OpenAI-compatible API` configurations without erasing either preset, and
    freeze the selected preset, endpoint, authentication scheme, models,
    language, prompt, and credential in each future job snapshot.

## 3. Non-goals

This pull request does not add:

- action-item extraction, decisions, risks, questions, or follow-up email
  generation;
- timestamped transcript segments, speaker diarization, or live captions;
- a `/responses` endpoint adapter or silent endpoint fallback;
- calendar, MCP, Zoom, Webex, or Google Meet integrations;
- summary full-text indexing or transcript-snippet replacement;
- Windows implementation changes or stacked Windows migration changes;
- the PR B/PR C feature-boundary refactor;
- production notarization, Teams hardware acceptance, or AirPods acceptance;
- transactional publication across the existing ASR artifact set and the new
  meeting-intelligence artifact set.
- automatic rotation across multiple HKT groups, local rate-limit proxies, or
  provider failover chains.

## 4. Confirmed Availability Contract

The approved automatic-generation rule is deliberately conservative:

```text
successful canonical transcript publication
  -> capture immutable provider snapshot
  -> GET <baseURL>/models with that snapshot
  -> decode the standard model inventory
  -> exact configured llmModel identifier is present
       yes -> automatic LLM generation may start
       no  -> send zero automatic LLM generation requests
```

Automatic generation is eligible only when all of the following are true:

- a saved provider profile can be snapshotted;
- `llmModel` is non-empty and is not the legacy
  `legacy-unconfigured-llm` placeholder;
- the canonical transcript is a readable, non-empty regular file inside the
  selected session folder;
- `GET <baseURL>/models` returns a successful, decodable model list;
- the exact configured `llmModel` occurs in that list;
- the same transcript revision has no current successful result;
- no active attempt already owns that session.

The following outcomes all send zero automatic chat requests:

- `/models` returns 404 or 405;
- the provider is unreachable or times out;
- authentication is rejected;
- the response is malformed, oversized, or contains too many models;
- the selected LLM identifier is absent;
- settings contain only the legacy placeholder;
- the transcript is missing, empty, unsafe, or beyond the supported source
  bound;
- the callback belongs to a stale transcription attempt.

`/models` confirmation proves only that the provider advertises the identifier.
It does not claim that `/chat/completions` will succeed. A later chat failure is
recorded as a meeting-intelligence failure and never changes ASR completion.

Manual Generate and Regenerate are explicit user authorization. They validate
the saved profile and transcript, capture a fresh immutable snapshot, and may
call `/chat/completions` without requiring `/models` confirmation. This supports
providers whose model discovery is missing or incomplete. Manual attempts still
obey every request-size, credential, redirect, single-attempt, cancellation, and
publication guard.

The legacy `legacy-unconfigured-llm` placeholder is never sent, including for a
manual attempt. The user must save a real LLM model identifier first.

Action intent is explicit:

| UI/event | Discovery required | May send chat | Title result |
|---|---|---|---|
| automatic after new ASR publication | exact `/models` match | only after match | apply only to `unset`/eligible generated title; otherwise suggestion |
| Check Again after automatic ineligibility | exact `/models` match | no; this action checks availability only | unchanged |
| Generate with no current result | bypass permitted by explicit action | yes | apply to `unset`; preserve manual title |
| Regenerate current or stale result | bypass permitted by explicit action | yes | replace eligible generated title; preserve manual title |
| Retry Generation after request/pipeline failure | bypass permitted by explicit action | yes | same as the failed Generate/Regenerate intent |
| Cancel | not applicable | sends no later request | unchanged |
| Apply Suggested Title | not applicable | no | compare-and-save suggestion as `meetingIntelligence` |

`Check Again` and `Retry Generation` are deliberately different labels and
commands. An availability check can never silently become a billable generation
request.

No availability result is persisted as a durable capability claim. Automatic
generation performs a fresh check for its immutable job snapshot. Provider URL,
API key, or model edits therefore affect future jobs without mutating an active
job.

## 5. Ownership and Architecture

Meeting intelligence is independent of `TranscriptionJobCoordinator`:

```text
TranscriptionJobCoordinator
  -> TranscriptPublished(
       session,
       canonicalURL,
       canonicalSHA256,
       sessionFolderIdentity,
       transcriptionCoordinatorInstanceID,
       transcriptionGeneration,
       transcriptionAttemptID
     )
       |-- Library search-document rebuild
       `-- MeetingIntelligenceJobCoordinator.startAutomatic(session)

Recordings UI
  -> Generate / Regenerate / Cancel / Apply Suggested Title
       `-- MeetingIntelligenceJobCoordinator
             |-- provider snapshot repository
             |-- availability client
             |-- bounded LLM pipeline
             |-- artifact/state stores
             `-- semantic publication callback
                    `-- targeted Library session refresh
```

`MeetingIntelligenceJobCoordinator` is `@MainActor` and is the only owner of:

- active per-session tasks;
- per-session generations and attempt identifiers;
- cancellation intent;
- per-session presentation state;
- provider/transcript snapshots captured for each attempt;
- stale-result and publication eligibility.

The coordinator may run attempts for distinct sessions independently. A session
has at most one active attempt. Regenerate for an active session first
invalidates and cancels the old attempt; the replacement receives a new
generation and attempt identifier.

For this bounded feature pull request, the existing single `AppModel`
temporarily constructs and retains exactly one meeting-intelligence
coordinator, forwards typed commands, and exposes read-only coordinator
projections. `AppModel` must not mirror its tasks, generations, attempts,
cancellation flags, or mutable dictionaries. A later PR C construction handoff
moves that same ownership boundary to `AppCoordinator` without copying state or
creating parallel instances.

The existing `AIProviderSettingsModel`, provider repository,
`TranscriptionJobCoordinator`, playback coordinator, recording engine, Teams
coordinators, and workspace-folder source remain single instances.

The provider repository owns one versioned settings envelope containing the
active provider kind plus independent generic and HKT configurations. A legacy
schema-v1 profile migrates as the generic preset. Switching the picker changes
only the selected draft/active kind; it does not copy fields or credentials
between presets. The generic credential retains its existing Keychain identity.
HKT uses a distinct Keychain service/account. Repository snapshots resolve a
complete immutable endpoint and authentication scheme before any ASR,
availability, or LLM work starts. Saving or switching settings changes future
snapshots only.

`TranscriptPublished` is an immutable semantic commit event, not a generic
filesystem notification. `TranscriptionJobCoordinator` emits it only after its
own generation/attempt ownership checks and canonical artifact validation. The
event carries the digest calculated from the committed canonical bytes plus a
coordinator-instance UUID, monotonically increasing transcription generation,
and attempt UUID.

Meeting intelligence records the newest accepted transcription publication
identity per session. It rejects an older or duplicate publication before
provider snapshot, `/models`, or chat work. It then securely rereads the
canonical file and requires its digest and folder identity to match the event.
This prevents a delayed old ASR callback from using a newer transcript to start
an extra automatic job.

## 6. Job Lifecycle and Stale-Result Rules

Each attempt freezes:

- `sessionID` and normalized session-folder identity;
- generation and attempt UUID;
- canonical transcript bytes and SHA-256 digest;
- source byte count;
- the normalized title and `titleOrigin` observed when the attempt starts;
- `OpenAICompatibleProviderSnapshot`, including the exact `llmModel`;
- generation intent: automatic, manual Generate, or manual Regenerate;
- start time.

The coordinator publishes these presentation phases:

```text
notGenerated
checkingAvailability        automatic attempts only
generating(stage/current/total)
ready
stale
failed(recoverableMessage)
cancelled
interrupted                 projected after app restart
```

`unavailable` is a derived presentation with a typed reason, not a successful
capability result. Examples include missing transcript, missing profile,
placeholder LLM model, and unconfirmed automatic availability.

Before every network operation, after every response, before decoding, between
pipeline stages, before artifact publication, and before metadata publication,
the attempt checks cancellation and ownership.

A transcript revision is defined exclusively as the SHA-256 digest of the exact
canonical `transcript.txt` bytes. Byte-identical retranscription or save is the
same revision even when its mtime changes. There is no second UUID/mtime
revision source.

A callback may publish only when all of these still match:

```text
sessionID
session folder identity
coordinator generation
attempt UUID
source transcript SHA-256
```

For automatic attempts, the accepted immutable `TranscriptPublished` identity
must also remain the newest identity for that session.

Immediately before publication, the coordinator rereads the canonical
transcript as a bounded regular file and recomputes its digest. A mismatch
rejects the result without replacing the previous successful artifact or title.

All app-owned transcript, metadata, intelligence-artifact, and
intelligence-state mutations for one session pass through one serialized
session-mutation boundary. Publication stages the candidate result outside the
visible artifact path, then enters that boundary. It revalidates generation and
digest before candidate promotion and again before any metadata write.

Immediately before title publication, the metadata store reloads the current
title and origin. It may write the generated title only when:

- the current origin is `unset`, or it is `meetingIntelligence` and the current
  normalized title still equals the generated title state captured at attempt
  start; and
- the transcript digest and generation are still current.

If title or origin changed while generation was running, publication treats the
current value as user-owned and stores only the new suggestion. Apply Suggested
Title uses the same serialized boundary and compare-before-save rule. This
prevents a completion racing with manual rename, manual clear, tag/Favorite
save, or another Apply action.

The coordinator emits its semantic Library refresh only after all required
publication checks settle. A race rejected before candidate promotion leaves
the prior successful artifact unchanged. A transcript change detected after
summary promotion but before title write leaves the new artifact present but
derived as stale, writes no title, and emits no ready projection; Regenerate is
the recovery.

Transcript save, retranscription publication, session trash, coordinator
shutdown, and replacement of the same session attempt invalidate the generation
and cancel the task. Delayed progress, response, decode, pipeline, and publication
callbacks are ignored. A byte-identical manual save does not invalidate the
artifact, but it still cancels an active attempt before writing and then
re-evaluates the digest. A changed manual transcript save only marks
intelligence stale; it never starts a background replacement. A later
successful ASR retranscription publication is a new authoritative publication
event and may start one availability-gated automatic replacement.

Provider settings saved during a job affect future jobs only. The active
provider snapshot and credential remain unchanged.

## 7. Bounded Long-Transcript Pipeline

The pipeline never silently truncates the transcript.

- One secure canonical-transcript reader is used for initial input, digest
  capture, event verification, and every publication-time reread.
- It accepts only the exact `transcript.txt` session-root path (or the existing
  resolved legacy path for an explicit manual Generate), resolved inside the
  normalized session folder.
- It uses no-follow file opening, requires a regular file, rejects symlinks and
  directories, records device/inode/link-count identity, and revalidates
  identity after the bounded read.
- A canonical file with unexpected additional hard links or an identity change
  during read is rejected. Unsafe input produces zero `/models` and zero chat
  requests.
- The canonical source is read with a fixed maximum of 4 MiB plus one byte for
  overflow detection, matching the current library-search safety boundary.
- A source beyond 4 MiB fails locally before sending transcript content.
- Empty or invalid UTF-8 input fails locally.
- Input is divided at paragraph, sentence, or UTF-8 scalar boundaries into
  request-safe chunks. Source content in one chunk may not exceed 64 KiB of
  UTF-8.
- A one-chunk transcript goes directly to final summary/title generation.
- A multi-chunk transcript is summarized sequentially into bounded partial
  summaries.
- Partial summaries are grouped and recursively reduced until one bounded final
  synthesis request can produce the contextual title and complete summary.
- Progress exposes stage and bounded counts without logging transcript content.
- Cancellation stops before the next request and prevents all later
  publication.

The fixed resource contract is:

| Resource | Bound |
|---|---:|
| canonical source read | 4 MiB plus one overflow byte |
| source content per request | 64 KiB UTF-8 |
| fully encoded JSON request body | 96 KiB |
| HTTP response body | 256 KiB |
| partial-summary content | 4 KiB UTF-8 |
| final summary | 48 KiB UTF-8 |
| contextual title | 120 extended grapheme clusters |
| source chunks | 64 |
| partial summaries per reduction group | 12 |
| recursive reduction depth | 4 |
| total LLM requests per job | 71 |
| one request timeout | 90 seconds |
| total job wall-clock time | 30 minutes |

The encoded JSON `Data.count` is the final authority after JSON escaping and
prompt overhead. The planner reduces a candidate chunk at a valid UTF-8 boundary
until the encoded body fits. If the minimum useful content cannot fit, it fails
locally. It never sends an oversized body.

Each partial response is validated before it can enter a reduction group.
Reduction terminates only when the next bounded input can be synthesized as the
final result. Reaching the chunk, depth, total-request, response, or wall-clock
limit fails the whole attempt with zero partial publication. Oversized model
output is rejected rather than truncated into a misleading result.

## 8. Provider Presets and OpenAI-Compatible LLM Contract

Settings offers exactly these saved provider kinds:

| Preset | User-configurable endpoint input | Resolved base URL | Authentication |
|---|---|---|---|
| `HKT GenAI Platform` | `Group ID`, 1–32 ASCII digits | `https://api.uat.bot-builder.pccw.com/v1/groups/{groupID}/openai` | `X-API-KEY: <key>` |
| `OpenAI-compatible API` | validated HTTPS or loopback base URL | existing normalized URL ending in `/v1` | `Authorization: Bearer <key>` |

The HKT host, scheme, version path, and `/openai` suffix are not editable.
Whitespace, signs, non-ASCII digits, zero digits, or more than 32 digits in
`Group ID` are rejected before any profile or credential write. HKT and generic
settings retain independent ASR model, LLM model, meeting language, prompt, and
credential values. Provider kind and schema are validated before a Keychain
read. Status, logs, metadata, and defaults never contain either credential.

Both presets expose the same OpenAI-compatible resource paths:
`/models`, `/audio/transcriptions`, and `/chat/completions`. The active snapshot
selects the required credential header; request clients do not infer the scheme
from the URL.

The first adapter uses:

```http
POST <baseURL>/chat/completions
Content-Type: application/json
Accept: application/json
Authorization: Bearer <api-key>  # generic preset, when non-empty
X-API-KEY: <api-key>              # HKT preset, when non-empty
```

Exactly one credential header is present for a request.

It sends:

- the immutable `llmModel`, never `asrModel`;
- non-streaming chat messages;
- a system instruction that treats transcript text as untrusted content and
  forbids following instructions embedded in it;
- a bounded user message containing either a source chunk or partial summaries;
- deterministic, low-variance generation parameters supported by the chosen
  OpenAI-compatible contract.

To maximize provider compatibility, JSON-only output is required through the
prompt and validated locally; support for provider-specific structured-output
extensions is not assumed.

The accepted outer response is one non-empty
`choices[0].message.content`. Final content must decode directly as:

```json
{
  "title": "Contextual meeting title",
  "summary": "Complete meeting summary"
}
```

Markdown fences, prose outside the JSON object, missing fields, blank strings,
oversized values, multiple ambiguous choices, and malformed envelopes are
rejected.

The contextual title validator:

- trims whitespace;
- normalizes Unicode to NFC;
- applies the 120-grapheme limit;
- requires meaningful non-date text;
- rejects the session-folder naming pattern and date/time-only output;
- rejects path separators, newlines, bidirectional override/isolate controls,
  NUL, C0/C1 controls, and invisible format controls;
- never falls back to fabricating a title locally.

The summary is generated in the transcript's primary language unless the
transcript itself clearly mixes languages. It must be evidence-bound to the
provided text and must not invent participants, decisions, or facts. Summary
validation normalizes Unicode to NFC, permits ordinary newlines and tabs, and
rejects NUL, other C0/C1 controls, bidirectional override/isolate controls, and
invisible format controls. SwiftUI renders the accepted values as plain text;
the app does not interpret HTML, Markdown links, terminal escapes, or embedded
commands.

Prompt-injection resistance is a layered contract, not a claim that a prompt
alone can control a model. Tests verify role separation and the untrusted-data
instruction, while strict JSON shape, length bounds, Unicode/control
validation, plain-text rendering, title ownership, and user-visible preview
constrain what may be persisted or applied.

## 9. Transport, Redirect, Attempt Budget, and Privacy

The client reuses `ProviderHTTPTransport` and
`URLSessionProviderHTTPTransport` for:

- ephemeral, non-caching sessions;
- bounded declared and streamed response bodies;
- task cancellation and one-shot continuation completion;
- release of session/task/body state after completion.

The current multipart-only redirect policy becomes content-type aware without
weakening transcription:

- only 307 and 308 are supported;
- origin means identical normalized scheme, host, and effective port;
- HTTPS cannot downgrade;
- POST method must be preserved;
- the complete body must be preserved;
- the original content type must be preserved after case-insensitive media-type
  normalization and parameter comparison;
- multipart and JSON requests are validated against their own expected content
  type;
- both `Authorization` and `X-API-KEY` are removed from the proposed redirect;
  exactly the source preset's credential header is restored only after every
  same-origin validation succeeds;
- cross-origin, 301–303, method-changing, missing-body, changed-body, changed
  content-type, scheme-changing, and port-changing redirects are rejected;
- rejected redirects send neither credential header to the destination.

Model-discovery GET requests reject every redirect. They do not reinterpret a
redirect as reachability and never forward either credential header to its
destination.

Redirect tests exercise the actual URLSession delegate path with controlled
URLProtocol/local HTTP fixtures, not only a pure policy function. The existing
multipart ASR 307/308 contract remains a required regression alongside JSON
`application/json` and `application/json; charset=utf-8` cases.

Each encoded request is checked against a fixed body cap before transport.
Response bytes are capped before status handling or decoding.

LLM generation requests are never retried automatically. Even an HTTP 408,
429, or 5xx can arrive after a provider performed billable generation, and an
OpenAI-compatible provider is not guaranteed to honor an idempotency key.
Every pipeline request therefore has an attempt budget of exactly one. The
current job fails without sending its next reduction request, keeps the
previous successful artifact, and offers an explicit user-controlled Retry
Generation or Regenerate action.

The UI may display a bounded Retry-After seconds or HTTP-date recovery hint for
429/503 when present, capped by the existing 60-second policy, but it does not
sleep and resend automatically. Authentication, bad request, model-not-found,
TLS/certificate, cancellation, unsafe redirect, invalid response, oversized
response, and transport failures are also terminal for that attempt.

Availability checking is a single bounded GET. A transient failure makes the
automatic attempt ineligible and sends no paid generation request.

Public errors and persisted state are typed and sanitized. They never contain:

- API keys, `Authorization`, or `X-API-KEY` values;
- request or response bodies;
- transcript or partial-summary content;
- provider error bodies;
- a full provider URL with sensitive components;
- raw prompts;
- complete local home or session paths.

No API key, credential header, transcript, provider body, or prompt is stored
in `recording-info.json`, `meeting-intelligence.json`, state files, diagnostic
status, or logs.

## 10. Persistence and Schema Evolution

### 10.1 Recording metadata v2

`RecordingSessionMetadata.currentSchemaVersion` becomes 2 and adds:

```text
titleOrigin: unset | meetingIntelligence | manual
```

Migration and ownership rules:

- v1 or legacy metadata with a non-empty title decodes as `manual`;
- v1 or legacy metadata with no title decodes as `unset`;
- an explicit manual title edit marks `manual`;
- explicitly clearing the title also marks `manual`;
- saving only tags or Favorite without changing the title preserves its
  existing origin;
- applying a generated suggestion marks `meetingIntelligence`;
- generated-title automatic refresh is allowed only for `unset` or
  `meetingIntelligence`;
- `manual` is never changed by background generation;
- unknown root fields, including nested objects and arrays, continue to
  round-trip unchanged.

The metadata editor captures the original normalized title when it opens and
submits a typed title edit intent. A normalized title different from the
original, including a change to blank, is manual. An unchanged title submitted
with tag/Favorite edits is `unchanged` and preserves origin. Re-entering the
same normalized text does not silently convert a generated title to manual;
the generated origin remains until the text actually changes.
`Apply Suggested Title` is a separate typed path and is the only UI action that writes
`titleOrigin = meetingIntelligence`.

The root recording-session contract accepts compatible v1 and v2 fixtures.
Windows paths are not changed.

### 10.2 Successful result artifact

`meeting-intelligence.json` is a versioned, atomically written success artifact:

```json
{
  "schemaVersion": 1,
  "summary": "…",
  "suggestedTitle": "…",
  "sourceTranscriptSHA256": "sha256:…",
  "sourceTranscriptByteCount": 12345,
  "model": "provider-model-id",
  "generatedAt": "ISO-8601 timestamp",
  "intent": "automatic"
}
```

It contains no credential, base URL, raw transcript, raw provider response, or
prompt.

Regenerate preserves the previous successful artifact until the replacement
has fully validated and atomically published. A failed or cancelled attempt
therefore leaves the last successful summary readable.

### 10.3 Lifecycle state artifact

`meeting-intelligence-state.json` stores the bounded phase, sanitized message,
attempt start/finish times, and source digest required to project interrupted or
stale state after relaunch. It stores no provider response or secret.

An on-disk active phase found at launch is projected as interrupted. The user
may Regenerate; the app never claims that a vanished process is still running.

### 10.4 Artifact read and compatibility rules

Both new stores:

- perform a bounded read before decoding;
- require a regular file at the exact session-root filename;
- reject symlinks, directories, hard-link identity changes during the read, and
  paths escaping the normalized session folder;
- accept only schema version 1;
- ignore unknown fields within version 1 on read because the app never performs
  in-place field editing of a success artifact;
- treat a newer schema version as `createdByNewerApp`, preserve it byte-for-byte,
  and disable automatic replacement;
- treat malformed, oversized, unsafe, or unsupported content as a typed,
  non-crashing Needs Attention projection;
- preserve an existing valid success artifact until an explicit manual
  Regenerate has produced and validated a complete replacement;
- write through a unique same-folder temporary file, fsync/close it, revalidate
  the destination, and atomically replace the exact regular-file target.

Malformed or unsafe state never makes a valid success artifact unreadable. It
is projected as Interrupted/Needs Attention and can be replaced by a later
explicit action. Test fixtures cover valid v1, unknown v1 fields, future
version, malformed, oversized, symlink, directory, and replacement-race cases.

### 10.5 Publication order

Successful generation publishes in recoverable order:

1. validate the current transcript digest and attempt ownership;
2. atomically replace `meeting-intelligence.json`;
3. when title ownership permits, atomically save the generated title and
   `titleOrigin`;
4. publish one semantic result to refresh the affected Library session;
5. settle the job state.

If summary publication succeeds but title metadata save fails, the summary and
suggestion remain available and the UI shows a bounded warning with an explicit
Apply Suggested Title recovery. The feature does not claim cross-file
transactionality.

## 11. Automatic and Manual Title Behavior

| Current title state | Automatic success | Manual Generate/Regenerate success |
|---|---|---|
| no title, origin `unset` | apply contextual title; origin becomes `meetingIntelligence` | apply contextual title |
| generated title, origin `meetingIntelligence` | replace only when transcript revision is new | replace generated title |
| non-empty manual title | preserve title; store new suggestion | preserve title; store new suggestion |
| manually cleared title | preserve the deliberate blank; store suggestion | preserve blank; store suggestion |
| legacy non-empty title | treat as manual and preserve | preserve; offer Apply Suggested Title |

`Use Suggested Title` is an explicit user action. It copies the current,
non-stale suggestion into metadata and sets origin to
`meetingIntelligence`. Any later manual edit restores `manual`.

ASR transcript publication with the same digest as the current success artifact
does not repeat automatic generation. A changed digest marks the old result
stale and may trigger one availability-gated automatic replacement. Manual
transcript editing only marks the result stale and exposes Regenerate; it does
not trigger automatic generation.

## 12. UI Contract

The Settings destination begins with a provider picker containing
`HKT GenAI Platform` and `OpenAI-compatible API`. HKT shows an editable
`Group ID` plus the resolved fixed endpoint as read-only context; generic shows
the editable base URL. Switching reloads that preset's retained draft and
credential status, invalidates any stale connection-test callback, and does not
save until the user chooses Save.

Settings keeps the existing separate ASR Model and LLM Model fields. It adds
stable accessibility identifiers to provider controls and clarifies that:

- ASR Model is used for transcription;
- LLM Model is used for summary and contextual title generation;
- Test lists models when supported;
- automatic meeting intelligence requires the selected LLM model to appear in
  the provider model list;
- manual Generate can still be attempted for providers without discovery.

The existing transcript sheet becomes the session's transcript and Meeting
Intelligence surface. It contains:

- status: Not Generated, Checking Availability, Generating, Ready, Stale,
  Interrupted, or Needs Attention;
- bounded progress without transcript content;
- summary or preserved stale summary;
- generated/suggested title;
- Generate, Regenerate, Cancel, Check Again, Retry Generation, and Use
  Suggested Title as applicable;
- a clear manual-title-protection explanation;
- provider/model recovery guidance when generation is unavailable.

`AppModel` passes the one coordinator-backed presentation source into the
Recordings UI and forwards typed commands. It exposes
`meetingIntelligencePresentation(for:)` as an immutable value derived by the
coordinator. It does not copy a `statesBySessionID` dictionary, task, generation,
or attempt. UI code cannot mutate coordinator lifecycle state directly.
Structural/API tests prove there is one coordinator instance and no second
AppModel-owned lifecycle map.

The session row remains readable and does not gain another dense action cluster.
It may show one compact, non-interactive intelligence status indicator; all
generation commands remain in the transcript sheet.

Stable accessibility identifiers include:

```text
recorder.meeting-intelligence.card
recorder.meeting-intelligence.status
recorder.meeting-intelligence.summary
recorder.meeting-intelligence.generate
recorder.meeting-intelligence.regenerate
recorder.meeting-intelligence.cancel
recorder.meeting-intelligence.check-again
recorder.meeting-intelligence.retry-generation
recorder.meeting-intelligence.suggested-title
recorder.meeting-intelligence.apply-title
recorder.meeting-intelligence.manual-title-protection
recorder.provider.base-url
recorder.provider.kind
recorder.provider.hkt-group-id
recorder.provider.hkt-resolved-url
recorder.provider.api-key
recorder.provider.asr-model
recorder.provider.llm-model
recorder.provider.language
recorder.provider.prompt
recorder.provider.save
recorder.provider.test
recorder.provider.remove-key
recorder.provider.status
```

At 860×680, opening the transcript/intelligence sheet must keep the status,
applicable primary action, and dismissal controls visible in the fixed
header/footer. Summary content and the transcript editor share one keyboard-
and accessibility-scrollable content region; their complete text does not need
to fit in the initial viewport. Phase-specific first-frame requirements are:

| Phase | Required visible identifiers/actions |
|---|---|
| Not Generated | status, Generate |
| Checking Availability | status, Cancel |
| Generating | status, progress, Cancel |
| Ready | status, summary viewport, Regenerate |
| Stale | status, stale explanation, preserved summary, Regenerate |
| Availability unconfirmed | status, Check Again, Generate |
| Generation failed/interrupted | status, Retry Generation |
| Manual title protected | manual protection, suggested title, Apply Title |

AppKit-hosted tests assert containment for the fixed elements and successful
keyboard/accessibility scrolling to the summary/editor content. They repeat
sheet close/reopen and destination switching, and confirm same-session title
projection refreshes one row without duplicating the session or losing draft
state. Wide layout remains stable. `AVPlayerView` remains outside the main
content hierarchy.

## 13. Error and Recovery Semantics

- ASR success never becomes ASR failure because of meeting intelligence.
- Automatic ineligibility is a local, non-destructive Not Generated state, not
  repeated background retry.
- Manual failure keeps the transcript, title, and previous successful summary.
- Authentication and configuration errors point to Settings.
- Transient HTTP failure offers an explicit Retry Generation/Regenerate after
  the one-request attempt budget.
- Cancellation settles promptly and suppresses every late callback.
- Transcript change during generation preserves the previous success and marks
  it stale; the stale in-flight result cannot publish.
- Session trash and app shutdown cancel and invalidate owned attempts.
- Provider settings changes do not mutate an active snapshot.
- Relaunch converts an unfinished persisted phase to Interrupted.
- Apply Suggested Title revalidates that the suggestion's transcript digest is
  current before writing metadata.

## 14. Testing Strategy

Implementation follows test-driven slices with observed RED before production
changes and focused GREEN after each slice.

Lifecycle tests use injected availability, LLM pipeline, clock/deadline,
artifact publisher, metadata store, transcript store, and semantic-refresh
fixtures. Each fixture exposes deterministic barriers such as
`availabilityStarted`, `responseReceived`, `decodeStarted`,
`candidatePromotionStarted`, and `metadataSaveStarted`; tests resume or cancel
from a known stage instead of polling with sleeps. Every race assertion checks
request count, artifact bytes, metadata, presentation, and Library refresh
count.

### Availability

- exact LLM model in inventory is eligible;
- different ASR and LLM identifiers use the correct fields;
- same identifier is allowed;
- absent model, placeholder, 404/405, malformed response, authentication,
  timeout, oversized response, and cancellation send zero automatic chat
  requests;
- manual Generate may proceed without discovery confirmation;
- provider edits affect future attempts only.

### LLM client and transport

- `/v1/chat/completions` request schema and optional Bearer header;
- request uses `llmModel`, never `asrModel`;
- bounded source, JSON request, partial output, and final response;
- strict outer and inner response validation;
- contextual-title and date-only rejection;
- same-origin 307/308 JSON body/method/content-type preservation;
- cross-origin, downgrade, port, 301–303, changed-method, missing-body,
  changed-body, and changed-content-type rejection;
- no Authorization leakage;
- Retry-After seconds and HTTP-date recovery-hint parsing without automatic
  resend;
- exactly one request for HTTP and transport failures;
- cancellation during transport, decode, reduction, and
  publication;
- multi-byte UTF-8 at chunk boundaries, one-byte source overflow, worst-case
  JSON escaping, encoded-body overflow, maximum fan-in/depth/request count, and
  recursive-reduction termination;
- real URLSession delegate redirect sequences for both existing multipart ASR
  and JSON LLM, plus rejected model-discovery GET redirects;
- errors and artifacts contain no key, transcript, prompt, body, or full path.

### Pipeline and coordinator

- one-chunk and multi-pass long transcript success;
- source overflow fails locally without a request;
- auto generation occurs exactly once after canonical publication when
  eligible;
- delayed/duplicate older `TranscriptPublished` identities start zero
  availability and chat requests; the newest publication starts exactly one;
- ineligible auto generation sends zero LLM requests;
- LLM failure leaves ASR completed;
- Generate later after configuration succeeds;
- Regenerate replaces only after complete success;
- same-session replacement cancels and invalidates the old attempt;
- distinct-session attempts do not overwrite each other;
- immutable provider snapshot;
- stale progress, response, decode, pipeline, and publication callbacks;
- transcript edit/retranscription digest mismatch;
- transcript symlink, path escape, additional hard link, and identity
  replacement during bounded read produce zero availability/chat requests;
- byte-identical save and retranscription digest behavior;
- manual rename and manual clear while generation is active;
- transcript mutation after initial digest check, after candidate promotion,
  and before title metadata save;
- Apply Suggested Title racing with Regenerate and manual metadata save;
- exact one-request count after 408, 429, 5xx, and ambiguous transport failure;
- shutdown, trash, and relaunch interruption;
- previous successful artifact survives failure and cancellation.

### Metadata, contracts, and library

- v1 title migration to conservative manual ownership;
- v1 missing title migration to unset;
- explicit manual clear remains protected;
- tag/Favorite-only save preserves title origin;
- generated title apply and later manual edit;
- unknown nested objects and arrays round-trip;
- recording v1/v2 schema fixtures;
- success/state artifact valid-v1, unknown-v1-field, future-version, malformed,
  oversized, symlink, directory, replacement-race, and secret-exclusion
  fixtures;
- generated metadata title becomes searchable through one targeted Library
  refresh;
- transcript search, snippets, favorites, and 4 MiB search bound remain
  unchanged.

### UI

- pure state-to-action presentation matrix;
- Generate, Regenerate, Cancel, Check Again, Retry Generation, stale, manual
  protection, and provider recovery;
- stable accessibility identifiers;
- AppKit-hosted 860×680 and wide render;
- repeated sheet open/close and destination switching;
- title projection updates the same session row;
- exactly one coordinator-backed presentation source with no mirrored
  AppModel lifecycle dictionary;
- `AVPlayerView` isolation remains intact.

### Complete automated gate

- focused meeting-intelligence suites;
- complete `swift test`;
- Python/script and policy tests;
- packaging tests and strict ad-hoc codesign;
- clean bundle-content verification with no Python or FFmpeg runtime helper;
- virtual microphone tests;
- `git diff --check`;
- GitHub Actions on `macos-26`.

## 15. Rollback-Safe Delivery

Implementation commits remain independently reviewable:

1. approved design, provider-preset amendment, and TDD implementation plan;
2. provider availability and credential-aware redirect contract;
3. success/state artifacts and metadata v2 ownership;
4. bounded LLM client and multi-pass pipeline;
5. saved HKT/generic profiles and immutable provider snapshots;
6. coordinator lifecycle and transcription-publication integration;
7. transcript-sheet/settings UI, accessibility, and render coverage;
8. documentation, contract fixtures, and complete validation evidence.

No commit modifies Windows implementation paths. No commit rebuilds or replaces
the non-staging application.

The branch is submitted as a Draft pull request. It is not merged until review,
CI, and user staging acceptance are complete.

## 16. Manual Acceptance Gates

Automated tests cannot prove provider compatibility or the final macOS runtime
experience. A development-only synthetic provider harness first records
sanitized event telemetry:

```text
timestamp
models GET count
audio-transcriptions POST count
chat-completions POST count
model role: asr | llm
terminal outcome: completed | cancelled | rejected-stale
```

It never records a credential, transcript, prompt, response body, full URL, or
local path, and it is excluded from the app bundle. This harness proves the
zero-chat and model-routing acceptance cases. Real-provider acceptance then
uses the provider's own request/usage telemetry where available plus the
visible app outcome; lack of provider telemetry is reported rather than
inferred from UI alone.

Before approval:

1. save independent HKT and generic configurations, switch between them, and
   verify neither preset nor Keychain credential overwrites the other;
2. configure a real provider with different ASR and LLM models;
3. verify ASR requests use only the ASR model and the selected preset's single
   credential header;
4. verify an advertised LLM model triggers one automatic summary/title flow;
5. verify an unadvertised or undiscoverable LLM triggers no automatic chat
   request;
6. explicitly Generate with discovery unsupported;
7. verify contextual title and complete summary quality against the transcript;
8. manually rename and manually clear titles, then Regenerate and confirm
   protection;
9. edit the transcript during generation and confirm stale-result rejection;
10. cancel during availability, request, reduction, decode, and response
   processing where practical;
11. relaunch after interruption and confirm the state is recoverable;
12. exercise a long transcript and confirm no silent truncation;
13. inspect 860×680 and wide UI in light/dark appearance;
14. verify the rebuilt app is exactly
    `/Applications/Local Meeting Recorder Staging.app`;
15. verify the non-staging application was not touched.

Real-provider behavior, signed/notarized production artifact acceptance, Teams
meeting acceptance, and AirPods hardware acceptance remain manual gates. A
green unit or packaging suite does not claim those gates passed.
