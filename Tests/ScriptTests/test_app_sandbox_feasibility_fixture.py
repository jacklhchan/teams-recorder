import pathlib
import subprocess
import tempfile
import unittest


class AppSandboxFeasibilityFixtureContractTests(unittest.TestCase):
    def fixture_source(self) -> str:
        root = pathlib.Path(__file__).resolve().parents[2]
        return (root / "Tests/ManualFixtures/run-app-sandbox-feasibility-spikes.sh").read_text()

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

    def test_runner_creates_and_removes_only_its_own_tmp_directory(self) -> None:
        source = self.fixture_source()

        self.assertIn('mktemp -d /private/tmp/lmr-sandbox-spike.XXXXXX', source)
        self.assertNotIn('OUTPUT_ROOT="${1:-', source)
        self.assertIn('is_owned_output_root()', source)
        self.assertIn('rm -rf -- "$OUTPUT_ROOT"', source)
        self.assertIn('canonical_output_root', source)
        self.assertIn('/private/tmp/lmr-sandbox-spike.*', source)
        self.assertIn('! -L "$OUTPUT_ROOT"', source)

    def test_runner_contract_rejects_escape_and_symlink_cleanup_targets(self) -> None:
        source = self.fixture_source()

        # These regressions are represented in the cleanup guard rather than
        # executed: the fixture must never receive a caller-owned path at all.
        self.assertIn('case "$canonical_output_root" in', source)
        self.assertIn('/private/tmp/lmr-sandbox-spike.*)', source)
        self.assertIn('[[ "$canonical_output_root" == "$OUTPUT_ROOT" ]]', source)

    def test_runner_rejects_caller_paths_before_any_fixture_work(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[2]
        runner = root / "Tests/ManualFixtures/run-app-sandbox-feasibility-spikes.sh"
        with tempfile.TemporaryDirectory() as temporary:
            target = pathlib.Path(temporary) / "target"
            target.mkdir()
            sentinel = target / "sentinel"
            sentinel.write_text("must survive", encoding="utf-8")
            linked = pathlib.Path(temporary) / "linked-output"
            linked.symlink_to(target, target_is_directory=True)

            for unsafe_path in ("/private/tmp/../../Users", str(linked)):
                result = subprocess.run(
                    ["/bin/bash", str(runner), unsafe_path],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 64)
                self.assertTrue(sentinel.exists())

    def test_pending_recovery_uses_a_second_process(self) -> None:
        source = self.fixture_source()
        probe_source = (
            pathlib.Path(__file__).resolve().parents[2]
            / "Tests/ManualFixtures/AppSandboxSpike.swift"
        ).read_text()

        self.assertIn('pending-create', source)
        self.assertIn('pending-recover', source)
        self.assertIn('pending-create', probe_source)
        self.assertIn('pending-recover', probe_source)
        self.assertNotIn('case "pending":', probe_source)

    def test_embedded_ipc_waits_for_server_readiness_marker(self) -> None:
        probe_source = (
            pathlib.Path(__file__).resolve().parents[2]
            / "Tests/ManualFixtures/AppSandboxSpike.swift"
        ).read_text()

        self.assertIn('ipc.server-ready', probe_source)
        self.assertIn('waitForReadyMarker', probe_source)
        self.assertIn('ipc.server-result=', probe_source)
        self.assertIn('ipc.helper-exit=', probe_source)
        self.assertNotIn('usleep(100_000)', probe_source)


if __name__ == "__main__":
    unittest.main()
