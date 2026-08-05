import hashlib
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

CANONICAL_APACHE_2_0_SIZE = 10254
CANONICAL_APACHE_2_0_SHA256 = (
    "7505b489cc8ad7f16ba08343184320f1583303cfacdb9121b9b756bc073df1ab"
)
REQUIRED_THIRD_PARTY_NOTICES = """# Third-Party Notices

Local Meeting Recorder is licensed under the Apache License, Version 2.0,
except for the separately identified material below.

## Apple Audio Server Driver Plug-in Sample

`Driver/LocalRecorderVirtualMic/LocalRecorderVirtualMic.c` is derived from
Apple's "Creating an Audio Server Driver Plug-in" sample.

Copyright (c) 2024 Apple Inc.

The applicable permission notice is distributed in:

`Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt`

That notice, rather than Apache-2.0, governs the Apple-derived sample material.

## External Runtime Systems

The following systems may be selected or installed separately by a user but
are not bundled or redistributed with Local Meeting Recorder:

- OpenAI-compatible API providers and their server software
- User-selected ASR and LLM models
- FFmpeg and FFprobe
- oMLX
- BlackHole

Each external system and model remains subject to its own license and terms.
Mentioning compatibility does not change or grant those licenses.
"""


class PackagingContractTests(unittest.TestCase):
    def test_cli_helper_packaging_and_verification_contract(self):
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        build = (ROOT / "scripts/build-app.sh").read_text(encoding="utf-8")
        verify = (
            ROOT / "scripts/verify-app-bundle.sh"
        ).read_text(encoding="utf-8")
        packaging = (
            ROOT / "Tests/PackagingTests/run-tests.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            '.executable(name: "recorderctl", targets: ["RecorderControlCLI"])',
            package,
        )
        self.assertIn('HELPER_EXECUTABLE="recorderctl"', build)
        self.assertIn('HELPER_BINARY_PATH="$BIN_DIR/$HELPER_EXECUTABLE"', build)
        self.assertIn('[[ -x "$HELPER_BINARY_PATH" ]]', build)
        self.assertIn('HELPERS_DIR="$CONTENTS_DIR/Helpers"', build)
        self.assertIn('mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"', build)
        self.assertIn(
            'cp "$HELPER_BINARY_PATH" "$HELPERS_DIR/$HELPER_EXECUTABLE"',
            build,
        )
        self.assertIn(
            '"$STRIP_BIN" -S "$HELPERS_DIR/$HELPER_EXECUTABLE"',
            build,
        )
        helper_sign = (
            '"$CODESIGN_BIN" --force --sign - --timestamp=none '
            '"$HELPERS_DIR/$HELPER_EXECUTABLE"'
        )
        app_binary_sign = (
            '"$CODESIGN_BIN" --force --sign - --timestamp=none --entitlements '
            '"$ENTITLEMENTS" "$MACOS_DIR/$APP_EXECUTABLE"'
        )
        outer_sign = (
            '"$CODESIGN_BIN" --force --sign - --timestamp=none --entitlements '
            '"$ENTITLEMENTS" "$TEMP_OUTPUT"'
        )
        self.assertLess(build.index(helper_sign), build.index(app_binary_sign))
        self.assertLess(build.index(app_binary_sign), build.index(outer_sign))

        self.assertIn('HELPER="$APP/Contents/Helpers/recorderctl"', verify)
        self.assertIn(
            'test -x "$APP/Contents/MacOS/LocalMeetingRecorder"',
            verify,
        )
        self.assertIn('test -x "$HELPER"', verify)
        self.assertIn('VTOOL_BIN="${VTOOL_BIN:-/usr/bin/xcrun}"', verify)
        self.assertIn('"$VTOOL_BIN" vtool -show-build "$HELPER"', verify)
        self.assertIn("minos 26\\.0", verify)
        self.assertIn(
            'validate_macos_26_binary '
            '"$MOVED/Contents/MacOS/LocalMeetingRecorder"',
            packaging,
        )
        self.assertIn(
            'validate_macos_26_binary '
            '"$MOVED/Contents/Helpers/recorderctl"',
            packaging,
        )

    def test_cli_installer_refuses_unowned_destination_objects(self):
        installer = ROOT / "scripts/install-recorder-cli.sh"
        script = installer.read_text(encoding="utf-8")
        self.assertIn('LINK_PATH="$INSTALL_ROOT/usr/local/bin/recorderctl"', script)
        self.assertIn("exit 73", script)
        self.assertNotIn("rm -rf", script)
        self.assertNotIn("/bin/ln -sfn", script)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Local Meeting Recorder.app"
            helper = app / "Contents/Helpers/recorderctl"
            marker = app / "Contents/Resources/.lmr-build-owner"
            helper.parent.mkdir(parents=True)
            marker.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\n", encoding="utf-8")
            helper.chmod(0o755)
            marker.write_text(
                "local.meeting.recorder.build-app.v1",
                encoding="utf-8",
            )

            for obstacle in ("file", "directory", "symlink", "dangling-symlink"):
                with self.subTest(obstacle=obstacle):
                    install_root = root / f"install-{obstacle}"
                    bin_dir = install_root / "usr/local/bin"
                    bin_dir.mkdir(parents=True)
                    destination = bin_dir / "recorderctl"
                    if obstacle == "file":
                        destination.write_text("keep", encoding="utf-8")
                    elif obstacle == "directory":
                        destination.mkdir()
                    elif obstacle == "symlink":
                        unrelated = root / "unrelated-helper"
                        unrelated.write_text("keep", encoding="utf-8")
                        destination.symlink_to(unrelated)
                    else:
                        destination.symlink_to(root / "missing-helper")

                    before = os.lstat(destination)
                    result = subprocess.run(
                        ["/bin/bash", str(installer), str(app)],
                        text=True,
                        capture_output=True,
                        check=False,
                        env={**os.environ, "RECORDER_CLI_INSTALL_ROOT": str(install_root)},
                    )
                    self.assertEqual(result.returncode, 73, result.stderr)
                    after = os.lstat(destination)
                    self.assertEqual(before.st_ino, after.st_ino)

    def test_cli_installer_replaces_owned_link_and_noops_current_link(self):
        installer = ROOT / "scripts/install-recorder-cli.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install_root = root / "install"
            destination = install_root / "usr/local/bin/recorderctl"
            destination.parent.mkdir(parents=True)

            helpers = []
            for name in ("Old Recorder.app", "New Recorder.app"):
                app = root / name
                helper = app / "Contents/Helpers/recorderctl"
                marker = app / "Contents/Resources/.lmr-build-owner"
                helper.parent.mkdir(parents=True)
                marker.parent.mkdir(parents=True)
                helper.write_text("#!/bin/sh\n", encoding="utf-8")
                helper.chmod(0o755)
                marker.write_text(
                    "local.meeting.recorder.build-app.v1",
                    encoding="utf-8",
                )
                helpers.append(helper)

            destination.symlink_to(helpers[0])
            environment = {
                **os.environ,
                "RECORDER_CLI_INSTALL_ROOT": str(install_root),
            }
            replaced = subprocess.run(
                ["/bin/bash", str(installer), str(helpers[1].parents[2])],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(replaced.returncode, 0, replaced.stderr)
            self.assertEqual(os.readlink(destination), str(helpers[1]))

            before_noop = os.lstat(destination)
            noop = subprocess.run(
                ["/bin/bash", str(installer), str(helpers[1].parents[2])],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
            )
            self.assertEqual(noop.returncode, 0, noop.stderr)
            self.assertEqual(before_noop.st_ino, os.lstat(destination).st_ino)

    def test_cli_installer_rejects_symlink_ancestor_escape(self):
        installer = ROOT / "scripts/install-recorder-cli.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Local Meeting Recorder.app"
            helper = app / "Contents/Helpers/recorderctl"
            marker = app / "Contents/Resources/.lmr-build-owner"
            helper.parent.mkdir(parents=True)
            marker.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\n", encoding="utf-8")
            helper.chmod(0o755)
            marker.write_text(
                "local.meeting.recorder.build-app.v1",
                encoding="utf-8",
            )

            escaped_usr = root / "escaped-usr"
            (escaped_usr / "local/bin").mkdir(parents=True)
            install_root = root / "install"
            install_root.mkdir()
            (install_root / "usr").symlink_to(escaped_usr)
            escaped_destination = escaped_usr / "local/bin/recorderctl"

            result = subprocess.run(
                ["/bin/bash", str(installer), str(app)],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "RECORDER_CLI_INSTALL_ROOT": str(install_root),
                },
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertFalse(os.path.lexists(escaped_destination))

    def test_cli_installer_preserves_late_post_check_replacement(self):
        installer = ROOT / "scripts/install-recorder-cli.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install_root = root / "install"
            destination = install_root / "usr/local/bin/recorderctl"
            destination.parent.mkdir(parents=True)

            helpers = []
            for name in ("Old Recorder.app", "New Recorder.app"):
                app = root / name
                helper = app / "Contents/Helpers/recorderctl"
                marker = app / "Contents/Resources/.lmr-build-owner"
                helper.parent.mkdir(parents=True)
                marker.parent.mkdir(parents=True)
                helper.write_text("#!/bin/sh\n", encoding="utf-8")
                helper.chmod(0o755)
                marker.write_text(
                    "local.meeting.recorder.build-app.v1",
                    encoding="utf-8",
                )
                helpers.append(helper)

            destination.symlink_to(helpers[0])
            late_replacement = root / "late-replacement"
            late_replacement.write_text("preserve me", encoding="utf-8")
            result = subprocess.run(
                ["/bin/bash", str(installer), str(helpers[1].parents[2])],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "RECORDER_CLI_INSTALL_ROOT": str(install_root),
                    "RECORDER_CLI_TEST_POST_UNLINK_SOURCE": str(late_replacement),
                },
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(destination.read_text(encoding="utf-8"), "preserve me")
            self.assertFalse((destination / "recorderctl").exists())

    def test_cli_installer_rejects_test_hook_before_real_destination_access(self):
        installer = ROOT / "scripts/install-recorder-cli.sh"
        script = installer.read_text(encoding="utf-8")
        python_blocks = script.split("<<'PY'\n")
        self.assertEqual(len(python_blocks), 3)
        safe_link_program = python_blocks[2].split("\nPY\n", 1)[0]
        destination_stubs = """
def forbidden_destination_access(*args, **kwargs):
    raise AssertionError("real destination access reached")

os.lstat = forbidden_destination_access
os.unlink = forbidden_destination_access
os.symlink = forbidden_destination_access
os.link = forbidden_destination_access
"""
        safe_link_program = safe_link_program.replace(
            "removed_existing = False",
            f"{destination_stubs}\nremoved_existing = False",
            1,
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "Local Meeting Recorder.app/Contents/Helpers/recorderctl"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\n", encoding="utf-8")
            helper.chmod(0o755)
            hook_source = root / "hook-source"
            hook_source.write_text("must not move", encoding="utf-8")

            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    safe_link_program,
                    "/usr/local/bin/recorderctl",
                    str(helper),
                    "local.meeting.recorder.build-app.v1",
                    "/",
                ],
                text=True,
                capture_output=True,
                check=False,
                env={
                    **os.environ,
                    "RECORDER_CLI_TEST_POST_UNLINK_SOURCE": str(hook_source),
                },
            )
            self.assertEqual(result.returncode, 73, result.stderr)
            self.assertIn("redirected test install root", result.stderr)
            self.assertNotIn("real destination access reached", result.stderr)
            self.assertEqual(hook_source.read_text(encoding="utf-8"), "must not move")

    def test_readme_describes_current_provider_and_license(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        normalized_readme = " ".join(readme.split())
        required_phrases = (
            "OpenAI-Compatible Transcription",
            "API Base URL ending in `/v1`",
            "ASR Model identifier",
            "LLM Model identifier",
            "optional API key, language, and transcription prompt",
            "POST <API Base URL>/audio/transcriptions",
            "Model discovery is optional",
            "`/v1/models` is unsupported",
            "manually entered model identifiers remain available",
            "transcript.txt",
            "transcript.raw.txt",
            "transcription.json",
            "transcription.log",
            "Native `AVFoundation`",
            "`URLSession`",
            "does not require Python, FFmpeg, or FFprobe",
            "`recording.mp4`",
            "`recording.m4a` audio-only recovery fallback",
            "There is no fixed 12-session display cap",
            "`schemaVersion`",
            "Unknown metadata fields are preserved",
            "Native audio chunks use an isolated system temporary workspace",
            "`.transcription-runs` is a legacy workspace only",
            "Successful native jobs keep only the four canonical artifacts",
            "provider API key and Teams pairing token are stored in macOS Keychain",
            "HKT GenAI Platform",
            "https://api.uat.bot-builder.pccw.com/v1/groups/{groupID}/openai",
            "X-API-KEY",
            "OpenAI-compatible API",
            "Authorization: Bearer",
            "exact `/models` match",
            "zero automatic chat",
            "Generate and Regenerate are explicit",
            "meeting-intelligence.json",
            "meeting-intelligence-state.json",
            "manual titles are preserved",
            "oMLX settings are read only for a one-time migration",
            "oMLX is\nnot required, launched, installed, or managed by the recorder",
            "build/Local Meeting Recorder Staging.app",
            "macOS 26.0 or newer",
            "Apache License 2.0",
            "Apple-derived virtual microphone sample material retains the separate",
            "Driver/LocalRecorderVirtualMic/LICENSE-Apple-Sample.txt",
        )
        for phrase in required_phrases:
            with self.subTest(phrase=phrase):
                self.assertIn(" ".join(phrase.split()), normalized_readme)

        stale_phrases = (
            "/Users/apple",
            "mlx_audio.stt.generate",
            "The transcript button opens oMLX",
            "Keychain migration is intentionally deferred",
            "choose Mic Only mode",
            "Write one combined `recording.m4a` file per session",
            "folders with a `recording.m4a` file",
        )
        for phrase in stale_phrases:
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, readme)
        self.assertIsNone(
            re.search(r"\bQwen[^\n`]*(?:4-bit|8-bit|8bit|bf16)\b", readme),
        )

    def test_macos_26_minimum_deployment_contract(self):
        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        app_build = (
            ROOT / "scripts/build-app.sh"
        ).read_text(encoding="utf-8")
        app_verify = (
            ROOT / "scripts/verify-app-bundle.sh"
        ).read_text(encoding="utf-8")
        virtual_mic_build = (
            ROOT / "scripts/build-virtual-mic.sh"
        ).read_text(encoding="utf-8")
        app_packaging_test = (
            ROOT / "Tests/PackagingTests/run-tests.sh"
        ).read_text(encoding="utf-8")
        driver_bundle_test = (
            ROOT / "Tests/VirtualMicDriverTests/run-bundle-tests.sh"
        ).read_text(encoding="utf-8")
        input_mute = (
            ROOT
            / "Sources/RecorderApp/VirtualMic/InputMuteController.swift"
        ).read_text(encoding="utf-8")
        with (
            ROOT / "Driver/LocalRecorderVirtualMic/Info.plist"
        ).open("rb") as stream:
            driver_info = plistlib.load(stream)

        self.assertIn('.macOS("26.0")', package)
        self.assertNotIn('.macOS("15.0")', package)
        self.assertIn('"LSMinimumSystemVersion": "26.0"', app_build)
        self.assertIn(
            "Print :LSMinimumSystemVersion' \"$PLIST\")\" = \"26.0\"",
            app_verify,
        )
        self.assertEqual(driver_info["LSMinimumSystemVersion"], "26.0")
        self.assertEqual(
            virtual_mic_build.count("-mmacosx-version-min=26.0"),
            3,
        )
        self.assertNotIn("-mmacosx-version-min=15.0", virtual_mic_build)
        self.assertIn("validate_macos_26_binary", app_packaging_test)
        self.assertIn(
            'validate_macos_26_binary "$MOVED/Contents/MacOS/'
            'LocalMeetingRecorder"',
            app_packaging_test,
        )
        self.assertIn(
            'LSMinimumSystemVersion raw "$INFO_PLIST")" = "26.0"',
            driver_bundle_test,
        )
        self.assertIn(
            '/usr/bin/xcrun vtool -show-build "$EXECUTABLE"',
            driver_bundle_test,
        )
        self.assertIn(r"minos 26\.0", driver_bundle_test)
        self.assertNotIn("@available(macOS 14.0, *)", input_mute)

    def test_app_build_packages_license_and_notices(self):
        script = (
            ROOT / "scripts/build-app.sh"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"',
            script,
        )
        self.assertIn(
            'cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" '
            '"$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"',
            script,
        )
        for legacy_helper in (
            "transcribe-openai-compatible.sh",
            "transcribe-qwen-asr.sh",
            "openai_asr_longform.py",
        ):
            with self.subTest(legacy_helper=legacy_helper):
                self.assertNotIn(legacy_helper, script)

    def test_driver_build_packages_apple_sample_license(self):
        script = (
            ROOT / "scripts/build-virtual-mic.sh"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'cp "$DRIVER_DIR/LICENSE-Apple-Sample.txt" '
            '"$CONTENTS/Resources/LICENSE-Apple-Sample.txt"',
            script,
        )

    def test_repository_declares_apache_2_0(self):
        license_bytes = (ROOT / "LICENSE").read_bytes()
        license_text = license_bytes.decode("utf-8")
        self.assertEqual(CANONICAL_APACHE_2_0_SIZE, len(license_bytes))
        self.assertEqual(
            CANONICAL_APACHE_2_0_SHA256,
            hashlib.sha256(license_bytes).hexdigest(),
        )
        self.assertTrue(license_text.startswith("Apache License\n"))
        self.assertIn(
            "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
            license_text,
        )
        self.assertTrue(
            license_text.endswith(
                "limitations under the License.\n"
            )
        )

    def test_notices_preserve_apple_sample_license_boundary(self):
        notices = (
            ROOT / "THIRD_PARTY_NOTICES.md"
        ).read_text(encoding="utf-8")
        self.assertEqual(REQUIRED_THIRD_PARTY_NOTICES, notices)

    def test_abandoned_release_manifest_is_absent(self):
        self.assertFalse(
            (
                ROOT
                / "Sources/RecorderApp/Setup/ReleaseManifest.swift"
            ).exists()
        )
        self.assertFalse(
            (
                ROOT
                / "Sources/RecorderApp/Resources/release-manifest.json"
            ).exists()
        )
        self.assertFalse(
            (
                ROOT
                / "Tests/RecorderAppTests/ReleaseManifestTests.swift"
            ).exists()
        )

        package = (ROOT / "Package.swift").read_text(encoding="utf-8")
        build = (
            ROOT / "scripts/build-app.sh"
        ).read_text(encoding="utf-8")
        self.assertNotIn("release-manifest", package)
        self.assertNotIn("release-manifest", build)
        self.assertNotIn("ReleaseManifest", package)

    def test_active_release_metadata_does_not_model_blackhole(self):
        active_paths = [
            ROOT / "Package.swift",
            ROOT / "Sources/RecorderApp/Setup",
            ROOT / "Sources/RecorderApp/Resources",
            ROOT / "scripts/build-app.sh",
        ]
        text = ""
        for path in active_paths:
            if path.is_file():
                text += path.read_text(encoding="utf-8")
            elif path.is_dir():
                for child in path.rglob("*"):
                    if child.is_file():
                        text += child.read_text(
                            encoding="utf-8",
                            errors="ignore",
                        )
        self.assertNotIn("BlackHole", text)

    def test_development_meeting_intelligence_harness_and_raw_fixtures_are_not_bundled(self):
        build = (ROOT / "scripts/build-app.sh").read_text(encoding="utf-8")
        forbidden = (
            "Tests/ManualFixtures",
            "meeting_intelligence_provider.py",
            "contracts/fixtures",
            "meeting-intelligence-v1.json",
            "recording-info-v2-meeting-intelligence.json",
        )
        for value in forbidden:
            with self.subTest(value=value):
                self.assertNotIn(value, build)
