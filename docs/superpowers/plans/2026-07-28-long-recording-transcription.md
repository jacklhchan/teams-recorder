# Long-Recording Qwen ASR Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace whole-file oMLX transcription with a sequential, silence-aware, validated chunk pipeline and prove it on the 33:02 Cantonese meeting recording.

**Architecture:** Keep `transcribe-qwen-asr.sh` as the app-facing entry point, but move long-form orchestration into a focused Python helper. The helper probes and chunks media with FFmpeg, submits bounded sequential oMLX requests, recursively bisects invalid chunks, merges boundary overlap, and atomically publishes output only after all accepted chunks pass validation.

**Tech Stack:** Bash, Python 3 standard library, FFmpeg/FFprobe, curl, oMLX OpenAI-compatible transcription API, OpenCC, Python `unittest`, Swift Package/XCTest for the existing app suite.

## Global Constraints

- Default chunk target is 120 seconds; hard ceiling is 180 seconds.
- Retry bisection stops at a 30-second minimum raw interval.
- Boundary padding is at most 1.5 seconds and remains inside the source duration.
- Silence detection uses `-40 dB` with a 0.6-second minimum silence.
- Requests are sequential and use `language=yue`, `response_format=json`, and `max_tokens=4096`.
- The configured model remains `mlx-community--Qwen3-ASR-1.7B-4bit`.
- The app-compatible historical `8bit` output filenames remain unchanged.
- Existing final transcripts are never replaced by a failed candidate.
- Logs never include the oMLX API key or Authorization header.
- Do not modify the existing uncommitted `ReleaseManifest.swift`, `ReleaseManifestTests.swift`, or `.superpowers/` content.

---

## File Structure

- Create `scripts/qwen_asr_longform.py`
  - Pure chunk-planning, validation, and merge functions.
  - External-command runner and long-form transcription coordinator.
  - CLI invoked by the packaged shell entry point.
- Create `Tests/ScriptTests/test_qwen_asr_longform.py`
  - Standard-library unit and integration tests for helper behavior.
- Modify `scripts/transcribe-qwen-asr.sh`
  - Resolve credentials and delegate one run to the helper.
  - Preserve existing log and status contract.
- Modify `scripts/build-app.sh`
  - Package the helper next to the shell entry point.
- Create `Tests/ScriptTests/test_transcribe_qwen_asr_entrypoint.py`
  - Verify argument/environment propagation and non-zero failure behavior with a
    real subprocess and a fake helper program.

### Task 1: Pure long-form planning, validation, and merge functions

**Files:**
- Create: `scripts/qwen_asr_longform.py`
- Create: `Tests/ScriptTests/test_qwen_asr_longform.py`

**Interfaces:**
- Produces: `Interval(start: float, end: float)`
- Produces: `parse_silence_events(log: str) -> list[Interval]`
- Produces: `plan_chunks(duration: float, silences: Sequence[Interval], target: float = 120.0, maximum: float = 180.0, padding: float = 1.5) -> list[Interval]`
- Produces: `validate_transcript(text: object) -> tuple[bool, str]`
- Produces: `merge_transcripts(texts: Sequence[str], minimum_overlap: int = 8) -> str`

- [ ] **Step 1: Write failing planning tests**

Add tests that require a split at the silence nearest 120 seconds, fall back to
120 seconds without silence, cover the full duration, and clamp padding:

```python
class PlanChunkTests(unittest.TestCase):
    def test_prefers_silence_near_target_and_covers_source(self):
        chunks = plan_chunks(
            250.0,
            [Interval(117.0, 119.0), Interval(238.0, 240.0)],
        )
        self.assertEqual(chunks[0], Interval(0.0, 119.5))
        self.assertEqual(chunks[1].start, 116.5)
        self.assertEqual(chunks[-1].end, 250.0)

    def test_falls_back_to_fixed_cut_without_silence(self):
        chunks = plan_chunks(250.0, [])
        self.assertEqual(chunks, [
            Interval(0.0, 121.5),
            Interval(118.5, 241.5),
            Interval(238.5, 250.0),
        ])
```

- [ ] **Step 2: Run planning tests to verify RED**

