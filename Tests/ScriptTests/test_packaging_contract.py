import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class PackagingContractTests(unittest.TestCase):
    def test_repository_declares_apache_2_0(self):
        license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        self.assertTrue(
            license_text.startswith(
                "Apache License\nVersion 2.0, January 2004"
            )
        )
        self.assertIn(
            "http://www.apache.org/licenses/",
            license_text,
        )
        self.assertIn(
            "END OF TERMS AND CONDITIONS",
            license_text,
        )

    def test_notices_preserve_apple_sample_license_boundary(self):
        notices = (
            ROOT / "THIRD_PARTY_NOTICES.md"
        ).read_text(encoding="utf-8")
        self.assertIn("Apple Audio Server Driver Plug-in sample", notices)
        self.assertIn("LICENSE-Apple-Sample.txt", notices)
        self.assertIn("not bundled", notices)
        self.assertIn("FFmpeg", notices)
        self.assertIn("OpenAI-compatible", notices)

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
