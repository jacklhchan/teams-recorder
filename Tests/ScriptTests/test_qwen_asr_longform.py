import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from qwen_asr_longform import (  # noqa: E402
    CommandResult,
    Interval,
    LongformTranscriber,
    TranscriptionConfig,
    TranscriptionError,
    emit_line,
    merge_transcripts,
    parse_silence_events,
    plan_chunks,
    validate_transcript,
)


class FakeCommandRunner:
    def __init__(self, model, duration, responses, silence_log=""):
        self.model = model
        self.duration = duration
        self.responses = list(responses)
        self.silence_log = silence_log
        self.transcription_requests = []

    def run(self, args):
        executable = Path(args[0]).name
        if executable == "ffprobe":
            return CommandResult(0, f"{self.duration}\n", "")
        if executable == "ffmpeg" and any(
            "silencedetect=" in value for value in args
        ):
            return CommandResult(0, "", self.silence_log)
        if executable == "ffmpeg":
            Path(args[-1]).write_bytes(b"fake wav")
            return CommandResult(0, "", "")
        if executable == "curl" and args[-1].endswith("/v1/models"):
            return CommandResult(
                0,
                json.dumps({"data": [{"id": self.model}]}),
                "",
            )
        if executable == "curl":
            self.transcription_requests.append(list(args))
            output_index = args.index("-o") + 1
            output = Path(args[output_index])
            output.write_text(
                json.dumps(self.responses.pop(0)),
                encoding="utf-8",
            )
            return CommandResult(0, "200", "")
        raise AssertionError(f"Unexpected command: {args}")


class PlanChunkTests(unittest.TestCase):
    def test_parses_ffmpeg_silence_pairs(self):
        events = parse_silence_events(
            """
            [silencedetect] silence_start: 117.25
            [silencedetect] silence_end: 119.75 | silence_duration: 2.5
            [silencedetect] silence_start: 238
            [silencedetect] silence_end: 240.5 | silence_duration: 2.5
            """
        )

        self.assertEqual(
            events,
            [Interval(117.25, 119.75), Interval(238.0, 240.5)],
        )

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

        self.assertEqual(
            chunks,
            [
                Interval(0.0, 121.5),
                Interval(118.5, 241.5),
                Interval(238.5, 250.0),
            ],
        )


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
        merged = merge_transcripts(
            [
                "第一段內容，今日討論address verification。",
                "今日討論address verification。以下係第二段詳細內容。",
                "以下係第二段詳細內容。最後結論。",
            ]
        )

        self.assertEqual(
            merged,
            "第一段內容，今日討論address verification。\n以下係第二段詳細內容。\n最後結論。",
        )

    def test_removes_normalized_boundary_overlap(self):
        merged = merge_transcripts(
            [
                "第一段，今日討論 address verification。",
                "今日討論address verification，第二段。",
            ]
        )

        self.assertEqual(
            merged,
            "第一段，今日討論 address verification。\n第二段。",
        )


class RecordingStream:
    def __init__(self):
        self.value = ""
        self.flush_count = 0

    def write(self, value):
        self.value += value

    def flush(self):
        self.flush_count += 1


class ProgressTests(unittest.TestCase):
    def test_emit_line_flushes_progress_immediately(self):
        stream = RecordingStream()

        emit_line("STATUS=Transcribing chunk 1 of 17", stream=stream)

        self.assertEqual(
            stream.value,
            "STATUS=Transcribing chunk 1 of 17\n",
        )
        self.assertEqual(stream.flush_count, 1)