Run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_qwen_asr_longform.PlanChunkTests -v
```

Expected: import failure because `scripts/qwen_asr_longform.py` does not exist.

- [ ] **Step 3: Implement minimal planning code**

Create `Interval`, parse FFmpeg `silence_start`/`silence_end` pairs, choose the
silence midpoint closest to each target within the current raw interval and
before the hard maximum, and convert raw boundaries into padded request
intervals:

```python
@dataclass(frozen=True)
class Interval:
    start: float
    end: float

def plan_chunks(duration, silences, target=120.0, maximum=180.0, padding=1.5):
    raw = []
    start = 0.0
    while duration - start > target:
        candidates = [
            (s.start + s.end) / 2
            for s in silences
            if start + 30.0 <= (s.start + s.end) / 2 <= min(start + maximum, duration)
        ]
        desired = min(start + target, duration)
        cut = min(candidates, key=lambda value: abs(value - desired)) if candidates else desired
        raw.append(Interval(start, cut))
        start = cut
    raw.append(Interval(start, duration))
    return [
        Interval(max(0.0, item.start - padding), min(duration, item.end + padding))
        for item in raw
    ]
```

- [ ] **Step 4: Run planning tests to verify GREEN**

Run the command from Step 2.

Expected: all `PlanChunkTests` pass.

- [ ] **Step 5: Write failing validation and merge tests**

Cover the observed bad suffix, ordinary fillers, repeating short patterns, and
overlap-only deduplication:

```python
class ValidationTests(unittest.TestCase):
    def test_rejects_observed_repeated_cantonese_filler_tail(self):
        valid, reason = validate_transcript("正常內容如果有" + "啊" * 1365)
        self.assertFalse(valid)
        self.assertEqual(reason, "repeated-character-tail")

    def test_allows_normal_cantonese_fillers(self):
        valid, reason = validate_transcript("係啊，我哋繼續。嗯，好啊。")
        self.assertEqual((valid, reason), (True, "ok"))

    def test_rejects_short_pattern_tail(self):
        valid, reason = validate_transcript("正常內容" + "係啦" * 12)
        self.assertEqual((valid, reason), (False, "repeated-pattern-tail"))

class MergeTests(unittest.TestCase):
    def test_removes_only_boundary_overlap(self):
        merged = merge_transcripts([
            "第一段內容，今日討論address verification。",
            "今日討論address verification。第二段內容。",
            "第二段內容。最後結論。",
        ])
        self.assertEqual(
            merged,
            "第一段內容，今日討論address verification。\n第二段內容。\n最後結論。",
        )
```

- [ ] **Step 6: Run validation and merge tests to verify RED**

Run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_qwen_asr_longform.ValidationTests \
  Tests.ScriptTests.test_qwen_asr_longform.MergeTests -v
```

Expected: failure because validation and merge functions are absent.

- [ ] **Step 7: Implement minimal validation and merge code**

Require a string with non-whitespace content. Inspect the normalized tail for a
single character repeated 20 times or a 2–8 character pattern repeated 10
times. For merging, find only the longest exact suffix/prefix match of at least
eight characters and remove it from the later chunk:

```python
def validate_transcript(text):
    if not isinstance(text, str) or not text.strip():
        return False, "empty-text"
    compact = re.sub(r"\s+", "", text)
    if re.search(r"(.)\1{19,}$", compact):
        return False, "repeated-character-tail"
    if re.search(r"(.{2,8})\1{9,}$", compact):
        return False, "repeated-pattern-tail"
    return True, "ok"

def merge_transcripts(texts, minimum_overlap=8):
    accepted = []
    for text in (value.strip() for value in texts if value.strip()):
        if accepted:
            limit = min(len(accepted[-1]), len(text))
            overlap = next(
                (size for size in range(limit, minimum_overlap - 1, -1)
                 if accepted[-1].endswith(text[:size])),
                0,
            )
            text = text[overlap:].lstrip()
        if text:
            accepted.append(text)
    return "\n".join(accepted)
```

- [ ] **Step 8: Run all helper unit tests**

Run:

```bash
/usr/bin/python3 -m unittest Tests.ScriptTests.test_qwen_asr_longform -v
```

Expected: all tests pass with no warnings.

- [ ] **Step 9: Commit Task 1**

