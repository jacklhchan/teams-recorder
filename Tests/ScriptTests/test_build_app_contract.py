import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD_APP = ROOT / "scripts/build-app.sh"


class BuildAppContractTests(unittest.TestCase):
    def run_build(self, *arguments):
        return subprocess.run(
            ["/bin/bash", str(BUILD_APP), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": str(Path.home()),
                "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            },
        )

    def test_rejects_invalid_configuration_before_build(self):
        result = self.run_build("--configuration", "profile", "--sign", "none")
        self.assertEqual(result.returncode, 64)
        self.assertIn("debug or release", result.stderr)

    def test_rejects_invalid_version_and_build_number(self):
        self.assertEqual(self.run_build("--version", "latest").returncode, 64)
        self.assertEqual(self.run_build("--build-number", "0").returncode, 64)

    def test_rejects_production_signing_mode(self):
        result = self.run_build("--sign", "Developer ID")
        self.assertEqual(result.returncode, 64)
        self.assertIn("ad-hoc or none", result.stderr)

    def test_script_uses_show_bin_path_not_hard_coded_build_path(self):
        script = BUILD_APP.read_text(encoding="utf-8")
        self.assertIn("--show-bin-path", script)
        self.assertNotIn(".build/arm64-apple-macosx/debug", script)

    def test_rejects_unowned_existing_output_before_build(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "Existing.app"
            output.mkdir()
            result = self.run_build("--output", str(output), "--sign", "none")
            self.assertEqual(result.returncode, 73)
            self.assertTrue(output.is_dir())

    def test_rejects_symlink_output_and_symlinked_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir()
            output_link = root / "Linked.app"
            output_link.symlink_to(target)
            self.assertEqual(
                self.run_build("--output", str(output_link), "--sign", "none").returncode,
                73,
            )

            parent_link = root / "linked-parent"
            parent_link.symlink_to(target)
            self.assertEqual(
                self.run_build(
                    "--output", str(parent_link / "Output.app"), "--sign", "none"
                ).returncode,
                73,
            )

    def test_microphone_entitlement_and_verifier_are_present(self):
        with (ROOT / "Config/LocalMeetingRecorder.entitlements").open("rb") as stream:
            entitlements = plistlib.load(stream)
        self.assertIs(entitlements["com.apple.security.device.audio-input"], True)
        verifier = ROOT / "scripts/verify-app-bundle.sh"
        self.assertTrue(os.access(verifier, os.X_OK))
