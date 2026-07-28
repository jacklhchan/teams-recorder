# Long-Recording Qwen ASR Transcription Design

Date: 2026-07-28
Status: Approved for implementation planning

## Summary

Local Meeting Recorder will replace its single-request long-recording
transcription path with a sequential, speech-aware chunking pipeline. The
pipeline will split long audio near silence, transcribe each chunk independently
through the existing authenticated oMLX endpoint, reject repetition and
truncation-shaped output, and publish a combined Traditional Chinese transcript
only after every chunk passes validation.

The first acceptance recording is
`/Users/apple/Downloads/meeting-2026-07-28-140101/recording.mp4`. It is 33:02
long. The current whole-file run returns HTTP 200 but its second server segment
ends in 1,365 consecutive `啊` characters and omits the remaining speech.

## Goals

- Produce a complete Cantonese transcript for recordings longer than 20 minutes.
- Prevent an HTTP 200 response from being presented as complete when its text is
  empty, repetitive, or otherwise structurally invalid.
- Keep unified-memory usage bounded by processing one short chunk at a time.
- Split near natural pauses and preserve speech around chunk boundaries.
- Preserve the current oMLX authentication, model discovery, `language=yue`,
  OpenCC conversion, app progress reporting, and expected final filename.
- Retain per-chunk evidence so a failed run can be diagnosed and resumed.
- Never replace a previously usable transcript with an incomplete candidate.

## Non-Goals

- Speaker diarization.
- Word-level timestamps or subtitle generation.
- Replacing oMLX or the selected Qwen3-ASR model.
- Parallel chunk inference on Apple Silicon.
- Automatically unloading unrelated oMLX models through an undocumented admin
  API.
- Removing ordinary Cantonese filler words such as isolated `啊`, `誒`, or `嗯`.
- General transcript rewriting, summarization, or factual correction.

## Considered Approaches

### Whole-file request with a larger token limit

This is the smallest change, but it leaves the decoder exposed to long-context
repetition and high peak memory. A very large token limit can make a repetition
loop longer rather than recover missing speech. This approach is rejected as
the primary long-recording strategy.

### Fixed-duration chunks

Hard cuts every two minutes bound memory and token output and are easy to test.
However, they can split a word or sentence at the boundary and require more
aggressive overlap deduplication. This remains the fallback when no usable
silence is found.

### Silence-aware bounded chunks

This is the selected approach. Chunks target 120 seconds, may extend to a
180-second hard ceiling to reach a suitable pause, and fall back to a hard cut
when necessary. Small boundary padding protects speech adjacent to the split.
It follows the long-audio pattern documented by the official Qwen3-ASR Toolkit
while keeping requests sequential for the local Mac runtime.

## Architecture

The existing `scripts/transcribe-qwen-asr.sh` remains the app entry point. A new
Python helper owns deterministic long-form planning, validation, retry
decisions, and transcript assembly. The shell entry point continues to own
environment discovery, oMLX authentication, model readiness checks, HTTP
requests, logging, and final output publication.

The helper exposes independently testable operations:

1. `plan_chunks`
   - Reads silence intervals and source duration.
   - Targets 120-second chunks.
   - Selects a split near silence without exceeding 180 seconds.
   - Uses a fixed-duration split when no suitable pause exists.
   - Adds up to 1.5 seconds of boundary padding without exceeding the source.

2. `validate_chunk`
   - Requires non-empty text for a chunk containing detected speech.
   - Rejects a repeated single character of 20 or more occurrences.
   - Rejects a short repeated pattern when it dominates the output tail.
   - Rejects malformed JSON and an oMLX response without string `text`.
   - Returns a machine-readable reason instead of silently cleaning bad text.

3. `merge_chunks`
   - Preserves chronological chunk order.
   - Removes only a normalized suffix/prefix match created by boundary padding.
   - Does not globally deduplicate legitimate repeated meeting statements.
   - Inserts a newline between accepted chunk texts for readable diagnostics and
     safe concatenation.

4. `retry_plan`
   - Bisects only the failing chunk.
   - Stops at a 30-second minimum chunk duration.
   - Fails the overall run if the minimum-sized retry is still invalid.

## Media Processing

The pipeline requires `ffmpeg` and `ffprobe` on the current `PATH`. Before
transcription it will:

1. Probe the audio-stream duration.
2. Detect silence using an explicit, versioned threshold.
3. Extract each planned interval as 16 kHz mono PCM WAV.

