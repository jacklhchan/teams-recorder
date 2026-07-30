import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = ROOT / "scripts" / "transcribe-openai-compatible.sh"
WRAPPER = ROOT / "scripts" / "transcribe-qwen-asr.sh"
BUILD_SCRIPT = ROOT / "scripts" / "build-app.sh"


class TranscriptionEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.audio = self.root / "recording.mp4"
        self.audio.write_bytes(b"fake media")
        self.output_dir = self.root / "output"
        self.capture_path = self.root / "invocation.json"
        self.helper = self.root / "fake_longform_helper.py"
        self.helper.write_text(textwrap.dedent("""
            import argparse
            import json
            import os
            import sys
            from pathlib import Path
            parser = argparse.ArgumentParser()
            parser.add_argument("--audio")
            parser.add_argument("--output-folder")
            parser.add_argument("--publish-mode")
            parser.add_argument("--log")
            args = parser.parse_args()
            Path(os.environ["CAPTURE_PATH"]).write_text(json.dumps(vars(args)), encoding="utf-8")
            received = sys.stdin.read()
            print("STATUS=Fake helper completed")
            if "secret-test-key" in received:
                print("STATUS=Payload received")
            raise SystemExit(int(os.environ.get("FAKE_HELPER_EXIT", "0")))
        """), encoding="utf-8")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_entrypoint(self, entrypoint=ENTRYPOINT, helper_exit=0):
        environment = os.environ.copy()
        environment.update({"PYTHON": "/usr/bin/python3", "LONGFORM_HELPER": str(self.helper), "CAPTURE_PATH": str(self.capture_path), "FAKE_HELPER_EXIT": str(helper_exit), "TRANSCRIPTION_PUBLISH_MODE": "candidate"})
        return subprocess.run(["/bin/bash", str(entrypoint), str(self.audio), str(self.output_dir)], input=json.dumps({"schemaVersion": 1, "baseURL": "http://127.0.0.1:1/v1", "asrModel": "test-model", "language": "yue", "prompt": "meeting context", "apiKey": "secret-test-key"}), text=True, capture_output=True, env=environment, check=False)

    def test_generic_entrypoint_forwards_stdin_and_only_nonsecret_arguments(self):
        result = self.run_entrypoint()
        self.assertEqual(result.returncode, 0)
        invocation = json.loads(self.capture_path.read_text(encoding="utf-8"))
        self.assertEqual(invocation["audio"], str(self.audio))
        self.assertEqual(invocation["output_folder"], str(self.output_dir))
        self.assertEqual(invocation["publish_mode"], "candidate")
        self.assertEqual(invocation["log"], str(self.output_dir / "transcription.log"))
        self.assertNotIn("secret-test-key", result.stdout + result.stderr)

    def test_compatibility_wrapper_has_no_provider_defaults(self):
        result = self.run_entrypoint(WRAPPER)
        self.assertEqual(result.returncode, 0)
        wrapper = WRAPPER.read_text(encoding="utf-8")
        self.assertNotIn("OMLX", wrapper)
        self.assertNotIn("Qwen", wrapper)

    def test_propagates_helper_failure(self):
        self.assertEqual(self.run_entrypoint(helper_exit=70).returncode, 70)

    def test_build_script_excludes_legacy_transcription_runtime_helpers(self):
        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")
        for name in ("transcribe-openai-compatible.sh", "transcribe-qwen-asr.sh", "openai_asr_longform.py"):
            self.assertNotIn(name, build_script)
        self.assertNotIn("prepare-qwen-asr.sh", build_script)
        self.assertNotIn("qwen_asr_longform.py", build_script)