```bash
git add scripts/qwen_asr_longform.py Tests/ScriptTests/test_qwen_asr_longform.py
git commit -m "Add long-recording chunk planning and validation"
```

### Task 2: Sequential oMLX coordinator with recursive bad-chunk retry

**Files:**
- Modify: `scripts/qwen_asr_longform.py`
- Modify: `Tests/ScriptTests/test_qwen_asr_longform.py`

**Interfaces:**
- Consumes: Task 1 `Interval`, `parse_silence_events`, `plan_chunks`, `validate_transcript`, and `merge_transcripts`
- Produces: `TranscriptionConfig`
- Produces: `CommandResult(returncode: int, stdout: str, stderr: str)`
- Produces: `CommandRunner.run(args: Sequence[str]) -> CommandResult`
- Produces: `LongformTranscriber.run() -> pathlib.Path`
- Produces CLI exit code 0 only after validated candidate or final publication

- [ ] **Step 1: Write a failing sequential-request integration test**

Use a temporary directory containing executable fake `ffprobe`, `ffmpeg`, and
`curl` programs. The fake curl records every argument vector and returns two
valid chunk responses. Assert that the coordinator:

```python
def test_transcribes_planned_chunks_sequentially_and_publishes_candidate(self):
    output = self.run_pipeline(
        duration=250.0,
        responses=[
            {"text": "第一段正常內容。"},
            {"text": "第二段正常內容。"},
            {"text": "最後正常內容。"},
        ],
        publish_mode="candidate",
    )
    self.assertEqual(
        output.read_text(encoding="utf-8"),
        "第一段正常內容。\n第二段正常內容。\n最後正常內容。",
    )
    request_log = self.read_request_log()
    self.assertEqual(len(request_log), 3)
    self.assertTrue(all("max_tokens=4096" in request for request in request_log))
    self.assertTrue(all("language=yue" in request for request in request_log))
```

- [ ] **Step 2: Run the new test to verify RED**

Run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_qwen_asr_longform.CoordinatorTests.test_transcribes_planned_chunks_sequentially_and_publishes_candidate -v
```

Expected: failure because `LongformTranscriber` is not implemented.

- [ ] **Step 3: Implement probe, silence detection, extraction, and request**

Implement `CommandRunner` with `subprocess.run(..., text=True,
capture_output=True)`. The coordinator must:

```python
probe = runner.run([
    ffprobe, "-v", "error", "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1", str(source),
])
silence = runner.run([
    ffmpeg, "-hide_banner", "-nostats", "-i", str(source),
    "-map", "0:a:0", "-af", "silencedetect=noise=-40dB:d=0.6",
    "-f", "null", "-",
])
```

For each planned interval, extract a WAV and use curl with the API key supplied
through config but never printed:

```python
[
    curl, "-sS", "--max-time", "7200",
    "-H", f"Authorization: Bearer {api_key}",
    "-o", str(response_path), "-w", "%{http_code}",
    f"{url}/v1/audio/transcriptions",
    "-F", f"file=@{wav_path}",
    "-F", f"model={model}",
    "-F", "language=yue",
    "-F", "response_format=json",
    "-F", "max_tokens=4096",
]
```

Write manifest state after every attempt. Convert final text with OpenCC when
available and publish `*_chunked_candidate.txt` in candidate mode.

- [ ] **Step 4: Run the sequential test to verify GREEN**

Run the command from Step 2.

Expected: PASS and exactly three recorded transcription requests.

- [ ] **Step 5: Write failing retry and non-publication tests**

The first test returns a repeated `啊` response for a 120-second chunk and valid
responses for both halves. The second keeps returning repetition through the
30-second retry floor:

```python
def test_bisects_only_invalid_chunk_and_merges_valid_retries(self):
    output = self.run_pipeline(
        duration=120.0,
        responses=[
            {"text": "如果有" + "啊" * 30},
            {"text": "修復後上半段。"},
            {"text": "修復後下半段。"},
        ],
        publish_mode="candidate",
    )
    self.assertIn("修復後上半段。\n修復後下半段。", output.read_text())
    self.assertEqual(len(self.read_request_log()), 3)

