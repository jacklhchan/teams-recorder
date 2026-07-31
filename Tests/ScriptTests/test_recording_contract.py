import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "contracts" / "recording-session.schema.json"
FIXTURE = ROOT / "contracts" / "fixtures" / "recording-info-v1.json"
V2_FIXTURE = (
    ROOT / "contracts" / "fixtures" / "recording-info-v2-meeting-intelligence.json"
)
INTELLIGENCE_SCHEMA = ROOT / "contracts" / "meeting-intelligence.schema.json"
INTELLIGENCE_FIXTURE = ROOT / "contracts" / "fixtures" / "meeting-intelligence-v1.json"


class RecordingContractTests(unittest.TestCase):
    def test_schema_and_fixture_are_versioned_valid_json(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

        self.assertIn(1, schema["properties"]["schemaVersion"]["enum"])
        self.assertEqual(fixture["schemaVersion"], 1)
        self.assertTrue(schema["additionalProperties"])

    def test_fixture_satisfies_required_v1_types_and_enums(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

        v1_schema = next(
            variant
            for variant in schema["oneOf"]
            if variant["properties"]["schemaVersion"]["const"] == 1
        )
        for key in v1_schema["required"]:
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

    def test_v2_fixture_declares_title_origin_and_valid_intelligence(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        fixture = json.loads(V2_FIXTURE.read_text(encoding="utf-8"))
        intelligence_schema = json.loads(
            INTELLIGENCE_SCHEMA.read_text(encoding="utf-8")
        )
        intelligence = json.loads(
            INTELLIGENCE_FIXTURE.read_text(encoding="utf-8")
        )

        self.assertEqual(fixture["schemaVersion"], 2)
        self.assertIn(
            fixture["titleOrigin"],
            {"unset", "meetingIntelligence", "manual"},
        )
        self.assertTrue(schema["additionalProperties"])
        self.assertEqual(intelligence["schemaVersion"], 1)
        self.assertEqual(
            intelligence_schema["properties"]["schemaVersion"]["const"],
            1,
        )
        self.assertEqual(
            intelligence["intent"],
            "automatic",
        )
        self.assertEqual(
            set(intelligence_schema["properties"]["intent"]["enum"]),
            {
                "automatic",
                "generate",
                "regenerate",
                "retryGeneration",
            },
        )
        self.assertNotIn(
            "manual",
            intelligence_schema["properties"]["intent"]["enum"],
        )
        self.assertEqual(
            intelligence_schema["properties"]["model"]["maxLength"],
            512,
        )
        self.assertTrue(
            intelligence["sourceTranscriptSHA256"].startswith("sha256:")
        )
        for forbidden in ("apiKey", "baseURL", "transcript", "prompt", "response"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, intelligence)

    def test_schema_accepts_version_one_and_two_contracts(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        v1 = json.loads(FIXTURE.read_text(encoding="utf-8"))
        v2 = json.loads(V2_FIXTURE.read_text(encoding="utf-8"))

        versions = {
            variant["properties"]["schemaVersion"]["const"]
            for variant in schema["oneOf"]
        }
        self.assertEqual(versions, {1, 2})
        self.assertEqual(v1["schemaVersion"], 1)
        self.assertEqual(v2["schemaVersion"], 2)


if __name__ == "__main__":
    unittest.main()
