"""Offline policy and provenance regression tests. Run with unittest discovery."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("catalog", Path(__file__).resolve().parents[1] / "generate_exercise_catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


class CatalogGenerationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "vendor/free-exercise-db"
        shutil.copytree(catalog.SOURCE, self.source)
        self.resources = self.root / "LiftLog/Core/Resources"
        self.resources.mkdir(parents=True)
        shutil.copy(catalog.ROOT / "LiftLog/Core/Resources/free-exercise-db-LICENSE.txt", self.resources)

    def read(self, filename):
        return json.loads((self.source / filename).read_text())

    def write(self, filename, value):
        (self.source / filename).write_text(json.dumps(value, ensure_ascii=False))

    def generate(self):
        return catalog.generate_resources(self.source, self.root)

    def update_entry(self, field, value):
        entries = self.read("exercises.json")
        entries[0][field] = value
        self.write("exercises.json", entries)
        metadata = self.read("source.json")
        metadata["sha256"] = catalog.sha256((self.source / "exercises.json").read_bytes())
        self.write("source.json", metadata)

    def test_reproducible_and_original_catalog_bytes_preserved(self):
        outputs = self.generate()
        self.assertEqual(outputs, self.generate())
        self.assertEqual(catalog.sha256(outputs["exercise-catalog.json"].encode()),
                         "1f2e839263c66baeaf1bb41639814b9e641e9ba7b8f845893fe1d4a04c61cb6f")
        self.assertEqual(len(json.loads(outputs["exercise-details.json"])), 876)
        for name, content in outputs.items():
            self.assertEqual(content, (catalog.ROOT / catalog.GENERATED_PATHS[name]).read_text())

    def test_runtime_details_are_lean_and_audit_stays_outside_the_bundle(self):
        outputs = self.generate()
        details = json.loads(outputs["exercise-details.json"])
        for detail in details.values():
            self.assertEqual(set(detail), set(catalog.DETAIL_FIELDS) | {"source"})
            self.assertEqual(set(detail["source"]), {"sourceID", "sourceRecordID"})
        self.assertEqual(list((catalog.ROOT / "LiftLog/Core/Resources").rglob("exercise-provenance.json")), [])
        for name, path in catalog.GENERATED_PATHS.items():
            if name == "exercise-provenance.json":
                self.assertFalse(path.is_relative_to("LiftLog/Core"))
            else:
                self.assertTrue(path.is_relative_to("LiftLog/Core/Resources"))

    def test_check_detects_missing_or_changed_runtime_and_audit_outputs(self):
        outputs = self.generate()
        for name, content in outputs.items():
            (self.root / catalog.GENERATED_PATHS[name]).write_text(content)
        self.assertEqual(catalog.stale_outputs(outputs, self.root), [])
        for name, content in outputs.items():
            with self.subTest(output=name):
                path = self.root / catalog.GENERATED_PATHS[name]
                path.unlink()
                self.assertEqual(catalog.stale_outputs(outputs, self.root), [name])
                path.write_text(content + " ")
                self.assertEqual(catalog.stale_outputs(outputs, self.root), [name])
                path.write_text(content)

    def test_fields_preserve_full_lists_unknowns_and_ordered_source_words(self):
        outputs = self.generate()
        ids = {row["sourceID"]: row["id"] for row in json.loads(outputs["exercise-catalog.json"])}
        details = json.loads(outputs["exercise-details.json"])
        audit = json.loads(outputs["exercise-provenance.json"])
        self.assertEqual(audit["schemaVersion"], 1)
        self.assertEqual(set(audit["records"]), set(details))
        for original in self.read("exercises.json"):
            detail = details[ids[original["id"]]]
            record_audit = audit["records"][ids[original["id"]]]
            self.assertEqual(detail["instructions"], [step for step in original["instructions"] if step.strip()])
            for field in ["primaryMuscles", "secondaryMuscles"]:
                self.assertEqual(detail[field], [self.read("normalization.json")["muscles"][muscle] for muscle in original[field]])
            self.assertEqual(detail["source"], {key: record_audit["source"][key] for key in ["sourceID", "sourceRecordID"]})
            self.assertEqual(detail["source"]["sourceRecordID"], original["id"])
            self.assertEqual(record_audit["source"]["sourceRecordSHA256"], catalog.content_hash(original))
            self.assertEqual(set(record_audit["provenance"]), set(catalog.DETAIL_FIELDS))
            for field, source_field in catalog.DETAIL_FIELDS.items():
                provenance = record_audit["provenance"][field]
                self.assertEqual(provenance["sourceField"], source_field)
                self.assertEqual(provenance["contentSHA256"], catalog.content_hash(original[source_field]))
                self.assertEqual(provenance["reviewStatus"], "pendingReview")
                if field == "type":
                    modifications = ["Source category renamed to type; label normalized."]
                elif detail[field] == original[source_field]:
                    modifications = []
                elif field == "instructions":
                    modifications = ["Empty instruction steps omitted; remaining wording and order preserved."]
                else:
                    modifications = ["Normalized using the committed explicit label mapping."]
                self.assertEqual(provenance["modifications"], modifications)
        self.assertIsNone(details[ids["Adductor_Groin"]]["equipment"])
        self.assertEqual(details[ids["3_4_Sit-Up"]]["equipment"], "Bodyweight")
        self.assertEqual(details[ids["Iron_Cross"]]["instructions"], [])
        self.assertIsNone(details[ids["90_90_Hamstring"]]["mechanic"])
        self.assertIsNone(details[ids["Balance_Board"]]["force"])

    def test_manifest_resolves_every_record_to_pinned_license_and_credit(self):
        outputs = self.generate()
        source = json.loads(outputs["exercise-attribution.json"])["sources"][0]
        metadata = self.read("source.json")
        self.assertEqual(source["revision"], metadata["commit"])
        self.assertEqual(source["sourceSHA256"], metadata["sha256"])
        self.assertEqual(source["licenseText"], (self.resources / "free-exercise-db-LICENSE.txt").read_text())
        self.assertEqual(source["licenseID"], "Unlicense")
        self.assertTrue(source["author"] and source["credit"] and source["licenseScope"])
        for detail in json.loads(outputs["exercise-details.json"]).values():
            self.assertEqual(detail["source"]["sourceID"], source["id"])
        for record in json.loads(outputs["exercise-provenance.json"])["records"].values():
            self.assertEqual(record["source"]["sourceID"], source["id"])
            self.assertEqual(record["source"]["sourceURL"], source["sourceURL"])

    def test_changed_source_and_license_checksums_are_rejected(self):
        (self.source / "exercises.json").write_text("[]")
        with self.assertRaisesRegex(ValueError, "Upstream checksum"):
            self.generate()
        shutil.copy(catalog.SOURCE / "exercises.json", self.source)
        (self.resources / "free-exercise-db-LICENSE.txt").write_text("different notice")
        with self.assertRaisesRegex(ValueError, "license checksum"):
            self.generate()

    def test_disallowed_license_and_missing_credit_are_rejected(self):
        policy = self.read("content-policy.json")
        for license_id in ["CC-BY-NC-4.0", "CC-BY-ND-4.0", "unknown", "app-only"]:
            with self.subTest(license=license_id):
                self.write("content-policy.json", {**policy, "licenseID": license_id})
                with self.assertRaisesRegex(ValueError, "license"):
                    self.generate()
        for field in ["author", "credit", "licenseScope"]:
            with self.subTest(field=field):
                self.write("content-policy.json", {**policy, field: ""})
                with self.assertRaisesRegex(ValueError, "Missing"):
                    self.generate()

    def test_changed_or_unreviewed_identity_mappings_are_rejected(self):
        policy = self.read("content-policy.json")
        policy["compatibilityMappings"]["reviewStatus"] = "pendingReview"
        self.write("content-policy.json", policy)
        with self.assertRaisesRegex(ValueError, "mappings"):
            self.generate()
        policy["compatibilityMappings"]["reviewStatus"] = "reviewed"
        self.write("content-policy.json", policy)
        mappings = self.read("legacy-ids.json")
        mappings["Barbell_Squat"]["id"] = "00000000-0000-0000-0000-000000000999"
        self.write("legacy-ids.json", mappings)
        with self.assertRaisesRegex(ValueError, "mappings"):
            self.generate()

    def test_unmapped_labels_fail_instead_of_becoming_bodyweight(self):
        self.update_entry("equipment", "new unknown equipment")
        with self.assertRaisesRegex(ValueError, "Unmapped equipment"):
            self.generate()

    def test_photos_cannot_enter_outputs_or_resource_directories(self):
        outputs = self.generate()
        for output in outputs.values():
            self.assertNotIn('"images"', output)
            self.assertNotIn("3_4_Sit-Up/0.jpg", output)
        for value in [{"images": []}, {"assetPath": "asset.jpg"}, {"url": "https://example.test/a.png"}]:
            with self.assertRaisesRegex(ValueError, "Blocked media"):
                catalog.validate_no_media(value)
        (self.source / "images").mkdir()
        with self.assertRaisesRegex(ValueError, "Blocked media"):
            self.generate()
        (self.source / "images").rmdir()
        (self.resources / "example.jpg").write_bytes(b"excluded")
        with self.assertRaisesRegex(ValueError, "Blocked media"):
            self.generate()

    def test_cannot_claim_content_review_or_enable_media(self):
        policy = self.read("content-policy.json")
        self.write("content-policy.json", {**policy, "reviewStatus": "reviewed"})
        with self.assertRaisesRegex(ValueError, "review"):
            self.generate()
        self.write("content-policy.json", {**policy, "mediaPolicy": "included"})
        with self.assertRaisesRegex(ValueError, "Photographs"):
            self.generate()


if __name__ == "__main__":
    unittest.main()
