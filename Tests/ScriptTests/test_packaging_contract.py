import hashlib
import plistlib
import re
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
    def test_readme_describes_current_provider_and_license(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        required_phrases = (
            "OpenAI-Compatible Transcription",
            "API Base URL ending in `/v1`",
            "ASR Model identifier",
            "LLM Model identifier",
            "optional API key, language, and transcription prompt",
            "POST <API Base URL>/audio/transcriptions",
            "Model discovery is optional",
            "when `/v1/models` is\n   unsupported",
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
            "`.transcription-runs` is a legacy\nworkspace only",
            "Successful native jobs keep only the four canonical artifacts",
            "provider API key and Teams pairing token are stored in macOS Keychain",
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
                self.assertIn(phrase, readme)

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
