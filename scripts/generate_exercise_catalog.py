#!/usr/bin/env python3
"""Build the offline catalog from the pinned, public-domain upstream dataset."""
import argparse
import hashlib
import json
from pathlib import Path
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "vendor/free-exercise-db"
OUTPUT = ROOT / "LiftLog/Core/Resources/exercise-catalog.json"
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


def generate():
    raw = (SOURCE / "exercises.json").read_bytes()
    metadata = json.loads((SOURCE / "source.json").read_text())
    if hashlib.sha256(raw).hexdigest() != metadata["sha256"]:
        raise ValueError("Upstream checksum differs from source.json")
    entries = json.loads(raw)
    legacy = json.loads((SOURCE / "legacy-ids.json").read_text())
    source_ids = [entry["id"] for entry in entries]
    if len(set(source_ids)) != len(source_ids) or set(legacy) - set(source_ids):
        raise ValueError("Duplicate upstream IDs or missing compatibility targets")

    catalog = []
    for entry in entries:
        override = legacy.get(entry["id"], {})
        muscles = entry["primaryMuscles"]
        category = MUSCLE_CATEGORIES[muscles[0]] if muscles else "Other"
        catalog.append({
            "id": override.get("id", str(uuid.uuid5(NAMESPACE, entry["id"]))),
            "name": override.get("name", entry["name"]),
            "category": category,
            "sourceID": entry["id"],
        })
    # Keep the original ten in place for starter templates; sort everything else.
    starters = {f"00000000-0000-0000-0000-{i:012d}": i for i in range(1, 11)}
    if not set(starters).issubset({entry["id"] for entry in catalog}):
        raise ValueError("Missing starter exercise identity")
    catalog.sort(key=lambda entry: (starters.get(entry["id"], 11), entry["name"].casefold()))
    if len({entry["id"] for entry in catalog}) != len(catalog):
        raise ValueError("Duplicate catalog UUIDs")
    if len({entry["name"].casefold() for entry in catalog}) != len(catalog):
        raise ValueError("Duplicate catalog names")
    return json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify the committed catalog is current")
    args = parser.parse_args()
    result = generate()
    if args.check:
        if OUTPUT.read_text() != result:
            raise SystemExit("Catalog is stale; run scripts/generate_exercise_catalog.py")
        print("Catalog matches the pinned upstream dataset and compatibility mappings.")
    else:
        OUTPUT.write_text(result)
        print(f"Generated {len(json.loads(result))} exercises.")