class CoordinatorTests(unittest.TestCase):
    MODEL = "mlx-community--Qwen3-ASR-1.7B-4bit"

    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.audio = self.root / "recording.mp4"
        self.audio.write_bytes(b"fake media")
        self.output_dir = self.root / "output"
        self.output_dir.mkdir()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def make_config(self, publish_mode="candidate"):
        return TranscriptionConfig(
            audio=self.audio,
            output_folder=self.output_dir,
            omlx_url="http://127.0.0.1:8000",
            model=self.MODEL,
            language="yue",
            api_key="secret-test-key",
            publish_mode=publish_mode,
            run_id="test-run",
        )

    def test_transcribes_planned_chunks_sequentially_and_publishes_candidate(self):
        runner = FakeCommandRunner(
            self.MODEL,
            duration=250.0,
            responses=[
                {"text": "第一段正常內容。"},
                {"text": "第二段正常內容。"},
                {"text": "最後正常內容。"},
            ],
        )
        emitted = []

        output = LongformTranscriber(
            self.make_config(),
            runner=runner,
            emit=emitted.append,
        ).run()

        self.assertEqual(
            output.read_text(encoding="utf-8"),
            "第一段正常內容。\n第二段正常內容。\n最後正常內容。",
        )
        self.assertEqual(len(runner.transcription_requests), 3)
        flattened = [" ".join(request) for request in runner.transcription_requests]
        self.assertTrue(all("max_tokens=4096" in value for value in flattened))
        self.assertTrue(all("language=yue" in value for value in flattened))
        self.assertIn("STATUS=Transcribing chunk 3 of 3", emitted)
        self.assertTrue(emitted[-1].startswith("TRANSCRIPT_PATH="))
        self.assertNotIn("secret-test-key", "\n".join(emitted))
        manifest = json.loads(
            (
                self.output_dir
                / ".transcription-runs"
                / "test-run"
                / "manifest.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["source_duration"], 250.0)
        self.assertEqual(len(manifest["accepted"]), 3)
        self.assertEqual(manifest["accepted"][0]["raw_start"], 0.0)
        self.assertEqual(manifest["accepted"][-1]["raw_end"], 250.0)

    def test_bisects_only_invalid_chunk_and_merges_valid_retries(self):
        runner = FakeCommandRunner(
            self.MODEL,
            duration=120.0,
            responses=[
                {"text": "如果有" + "啊" * 30},
                {"text": "修復後上半段。"},
                {"text": "修復後下半段。"},
            ],
        )

        output = LongformTranscriber(
            self.make_config(),
            runner=runner,
            emit=lambda _: None,
        ).run()

        self.assertEqual(
            output.read_text(encoding="utf-8"),
            "修復後上半段。\n修復後下半段。",
        )
        self.assertEqual(len(runner.transcription_requests), 3)

    def test_preserves_existing_final_when_minimum_retry_still_invalid(self):
        final = (
            self.output_dir
            / "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
        )
        final.write_text("existing", encoding="utf-8")
        runner = FakeCommandRunner(
            self.MODEL,
            duration=30.0,
            responses=[{"text": "啊" * 30}],
        )

        with self.assertRaises(TranscriptionError):
            LongformTranscriber(
                self.make_config(publish_mode="replace"),
                runner=runner,
                emit=lambda _: None,
            ).run()

        self.assertEqual(final.read_text(encoding="utf-8"), "existing")

    def test_successful_replace_backs_up_existing_outputs(self):
        raw = self.output_dir / "transcript_qwen3_asr_1_7b_8bit_yue.txt"
        trad = (
            self.output_dir
            / "transcript_qwen3_asr_1_7b_8bit_yue_trad.txt"
        )
        raw.write_text("old raw", encoding="utf-8")
        trad.write_text("old trad", encoding="utf-8")
        runner = FakeCommandRunner(
            self.MODEL,
            duration=30.0,
            responses=[{"text": "新內容。"}],
        )

        LongformTranscriber(
            self.make_config(publish_mode="replace"),
            runner=runner,
            emit=lambda _: None,
        ).run()

        self.assertEqual(raw.read_text(encoding="utf-8"), "新內容。")
        self.assertEqual(trad.read_text(encoding="utf-8"), "新內容。")
        raw_backups = list(
            self.output_dir.glob(f"{raw.name}.previous-*")
        )
        trad_backups = list(
            self.output_dir.glob(f"{trad.name}.previous-*")
        )
        self.assertEqual(len(raw_backups), 1)
        self.assertEqual(len(trad_backups), 1)
        self.assertEqual(
            raw_backups[0].read_text(encoding="utf-8"),
            "old raw",
        )
        self.assertEqual(
            trad_backups[0].read_text(encoding="utf-8"),
            "old trad",
        )

    def test_manifest_records_acceptance_immediately_after_chunk(self):
        runner = FakeCommandRunner(
            self.MODEL,
            duration=30.0,
            responses=[{"text": "正常內容。"}],
        )
        transcriber = LongformTranscriber(
            self.make_config(),
            runner=runner,
            emit=lambda _: None,
        )
        transcriber.duration = 30.0
        transcriber.chunks_directory.mkdir(parents=True)
        transcriber.responses_directory.mkdir(parents=True)

        transcriber._transcribe_interval(Interval(0.0, 30.0))

        manifest = json.loads(
            transcriber.manifest_path.read_text(encoding="utf-8")
        )
        self.assertEqual(len(manifest["attempts"]), 1)
        self.assertEqual(len(manifest["accepted"]), 1)


class CliTests(unittest.TestCase):
    HELPER = ROOT / "scripts" / "qwen_asr_longform.py"

    def test_help_is_available(self):
        result = subprocess.run(
            ["/usr/bin/python3", str(self.HELPER), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("--publish-mode", result.stdout)

    def test_missing_api_key_fails_without_traceback(self):
        environment = os.environ.copy()
        environment.pop("OMLX_API_KEY", None)
        result = subprocess.run(
            [
                "/usr/bin/python3",
                str(self.HELPER),
                "--audio",
                "missing.mp4",
                "--output-folder",
                ".",
                "--omlx-url",
                "http://127.0.0.1:8000",
                "--model",
                "test-model",
                "--language",
                "yue",
                "--publish-mode",
                "candidate",
            ],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

        self.assertEqual(result.returncode, 69)
        self.assertIn("Missing oMLX API key", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