def test_preserves_existing_final_when_minimum_retry_still_invalid(self):
    final = self.output_dir / "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
    final.write_text("existing", encoding="utf-8")
    with self.assertRaises(TranscriptionError):
        self.run_pipeline(duration=30.0, responses=[{"text": "啊" * 30}])
    self.assertEqual(final.read_text(encoding="utf-8"), "existing")
```

- [ ] **Step 6: Run retry tests to verify RED**

Run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_qwen_asr_longform.CoordinatorTests.test_bisects_only_invalid_chunk_and_merges_valid_retries \
  Tests.ScriptTests.test_qwen_asr_longform.CoordinatorTests.test_preserves_existing_final_when_minimum_retry_still_invalid -v
```

Expected: failures because recursive bisection and atomic publication are not
implemented.

- [ ] **Step 7: Implement recursive bisection and atomic publication**

Add `_transcribe_interval(raw_interval, request_interval, chunk_id, attempt)`.
When validation fails and the raw interval is longer than 30 seconds, choose a
silence midpoint nearest its center or use its exact midpoint, then recurse on
the two children. When it fails at or below 30 seconds, raise
`TranscriptionError`.

Write candidates in the staging run directory. In replace mode, preserve each
existing final as `<name>.previous-<UTC timestamp>` and use `os.replace` only
after raw and Traditional Chinese candidates both exist.

- [ ] **Step 8: Run all coordinator and helper tests**

Run:

```bash
/usr/bin/python3 -m unittest Tests.ScriptTests.test_qwen_asr_longform -v
```

Expected: all tests pass; bad minimum-size output leaves the existing final
unchanged.

- [ ] **Step 9: Commit Task 2**

```bash
git add scripts/qwen_asr_longform.py Tests/ScriptTests/test_qwen_asr_longform.py
git commit -m "Add validated sequential oMLX transcription"
```

### Task 3: App-facing shell entry point and packaged helper

**Files:**
- Modify: `scripts/transcribe-qwen-asr.sh`
- Modify: `scripts/build-app.sh`
- Create: `Tests/ScriptTests/test_transcribe_qwen_asr_entrypoint.py`

**Interfaces:**
- Consumes: Task 2 helper CLI
- Produces: shell usage `transcribe-qwen-asr.sh <audio-file> <output-folder>`
- Produces: `STATUS=...`, `TRANSCRIPT_PATH=...`, and non-zero failure contract
- Produces packaged resources `transcribe-qwen-asr.sh` and `qwen_asr_longform.py`

- [ ] **Step 1: Write failing shell delegation tests**

Create a temporary fake helper that writes its received arguments and selected
environment values to JSON. Run the real shell entry point with temporary oMLX
settings and assert:

```python
def test_delegates_to_packaged_helper_without_leaking_api_key(self):
    result = self.run_entrypoint(helper_exit=0)
    self.assertEqual(result.returncode, 0)
    invocation = json.loads(self.capture_path.read_text())
    self.assertEqual(invocation["audio"], str(self.audio))
    self.assertEqual(invocation["output"], str(self.output_dir))
    self.assertNotIn("secret-test-key", result.stdout + result.stderr)

def test_propagates_helper_failure(self):
    result = self.run_entrypoint(helper_exit=70)
    self.assertEqual(result.returncode, 70)
    self.assertNotIn("TRANSCRIPT_PATH=", result.stdout)
```

- [ ] **Step 2: Run shell tests to verify RED**

Run:

```bash
/usr/bin/python3 -m unittest \
  Tests.ScriptTests.test_transcribe_qwen_asr_entrypoint -v
```

Expected: failure because the current shell performs the whole curl request and
does not invoke the helper.

- [ ] **Step 3: Replace shell orchestration with helper delegation**

Keep usage, PATH, credential resolution, logging, and source checks. Resolve:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LONGFORM_HELPER="${LONGFORM_HELPER:-${SCRIPT_DIR}/qwen_asr_longform.py}"
PUBLISH_MODE="${TRANSCRIPTION_PUBLISH_MODE:-replace}"
```

Then execute the helper with explicit non-secret arguments and the API key in a
dedicated environment variable:

```bash
OMLX_API_KEY="$API_KEY" "$PYTHON" "$LONGFORM_HELPER" \
  --audio "$AUDIO_FILE" \
  --output-folder "$OUTPUT_FOLDER" \
  --omlx-url "$OMLX_URL" \
  --model "$OMLX_ASR_MODEL" \
  --language "$LANGUAGE" \
  --publish-mode "$PUBLISH_MODE"
