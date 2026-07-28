import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from qwen_asr_longform import (  # noqa: E402
    Interval,
    merge_transcripts,
    parse_silence_events,
    plan_chunks,
    validate_transcript,
)


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


if __name__ == "__main__":
    unittest.main()
