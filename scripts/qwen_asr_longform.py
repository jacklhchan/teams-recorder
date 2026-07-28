#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
from datetime import datetime, timezone
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional, Sequence


@dataclass(frozen=True)
class Interval:
    start: float
    end: float


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


class CommandRunner:
    def run(self, args: Sequence[str]) -> CommandResult:
        completed = subprocess.run(
            list(args),
            text=True,
            capture_output=True,
            check=False,
        )
        return CommandResult(
            completed.returncode,
            completed.stdout,
            completed.stderr,
        )


@dataclass(frozen=True)
class TranscriptionConfig:
    audio: Path
    output_folder: Path
    omlx_url: str
    model: str
    language: str
    api_key: str
    publish_mode: str = "replace"
    run_id: Optional[str] = None
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"
    curl: str = "curl"


class TranscriptionError(RuntimeError):
    pass


def emit_line(line: str, stream=None) -> None:
    print(line, file=stream or sys.stdout, flush=True)


def parse_silence_events(log: str) -> list[Interval]:
    starts = [
        float(value)
        for value in re.findall(r"silence_start:\s*([0-9]+(?:\.[0-9]+)?)", log)
    ]
    ends = [
        float(value)
        for value in re.findall(r"silence_end:\s*([0-9]+(?:\.[0-9]+)?)", log)
    ]
    return [
        Interval(start, end)
        for start, end in zip(starts, ends)
        if end >= start
    ]


def plan_chunks(
    duration: float,
    silences: Sequence[Interval],
    target: float = 120.0,
    maximum: float = 180.0,
    padding: float = 1.5,
) -> list[Interval]:
    raw_intervals: list[Interval] = []
    start = 0.0

    while duration - start > target:
        desired = min(start + target, duration)
        latest = min(start + maximum, duration)
        candidates = [
            (silence.start + silence.end) / 2
            for silence in silences
            if start + 30.0
            <= (silence.start + silence.end) / 2
            <= latest
        ]
        cut = (
            min(candidates, key=lambda value: abs(value - desired))
            if candidates
            else desired
        )
        raw_intervals.append(Interval(start, cut))
        start = cut

    raw_intervals.append(Interval(start, duration))
    return [
        Interval(
            max(0.0, interval.start - padding),
            min(duration, interval.end + padding),
        )
        for interval in raw_intervals
    ]


def validate_transcript(text: object) -> tuple[bool, str]:
    if not isinstance(text, str) or not text.strip():
        return False, "empty-text"

    compact = re.sub(r"\s+", "", text)
    if re.search(r"(.)\1{19,}$", compact):
        return False, "repeated-character-tail"
    if re.search(r"(.{2,8})\1{9,}$", compact):
        return False, "repeated-pattern-tail"
    return True, "ok"


def merge_transcripts(
    texts: Sequence[str],
    minimum_overlap: int = 8,
) -> str:
    accepted: list[str] = []
    for text in (value.strip() for value in texts if value.strip()):
        if accepted:
            previous_normalized, _ = _normalized_characters(accepted[-1])
            text_normalized, text_positions = _normalized_characters(text)
            limit = min(
                len(previous_normalized),
                len(text_normalized),
            )
            overlap_size = next(
                (
                    size
                    for size in range(limit, minimum_overlap - 1, -1)
                    if previous_normalized.endswith(
                        text_normalized[:size]
                    )
                ),
                0,
            )
            if overlap_size:
                text = text[text_positions[overlap_size - 1] + 1 :]
                text = _strip_boundary_prefix(text)
        if text:
            accepted.append(text)
    return "\n".join(accepted)


def _normalized_characters(text: str) -> tuple[str, list[int]]:
    characters: list[str] = []
    positions: list[int] = []
    for index, character in enumerate(text):
        category = unicodedata.category(character)
        if character.isspace() or category.startswith(("P", "Z")):
            continue
        characters.append(character.casefold())
        positions.append(index)
    return "".join(characters), positions


def _strip_boundary_prefix(text: str) -> str:
    index = 0
    while index < len(text):
        character = text[index]
        if (
            character.isspace()
            or unicodedata.category(character).startswith(("P", "Z"))
        ):
            index += 1
            continue
        break
    return text[index:]