The first implementation uses:

```text
target duration: 120 seconds
maximum duration: 180 seconds
minimum retry duration: 30 seconds
boundary padding: up to 1.5 seconds
silence threshold: -40 dB
minimum silence duration: 0.6 seconds
```

These values are constants with focused tests. Environment overrides may be
added only for diagnostics; the app path uses the tested defaults.

If `ffmpeg` or `ffprobe` is unavailable, the run fails before publishing output
and names the missing dependency. Packaging or installing FFmpeg is outside
this vertical slice and must be handled separately before wider distribution.

## oMLX Requests

Each chunk is uploaded sequentially to the existing
`POST /v1/audio/transcriptions` endpoint with:

```text
model=mlx-community--Qwen3-ASR-1.7B-4bit
language=yue
response_format=json
max_tokens=4096
```

The per-request timeout remains bounded. A non-200 response, malformed JSON, or
invalid text fails that chunk and is eligible for bisection. The log records
chunk index, source interval, attempt, HTTP status, validation result, elapsed
time, and character count, but never records the API key.

The implementation will not claim that `max_tokens` alone guarantees
completeness. Its purpose is to give each bounded chunk enough output capacity
while preventing an unbounded runaway.

## Output and Recovery

All intermediate files live under a run-specific staging directory inside the
selected recording folder:

```text
.transcription-runs/<run-id>/chunks/000.wav
.transcription-runs/<run-id>/responses/000.json
.transcription-runs/<run-id>/texts/000.txt
.transcription-runs/<run-id>/manifest.json
.transcription-runs/<run-id>/candidate_raw.txt
.transcription-runs/<run-id>/candidate_trad.txt
```

`manifest.json` records the source duration, chunk boundaries, attempts,
validation results, and accepted response paths. It contains no credential.

The current final paths remain:

```text
transcript_qwen3_asr_1_7b_8bit_yue.txt
transcript_qwen3_asr_1_7b_8bit_yue_trad.txt
```

The historical `8bit` filename is retained for app compatibility even though
the configured model identifier is currently `4bit`; correcting that naming
mismatch is a separate migration.

Candidate outputs are written beside the final outputs with temporary names.
Only after all chunks validate and conversion succeeds are they atomically
renamed into place. If final files already exist, they are first preserved with
a timestamped `.previous-...` suffix. On failure, existing finals remain
unchanged and the manifest plus failed response are retained for diagnosis.

## App State and Progress

The shell log continues to emit `STATUS=...` lines consumed by the app. During a
long run it additionally emits:

```text
STATUS=Transcribing chunk 3 of 17
STATUS=Retrying chunk 3 with shorter intervals
```

`TRANSCRIPT_PATH=...` is emitted only after atomic publication. Therefore the
existing app completion transition occurs only for a fully validated run. A
validation failure exits non-zero and surfaces a concise reason rather than
`Transcription complete`.

## Testing

Implementation follows RED-GREEN-REFACTOR.

Focused Python tests will cover:

- silence-aware split selection near the target;
- fallback hard cuts and full duration coverage;
- padding bounded to the source duration;
- detection of the observed 1,365-character `啊` suffix;
- allowance for normal isolated Cantonese fillers;
- short-pattern tail repetition;
- bisection and the 30-second retry floor;
- overlap removal without global deduplication;
- malformed or empty response rejection.

A shell integration test with fake `ffprobe`, `ffmpeg`, and HTTP responses will
verify:

- requests are sequential and carry the expected fields;
- a bad chunk is retried at shorter intervals;
- existing final output is unchanged when a retry still fails;
- successful candidates are atomically published;
- credentials are absent from logs.

After focused and full automated tests, the acceptance run will use the actual
33:02 MP4. Acceptance requires:

- every planned source interval accounted for;
- no chunk validation failures;
- no repeated-character or repeated-pattern tail;
- output continuing beyond the previous failure phrase `如果有`;
- a non-empty transcript for the final source interval;
- final files and manifest preserved for inspection;
- the app state ending in completed only after these checks.

The acceptance run proves this recording passes the new pipeline. It does not
establish transcript word accuracy without human listening and review.

## Rollout

The first run writes a separate candidate in the recording folder so the
current transcript remains available for comparison. Once the candidate passes
automated checks and a manual tail review, the app-compatible final can be
replaced through the atomic publication path.

No unrelated release-manifest or recording worktree changes are included in
this feature.
