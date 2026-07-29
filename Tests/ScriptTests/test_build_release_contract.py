import errno
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
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


def load_atomic_publish_module():
    spec = importlib.util.spec_from_file_location(
        "atomic_publish_directory",
        ATOMIC_PUBLISH,
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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

    def write_release_fixture(self, root, transform):
        scripts = root / "scripts"
        scripts.mkdir()
        source = RELEASE_SCRIPT.read_text(encoding="utf-8")
        fixture = scripts / "build-release.sh"
        fixture.write_text(transform(source), encoding="utf-8")
        fixture.chmod(0o755)
        for name in (
            "build-app.sh",
            "write-sha256.sh",
            "atomic-publish-directory.py",
        ):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        return fixture

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

    def test_hostile_developer_dir_cannot_redirect_xcode_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            hostile = root / "hostile-developer"
            (hostile / "usr/bin").mkdir(parents=True)
            (hostile / "usr/bin/codesign").write_text("hostile")
            identity = (
                'IDENTITIES=\' 1) HASH "Developer ID Application: '
                'Test (TEAMID)"\''
            )

            def transform(source):
                source = source.replace(
                    'IDENTITIES="$(/usr/bin/security find-identity -v '
                    '-p codesigning 2>/dev/null || true)"',
                    identity,
                )
                return source.replace(
                    'CODESIGN_BIN="$(resolve_xcode_tool codesign)"',
                    'CODESIGN_BIN="$(resolve_xcode_tool codesign)"\n'
                    'printf "developer_dir=%s\\nresolved=%s\\n" '
                    '"$DEVELOPER_DIR" "$CODESIGN_BIN"\n'
                    'exit 0',
                )

            fixture = self.write_release_fixture(root, transform)
            environment = SAFE_ENV | {"DEVELOPER_DIR": str(hostile)}
            result = subprocess.run(
                [
                    "/bin/bash", str(fixture),
                    *self.dry_run_arguments(
                        "--output-dir", str(root / "release"),
                    ),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(
                "developer_dir=/Applications/Xcode.app/Contents/Developer",
                result.stdout,
            )
            self.assertNotIn(str(hostile), result.stdout)

    def test_unsupported_host_fails_closed_even_in_dry_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = self.write_release_fixture(
                root,
                lambda source: source.replace(
                    '"$(/usr/bin/uname -s)" == "Darwin"',
                    '"Linux" == "Darwin"',
                ),
            )
            sentinel = root / "sentinel"
            sentinel.write_text(
                '#!/bin/sh\necho "$0" >> "$R3_SENTINEL"\nexit 99\n',
                encoding="utf-8",
            )
            sentinel.chmod(0o755)
            environment = SAFE_ENV | {
                "PATH": f"{root}:/usr/bin:/bin",
                "R3_SENTINEL": str(root / "calls"),
            }
            for name in ("security", "swift", "codesign", "notarytool", "ditto", "rm", "mkdir"):
                (root / name).symlink_to(sentinel)
            result = subprocess.run(
                [
                    "/bin/bash", str(fixture),
                    *self.dry_run_arguments(
                        "--output-dir", str(root / "release"),
                        "--dry-run",
                    ),
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 78)
            self.assertFalse((root / "release").exists())
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

    def test_atomic_publish_preserves_exact_release_set(self):
        module = load_atomic_publish_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            destination = root / "release"
            source.mkdir()
            expected = {
                "Local-Meeting-Recorder.zip": b"PK\x03\x04release-zip",
                "Local-Meeting-Recorder.zip.sha256": (
                    b"0123456789abcdef  Local-Meeting-Recorder.zip\n"
                ),
                "LICENSE": b"release license\n",
                "THIRD_PARTY_NOTICES.md": b"# Notices\nExact bytes.\n",
            }
            for name, contents in expected.items():
                (source / name).write_bytes(contents)

            module.publish_directory(source, destination)

            self.assertFalse(source.exists())
            self.assertEqual(
                {entry.name for entry in destination.iterdir()},
                set(expected),
            )
            self.assertEqual(
                {
                    name: (destination / name).read_bytes()
                    for name in expected
                },
                expected,
            )

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

    def test_atomic_publish_rejects_destination_ancestor_swap_before_rename(self):
        module = load_atomic_publish_module()
        self.assertTrue(hasattr(module, "publish_directory"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source/staged"
            source.mkdir(parents=True)
            (source / "artifact.zip").write_bytes(b"release")
            output_parent = root / "output"
            output_parent.mkdir()
            detached = root / "detached-output"
            attacker = root / "attacker-output"
            attacker.mkdir()

            real_copy = module.copy_directory

            def copy_then_swap(source_fd, destination_fd):
                real_copy(source_fd, destination_fd)
                output_parent.rename(detached)
                output_parent.symlink_to(attacker, target_is_directory=True)

            with mock.patch.object(module, "copy_directory", copy_then_swap):
                with self.assertRaises(module.PublishError) as raised:
                    module.publish_directory(source, output_parent / "release")
            self.assertEqual(raised.exception.status, 73)
            self.assertFalse((detached / "release").exists())
            self.assertFalse((attacker / "release").exists())

    def test_atomic_publish_rejects_source_ancestor_swap_after_open(self):
        module = load_atomic_publish_module()
        self.assertTrue(hasattr(module, "publish_directory"))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_parent = root / "source"
            source = source_parent / "staged"
            source.mkdir(parents=True)
            (source / "artifact.zip").write_bytes(b"release")
            detached = root / "detached-source"
            attacker = root / "attacker-source"
            attacker.mkdir()

            real_copy = module.copy_directory

            def copy_then_swap(source_fd, destination_fd):
                real_copy(source_fd, destination_fd)
                source_parent.rename(detached)
                source_parent.symlink_to(attacker, target_is_directory=True)

            with mock.patch.object(module, "copy_directory", copy_then_swap):
                with self.assertRaises(module.PublishError) as raised:
                    module.publish_directory(source, root / "output/release")
            self.assertEqual(raised.exception.status, 73)
            self.assertFalse((root / "output/release").exists())

    def test_atomic_publish_rejects_staging_entry_replacement_before_rename(self):
        module = load_atomic_publish_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            destination_parent = root / "output"
            destination = destination_parent / "release"
            source.mkdir()
            destination_parent.mkdir()
            (source / "artifact.zip").write_bytes(b"trusted release")
            real_copy = module.copy_directory

            def copy_then_replace_staging(source_fd, destination_fd):
                real_copy(source_fd, destination_fd)
                staging = next(
                    entry
                    for entry in destination_parent.iterdir()
                    if entry.name.startswith(".lmr-release-publish.")
                )
                staging.rename(destination_parent / "detached-staging")
                staging.mkdir()
                (staging / "artifact.zip").write_bytes(b"malicious replacement")

            with mock.patch.object(
                module,
                "copy_directory",
                copy_then_replace_staging,
            ):
                with self.assertRaises(module.PublishError) as raised:
                    module.publish_directory(source, destination)

            self.assertEqual(raised.exception.status, 73)
            self.assertFalse(destination.exists())

    def test_atomic_publish_rejects_bad_inputs_and_maps_cross_device_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            source.mkdir()
            destination = root / "release"
            bad_source = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), str(root / "absent"), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(bad_source.returncode, 66)
            undocumented = subprocess.run(["/usr/bin/python3", str(ATOMIC_PUBLISH), "--force-errno", "18", str(source), str(destination)], text=True, capture_output=True, check=False, env=SAFE_ENV)
            self.assertEqual(undocumented.returncode, 64)
            module = load_atomic_publish_module()
            self.assertTrue(hasattr(module, "publish_directory"))

            def cross_device(*_arguments):
                raise OSError(errno.EXDEV, "cross-device")

            with self.assertRaises(module.PublishError) as raised:
                module.publish_directory(
                    source,
                    destination,
                    rename_exclusive=cross_device,
                )
            self.assertEqual(raised.exception.status, 70)

    def test_atomic_publish_maps_parent_creation_failure_to_execution_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "staged"
            source.mkdir()
            (source / "artifact.zip").write_bytes(b"release")
            module = load_atomic_publish_module()
            original_mkdir = module.os.mkdir

            def deny_new_directory(name, *args, **kwargs):
                if name == "missing":
                    raise OSError(errno.EACCES, "permission denied")
                return original_mkdir(name, *args, **kwargs)

            with mock.patch.object(module.os, "mkdir", deny_new_directory):
                with self.assertRaises(module.PublishError) as raised:
                    module.publish_directory(
                        source,
                        root / "locked/missing/release",
                    )
            self.assertEqual(raised.exception.status, 70)

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
        helper = ATOMIC_PUBLISH.read_text(encoding="utf-8")
        self.assertIn(".lmr-release-publish.", helper)
        self.assertIn('PUBLISH_SOURCE="$WORK_DIR/release"', script)
        self.assertNotIn('/bin/mkdir -p "$OUTPUT_PARENT"', script)
        self.assertIn('cp "$ROOT_DIR/LICENSE"', script)
        self.assertIn('cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md"', script)
        publish_call = '"$ROOT_DIR/scripts/atomic-publish-directory.py"'
        self.assertIn(publish_call, script)
        self.assertLess(script.index('cp "$ROOT_DIR/LICENSE"'), script.rindex(publish_call))

    def test_signing_and_notary_command_order_is_fixed(self):
        script = RELEASE_SCRIPT.read_text(encoding="utf-8")
        commands = [
            '"$ROOT_DIR/scripts/build-app.sh"',
            '"$APP/Contents/MacOS/LocalMeetingRecorder"',
            '--entitlements "$ROOT_DIR/Config/LocalMeetingRecorder.entitlements" "$APP"',
            '--verify --deep --strict --verbose=2 "$APP"',
            "grep -q 'flags=.*runtime'",
            "grep -q 'TeamIdentifier='",
            '-d --entitlements :- "$APP"',
            '"$DITTO_BIN" -c -k --keepParent "$APP" "$SUBMISSION_ZIP"',
            '"$NOTARYTOOL_BIN" submit',
            '"$STAPLER_BIN" staple "$APP"',
            '"$STAPLER_BIN" validate "$APP"',
            '"$SPCTL_BIN" --assess',
            '"$DITTO_BIN" -c -k --keepParent "$APP" "$STAGED_ZIP"',
            '"$ROOT_DIR/scripts/write-sha256.sh"',
            'cp "$ROOT_DIR/LICENSE"',
            '"$ROOT_DIR/scripts/atomic-publish-directory.py"',
        ]
        position = 0
        for command in commands:
            position = script.find(command, position)
            self.assertNotEqual(position, -1, command)
