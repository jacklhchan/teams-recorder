import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from openai_asr_longform import (  # noqa: E402
    CommandResult,
    HTTPResult,
    Interval,
    LongformTranscriber,
    OpenAICompatibleTranscriptionClient,
    TranscriptionConfig,
    TranscriptionError,
    build_transcription_prompt,
    merge_transcripts,
    plan_chunks,
    read_launch_payload,
    validate_transcript,
)


class FakeRunner:
    def __init__(self, duration=10.0, silence_log=""):
        self.duration = duration
        self.silence_log = silence_log

    def run(self, args):
        executable = Path(args[0]).name
        if executable == "ffprobe":
            return CommandResult(0, f"{self.duration}\n", "")
        if executable == "ffmpeg" and any("silencedetect=" in value for value in args):
            return CommandResult(0, "", self.silence_log)
        if executable == "ffmpeg":
            Path(args[-1]).write_bytes(b"fake wav")
            return CommandResult(0, "", "")
        raise AssertionError(f"Unexpected command: {args}")


class RecordingTranscriptionClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def transcribe(self, *, audio, model, language, prompt):
        self.requests.append({"audio": audio, "model": model, "language": language, "prompt": prompt})
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


class RecordingHTTPTransport:
    def __init__(self, response_status=200, response_body=b'{"text":"ok"}'):
        self.response_status = response_status
        self.response_body = response_body
        self.last_request = None

    def send(self, url, *, headers, body, timeout):
        self.last_request = type("Request", (), {"url": url, "headers": headers, "body": body, "timeout": timeout})()
        return HTTPResult(self.response_status, self.response_body)


class PlanningTests(unittest.TestCase):
    def test_preserves_silence_aware_120_target_180_maximum_and_overlap(self):
        chunks = plan_chunks(250.0, [Interval(117.0, 119.0), Interval(238.0, 240.0)])
        self.assertEqual(chunks[0], Interval(0.0, 119.5))
        self.assertEqual(chunks[1].start, 116.5)
        self.assertEqual(chunks[-1].end, 250.0)

    def test_preserves_repetition_and_overlap_validation(self):
        self.assertEqual(validate_transcript("正常內容" + "啊" * 30), (False, "repeated-character-tail"))
        self.assertEqual(merge_transcripts(["第一段共同重複內容文字。", "共同重複內容文字。第二段。"]), "第一段共同重複內容文字。\n第二段。")
        prompt = build_transcription_prompt("全域提示", "前段內容" * 80, 12)
        self.assertTrue(prompt.endswith(("前段內容" * 80)[-12:]))


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.chunk = Path(self.temporary_directory.name) / "chunk.wav"
        self.chunk.write_bytes(b"audio")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_standard_request_omits_empty_language_and_prompt(self):
        transport = RecordingHTTPTransport()
        OpenAICompatibleTranscriptionClient(base_url="https://example.test/v1", api_key=None, transport=transport).transcribe(audio=self.chunk, model="custom-asr", language="", prompt="")
        body = transport.last_request.body
        self.assertIn(b'name="file"', body)
        self.assertIn(b'name="model"', body)
        self.assertIn(b'name="response_format"', body)
        self.assertNotIn(b'name="language"', body)
        self.assertNotIn(b'name="prompt"', body)
        self.assertNotIn(b"max_tokens", body)
        self.assertNotIn("Authorization", transport.last_request.headers)

    def test_request_adds_nonempty_fields_and_optional_bearer(self):
        transport = RecordingHTTPTransport()
        OpenAICompatibleTranscriptionClient(base_url="https://example.test/v1/", api_key="secret", transport=transport).transcribe(audio=self.chunk, model="custom-asr", language="yue", prompt="context")
        self.assertEqual(transport.last_request.url, "https://example.test/v1/audio/transcriptions")
        self.assertEqual(transport.last_request.headers["Authorization"], "Bearer secret")
        self.assertIn(b'name="language"', transport.last_request.body)
        self.assertIn(b'name="prompt"', transport.last_request.body)

    def test_typed_http_and_response_failures_are_redacted(self):
        cases = [(401, b"secret response"), (404, b"secret response"), (200, b"not json"), (200, b'{"text": 2}')]
        for status, body in cases:
            with self.subTest(status=status, body=body):
                with self.assertRaises(TranscriptionError) as raised:
                    OpenAICompatibleTranscriptionClient(base_url="https://example.test/v1", api_key="secret", transport=RecordingHTTPTransport(status, body)).transcribe(audio=self.chunk, model="custom-asr", language="", prompt="")
                self.assertNotIn("secret", str(raised.exception))
                self.assertNotIn("not json", str(raised.exception))

    def test_transport_timeout_is_redacted(self):
        class TimeoutTransport:
            def send(self, *args, **kwargs):
                raise TimeoutError("secret response")
        with self.assertRaises(TranscriptionError) as raised:
            OpenAICompatibleTranscriptionClient(base_url="https://example.test/v1", api_key="secret", transport=TimeoutTransport()).transcribe(audio=self.chunk, model="custom-asr", language="", prompt="")
        self.assertEqual(str(raised.exception), "Provider transcription request timed out")


