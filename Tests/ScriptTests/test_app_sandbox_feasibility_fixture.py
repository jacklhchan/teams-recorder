import pathlib
import unittest


class AppSandboxFeasibilityFixtureContractTests(unittest.TestCase):
    def test_fixture_keeps_all_spikes_isolated_from_production_builds(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[2]
        fixture = root / "Tests/ManualFixtures/run-app-sandbox-feasibility-spikes.sh"
        source = fixture.read_text()
        app_entitlements = (
            root / "Tests/ManualFixtures/AppSandboxSpike.entitlements"
        ).read_text()
        helper_entitlements = (
            root / "Tests/ManualFixtures/AppSandboxSpikeHelper.entitlements"
        ).read_text()
        probe_source = (root / "Tests/ManualFixtures/AppSandboxSpike.swift").read_text()
        all_fixture_text = "\n".join(
            [source, app_entitlements, helper_entitlements, probe_source]
        )

        self.assertIn("com.localmeetingrecorder.sandbox-spike", source)
        self.assertIn("/private/tmp", source)
        self.assertIn("ScreenCaptureKit", source)
        self.assertIn("com.apple.security.device.audio-input", all_fixture_text)
        self.assertIn("com.apple.security.files.user-selected.read-write", all_fixture_text)
        self.assertIn("com.apple.security.inherit", all_fixture_text)
        self.assertIn("bookmark", all_fixture_text)
        self.assertIn("pending", all_fixture_text)
        self.assertIn("AF_UNIX", all_fixture_text)
        self.assertNotIn("scripts/build-app.sh", source)
        self.assertNotIn("scripts/install-app.sh", source)
        self.assertNotIn("Config/LocalMeetingRecorder.entitlements", source)


if __name__ == "__main__":
    unittest.main()
