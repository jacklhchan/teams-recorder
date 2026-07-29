import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ci.yml"
CHECKOUT_SHA = "34e114876b0b11c390a56381ad16ebd13914f8d5"
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


if __name__ == "__main__":
    unittest.main()
