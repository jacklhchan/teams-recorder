import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
CHECKOUT_SHA = "34e114876b0b11c390a56381ad16ebd13914f8d5"
UPLOAD_ARTIFACT_SHA = "ea165f8d65b6e75b540449e92b4886f43607fa02"
REQUIRED_JOBS = {"swift-tests", "script-tests", "packaging", "policy"}
FORBIDDEN_WORKFLOW_TERMS = (
    "install",
    "launch",
    "provider",
    "network",
    "tcc",
    "teams",
    "curl",
    "wget",
    "brew",
)


class WorkflowContractTests(unittest.TestCase):
    def read_workflow(self):
        self.assertTrue(WORKFLOW.is_file(), f"Missing workflow: {WORKFLOW}")
        return WORKFLOW.read_text(encoding="utf-8")

    def job_body(self, workflow, job):
        match = re.search(
            rf"(?ms)^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [a-z][a-z-]*:\n|\Z)",
            workflow,
        )
        self.assertIsNotNone(match, f"Missing job: {job}")
        return match.group("body")

    def jobs_body(self, workflow):
        match = re.search(r"(?ms)^jobs:\n(?P<body>.*)\Z", workflow)
        self.assertIsNotNone(match, "Missing jobs section")
        return match.group("body")

    def assert_step_command(self, job, name, command):
        self.assertRegex(
            job,
            rf"(?m)^      - name: {re.escape(name)}\n"
            rf"        run: {re.escape(command)}$",
        )

    def assert_no_forbidden_workflow_terms(self, workflow):
        for forbidden in FORBIDDEN_WORKFLOW_TERMS:
            self.assertNotIn(
                forbidden,
                workflow,
                f"Forbidden workflow term found: {forbidden}",
            )

    def test_ci_yaml_is_syntax_valid_with_ruby_stdlib(self):
        self.assertTrue(WORKFLOW.is_file(), f"Missing workflow: {WORKFLOW}")
        result = subprocess.run(
            [
                "/usr/bin/ruby",
                "-e",
                'require "yaml"; YAML.parse_file(ARGV.fetch(0))',
                str(WORKFLOW),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ci_has_exact_required_macos_jobs_and_dependencies(self):
        workflow = self.read_workflow()
        job_names = set(
            re.findall(r"(?m)^  ([a-z][a-z-]*):\n", self.jobs_body(workflow))
        )
        self.assertEqual(job_names, REQUIRED_JOBS)

        for job_name in REQUIRED_JOBS:
            with self.subTest(job=job_name):
                self.assertRegex(
                    self.job_body(workflow, job_name),
                    r"(?m)^    runs-on: macos-15$",
                )

        packaging = self.job_body(workflow, "packaging")
        self.assertRegex(
            packaging,
            r"(?m)^    needs: \[swift-tests, script-tests\]$",
        )

    def test_ci_anchors_required_test_and_packaging_commands(self):
        workflow = self.read_workflow()
        swift_tests = self.job_body(workflow, "swift-tests")
        self.assertEqual(len(re.findall(r"(?m)^        run: swift test$", swift_tests)), 2)
        self.assert_step_command(
            swift_tests,
            "Swift tests first pass",
            "swift test",
        )
        self.assert_step_command(
            swift_tests,
            "Swift tests stability pass",
            "swift test",
        )

        script_tests = self.job_body(workflow, "script-tests")
        self.assertRegex(
            script_tests,
            r"(?ms)^      - name: Python script tests\n"
            r"        run: >-\n"
            r"          python3 -m unittest discover\n"
            r"          -s Tests/ScriptTests\n"
            r"          -p 'test_\*\.py'\n"
            r"          -v$",
        )

        packaging = self.job_body(workflow, "packaging")
        for name, command in (
            ("App bundle smoke tests", "Tests/PackagingTests/run-tests.sh"),
            (
                "Virtual microphone bridge tests",
                "Tests/VirtualMicDriverTests/run-tests.sh",
            ),
            (
                "Virtual microphone bundle tests",
                "Tests/VirtualMicDriverTests/run-bundle-tests.sh",
            ),
            (
                "Virtual microphone script tests",
                "Tests/VirtualMicDriverTests/run-script-tests.sh",
            ),
        ):
            with self.subTest(step=name):
                self.assert_step_command(packaging, name, command)

    def test_ci_is_read_only_and_uses_fully_pinned_checkout(self):
        workflow = self.read_workflow()
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertNotRegex(workflow, r"(?mi)^\s*[a-z-]+:\s*write\s*$")
        self.assertNotRegex(workflow, r"(?i)\bsecrets\b")

        actions = re.findall(r"(?m)^\s*- uses: ([^\s#]+)", workflow)
        self.assertEqual(len(actions), 4)
        for action in actions:
            with self.subTest(action=action):
                self.assertRegex(action, r"^[^@]+@[0-9a-f]{40}$")
                self.assertEqual(action, f"actions/checkout@{CHECKOUT_SHA}")
        self.assertRegex(
            workflow,
            rf"(?m)^\s*- uses: actions/checkout@{CHECKOUT_SHA} # v4\.3\.1$",
        )

    def test_ci_does_not_install_launch_or_contact_external_services(self):
        workflow = self.read_workflow().lower()
        self.assert_no_forbidden_workflow_terms(workflow)

    def test_forbidden_term_guard_rejects_tcc_and_teams(self):
        workflow = self.read_workflow().lower()
        for forbidden in ("tcc", "teams"):
            with self.subTest(forbidden=forbidden):
                with self.assertRaisesRegex(
                    AssertionError,
                    rf"Forbidden workflow term found: {forbidden}",
                ):
                    self.assert_no_forbidden_workflow_terms(
                        f"{workflow}\n# injected review fixture: {forbidden}\n"
                    )


class ReleaseWorkflowContractTests(unittest.TestCase):
    def read_workflow(self):
        self.assertTrue(
            RELEASE_WORKFLOW.is_file(),
            f"Missing workflow: {RELEASE_WORKFLOW}",
        )
        return RELEASE_WORKFLOW.read_text(encoding="utf-8")

    def test_release_yaml_is_syntax_valid_with_ruby_stdlib(self):
        result = subprocess.run(
            [
                "/usr/bin/ruby",
                "-e",
                'require "yaml"; YAML.parse_file(ARGV.fetch(0))',
                str(RELEASE_WORKFLOW),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_is_manual_protected_and_read_only(self):
        workflow = self.read_workflow()
        self.assertRegex(workflow, r"(?m)^  workflow_dispatch:$")
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertRegex(workflow, r"(?m)^permissions:\n  contents: read$")
        self.assertRegex(workflow, r"(?m)^  release:\n")
        self.assertEqual(
            re.findall(r"(?m)^  ([a-z][a-z-]*):\n", workflow.split("jobs:\n", 1)[1]),
            ["release"],
        )
        self.assertRegex(workflow, r"(?m)^    runs-on: macos-15$")
        self.assertRegex(workflow, r"(?m)^    environment: production$")
        self.assertIn("refs/heads/main", workflow)

    def test_release_uses_exact_pinned_actions_and_artifacts(self):
        workflow = self.read_workflow()
        self.assertRegex(
            workflow,
            rf"(?m)^      - uses: actions/checkout@{CHECKOUT_SHA} # v4\.3\.1$",
        )
        self.assertRegex(
            workflow,
            rf"(?m)^        uses: actions/upload-artifact@{UPLOAD_ARTIFACT_SHA} # v4\.6\.2$",
        )
        actions = re.findall(r"(?m)^\s*(?:- )?uses: ([^\s#]+)", workflow)
        self.assertEqual(
            actions,
            [
                f"actions/checkout@{CHECKOUT_SHA}",
                f"actions/upload-artifact@{UPLOAD_ARTIFACT_SHA}",
            ],
        )
        self.assertIn("${{ runner.temp }}/release/*.zip", workflow)
        self.assertIn("${{ runner.temp }}/release/*.sha256", workflow)
        self.assertIn("${{ runner.temp }}/release/LICENSE", workflow)
        self.assertIn("${{ runner.temp }}/release/THIRD_PARTY_NOTICES.md", workflow)

    def test_release_inputs_are_validated_through_step_environment(self):
        workflow = self.read_workflow()
        self.assertRegex(
            workflow,
            r"(?ms)- name: Validate release inputs\n"
            r"        env:\n"
            r"          RELEASE_VERSION: \$\{\{ inputs\.version \}\}\n"
            r"          RELEASE_BUILD_NUMBER: \$\{\{ inputs\.build_number \}\}",
        )
        self.assertIn('[[ "$RELEASE_VERSION" =~ ^[0-9]+(\\.[0-9]+){1,2}$ ]]', workflow)
        self.assertIn('[[ "$RELEASE_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]', workflow)
        run_blocks = re.findall(r"(?ms)^        run: \|\n(.*?)(?=^      - |\Z)", workflow)
        self.assertTrue(run_blocks)
        for run_block in run_blocks:
            with self.subTest(run_block=run_block):
                self.assertNotRegex(run_block, r"\$\{\{\s*inputs\.")
                self.assertIn("set -euo pipefail", run_block)
                self.assertNotIn("set -x", run_block)

    def test_release_gates_and_secret_preflight_precede_import(self):
        workflow = self.read_workflow()
        self.assertLess(
            workflow.index("Verify releasable ref"),
            workflow.index("Configure temporary signing keychain"),
        )
        self.assertLess(
            workflow.index("Validate release inputs"),
            workflow.index("Preflight required secrets"),
        )
        self.assertLess(
            workflow.index("Run release gates"),
            workflow.index("Configure temporary signing keychain"),
        )
        self.assertLess(
            workflow.index("Preflight required secrets"),
            workflow.index("Configure temporary signing keychain"),
        )
        for secret in (
            "MACOS_CERTIFICATE_P12_BASE64",
            "MACOS_CERTIFICATE_PASSWORD",
            "MACOS_SIGNING_IDENTITY",
            "MACOS_NOTARY_KEY_ID",
            "MACOS_NOTARY_ISSUER_ID",
            "MACOS_NOTARY_PRIVATE_KEY_BASE64",
        ):
            with self.subTest(secret=secret):
                self.assertIn(secret, workflow)
        self.assertIn("A required production secret is missing.", workflow)

    def test_release_preserves_keychain_search_list_and_cleans_up(self):
        workflow = self.read_workflow()
        self.assertIn("umask 077", workflow)
        self.assertIn('security list-keychains -d user > "$ORIGINAL_KEYCHAINS"', workflow)
        self.assertIn(
            'security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS_ARRAY[@]}"',
            workflow,
        )
        self.assertLess(
            workflow.index('echo "::add-mask::$KEYCHAIN_PASSWORD"'),
            workflow.index('printf \'%s\' "$P12"'),
        )
        cleanup = workflow.split("- name: Remove temporary credentials", 1)[1]
        self.assertIn("if: always()", cleanup)
        self.assertIn('KEYCHAIN="${LMR_KEYCHAIN:-$RUNNER_TEMP/lmr-signing.keychain-db}"', cleanup)
        self.assertLess(
            cleanup.index('security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"'),
            cleanup.index('security delete-keychain "$KEYCHAIN"'),
        )
        self.assertIn("$RUNNER_TEMP/signing.p12", cleanup)
        self.assertIn("$RUNNER_TEMP/AuthKey.p8", cleanup)
        self.assertIn("$RUNNER_TEMP/lmr-original-keychains", cleanup)

    def test_release_configure_failure_trap_restores_before_mutation(self):
        workflow = self.read_workflow()
        configure = workflow.split("- name: Configure temporary signing keychain", 1)[1]
        configure = configure.split("- name: Build, sign, notarize, and verify", 1)[0]
        self.assertLess(
            configure.index('echo "LMR_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"'),
            configure.index('security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"'),
        )
        self.assertLess(
            configure.index('echo "LMR_ORIGINAL_KEYCHAINS=$ORIGINAL_KEYCHAINS" >> "$GITHUB_ENV"'),
            configure.index('security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"'),
        )
        self.assertLess(
            configure.index('echo "LMR_SIGNING_P12=$SIGNING_P12" >> "$GITHUB_ENV"'),
            configure.index('security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"'),
        )
        self.assertLess(
            configure.index('echo "LMR_NOTARY_KEY=$NOTARY_KEY" >> "$GITHUB_ENV"'),
            configure.index('security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"'),
        )
        self.assertIn("configure_cleanup()", configure)
        self.assertIn("trap configure_cleanup ERR", configure)
        trap_index = configure.index("trap configure_cleanup ERR")
        mutation_index = configure.index('security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"')
        self.assertLess(trap_index, mutation_index)
        self.assertIn(
            'security list-keychains -d user -s "${ORIGINAL_KEYCHAINS_ARRAY[@]}"',
            configure,
        )
        self.assertIn('security delete-keychain "$KEYCHAIN" || true', configure)
        self.assertNotIn("mapfile", workflow)
        self.assertNotIn("readarray", workflow)
        self.assertNotIn("eval", workflow)
        self.assertNotRegex(workflow, r"\$\([^)]*security list-keychains")

    def test_release_builds_notarized_artifacts_without_operational_side_effects(self):
        workflow = self.read_workflow().lower()
        self.assertIn("./scripts/build-release.sh", workflow)
        self.assertIn("--notary-profile lmr-production", workflow)
        self.assertIn("--notary-keychain \"$lmr_keychain\"", workflow)
        self.assertIn('"$runner_temp/release"', workflow)
        self.assertIn("/usr/bin/shasum -a 256 -c ./*.sha256", workflow)
        for forbidden in (
            "install",
            "launch",
            "tcc",
            "teams",
            "provider",
            "github release",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, workflow)


if __name__ == "__main__":
    unittest.main()
