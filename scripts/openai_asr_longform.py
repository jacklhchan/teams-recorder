#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence
from urllib import error, request


DEFAULT_CONTEXT = "香港粵語商務會議，可能夾雜英文、人名、公司名、產品名及技術縮寫。請忠實轉錄錄音內容，不要翻譯或補寫沒有說出的內容。"


@dataclass(frozen=True)
class Interval:
    start: float
    end: float


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class HTTPResult:
    status: int
    body: bytes


@dataclass(frozen=True)
class ProviderResponse:
    payload: dict
    raw_body: bytes


@dataclass(frozen=True)
class LaunchPayload:
    schema_version: int
    base_url: str
    asr_model: str
    language: str
    prompt: str
    api_key: Optional[str]


@dataclass(frozen=True)
class TranscriptionConfig:
    audio: Path
    output_folder: Path
    base_url: str
    model: str
    language: str
    publish_mode: str = "replace"
    run_id: Optional[str] = None
    ffmpeg: str = "ffmpeg"
    ffprobe: str = "ffprobe"
    context: str = DEFAULT_CONTEXT
    rolling_context_characters: int = 120


class TranscriptionError(RuntimeError):
    pass


class CommandRunner:
    def run(self, args: Sequence[str]) -> CommandResult:
        completed = subprocess.run(list(args), text=True, capture_output=True, check=False)
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)


class URLTransport:
    def send(self, url: str, *, headers: Mapping[str, str], body: bytes, timeout: float) -> HTTPResult:
        http_request = request.Request(url, data=body, headers=dict(headers), method="POST")
        try:
            with request.urlopen(http_request, timeout=timeout) as response:
                return HTTPResult(response.status, response.read())
        except error.HTTPError as http_error:
            return HTTPResult(http_error.code, http_error.read(2048))


def encode_multipart(*, fields: Mapping[str, str], file_path: Path) -> tuple[str, bytes]:
    boundary = f"lmr-{uuid.uuid4().hex}"
    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n".encode())
        body.extend(value.encode("utf-8"))
        body.extend(b"\r\n")
    content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    body.extend(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{file_path.name}\"\r\nContent-Type: {content_type}\r\n\r\n".encode())
    body.extend(file_path.read_bytes())
    body.extend(f"\r\n--{boundary}--\r\n".encode())
    return f"multipart/form-data; boundary={boundary}", bytes(body)


class OpenAICompatibleTranscriptionClient:
    def __init__(self, *, base_url: str, api_key: Optional[str], transport=None):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.transport = transport or URLTransport()

    def transcribe(
        self,
        *,
        audio: Path,
        model: str,
        language: str,
        prompt: str,
    ) -> ProviderResponse:
        fields = {"model": model, "response_format": "json"}
        if language:
            fields["language"] = language
        if prompt:
            fields["prompt"] = prompt
        content_type, body = encode_multipart(fields=fields, file_path=audio)
        headers = {"Accept": "application/json", "Content-Type": content_type}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        try:
            result = self.transport.send(f"{self.base_url}/audio/transcriptions", headers=headers, body=body, timeout=7200)
        except TimeoutError as exc:
            raise TranscriptionError("Provider transcription request timed out") from exc
        except Exception as exc:
            raise TranscriptionError("Provider transcription request failed") from exc
        if result.status != 200:
            raise TranscriptionError(f"Provider transcription failed with HTTP {result.status}")
        try:
            payload = json.loads(result.body)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise TranscriptionError("Provider returned malformed transcription JSON") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
            raise TranscriptionError("Provider response did not contain string text")
        return ProviderResponse(payload=payload, raw_body=result.body)


def read_launch_payload(stream) -> LaunchPayload:
    try:
        document = json.load(stream)
    except (json.JSONDecodeError, TypeError) as exc:
        raise TranscriptionError("Provider launch payload was not valid JSON") from exc
    if not isinstance(document, dict) or document.get("schemaVersion") != 1:
        raise TranscriptionError("Unsupported provider payload version")
    base_url = str(document.get("baseURL", "")).rstrip("/")
    model = str(document.get("asrModel", "")).strip()
    if not base_url or not model:
        raise TranscriptionError("Provider base URL and ASR model are required")
    return LaunchPayload(1, base_url, model, str(document.get("language", "")).strip(), str(document.get("prompt", "")).strip(), str(document["apiKey"]) if document.get("apiKey") else None)