class PayloadTests(unittest.TestCase):
    def test_reads_nonsecret_launch_payload(self):
        payload = read_launch_payload(io.StringIO(json.dumps({"schemaVersion": 1, "baseURL": "https://example.test/v1/", "asrModel": "custom-asr", "language": " yue ", "prompt": " context ", "apiKey": "secret"})))
        self.assertEqual(payload.base_url, "https://example.test/v1")
        self.assertEqual(payload.asr_model, "custom-asr")
        self.assertEqual(payload.language, "yue")
        self.assertEqual(payload.prompt, "context")

    def test_rejects_invalid_payload_without_echoing_secrets(self):
        with self.assertRaises(TranscriptionError) as raised:
            read_launch_payload(io.StringIO('{"schemaVersion":2,"apiKey":"secret"}'))
        self.assertNotIn("secret", str(raised.exception))


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.audio = self.root / "recording.mp4"
        self.audio.write_bytes(b"fake media")
        self.output = self.root / "output"
        self.output.mkdir()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def config(self, mode="candidate"):
        return TranscriptionConfig(audio=self.audio, output_folder=self.output, base_url="https://example.test/v1", model="custom-asr", language="yue", publish_mode=mode, run_id="test-run", context="會議術語", rolling_context_characters=120)

    def test_transcription_does_not_require_models_endpoint(self):
        client = RecordingTranscriptionClient([{"text": "valid transcript"}])
        output = LongformTranscriber(self.config(), runner=FakeRunner(), client=client, emit=lambda _: None).run()
        self.assertTrue(output.is_file())
        self.assertEqual(len(client.requests), 1)

    def test_retries_without_context_then_shorter_intervals(self):
        client = RecordingTranscriptionClient([{"text": "第一段正常內容。"}, {"text": "啊" * 30}, {"text": "恢復正常。"}])
        output = LongformTranscriber(self.config(), runner=FakeRunner(duration=240.0), client=client, emit=lambda _: None).run()
        self.assertIn("恢復正常", output.read_text(encoding="utf-8"))
        self.assertEqual(client.requests[2]["prompt"], "會議術語")

    def test_candidate_and_replace_publish_canonical_artifacts(self):
        client = RecordingTranscriptionClient([{"text": "內容。"}])
        candidate = LongformTranscriber(self.config(), runner=FakeRunner(), client=client, emit=lambda _: None).run()
        self.assertEqual(candidate.name, "transcript.candidate.txt")
        self.assertTrue((self.output / "transcript.candidate.raw.txt").is_file())
        self.assertTrue((self.output / "transcription.candidate.json").is_file())
        (self.output / "transcript.txt").write_text("old", encoding="utf-8")
        output = LongformTranscriber(self.config("replace"), runner=FakeRunner(), client=RecordingTranscriptionClient([{"text": "新內容。"}]), emit=lambda _: None).run()
        self.assertEqual(output.name, "transcript.txt")
        self.assertTrue(list(self.output.glob("transcript.txt.previous-*")))


class CliTests(unittest.TestCase):
    HELPER = ROOT / "scripts" / "openai_asr_longform.py"

    def test_help_is_available_without_provider_defaults(self):
        result = subprocess.run(["/usr/bin/python3", str(self.HELPER), "--help"], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("omlx", result.stdout.lower())
