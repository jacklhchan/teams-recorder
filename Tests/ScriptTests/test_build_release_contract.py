import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RELEASE_SCRIPT = ROOT / "scripts/build-release.sh"
WRITE_SHA256 = ROOT / "scripts/write-sha256.sh"
ATOMIC_PUBLISH = ROOT / "scripts/atomic-publish-directory.py"
SAFE_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": str(Path.home()),
    "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
}


class BuildReleaseContractTests(unittest.TestCase):
    def run_release(self, *arguments, env=None):
        return subprocess.run(
            ["/bin/bash", str(RELEASE_SCRIPT), *arguments],
            text=True,
            capture_output=True,
            check=False,
            env=SAFE_ENV if env is None else env,
        )

    def dry_run_arguments(self, *extra):
        return (
            "--version", "1.0.0", "--build-number", "100",
            "--signing-identity", "Developer ID Application: Test (TEAMID)",
            "--signed-only", *extra,
        )

    def test_requires_exact_version_build_identity_and_mode(self):
        result = self.run_release("--dry-run")
        self.assertEqual(result.returncode, 64)

    def test_rejects_both_notary_modes(self):
        result = self.run_release(
            "--version", "1.0.0", "--build-number", "100",
            "--signing-identity", "Developer ID Application: Test",
            "--notary-profile", "profile", "--signed-only", "--dry-run",
        )
        self.assertEqual(result.returncode, 64)

    def test_notary_profile_requires_explicit_keychain(self):
        result = self.run_release(
            "--version", "1.0.0", "--build-number", "100",
            "--signing-identity", "Developer ID Application: Test (TEAMID)",
            "--notary-profile", "profile", "--dry-run",
        )
        self.assertEqual(result.returncode, 64)

    def test_dry_run_prints_plan_without_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary).resolve() / "release"
            result = self.run_release(*self.dry_run_arguments(
                "--output-dir", str(output), "--dry-run"))
            self.assertEqual(result.returncode, 0)
            self.assertIn("local.meeting.recorder", result.stdout)
            self.assertIn("release-candidate", result.stdout)
            self.assertFalse(output.exists())

    def test_dry_run_uses_normalized_default_output_without_creating_it(self):
        expected = ROOT / "build/releases/Local-Meeting-Recorder-1.0.0-100-release-candidate"
        result = self.run_release(*self.dry_run_arguments("--dry-run"))
        self.assertEqual(result.returncode, 0)
        self.assertIn(f"output_dir={expected}", result.stdout)
        self.assertFalse(expected.exists())

    def test_dry_run_never_runs_sensitive_commands_when_environment_is_hostile(self):
        with tempfile.TemporaryDirectory() as temporary:
            sentinel = Path(temporary) / "sentinel"
            sentinel.write_text(
                '#!/bin/sh\necho "$0" >> "$R3_SENTINEL"\nexit 99\n'
            )
            sentinel.chmod(0o755)
            environment = SAFE_ENV | {
                "PATH": f"{temporary}:/usr/bin:/bin",
                "SWIFT_BIN": str(sentinel),
                "CODESIGN_BIN": str(sentinel),
                "R3_SENTINEL": str(Path(temporary) / "calls"),
            }
            for name in ("security", "swift", "codesign", "notarytool", "ditto", "rm", "mkdir"):
                (Path(temporary) / name).symlink_to(sentinel)
            result = self.run_release(*self.dry_run_arguments("--dry-run"), env=environment)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(Path(environment["R3_SENTINEL"]).exists())

    def test_missing_identity_fails_before_build(self):
        result = self.run_release(*self.dry_run_arguments())
        self.assertEqual(result.returncode, 78)
        self.assertIn("identity", result.stderr.lower())
        script = RELEASE_SCRIPT.read_text(encoding="utf-8")
        self.assertLess(
            script.index("security find-identity"),
            script.rindex('"$ROOT_DIR/scripts/build-app.sh"'),
        )

    def test_rejects_relative_and_symlinked_output_paths(self):
        relative = self.run_release(*self.dry_run_arguments("--output-dir", "release", "--dry-run"))
        self.assertEqual(relative.returncode, 64)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            target = root / "target"
            target.mkdir()
            link = root / "link"
            link.symlink_to(target)
            symlinked = self.run_release(*self.dry_run_arguments(
                "--output-dir", str(link / "release"), "--dry-run"))
            self.assertEqual(symlinked.returncode, 73)

    def test_release_and_checksum_scripts_are_executable(self):
        self.assertTrue(os.access(RELEASE_SCRIPT, os.X_OK))
        self.assertTrue(os.access(WRITE_SHA256, os.X_OK))

    def test_atomic_publish_succeeds_only_when_destination_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            destination = root / "release"
            source.mkdir()
            (source / "artifact.zip").write_bytes(b"release")
            success = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), str(source), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(success.returncode, 0)
            self.assertFalse(source.exists())
            self.assertTrue((destination / "artifact.zip").is_file())

    def test_atomic_publish_refuses_competing_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            destination = root / "release"
            source.mkdir()
            destination.mkdir()
            (source / "artifact.zip").write_bytes(b"release")
            refused = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), str(source), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(refused.returncode, 73)
            self.assertTrue(source.is_dir())

    def test_atomic_publish_is_race_safe_for_competing_destinations(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            destination = root / "release"
            sources = [root / "staged-one", root / "staged-two"]
            for index, source in enumerate(sources, start=1):
                source.mkdir()
                (source / "artifact.zip").write_text(str(index))
            processes = [
                subprocess.Popen(
                    ["/usr/bin/python3", str(ATOMIC_PUBLISH), str(source), str(destination)],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=SAFE_ENV,
                )
                for source in sources
            ]
            results = [process.communicate() for process in processes]
            self.assertEqual(sorted(process.returncode for process in processes), [0, 73])
            self.assertTrue((destination / "artifact.zip").is_file())
            self.assertEqual(sum(source.exists() for source in sources), 1)

    def test_atomic_publish_rejects_bad_inputs_and_maps_cross_device_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            source.mkdir()
            destination = root / "release"
            bad_source = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), str(root / "absent"), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(bad_source.returncode, 66)
            forced = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), "--force-errno", "18", str(source), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(forced.returncode, 70)

    def test_checksum_is_portable_and_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact = Path(temporary) / "artifact.zip"
            artifact.write_bytes(b"release")
            result = subprocess.run([str(WRITE_SHA256), str(artifact)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(result.returncode, 0)
            checksum = artifact.with_suffix(".zip.sha256")
            line = checksum.read_text(encoding="utf-8").strip()
            self.assertTrue(line.endswith("  artifact.zip"))
            self.assertNotIn(str(Path(temporary)), line)
            verified = subprocess.run(["/usr/bin/shasum", "-a", "256", "-c", checksum.name], cwd=temporary, text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(verified.returncode, 0)

    def test_publication_stages_complete_release_before_rename(self):
        script = RELEASE_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(".lmr-release-publish.XXXXXX", script)
        self.assertIn('cp "$ROOT_DIR/LICENSE"', script)
        self.assertIn('cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md"', script)
        publish_call = '"$ROOT_DIR/scripts/atomic-publish-directory.py"'
        self.assertIn(publish_call, script)
        self.assertLess(script.index('cp "$ROOT_DIR/LICENSE"'), script.rindex(publish_call))
