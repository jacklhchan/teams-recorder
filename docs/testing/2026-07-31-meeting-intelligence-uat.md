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
8. Manually rename and manually clear titles, then Regenerate and confirm
   protection.
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