```

The helper reads `OMLX_API_KEY`, emits status lines, and never echoes it.

- [ ] **Step 4: Package the helper**

Add to `scripts/build-app.sh`:

```bash
cp "$ROOT_DIR/scripts/qwen_asr_longform.py" \
  "$RESOURCES_DIR/qwen_asr_longform.py"
chmod +x "$RESOURCES_DIR/qwen_asr_longform.py"
```

- [ ] **Step 5: Run shell delegation tests to verify GREEN**

Run the command from Step 2.

Expected: both tests pass and captured output contains no test API key.

- [ ] **Step 6: Run focused script tests**

Run:

```bash
/usr/bin/python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py' -v
```

Expected: all script tests pass.

- [ ] **Step 7: Commit Task 3**

```bash
git add scripts/transcribe-qwen-asr.sh scripts/build-app.sh \
  Tests/ScriptTests/test_transcribe_qwen_asr_entrypoint.py
git commit -m "Route recorder transcription through long-form pipeline"
```

### Task 4: Full verification and real 33-minute acceptance run

**Files:**
- Runtime input: `/Users/apple/Downloads/meeting-2026-07-28-140101/recording.mp4`
- Runtime candidate output: `/Users/apple/Downloads/meeting-2026-07-28-140101/transcript_qwen3_asr_1_7b_8bit_yue_trad_chunked_candidate.txt`
- Runtime evidence: `/Users/apple/Downloads/meeting-2026-07-28-140101/.transcription-runs/<run-id>/manifest.json`

**Interfaces:**
- Consumes: packaged shell/helper pipeline from Tasks 1–3
- Produces: validated candidate transcript and manifest without replacing the
  original transcript

- [ ] **Step 1: Run focused Python tests fresh**

```bash
/usr/bin/python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py' -v
```

Expected: zero failures and zero errors.

- [ ] **Step 2: Run the complete Swift test suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: zero failures. Existing unrelated dirty release-manifest tests must
not be staged or rewritten as part of this work.

- [ ] **Step 3: Build the app bundle**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
```

Expected: exit 0 and both transcription resources present in the built app.

- [ ] **Step 4: Confirm runtime prerequisites and reduce memory pressure**

Verify `ffmpeg`, `ffprobe`, the configured oMLX model, and free memory. Ask the
user to unload the pinned Qwen3.6 model through the oMLX UI if it remains loaded;
do not call an undocumented or destructive admin endpoint automatically.

- [ ] **Step 5: Run candidate transcription without replacing originals**

```bash
TRANSCRIPTION_PUBLISH_MODE=candidate \
  /Users/apple/Documents/recorder/scripts/transcribe-qwen-asr.sh \
  /Users/apple/Downloads/meeting-2026-07-28-140101/recording.mp4 \
  /Users/apple/Downloads/meeting-2026-07-28-140101
```

Expected: exit 0, chunk progress, and a
`*_trad_chunked_candidate.txt` path.

- [ ] **Step 6: Validate candidate structure against the original failure**

Run a checker that asserts:

```text
manifest source duration is approximately 1982.13 seconds
all accepted intervals cover the full source timeline
every accepted chunk validation result is ok
candidate does not end in repeated-character or repeated-pattern output
candidate contains text after the previous phrase 如果有
the final accepted interval has non-empty text
the original transcript files are unchanged
```

Expected: all checks pass. If a check fails, report the exact failed chunk and
retain its response rather than claiming completion.

- [ ] **Step 7: Inspect the final two minutes**

Compare the final candidate chunk with the final two minutes of audio. Record
whether speech is present and whether the transcript reaches the audible meeting
ending. This is a manual content check, distinct from automated completeness.

- [ ] **Step 8: Review final diff and worktree status**

```bash
git diff HEAD~3..HEAD --check
git status --short --branch
```

Expected: only planned transcription files and commits are present; original
uncommitted release-manifest changes and `.superpowers/` remain untouched.
