import os
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD_APP = ROOT / "scripts/build-app.sh"
VERIFY_APP = ROOT / "scripts/verify-app-bundle.sh"
PACKAGING_SMOKE = ROOT / "Tests/PackagingTests/run-tests.sh"
OWNER_MARKER_VALUE = "local.meeting.recorder.build-app.v1"


class BuildAppContractTests(unittest.TestCase):
    def test_packaging_smoke_script_is_executable_contract(self):
        script = PACKAGING_SMOKE.read_text(encoding="utf-8")
        self.assertIn("verify-app-bundle.sh", script)
        self.assertIn("moved", script.lower())
        self.assertNotIn("open -n", script)
        self.assertIn("validate_macho_dependencies", script)
        self.assertIn("/usr/bin/otool", script)
        self.assertNotIn("@rpath/libswift*", script)

        valid = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; validate_macho_dependencies',
                "validate-macho-dependencies",
                str(PACKAGING_SMOKE),
            ],
            input="/System/Library/Frameworks/Foundation.framework/Foundation\n/usr/lib/libSystem.B.dylib\n",
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(valid.returncode, 0, valid.stderr)
        invalid = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; validate_macho_dependencies',
                "validate-macho-dependencies",
                str(PACKAGING_SMOKE),
            ],
            input="@rpath/libswiftMalware.dylib\n",
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("Unexpected dependency", invalid.stderr)

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
        self.assertEqual(
            entitlements,
            {"com.apple.security.device.audio-input": True},
        )
        verifier = ROOT / "scripts/verify-app-bundle.sh"
        self.assertTrue(os.access(verifier, os.X_OK))

    def write_executable(self, path, content):
        path.write_text(content, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def make_swift_shim(self, directory, binary_directory):
        shim = directory / "swift-shim"
        self.write_executable(
            shim,
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$SWIFT_LOG"
if [[ "$*" == *"--show-bin-path"* ]]; then
  printf '%s\\n' "$SWIFT_BIN_DIR"
else
  printf 'shim build progress\\n' >&2
fi
""",
        )
        return shim

    def make_codesign_shim(self, directory):
        shim = directory / "codesign-shim"
        self.write_executable(
            shim,
            """#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --verify --deep --strict "*) exit 0 ;;
  *" --entitlements :- "*) cat "$CODESIGN_ENTITLEMENTS" ;;
  *" --verbose=4 "*)
    printf 'Signature=%s\\n' "$CODESIGN_SIGNATURE"
    if [[ -n "${CODESIGN_TEAM:-}" ]]; then
      printf 'TeamIdentifier=%s\\n' "$CODESIGN_TEAM"
    fi
    ;;
  *" --remove-signature "*) exit 0 ;;
  *" -dv "*) exit "${CODESIGN_DV_EXIT:-1}" ;;
