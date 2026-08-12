import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AUDIT = ROOT / "scripts" / "check-no-accessibility-api.sh"


class AccessibilityAPIAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write(self, relative_path, contents):
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    def run_audit(self, extra_environment=None):
        environment = os.environ.copy()
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            ["/bin/bash", str(AUDIT), str(self.root)],
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )

    def make_failing_tool(self, name):
        tool = self.root / name
        tool.write_text("#!/bin/bash\nexit 2\n", encoding="utf-8")
        tool.chmod(0o755)
        return tool

    def test_allows_swiftui_identifier_and_ignored_fixture_locations(self):
        self.write("Sources/RecorderApp/ContentView.swift", 'Text("Record").accessibilityIdentifier("record")\n')
        self.write("docs/example.swift", "let item = AXUIElementCreateApplication(1)\n")
        self.write("Tests/Fixtures/Bad.swift", "let item = AXUIElementCreateApplication(1)\n")
        self.write("build/Generated.swift", "let item = AXUIElementCreateApplication(1)\n")

        result = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "Accessibility API audit passed.\n")

    def test_rejects_accessibility_symbol_with_repo_relative_file_and_symbol(self):
        self.write("Sources/RecorderApp/Teams/Detector.swift", "let app = AXUIElementCreateApplication(123)\n")

        result = self.run_audit()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr,
            "Accessibility API prohibited: Sources/RecorderApp/Teams/Detector.swift: AXUIElementCreateApplication\n",
        )

    def test_rejects_framework_import_in_package_configuration(self):
        self.write("Package.swift", "import ApplicationServices\n")

        result = self.run_audit()

        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr,
            "Accessibility API prohibited: Package.swift: ApplicationServices\n",
        )

    def test_fails_closed_when_grep_errors(self):
        self.write("Sources/RecorderApp/ContentView.swift", 'Text("Record")\n')
        grep = self.make_failing_tool("fake-grep")

        result = self.run_audit(
            {
                "ACCESSIBILITY_AUDIT_TEST_MODE": "1",
                "ACCESSIBILITY_AUDIT_ALLOW_TOOL_OVERRIDES": "1",
                "ACCESSIBILITY_AUDIT_GREP_BIN": str(grep),
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("grep failed", result.stderr)

    def test_fails_closed_when_find_errors(self):
        self.write("Sources/RecorderApp/ContentView.swift", 'Text("Record")\n')
        find = self.make_failing_tool("fake-find")

        result = self.run_audit(
            {
                "ACCESSIBILITY_AUDIT_TEST_MODE": "1",
                "ACCESSIBILITY_AUDIT_ALLOW_TOOL_OVERRIDES": "1",
                "ACCESSIBILITY_AUDIT_FIND_BIN": str(find),
            }
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("find failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