class LongformTranscriber:
    TARGET_DURATION = 120.0
    MAXIMUM_DURATION = 180.0
    MINIMUM_RETRY_DURATION = 30.0
    PADDING = 1.5
    MAX_TOKENS = 4096

    def __init__(
        self,
        config: TranscriptionConfig,
        runner: Optional[CommandRunner] = None,
        emit: Callable[[str], None] = emit_line,
    ):
        self.config = config
        self.runner = runner or CommandRunner()
        self.emit = emit
        self.duration = 0.0
        self.silences: list[Interval] = []
        self.attempts: list[dict] = []
        self.accepted: list[dict] = []
        self.request_number = 0
        run_id = config.run_id or datetime.now(timezone.utc).strftime(
            "%Y%m%dT%H%M%SZ"
        )
        self.staging = config.output_folder / ".transcription-runs" / run_id
        self.chunks_directory = self.staging / "chunks"
        self.responses_directory = self.staging / "responses"
        self.manifest_path = self.staging / "manifest.json"

    def run(self) -> Path:
        if not self.config.audio.is_file():
            raise TranscriptionError(
                f"Missing audio file: {self.config.audio}"
            )
        if self.config.publish_mode not in {"candidate", "replace"}:
            raise TranscriptionError(
                f"Unsupported publish mode: {self.config.publish_mode}"
            )

        self.chunks_directory.mkdir(parents=True, exist_ok=True)
        self.responses_directory.mkdir(parents=True, exist_ok=True)

        self.emit("STATUS=Checking oMLX ASR model")
        self._check_model()
        self.emit("STATUS=Analyzing audio")
        self.duration = self._probe_duration()
        self.silences = self._detect_silences()

        request_intervals = plan_chunks(
            self.duration,
            self.silences,
            target=self.TARGET_DURATION,
            maximum=self.MAXIMUM_DURATION,
            padding=self.PADDING,
        )
        raw_intervals = [
            self._remove_padding(interval) for interval in request_intervals
        ]

        for index, raw_interval in enumerate(raw_intervals, start=1):
            self.emit(
                f"STATUS=Transcribing chunk {index} of {len(raw_intervals)}"
            )
            self._transcribe_interval(raw_interval)

        merged = merge_transcripts(
            [entry["text"] for entry in self.accepted]
        )
        valid, reason = validate_transcript(merged)
        if not valid:
            raise TranscriptionError(
                f"Merged transcript validation failed: {reason}"
            )

        raw_candidate = self.staging / "candidate_raw.txt"
        trad_candidate = self.staging / "candidate_trad.txt"
        raw_candidate.write_text(merged, encoding="utf-8")
        trad_candidate.write_text(
            self._traditional_chinese(merged),
            encoding="utf-8",
        )
        self._write_manifest()
        output = self._publish(raw_candidate, trad_candidate)
        self.emit(f"TRANSCRIPT_PATH={output}")
        return output

    def _check_model(self) -> None:
        result = self.runner.run(
            [
                self.config.curl,
                "-sS",
                "--max-time",
                "10",
                "-H",
                f"Authorization: Bearer {self.config.api_key}",
                f"{self.config.omlx_url.rstrip('/')}/v1/models",
            ]
        )
        if result.returncode != 0:
            raise TranscriptionError(
                f"Unable to query oMLX models: {result.stderr.strip()}"
            )
        try:
            payload = json.loads(result.stdout)
            model_ids = {
                item.get("id")
                for item in payload.get("data", [])
                if isinstance(item, dict)
            }
        except (json.JSONDecodeError, AttributeError) as error:
            raise TranscriptionError(
                "oMLX model response was not valid JSON"
            ) from error
        if self.config.model not in model_ids:
            raise TranscriptionError(
                f"oMLX ASR model is not ready: {self.config.model}"
            )

    def _probe_duration(self) -> float:
        result = self.runner.run(
            [
                self.config.ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(self.config.audio),
            ]
        )
        try:
            duration = float(result.stdout.strip())
        except ValueError as error:
            raise TranscriptionError(
                f"Unable to read audio duration: {result.stderr.strip()}"
            ) from error
        if result.returncode != 0 or duration <= 0:
            raise TranscriptionError(
                f"Unable to read audio duration: {result.stderr.strip()}"
            )
        return duration

    def _detect_silences(self) -> list[Interval]:
        result = self.runner.run(
            [
                self.config.ffmpeg,
                "-hide_banner",
                "-nostats",
                "-i",
                str(self.config.audio),
                "-map",
                "0:a:0",
                "-af",
                "silencedetect=noise=-40dB:d=0.6",
                "-f",
                "null",
                "-",
            ]
        )
        if result.returncode != 0:
            raise TranscriptionError(
                f"Unable to analyze audio silence: {result.stderr.strip()}"
            )
        return parse_silence_events(result.stderr)

    def _remove_padding(self, interval: Interval) -> Interval:
        start = (
            0.0
            if interval.start <= 0.0
            else min(self.duration, interval.start + self.PADDING)
        )
        end = (
            self.duration
            if interval.end >= self.duration
            else max(0.0, interval.end - self.PADDING)
        )
        return Interval(start, end)

    def _with_padding(self, interval: Interval) -> Interval:
        return Interval(
            max(0.0, interval.start - self.PADDING),
            min(self.duration, interval.end + self.PADDING),
        )

    def _transcribe_interval(self, raw_interval: Interval) -> None:
        request_interval = self._with_padding(raw_interval)
        self.request_number += 1
        request_id = f"{self.request_number:04d}"
        chunk_path = self.chunks_directory / f"{request_id}.wav"
        response_path = self.responses_directory / f"{request_id}.json"

        self._extract_audio(request_interval, chunk_path)
        result = self.runner.run(
            [
                self.config.curl,
                "-sS",
                "--max-time",
                "7200",
                "-H",
                f"Authorization: Bearer {self.config.api_key}",
                "-o",
                str(response_path),
                "-w",
                "%{http_code}",
                f"{self.config.omlx_url.rstrip('/')}/v1/audio/transcriptions",
                "-F",
                f"file=@{chunk_path}",
                "-F",
                f"model={self.config.model}",
                "-F",
                f"language={self.config.language}",
                "-F",
                "response_format=json",
                "-F",
                f"max_tokens={self.MAX_TOKENS}",
            ]
        )
        http_status = result.stdout.strip()
        text: object = ""
        response_error = ""
        if result.returncode == 0 and http_status == "200":
            try:
                payload = json.loads(response_path.read_text(encoding="utf-8"))
                text = payload.get("text", "")
            except (json.JSONDecodeError, OSError, AttributeError) as error:
                response_error = f"malformed-response:{error}"
        else:
            response_error = (
                f"http-{http_status or 'transport-error'}:"
                f"{result.stderr.strip()}"
            )

        valid, reason = (
            validate_transcript(text)
            if not response_error
            else (False, response_error)
        )
        attempt = {
            "request_id": request_id,
            "raw_start": raw_interval.start,
            "raw_end": raw_interval.end,
            "request_start": request_interval.start,
            "request_end": request_interval.end,
            "response": str(response_path),
            "character_count": len(text) if isinstance(text, str) else 0,
            "validation": reason,
        }
        self.attempts.append(attempt)

        if valid and isinstance(text, str):
            self.accepted.append({**attempt, "text": text})
            self._write_manifest()
            return

        self._write_manifest()
        if (
            raw_interval.end - raw_interval.start
            >= self.MINIMUM_RETRY_DURATION * 2
        ):
            self.emit(
                "STATUS=Retrying failed chunk with shorter intervals"
            )
            split = self._split_point(raw_interval)
            self._transcribe_interval(
                Interval(raw_interval.start, split)
            )
            self._transcribe_interval(
                Interval(split, raw_interval.end)
            )
            return

        raise TranscriptionError(
            f"Chunk {request_id} failed validation at "
            f"{raw_interval.start:.3f}-{raw_interval.end:.3f}: {reason}"
        )

    def _split_point(self, interval: Interval) -> float:
        center = (interval.start + interval.end) / 2
        candidates = [
            (silence.start + silence.end) / 2
            for silence in self.silences
            if interval.start + self.MINIMUM_RETRY_DURATION
            <= (silence.start + silence.end) / 2
            <= interval.end - self.MINIMUM_RETRY_DURATION
        ]
        return (
            min(candidates, key=lambda value: abs(value - center))
            if candidates
            else center
        )

    def _extract_audio(self, interval: Interval, output: Path) -> None:
        result = self.runner.run(
            [
                self.config.ffmpeg,
                "-hide_banner",
                "-nostats",
                "-y",
                "-ss",
                f"{interval.start:.6f}",
                "-to",
                f"{interval.end:.6f}",
                "-i",
                str(self.config.audio),
                "-vn",
                "-ac",
                "1",
                "-ar",
                "16000",
                "-c:a",
                "pcm_s16le",
                str(output),
            ]
        )
        if result.returncode != 0 or not output.is_file():
            raise TranscriptionError(
                f"Unable to extract audio chunk: {result.stderr.strip()}"
            )

    def _traditional_chinese(self, text: str) -> str:
        try:
            from opencc import OpenCC
        except ImportError:
            return text
        return OpenCC("s2hk").convert(text)

    def _write_manifest(self) -> None:
        self.staging.mkdir(parents=True, exist_ok=True)
        temporary = self.manifest_path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(
                {
                    "source": str(self.config.audio),
                    "source_duration": self.duration,
                    "model": self.config.model,
                    "language": self.config.language,
                    "attempts": self.attempts,
                    "accepted": [
                        {
                            key: value
                            for key, value in item.items()
                            if key != "text"
                        }
                        for item in self.accepted
                    ],
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        os.replace(temporary, self.manifest_path)

    def _publish(self, raw_candidate: Path, trad_candidate: Path) -> Path:
        raw_name = (
            "transcript_qwen3_asr_1_7b_8bit_"
            f"{self.config.language}.txt"
        )
        trad_name = (
            "transcript_qwen3_asr_1_7b_8bit_"
            f"{self.config.language}_trad.txt"
        )
        if self.config.publish_mode == "candidate":
            raw_output = self.config.output_folder / raw_name.replace(
                ".txt", "_chunked_candidate.txt"
            )
            trad_output = self.config.output_folder / trad_name.replace(
                ".txt", "_chunked_candidate.txt"
            )
        else:
            raw_output = self.config.output_folder / raw_name
            trad_output = self.config.output_folder / trad_name
            self._backup_existing(raw_output)
            self._backup_existing(trad_output)

        self._atomic_copy(raw_candidate, raw_output)
        self._atomic_copy(trad_candidate, trad_output)
        return trad_output

    def _backup_existing(self, output: Path) -> None:
        if not output.exists():
            return
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = output.with_name(f"{output.name}.previous-{timestamp}")
        shutil.copy2(output, backup)

    def _atomic_copy(self, source: Path, output: Path) -> None:
        temporary = output.with_name(f".{output.name}.tmp")
        temporary.write_bytes(source.read_bytes())
        os.replace(temporary, output)


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Transcribe long recordings through sequential oMLX chunks."
    )
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--output-folder", type=Path, required=True)
    parser.add_argument("--omlx-url", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--language", default="yue")
    parser.add_argument(
        "--publish-mode",
        choices=("candidate", "replace"),
        default="replace",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _argument_parser().parse_args(argv)
    api_key = os.environ.get("OMLX_API_KEY", "")
    if not api_key:
        print("Missing oMLX API key", file=sys.stderr)
        return 69

    config = TranscriptionConfig(
        audio=args.audio,
        output_folder=args.output_folder,
        omlx_url=args.omlx_url,
        model=args.model,
        language=args.language,
        api_key=api_key,
        publish_mode=args.publish_mode,
        ffmpeg=os.environ.get("FFMPEG", "ffmpeg"),
        ffprobe=os.environ.get("FFPROBE", "ffprobe"),
        curl=os.environ.get("CURL", "curl"),
    )
    try:
        args.output_folder.mkdir(parents=True, exist_ok=True)
        LongformTranscriber(config).run()
    except FileNotFoundError as error:
        print(f"Missing required command: {error.filename}", file=sys.stderr)
        return 69
    except TranscriptionError as error:
        print(str(error), file=sys.stderr)
        return 70
    except KeyboardInterrupt:
        print("Transcription cancelled", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