esac
""",
        )
        return shim

    def make_file_shim(self, directory):
        shim = directory / "file-shim"
        self.write_executable(shim, "#!/usr/bin/env bash\nprintf '%s: arm64\\n' \"$1\"\n")
        return shim

    def make_app_fixture(self, root):
        app = root / "Fixture.app"
        macos = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        macos.mkdir(parents=True)
        resources.mkdir()
        executable = macos / "LocalMeetingRecorder"
        executable.write_text("fixture", encoding="utf-8")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "local.meeting.recorder.fixture",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "7",
                    "LSMinimumSystemVersion": "26.0",
                },
                stream,
            )
        for name in (
            "AppIcon.icns",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            ".lmr-build-owner",
        ):
            (resources / name).write_text(
                OWNER_MARKER_VALUE if name == ".lmr-build-owner" else name,
                encoding="utf-8",
            )
        return app

    def run_verify(
        self, app, codesign, file_command, entitlement_path, sign_mode="ad-hoc", **extra
    ):
        env = os.environ.copy()
        env.update(
            {
                "CODESIGN_BIN": str(codesign),
                "FILE_BIN": str(file_command),
                "CODESIGN_ENTITLEMENTS": str(entitlement_path),
                "CODESIGN_SIGNATURE": "adhoc",
                "CODESIGN_TEAM": "not set",
                "CODESIGN_DV_EXIT": "1",
            }
        )
        env.update(extra)
        return subprocess.run(
            [
                "/bin/bash",
                str(VERIFY_APP),
                str(app),
                "local.meeting.recorder.fixture",
                "1.2.3",
                "7",
                sign_mode,
            ],
            text=True,
            capture_output=True,
            check=False,
            env=env,
        )

    def test_build_stdout_and_plist_are_exact_with_sensitive_arguments(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            binary_directory = root / "bin"
            binary_directory.mkdir()
            binary = binary_directory / "LocalMeetingRecorder"
            binary.write_text("fixture", encoding="utf-8")
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
            swift = self.make_swift_shim(root, binary_directory)
            codesign = self.make_codesign_shim(root)
            swift_log = root / "swift.log"
            output = root / "Sensitive.app"
            environment = os.environ.copy()
            environment.update(
                {
                    "SWIFT_BIN": str(swift),
                    "SWIFT_BIN_DIR": str(binary_directory),
                    "SWIFT_LOG": str(swift_log),
                    "CODESIGN_BIN": str(codesign),
                    "CODESIGN_DV_EXIT": "1",
                }
            )
            result = subprocess.run(
                [
                    "/bin/bash", str(BUILD_APP),
                    "--configuration", "debug",
                    "--version", "1.2.3",
                    "--build-number", "7",
                    "--bundle-id", "local.meeting.recorder.fixture",
                    "--bundle-name", "A & B <Recorder> \"quoted\"",
                    "--output", str(output),
                    "--sign", "none",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{output}\n")
            self.assertIn("Building debug app binary", result.stderr)
            with (output / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertEqual(info["CFBundleName"], 'A & B <Recorder> "quoted"')
            self.assertIn("-c debug", swift_log.read_text(encoding="utf-8"))

    def test_build_honors_debug_and_release_show_bin_path(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            codesign = self.make_codesign_shim(root)
            for configuration in ("debug", "release"):
                with self.subTest(configuration=configuration):
                    binary_directory = root / configuration
                    binary_directory.mkdir()
                    binary = binary_directory / "LocalMeetingRecorder"
                    binary.write_text(configuration, encoding="utf-8")
                    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
                    swift = self.make_swift_shim(root / configuration, binary_directory)
                    swift_log = root / f"{configuration}.log"
                    result = subprocess.run(
                        ["/bin/bash", str(BUILD_APP), "--configuration", configuration,
                         "--output", str(root / f"{configuration}.app"), "--sign", "none"],
                        text=True,
                        capture_output=True,
                        check=False,
                        env={
                            **os.environ,
                            "SWIFT_BIN": str(swift),
                            "SWIFT_BIN_DIR": str(binary_directory),
                            "SWIFT_LOG": str(swift_log),
                            "CODESIGN_BIN": str(codesign),
                            "CODESIGN_DV_EXIT": "1",
                        },
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f"-c {configuration}", swift_log.read_text(encoding="utf-8"))

    def test_release_uses_fixed_xcrun_and_ignores_path_hijack(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            binary_directory = root / "bin"
            binary_directory.mkdir()
            binary = binary_directory / "LocalMeetingRecorder"
            shutil.copyfile("/usr/bin/true", binary)
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
            swift = self.make_swift_shim(root, binary_directory)
            codesign = self.make_codesign_shim(root)
            hijack = root / "xcrun"
            hijack_log = root / "xcrun-hijack.log"
            self.write_executable(
                hijack,
                "#!/usr/bin/env bash\nprintf 'hijacked\\n' > \"$XCRUN_HIJACK_LOG\"\nprintf '%s\\n' /usr/bin/strip\n",
            )
            environment = {
                **os.environ,
                "PATH": f"{root}:/usr/bin:/bin:/usr/sbin:/sbin",
                "SWIFT_BIN": str(swift),
                "SWIFT_BIN_DIR": str(binary_directory),
                "SWIFT_LOG": str(root / "swift.log"),
                "CODESIGN_BIN": str(codesign),
                "CODESIGN_DV_EXIT": "1",
                "XCRUN_HIJACK_LOG": str(hijack_log),
            }
            output = root / "release.app"
            result = subprocess.run(
                [
                    "/bin/bash", str(BUILD_APP),
                    "--configuration", "release",
                    "--output", str(output),
                    "--sign", "none",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(hijack_log.exists())
            script = BUILD_APP.read_text(encoding="utf-8")
            self.assertIn('STRIP_BIN="$(/usr/bin/xcrun --find strip)"', script)
            self.assertIn('[[ "$STRIP_BIN" == /* && -x "$STRIP_BIN" ]]', script)

    def test_owned_output_is_replaced_by_successful_build(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
            root = Path(temporary)
            output = root / "Owned.app"
            marker = output / "Contents/Resources/.lmr-build-owner"
            marker.parent.mkdir(parents=True)
            marker.write_text(OWNER_MARKER_VALUE, encoding="utf-8")
            sentinel = output / "old-artifact"
            sentinel.write_text("old", encoding="utf-8")
            binary_directory = root / "bin"
            binary_directory.mkdir()
            binary = binary_directory / "LocalMeetingRecorder"
            binary.write_text("new", encoding="utf-8")
            binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
            swift = self.make_swift_shim(root, binary_directory)
            codesign = self.make_codesign_shim(root)
            result = subprocess.run(
                ["/bin/bash", str(BUILD_APP), "--output", str(output), "--sign", "none"],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "SWIFT_BIN": str(swift), "SWIFT_BIN_DIR": str(binary_directory),
                    "SWIFT_LOG": str(root / "swift.log"), "CODESIGN_BIN": str(codesign),
                    "CODESIGN_DV_EXIT": "1",
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(sentinel.exists())
            self.assertEqual(result.stdout, f"{output}\n")

    def test_verifier_accepts_adhoc_fixture_and_rejects_signer_or_entitlement_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app_fixture(root)
            codesign = self.make_codesign_shim(root)
            file_command = self.make_file_shim(root)
            entitlements = root / "entitlements.plist"
            with entitlements.open("wb") as stream:
                plistlib.dump({"com.apple.security.device.audio-input": True}, stream)
            self.assertEqual(
                self.run_verify(app, codesign, file_command, entitlements).returncode,
                0,
            )
            self.assertNotEqual(
                self.run_verify(
                    app, codesign, file_command, entitlements,
                    CODESIGN_SIGNATURE="Developer ID Application: Fixture",
                    CODESIGN_TEAM="ABC123",
                ).returncode,
                0,
            )
            self.assertNotEqual(
                self.run_verify(
                    app, codesign, file_command, entitlements,
                    CODESIGN_SIGNATURE="adhoc",
                    CODESIGN_TEAM="ABC123",
                ).returncode,
                0,
            )
            self.assertEqual(
                self.run_verify(
                    app, codesign, file_command, entitlements,
                    CODESIGN_TEAM="",
                ).returncode,
                0,
            )
            with entitlements.open("wb") as stream:
                plistlib.dump(
                    {
                        "com.apple.security.device.audio-input": True,
                        "com.apple.security.network.client": True,
                    },
                    stream,
                )
            self.assertNotEqual(
                self.run_verify(app, codesign, file_command, entitlements).returncode,
                0,
            )

    def test_verifier_requires_none_to_be_genuinely_unsigned(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = self.make_app_fixture(root)
            codesign = self.make_codesign_shim(root)
            file_command = self.make_file_shim(root)
            entitlements = root / "entitlements.plist"
            with entitlements.open("wb") as stream:
                plistlib.dump({"com.apple.security.device.audio-input": True}, stream)
            self.assertEqual(
                self.run_verify(
                    app, codesign, file_command, entitlements, sign_mode="none"
                ).returncode,
                0,
            )
            self.assertNotEqual(
                self.run_verify(
                    app,
                    codesign,
                    file_command,
                    entitlements,
                    sign_mode="none",
                    CODESIGN_DV_EXIT="0",
                ).returncode,
                0,
            )

    def test_verifier_rejects_missing_resources_and_legacy_runtime_helpers(self):
        required = (
            "AppIcon.icns",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            ".lmr-build-owner",
        )
        legacy_helpers = (
            "transcribe-openai-compatible.sh",
            "transcribe-qwen-asr.sh",
            "openai_asr_longform.py",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            codesign = self.make_codesign_shim(root)
            file_command = self.make_file_shim(root)
            entitlements = root / "entitlements.plist"
            with entitlements.open("wb") as stream:
                plistlib.dump({"com.apple.security.device.audio-input": True}, stream)
            for name in required:
                with self.subTest(missing=name):
                    app = self.make_app_fixture(root / f"missing-{name}")
                    (app / "Contents/Resources" / name).unlink()
                    self.assertNotEqual(
                        self.run_verify(app, codesign, file_command, entitlements).returncode,
                        0,
                    )
            for name in legacy_helpers:
                with self.subTest(legacy_helper=name):
                    app = self.make_app_fixture(root / f"legacy-{name}")
                    helper = app / "Contents/Resources" / name
                    helper.write_text("legacy runtime dependency", encoding="utf-8")
                    self.assertNotEqual(
                        self.run_verify(app, codesign, file_command, entitlements).returncode,
                        0,
                    )
            app = self.make_app_fixture(root / "wrong-marker")
            (app / "Contents/Resources/.lmr-build-owner").write_text(
                "not-owned", encoding="utf-8"
            )
            self.assertNotEqual(
                self.run_verify(app, codesign, file_command, entitlements).returncode,
                0,
            )
