import importlib.util
import json
import urllib.error
import urllib.request
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = ROOT / "Tests" / "ManualFixtures" / "meeting_intelligence_provider.py"


def load_fixture_module():
    spec = importlib.util.spec_from_file_location(
        "meeting_intelligence_provider",
        FIXTURE_PATH,
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def request_json(url, method="GET", payload=None, headers=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers=headers or {},
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        return response.status, json.loads(response.read().decode("utf-8"))


class MeetingIntelligenceProviderFixtureTests(unittest.TestCase):
    def test_models_and_model_routed_endpoints_emit_sanitized_counts(self):
        fixture = load_fixture_module()
        with fixture.SyntheticMeetingIntelligenceProvider(
            advertised_models=("asr-model", "llm-model"),
        ) as provider:
            status, models = request_json(f"{provider.base_url}/models")
            self.assertEqual(status, 200)
            self.assertEqual(
                {item["id"] for item in models["data"]},
                {"asr-model", "llm-model"},
            )
            status, _ = request_json(
                f"{provider.base_url}/audio/transcriptions",
                method="POST",
                payload={"model": "asr-model", "file": "ignored"},
            )
            self.assertEqual(status, 200)
            status, _ = request_json(
                f"{provider.base_url}/chat/completions",
                method="POST",
                payload={
                    "model": "llm-model",
                    "messages": [{"role": "user", "content": "private"}],
                },
            )
            self.assertEqual(status, 200)

            events = provider.read_events()
            self.assertEqual(provider.request_counts, {
                "models": 1,
                "audio-transcriptions": 1,
                "chat-completions": 1,
            })
            self.assertEqual(
                [event["modelRole"] for event in events if "modelRole" in event],
                ["asr", "llm"],
            )
            self.assertTrue(all(set(event) <= {
                "timestamp", "endpoint", "requestCount", "modelRole", "outcome"
            } for event in events))

    def test_missing_model_delayed_and_forced_status_modes_are_counted(self):
        fixture = load_fixture_module()
        with fixture.SyntheticMeetingIntelligenceProvider(
            advertised_models=("asr-model",),
            forced_status={"chat-completions": 429},
            response_delay_seconds=0.01,
        ) as provider:
            _, models = request_json(f"{provider.base_url}/models")
            self.assertNotIn("llm-model", {item["id"] for item in models["data"]})
            with self.assertRaises(urllib.error.HTTPError) as error:
                request_json(
                    f"{provider.base_url}/chat/completions",
                    method="POST",
                    payload={"model": "llm-model", "messages": []},
                )
            self.assertEqual(error.exception.code, 429)
            error.exception.close()
            self.assertEqual(provider.request_counts["chat-completions"], 1)
            self.assertEqual(provider.read_events()[-1]["outcome"], "forced-status")

    def test_telemetry_excludes_credentials_content_urls_and_paths(self):
        fixture = load_fixture_module()
        secret = "Bearer canary-credential"
        prompt = "canary prompt /Users/example/private/transcript.txt"
        response = "canary response body"
        with fixture.SyntheticMeetingIntelligenceProvider(
            chat_response=response,
        ) as provider:
            request_json(
                f"{provider.base_url}/chat/completions",
                method="POST",
                payload={
                    "model": "llm-model",
                    "messages": [{"role": "user", "content": prompt}],
                },
                headers={"Authorization": secret},
            )
            telemetry = provider.telemetry_path.read_text(encoding="utf-8")
            for forbidden in (
                secret,
                prompt,
                response,
                provider.base_url,
                "/Users/example/private",
                "Authorization",
                "messages",
            ):
                with self.subTest(forbidden=forbidden):
                    self.assertNotIn(forbidden, telemetry)


if __name__ == "__main__":
    unittest.main()
