import hashlib
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
