# Meeting Intelligence UAT Record

This is a manual acceptance record for the staging app only. It does not prove
real-provider quality, a signed/notarized production artifact, Teams meeting
acceptance, or AirPods hardware acceptance.

## Evidence

| Field | Record |
| --- | --- |
| Date and tester | |
| App commit SHA | |
| Staging bundle path | `/Applications/Local Meeting Recorder Staging.app` |
| Staging bundle SHA-256 | |
| macOS version | 26.0 or newer |
| Provider preset | |
| ASR model | |
| LLM model | |
| Meeting language | |
| `/models` GET count | |
| `/audio/transcriptions` POST count | |
| `/chat/completions` POST count | |
| Artifact intent (`automatic`, `generate`, `regenerate`, or `retryGeneration`) | |
| Result and observed title provenance | |
| Screenshot paths (without credentials or transcript content) | |
| Outstanding gates | Real provider / notarized artifact / Teams / AirPods |

## Development-only synthetic provider

`Tests/ManualFixtures/meeting_intelligence_provider.py` may be used on a
loopback ephemeral port before real-provider testing. It records sanitized
JSON-lines telemetry only: timestamp, endpoint class, request count, optional
model role (`asr` or `llm`), and terminal outcome. It records no credential,
prompt, transcript, response body, full URL, or local path, and it is excluded
from the packaged app.

## Acceptance steps

1. Save independent HKT and generic configurations, switch between them, and
   verify neither preset nor Keychain credential overwrites the other.
2. Configure a real provider with different ASR and LLM models.
3. Verify ASR requests use only the ASR model and the selected preset's single
   credential header.
4. Verify an advertised LLM model triggers one automatic summary/title flow.
5. Verify an unadvertised or undiscoverable LLM triggers no automatic chat
   request.
6. Explicitly Generate with discovery unsupported.
7. Verify contextual title and complete summary quality against the transcript.
8. Run the title-ownership and open-detail-sheet coverage below.
9. Edit the transcript during generation and confirm stale-result rejection.
10. Cancel during availability, request, reduction, decode, and response
    processing where practical.
11. Relaunch after interruption and confirm the state is recoverable.
12. Exercise a long transcript and confirm no silent truncation.
13. Inspect 860×680 and wide UI in light/dark appearance.
14. Verify the rebuilt app is exactly
    `/Applications/Local Meeting Recorder Staging.app`; verify the non-staging
    application was not touched.
15. Select Cantonese, save, start a new transcription, and record the result.
16. Select English, save, start a new transcription, and record the result.
17. Select Mandarin, save, start a new transcription, and record the result.
18. Change the saved language while a controlled transcription is active and
    confirm that active job finishes with its original snapshot while the next
    job uses the newly saved choice.

Record whether each step passed, failed, or remains blocked. Do not infer
provider request counts from UI alone when provider telemetry is unavailable.

## Title ownership with the detail sheet kept open

Use an advertised LLM model and provider telemetry. Open the transcript detail
sheet while the meeting title is unset, and keep that same sheet open for the
entire sequence:

1. Allow the first automatic generation to set automatic title **A**.
2. Wait for the canonical recording-session metadata/library refresh while the
   sheet remains open; do not close and reopen it to obtain the refreshed state.
3. Select **Regenerate** and verify automatic title **B** replaces **A** in the
   still-open sheet and remains meeting-intelligence-owned.
4. Repeat the sequence after manually entering a title, and separately after
   manually clearing the title. In both cases, preserve the manual title or
   manual blank respectively; regeneration must not claim either as an
   automatic meeting-intelligence title.

Record the actual telemetry deltas for each run. For a single-chunk automatic
generation, `/models` GET must increase by exactly **1** and
`/chat/completions` POST by exactly **1**. For the subsequent regeneration
while the same sheet stays open, `/chat/completions` POST must increase by
exactly **1**, while `/models` GET and `/audio/transcriptions` POST each
increase by exactly **0**. Capture the provider telemetry rows and the visible
title/provenance state; do not infer these deltas from UI indications alone.

## `/models` GET redirect rejection

With a controlled provider, test source `/models` GET endpoints responding
with each of **307** and **308**, once to a controlled same-origin destination
and once to a controlled cross-origin destination. In every case, the source
must receive exactly one request; the destination must receive **0** requests
and **0** credentials; and **Test Connection** must fail with redirect
rejected. Retain sanitized source/destination telemetry as evidence.

This deliberate source-GET redirect rejection is different from the supported
upload-preserving POST 307/308 behavior. Do not treat the latter as evidence
that `/models` GET redirects are allowed.

## Exact 4 MiB long-transcript request accounting

Use provider telemetry and construct an exactly **4 MiB UTF-8** transcript as
**64 × 64 KiB** newline-friendly blocks. Start with a manually selected
**Regenerate** action so model discovery is not part of this measurement. The
actual deltas must be exactly: `/chat/completions` POST **+71** (= 64 partial
plus 6 reduction plus 1 final), `/models` GET **+0**, and
`/audio/transcriptions` POST **+0**. Record the telemetry counts themselves,
not a UI-derived estimate, and do not include transcript content in the
evidence. Keep real-provider, notarized-artifact, Teams, and AirPods as
outstanding gates, and include no secrets in any evidence.