def build_transcription_prompt(global_context: str, previous_text: str, rolling_context_characters: int) -> str:
    sections = [global_context.strip()] if global_context.strip() else []
    if previous_text.strip() and rolling_context_characters > 0:
        sections.append("上一段錄音的轉錄結尾，只用作延續語境及專有名詞參考，不要在本段重複輸出：\n" + previous_text.strip()[-rolling_context_characters:])
    return "\n\n".join(sections)


def parse_silence_events(log: str) -> list[Interval]:
    starts = [float(value) for value in re.findall(r"silence_start:\s*([0-9]+(?:\.[0-9]+)?)", log)]
    ends = [float(value) for value in re.findall(r"silence_end:\s*([0-9]+(?:\.[0-9]+)?)", log)]
    return [Interval(start, end) for start, end in zip(starts, ends) if end >= start]


def plan_chunks(duration: float, silences: Sequence[Interval], target: float = 120.0, maximum: float = 180.0, padding: float = 1.5) -> list[Interval]:
    raw, start = [], 0.0
    while duration - start > target:
        desired, latest = min(start + target, duration), min(start + maximum, duration)
        candidates = [(silence.start + silence.end) / 2 for silence in silences if start + 30 <= (silence.start + silence.end) / 2 <= latest]
        cut = min(candidates, key=lambda value: abs(value - desired)) if candidates else desired
        raw.append(Interval(start, cut)); start = cut
    raw.append(Interval(start, duration))
    return [Interval(max(0.0, interval.start - padding), min(duration, interval.end + padding)) for interval in raw]


def _normalized_characters(text: str) -> tuple[str, list[int]]:
    chars, positions = [], []
    for index, char in enumerate(text):
        if char.isspace() or unicodedata.category(char).startswith(("P", "Z")):
            continue
        chars.append(char.casefold()); positions.append(index)
    return "".join(chars), positions


def _strip_boundary_prefix(text: str) -> str:
    index = 0
    while index < len(text):
        character = text[index]
        if character.isspace() or unicodedata.category(character).startswith(("P", "Z")):
            index += 1
            continue
        break
    return text[index:]


def merge_transcripts(texts: Sequence[str], minimum_overlap: int = 8) -> str:
    accepted = []
    for text in (value.strip() for value in texts if value.strip()):
        if accepted:
            old, _ = _normalized_characters(accepted[-1]); new, positions = _normalized_characters(text)
            overlap = next((size for size in range(min(len(old), len(new)), minimum_overlap - 1, -1) if old.endswith(new[:size])), 0)
            if overlap:
                text = _strip_boundary_prefix(text[positions[overlap - 1] + 1:])
        if text:
            accepted.append(text)
    return "\n".join(accepted)


def validate_transcript(text: object, audio_duration: Optional[float] = None, previous_text: str = "") -> tuple[bool, str]:
    if not isinstance(text, str) or not text.strip(): return False, "empty-text"
    compact = re.sub(r"\s+", "", text)
    if re.search(r"(.)\1{19,}$", compact): return False, "repeated-character-tail"
    if re.search(r"(.{2,8})\1{9,}$", compact): return False, "repeated-pattern-tail"
    if audio_duration and len(compact) / audio_duration > 20: return False, "excessive-output-density"
    if audio_duration and audio_duration >= 30 and previous_text.strip():
        previous, _ = _normalized_characters(previous_text); current, _ = _normalized_characters(text)
        if len(current) >= 8 and previous.endswith(current): return False, "prompt-echo-only"
    return True, "ok"


def backup_existing(path: Path) -> None:
    if path.exists():
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.copy2(path, path.with_name(f"{path.name}.previous-{stamp}"))


class StatusEmitter:
    def __init__(self, log_path: Path): self.stream = log_path.open("w", encoding="utf-8", buffering=1)
    def emit(self, line: str) -> None: print(line, flush=True); self.stream.write(line + "\n"); self.stream.flush()
    def close(self) -> None: self.stream.close()


