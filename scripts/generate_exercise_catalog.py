#!/usr/bin/env python3
"""Generate offline catalog, details, credits, and a separate provenance audit."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "vendor/free-exercise-db"
OUTPUT = ROOT / "LiftLog/Core/Resources/exercise-catalog.json"
GENERATED_PATHS = {
    name: Path("LiftLog/Core/Resources") / name
    for name in ["exercise-catalog.json", "exercise-details.json", "exercise-attribution.json"]
}
GENERATED_PATHS["exercise-provenance.json"] = Path("vendor/free-exercise-db/exercise-provenance.json")
# Permanent namespace: IDs depend on upstream IDs, never names or array positions.
NAMESPACE = uuid.UUID("e668353b-034f-4874-a79b-076dcabf47c8")
MUSCLE_CATEGORIES = {
    "abdominals": "Abdominals", "abductors": "Legs", "adductors": "Legs",
    "biceps": "Biceps", "calves": "Calves", "chest": "Chest",
    "forearms": "Forearms", "glutes": "Legs", "hamstrings": "Legs",
    "lats": "Back", "lower back": "Back", "middle back": "Back",
    "neck": "Neck", "quadriceps": "Legs", "shoulders": "Shoulders",
    "traps": "Back", "triceps": "Triceps",
}
# Deliberately restricted to the sole selected source/license, not API code licenses.
APPROVED_LICENSES = {"Unlicense"}
DETAIL_FIELDS = {
    "equipment": "equipment", "primaryMuscles": "primaryMuscles",
    "secondaryMuscles": "secondaryMuscles", "instructions": "instructions",
    "type": "category", "level": "level", "force": "force", "mechanic": "mechanic",
}


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def content_hash(value):
    """SHA-256 of UTF-8 JSON, sorted keys, compact separators, no ASCII escaping."""
    return sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def formatted(value):
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def required_text(value, name):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing {name}")
    return value


def validate_no_media(value):
    """Outputs may contain credit prose, but never asset keys or media locations."""
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in {"images", "image", "photos", "media", "assets", "assetpath", "imagepath"}:
                raise ValueError(f"Blocked media field: {key}")
            validate_no_media(child)
    elif isinstance(value, list):
        for child in value:
            validate_no_media(child)
    elif isinstance(value, str) and re.search(r"\.(?:jpe?g|png|gif|webp|svg|mp4|mov)(?:$|[?#])", value, re.I):
        raise ValueError("Blocked media location in generated output")


def validate_no_media_files(directory):
    for path in directory.rglob("*"):
        if path.name.lower() in {"images", "photos", "media"} or path.suffix.lower() in {".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".mp4", ".mov"}:
            raise ValueError(f"Blocked media file or directory: {path.name}")


def load_inputs(source, root):
    validate_no_media_files(source)
    validate_no_media_files(root / "LiftLog/Core/Resources")
    raw = (source / "exercises.json").read_bytes()
    metadata = json.loads((source / "source.json").read_text(encoding="utf-8"))
    policy = json.loads((source / "content-policy.json").read_text(encoding="utf-8"))
    if sha256(raw) != metadata["sha256"]:
        raise ValueError("Upstream checksum differs from source.json")
    if not re.fullmatch(r"[0-9a-f]{40}", metadata["commit"]):
        raise ValueError("Source revision must be a pinned commit")
    if metadata["repository"] != "https://github.com/yuhonas/free-exercise-db" or metadata["file"] != "dist/exercises.json":
        raise ValueError("Only the selected free-exercise-db source is approved")
    if policy["sourceID"] != "free-exercise-db" or policy["schemaVersion"] != 1:
        raise ValueError("Unsupported content policy")
    if metadata["license"] not in APPROVED_LICENSES or policy["licenseID"] != metadata["license"]:
        raise ValueError("Disallowed or inconsistent data license")
    for key in ["name", "author", "licenseURL", "licenseScope", "credit", "reviewNote"]:
        required_text(policy.get(key), key)
    if policy["licenseURL"] != "https://unlicense.org/":
        raise ValueError("License URL does not match the approved license")
    if policy["reviewStatus"] != "pendingReview":
        raise ValueError("Individual content review requires a separate reviewed-content workflow")
    if policy["mediaPolicy"] != "excluded" or not policy["excludedContent"]:
        raise ValueError("Photographs must remain excluded")
    for key in ["modifications", "excludedContent"]:
        if not isinstance(policy[key], list) or not policy[key]:
            raise ValueError(f"Missing {key}")
        for text in policy[key]:
            required_text(text, key)
    license_path = (root / policy["licenseFile"]).resolve()
    if license_path != (root / "LiftLog/Core/Resources/free-exercise-db-LICENSE.txt").resolve():
        raise ValueError("Unexpected license resource path")
    license_raw = license_path.read_bytes()
    if sha256(license_raw) != policy["licenseSHA256"]:
        raise ValueError("Bundled license checksum differs from content policy")
    legacy_raw = (source / "legacy-ids.json").read_bytes()
    mapping_policy = policy["compatibilityMappings"]
    if mapping_policy["reviewStatus"] != "reviewed" or sha256(legacy_raw) != mapping_policy["sha256"]:
        raise ValueError("Compatibility mappings are unreviewed or their checksum changed")
    normalization = json.loads((source / "normalization.json").read_text(encoding="utf-8"))
    return json.loads(raw), metadata, policy, json.loads(legacy_raw), normalization, license_raw.decode("utf-8")


def generate_resources(source=SOURCE, root=ROOT):
    entries, metadata, policy, legacy, mappings, license_text = load_inputs(source, root)
    source_ids = [entry["id"] for entry in entries]
    if len(set(source_ids)) != len(source_ids) or set(legacy) - set(source_ids):
        raise ValueError("Duplicate upstream IDs or missing compatibility targets")

    def normalize(value, mapping):
        if value is None:
            return None  # Unknown is distinct from bodyweight and other equipment.
        if value not in mappings[mapping]:
            raise ValueError(f"Unmapped {mapping} label: {value!r}")
        return required_text(mappings[mapping][value], f"normalized {mapping}")

    catalog, details, audit = [], {}, {}
    for entry in entries:
        override = legacy.get(entry["id"], {})
        exercise_id = override.get("id", str(uuid.uuid5(NAMESPACE, entry["id"])))
        uuid.UUID(exercise_id)
        muscles = entry["primaryMuscles"]
        category = MUSCLE_CATEGORIES[muscles[0]] if muscles else "Other"
        catalog.append({"id": exercise_id, "name": override.get("name", entry["name"]),
                        "category": category, "sourceID": entry["id"]})
        if not isinstance(entry["instructions"], list) or any(not isinstance(step, str) for step in entry["instructions"]):
            raise ValueError("Instructions must be an ordered list of strings")
        detail = {
            "equipment": normalize(entry["equipment"], "equipment"),
            "primaryMuscles": [normalize(m, "muscles") for m in muscles],
            "secondaryMuscles": [normalize(m, "muscles") for m in entry["secondaryMuscles"]],
            "instructions": [step for step in entry["instructions"] if step.strip()],
            "type": normalize(entry["category"], "type"),
            "level": normalize(entry["level"], "level"),
            "force": normalize(entry["force"], "force"),
            "mechanic": normalize(entry["mechanic"], "mechanic"),
            "source": {
                "sourceID": policy["sourceID"], "sourceRecordID": entry["id"],
            },
        }
        record_audit = {
            "source": {
                **detail["source"],
                "sourceURL": f'{metadata["repository"]}/blob/{metadata["commit"]}/{metadata["file"]}',
                "sourceRecordSHA256": content_hash(entry),
            },
            "provenance": {},
        }
        for field, original in DETAIL_FIELDS.items():
            changed = detail[field] != entry[original] or field != original
            modifications = []
            if field == "type":
                modifications = ["Source category renamed to type; label normalized."]
            elif changed and field == "instructions":
                modifications = ["Empty instruction steps omitted; remaining wording and order preserved."]
            elif changed:
                modifications = ["Normalized using the committed explicit label mapping."]
            record_audit["provenance"][field] = {
                "sourceField": original, "contentSHA256": content_hash(entry[original]),
                "modifications": modifications, "reviewStatus": policy["reviewStatus"],
            }
        details[exercise_id] = detail
        audit[exercise_id] = record_audit
    # Keep the original ten in place for starter templates; sort everything else.
    starters = {f"00000000-0000-0000-0000-{i:012d}": i for i in range(1, 11)}
    if not set(starters).issubset({entry["id"] for entry in catalog}):
        raise ValueError("Missing starter exercise identity")
    catalog.sort(key=lambda entry: (starters.get(entry["id"], 11), entry["name"].casefold()))
    if len({entry["id"] for entry in catalog}) != len(catalog):
        raise ValueError("Duplicate catalog UUIDs")
    if len({entry["name"].casefold() for entry in catalog}) != len(catalog):
        raise ValueError("Duplicate catalog names")
    source_credit = {key: policy[key] for key in ["name", "author", "licenseID", "licenseURL", "licenseScope", "credit",
                                                       "modifications", "reviewStatus", "reviewNote", "excludedContent"]}
    source_credit.update({"id": policy["sourceID"], "repositoryURL": metadata["repository"],
                          "revision": metadata["commit"], "sourceURL": f'{metadata["repository"]}/blob/{metadata["commit"]}/{metadata["file"]}',
                          "sourceSHA256": metadata["sha256"], "licenseText": license_text,
                          "licenseSHA256": policy["licenseSHA256"],
                          "compatibilityMappingsSHA256": policy["compatibilityMappings"]["sha256"],
                          "normalizationSHA256": sha256((source / "normalization.json").read_bytes())})
    outputs = {"exercise-catalog.json": catalog, "exercise-details.json": {key: details[key] for key in sorted(details)},
               "exercise-attribution.json": {"schemaVersion": 1, "sources": [source_credit]},
               "exercise-provenance.json": {"schemaVersion": 1, "records": {key: audit[key] for key in sorted(audit)}}}
    for output in outputs.values():
        validate_no_media(output)
    return {name: formatted(value) for name, value in outputs.items()}


def generate():
    """Compatibility entry point for callers checking the original catalog."""
    return generate_resources()["exercise-catalog.json"]


def stale_outputs(outputs, root=ROOT):
    """Check runtime resources and the nonbundled audit against the same inputs."""
    return [name for name, result in outputs.items()
            if not (root / GENERATED_PATHS[name]).exists()
            or (root / GENERATED_PATHS[name]).read_text(encoding="utf-8") != result]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify runtime resources and the nonbundled provenance audit")
    args = parser.parse_args()
    results = generate_resources()
    if args.check:
        stale = stale_outputs(results)
        if stale:
            raise SystemExit(f"Generated resources are stale: {', '.join(stale)}; run scripts/generate_exercise_catalog.py")
        print("Catalog, details, attribution, and provenance audit match the pinned inputs and content policy.")
    else:
        for name, result in results.items():
            (ROOT / GENERATED_PATHS[name]).write_text(result, encoding="utf-8")
        print(f"Generated {len(json.loads(results['exercise-catalog.json']))} exercises, details, attribution, and provenance audit.")
