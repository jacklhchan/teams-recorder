import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ENTRYPOINT = ROOT / "scripts" / "transcribe-qwen-asr.sh"
BUILD_SCRIPT = ROOT / "scripts" / "build-app.sh"


class TranscriptionEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.audio = self.root / "recording.mp4"
        self.audio.write_bytes(b"fake media")
        self.output_dir = self.root / "output"
        self.output_dir.mkdir()
        self.capture_path = self.root / "invocation.json"
        self.settings = self.root / "settings.json"
        self.settings.write_text(
            json.dumps({"auth": {"api_key": "secret-test-key"}}),
            encoding="utf-8",
        )
        self.helper = self.root / "fake_longform_helper.py"
        self.helper.write_text(
            textwrap.dedent(
                """
                import argparse
                import json
                import os
                from pathlib import Path

                parser = argparse.ArgumentParser()
                parser.add_argument("--audio")
                parser.add_argument("--output-folder")
                parser.add_argument("--omlx-url")
                parser.add_argument("--model")
                parser.add_argument("--language")
                parser.add_argument("--publish-mode")
                args = parser.parse_args()
                Path(os.environ["CAPTURE_PATH"]).write_text(
                    json.dumps({
                        **vars(args),
                        "api_key": os.environ.get("OMLX_API_KEY"),
                    }),
                    encoding="utf-8",
                )
                print("STATUS=Fake helper completed")
                if int(os.environ.get("FAKE_HELPER_EXIT", "0")) == 0:
                    print(
                        "TRANSCRIPT_PATH="
                        + str(Path(args.output_folder) / "candidate.txt")
                    )
                raise SystemExit(int(os.environ.get("FAKE_HELPER_EXIT", "0")))
                """
            ),
            encoding="utf-8",
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_entrypoint(self, helper_exit):
        environment = os.environ.copy()
        environment.update(
            {
                "PYTHON": "/usr/bin/python3",
                "OMLX_SETTINGS": str(self.settings),
                "OMLX_URL": "http://127.0.0.1:1",
                "OMLX_ASR_MODEL": "test-model",
                "LANGUAGE": "yue",
                "LONGFORM_HELPER": str(self.helper),
                "CAPTURE_PATH": str(self.capture_path),
                "FAKE_HELPER_EXIT": str(helper_exit),
                "TRANSCRIPTION_PUBLISH_MODE": "candidate",
                "OMLX_LAUNCH_APP": "0",
            }
        )
        return subprocess.run(
            ["/bin/bash", str(ENTRYPOINT), str(self.audio), str(self.output_dir)],
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def test_delegates_to_packaged_helper_without_leaking_api_key(self):
        result = self.run_entrypoint(helper_exit=0)

        self.assertEqual(result.returncode, 0)
        invocation = json.loads(self.capture_path.read_text(encoding="utf-8"))
        self.assertEqual(invocation["audio"], str(self.audio))
        self.assertEqual(invocation["output_folder"], str(self.output_dir))
        self.assertEqual(invocation["model"], "test-model")
        self.assertEqual(invocation["language"], "yue")
        self.assertEqual(invocation["publish_mode"], "candidate")
        self.assertEqual(invocation["api_key"], "secret-test-key")
        self.assertNotIn(
            "secret-test-key",
            result.stdout + result.stderr,
        )

    def test_propagates_helper_failure(self):
        result = self.run_entrypoint(helper_exit=70)

        self.assertEqual(result.returncode, 70)
        self.assertNotIn("TRANSCRIPT_PATH=", result.stdout)

    def test_build_script_packages_longform_helper(self):
        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            'cp "$ROOT_DIR/scripts/qwen_asr_longform.py" '
            '"$RESOURCES_DIR/qwen_asr_longform.py"',
            build_script,
        )
        self.assertIn(
            'chmod +x "$RESOURCES_DIR/qwen_asr_longform.py"',
            build_script,
        )


if __name__ == "__main__":
    unittest.main()