class LongformTranscriber:
    TARGET_DURATION, MAXIMUM_DURATION, MINIMUM_RETRY_DURATION, PADDING = 120.0, 180.0, 30.0, 1.5
    def __init__(self, config: TranscriptionConfig, runner: Optional[CommandRunner] = None, client=None, emit: Callable[[str], None] = print):
        self.config, self.runner, self.client, self.emit = config, runner or CommandRunner(), client, emit
        self.duration, self.silences, self.attempts, self.accepted, self.request_number = 0.0, [], [], [], 0
        run_id = config.run_id or datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.staging = config.output_folder / ".transcription-runs" / run_id; self.chunks_directory = self.staging / "chunks"; self.responses_directory = self.staging / "responses"; self.manifest_path = self.staging / "manifest.json"

    def run(self) -> Path:
        if not self.config.audio.is_file(): raise TranscriptionError(f"Missing audio file: {self.config.audio}")
        if self.config.publish_mode not in {"candidate", "replace"}: raise TranscriptionError(f"Unsupported publish mode: {self.config.publish_mode}")
        self.chunks_directory.mkdir(parents=True, exist_ok=True); self.responses_directory.mkdir(parents=True, exist_ok=True)
        self.emit("STATUS=Analyzing audio"); self.duration = self._probe_duration(); self.silences = self._detect_silences()
        intervals = [self._remove_padding(item) for item in plan_chunks(self.duration, self.silences, self.TARGET_DURATION, self.MAXIMUM_DURATION, self.PADDING)]
        for index, interval in enumerate(intervals, 1): self.emit(f"STATUS=Transcribing chunk {index} of {len(intervals)}"); self._transcribe_interval(interval)
        merged = merge_transcripts([item["text"] for item in self.accepted]); valid, reason = validate_transcript(merged)
        if not valid: raise TranscriptionError(f"Merged transcript validation failed: {reason}")
        raw, final = self.staging / "candidate_raw.txt", self.staging / "candidate.txt"; raw.write_text(merged, encoding="utf-8"); final.write_text(self._traditional_chinese(merged), encoding="utf-8"); self._write_manifest()
        output = self._publish(raw, final); self.emit(f"TRANSCRIPT_PATH={output}"); return output

    def _probe_duration(self) -> float:
        result = self.runner.run([self.config.ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(self.config.audio)])
        try: duration = float(result.stdout.strip())
        except ValueError as exc: raise TranscriptionError("Unable to read audio duration") from exc
        if result.returncode or duration <= 0: raise TranscriptionError("Unable to read audio duration")
        return duration

    def _detect_silences(self) -> list[Interval]:
        result = self.runner.run([self.config.ffmpeg, "-hide_banner", "-nostats", "-i", str(self.config.audio), "-map", "0:a:0", "-af", "silencedetect=noise=-40dB:d=0.6", "-f", "null", "-"])
        if result.returncode: raise TranscriptionError("Unable to analyze audio silence")
        return parse_silence_events(result.stderr)

    def _remove_padding(self, interval: Interval) -> Interval:
        return Interval(0.0 if interval.start <= 0 else min(self.duration, interval.start + self.PADDING), self.duration if interval.end >= self.duration else max(0.0, interval.end - self.PADDING))
    def _with_padding(self, interval: Interval) -> Interval: return Interval(max(0, interval.start - self.PADDING), min(self.duration, interval.end + self.PADDING))

    def _transcribe_interval(self, raw_interval: Interval, use_rolling_context: bool = True) -> None:
        interval = self._with_padding(raw_interval); previous = self.accepted[-1]["text"] if self.accepted and use_rolling_context else ""; prompt = build_transcription_prompt(self.config.context, previous, self.config.rolling_context_characters)
        self.request_number += 1; request_id = f"{self.request_number:04d}"; chunk = self.chunks_directory / f"{request_id}.wav"; response = self.responses_directory / f"{request_id}.json"; self._extract_audio(interval, chunk)
        rolling_context_used = bool(
            previous.strip() and self.config.rolling_context_characters > 0
        )
        try:
            provider_response = self.client.transcribe(audio=chunk, model=self.config.model, language=self.config.language, prompt=prompt)
            response.write_bytes(provider_response.raw_body)
            text = provider_response.payload["text"]
            response_error = ""
        except TranscriptionError as exc: text, response_error = "", str(exc)
        valid, reason = validate_transcript(text, interval.end - interval.start, previous) if not response_error else (False, response_error)
        attempt = {"request_id": request_id, "raw_start": raw_interval.start, "raw_end": raw_interval.end, "request_start": interval.start, "request_end": interval.end, "response": str(response), "character_count": len(text) if isinstance(text, str) else 0, "prompt_character_count": len(prompt), "rolling_context_used": rolling_context_used, "validation": reason}; self.attempts.append(attempt)
        if valid and isinstance(text, str): self.accepted.append({**attempt, "text": text}); self._write_manifest(); return
        self._write_manifest()
        if rolling_context_used: self.emit("STATUS=Retrying failed chunk without previous transcript context"); return self._transcribe_interval(raw_interval, False)
        if raw_interval.end - raw_interval.start >= self.MINIMUM_RETRY_DURATION * 2:
            self.emit("STATUS=Retrying failed chunk with shorter intervals"); split = self._split_point(raw_interval); self._transcribe_interval(Interval(raw_interval.start, split)); return self._transcribe_interval(Interval(split, raw_interval.end))
        raise TranscriptionError(f"Chunk {request_id} failed validation: {reason}")

    def _split_point(self, interval: Interval) -> float:
        center = (interval.start + interval.end) / 2; candidates = [(item.start + item.end) / 2 for item in self.silences if interval.start + self.MINIMUM_RETRY_DURATION <= (item.start + item.end) / 2 <= interval.end - self.MINIMUM_RETRY_DURATION]
        return min(candidates, key=lambda value: abs(value - center)) if candidates else center
    def _extract_audio(self, interval: Interval, output: Path) -> None:
        result = self.runner.run([self.config.ffmpeg, "-hide_banner", "-nostats", "-y", "-ss", f"{interval.start:.6f}", "-to", f"{interval.end:.6f}", "-i", str(self.config.audio), "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(output)])
        if result.returncode or not output.is_file(): raise TranscriptionError("Unable to extract audio chunk")
    def _traditional_chinese(self, text: str) -> str:
        try:
            from opencc import OpenCC
            return OpenCC("s2hk").convert(text)
        except ImportError: return text
    def _write_manifest(self) -> None:
        self.staging.mkdir(parents=True, exist_ok=True); temporary = self.manifest_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps({"source": str(self.config.audio), "source_duration": self.duration, "model": self.config.model, "language": self.config.language, "attempts": self.attempts, "accepted": [{key: value for key, value in item.items() if key != "text"} for item in self.accepted]}, ensure_ascii=False, indent=2), encoding="utf-8"); os.replace(temporary, self.manifest_path)
    def _publish(self, raw_candidate: Path, final_candidate: Path) -> Path:
        names = {"raw": "transcript.raw.txt", "final": "transcript.txt", "manifest": "transcription.json"}
        outputs = {key: self.config.output_folder / (value.replace(".", ".candidate.", 1) if self.config.publish_mode == "candidate" else value) for key, value in names.items()}
        if self.config.publish_mode == "replace":
            for output in outputs.values(): backup_existing(output)
        self._atomic_copy(raw_candidate, outputs["raw"]); self._atomic_copy(final_candidate, outputs["final"]); self._atomic_copy(self.manifest_path, outputs["manifest"]); return outputs["final"]
    def _atomic_copy(self, source: Path, output: Path) -> None:
        temporary = output.with_name(f".{output.name}.tmp"); temporary.write_bytes(source.read_bytes()); os.replace(temporary, output)


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Transcribe long recordings through sequential provider-compatible chunks.")
    parser.add_argument("--audio", type=Path, required=True); parser.add_argument("--output-folder", type=Path, required=True); parser.add_argument("--publish-mode", choices=("candidate", "replace"), default="replace"); parser.add_argument("--rolling-context-characters", type=int, default=120); parser.add_argument("--log", type=Path, required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _argument_parser().parse_args(argv)
    try:
        args.output_folder.mkdir(parents=True, exist_ok=True)
        backup_existing(args.log)
        emitter = StatusEmitter(args.log)
    except Exception as exc:
        print(f"ERROR=Unexpected {type(exc).__name__}", flush=True)
        return 70
    emitter.emit(f"LOG_PATH={args.log.resolve()}")
    try:
        payload = read_launch_payload(sys.stdin); config = TranscriptionConfig(audio=args.audio, output_folder=args.output_folder, base_url=payload.base_url, model=payload.asr_model, language=payload.language, publish_mode=args.publish_mode, context=payload.prompt, rolling_context_characters=args.rolling_context_characters, ffmpeg=os.environ.get("FFMPEG", "ffmpeg"), ffprobe=os.environ.get("FFPROBE", "ffprobe")); LongformTranscriber(config, client=OpenAICompatibleTranscriptionClient(base_url=payload.base_url, api_key=payload.api_key), emit=emitter.emit).run()
    except FileNotFoundError: emitter.emit("ERROR=Missing required command"); return 69
    except TranscriptionError as exc: emitter.emit(f"ERROR={exc}"); return 70
    except KeyboardInterrupt: emitter.emit("ERROR=Transcription cancelled"); return 130
    except Exception as exc: emitter.emit(f"ERROR=Unexpected {type(exc).__name__}"); return 70
    finally: emitter.close()
    return 0


if __name__ == "__main__": raise SystemExit(main())
