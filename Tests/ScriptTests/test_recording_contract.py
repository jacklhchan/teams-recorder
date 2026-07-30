import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "contracts" / "recording-session.schema.json"
FIXTURE = ROOT / "contracts" / "fixtures" / "recording-info-v1.json"


class RecordingContractTests(unittest.TestCase):
    def test_schema_and_fixture_are_versioned_valid_json(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

        self.assertEqual(schema["properties"]["schemaVersion"]["const"], 1)
        self.assertEqual(fixture["schemaVersion"], 1)
        self.assertTrue(schema["additionalProperties"])

    def test_fixture_satisfies_required_v1_types_and_enums(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

        for key in schema["required"]:
            self.assertIn(key, fixture)
        self.assertIsInstance(fixture["tags"], list)
        self.assertIsInstance(fixture["isFavorite"], bool)
        self.assertIn(
            fixture["mediaKind"],
            schema["properties"]["mediaKind"]["enum"],
        )
        self.assertIn(
            fixture["recoveryState"],
            schema["properties"]["recoveryState"]["enum"],
        )
        self.assertIn(
            fixture["source"],
            schema["properties"]["source"]["enum"],
        )
        self.assertIsInstance(fixture["participants"], list)

    def test_fixture_demonstrates_forward_compatible_platform_extension(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

        self.assertTrue(schema["additionalProperties"])
        self.assertEqual(
            fixture["windowsCapture"]["endpointId"],
            "default",
        )


if __name__ == "__main__":
    unittest.main()
