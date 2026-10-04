# Exercise catalog

The app's sole external catalog source is [yuhonas/free-exercise-db](https://github.com/yuhonas/free-exercise-db), published under the Unlicense. The previous website-derived catalog and guide links have been removed. The app ships 876 exercises, works offline, and makes no catalog network requests.

## Provenance and licensing

- Pinned upstream commit: `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`.
- Original dataset: `vendor/free-exercise-db/exercises.json`, copied unchanged from upstream `dist/exercises.json`.
- Repository, revision, and SHA-256 checksum: `vendor/free-exercise-db/source.json`.
- Upstream license: `LiftLog/Core/Resources/free-exercise-db-LICENSE.txt`, bundled with the app and Swift package.

The upstream repository describes its dataset as public domain. Its license permits copying, modification, and redistribution. Attribution is retained here for traceability. No website scraping is part of this import or its generation workflow.

The complete upstream JSON is retained for audit and future use. Only IDs, names, and muscle categories are exposed in the current app. Instructions and image paths remain in the vendor snapshot; images are not downloaded, bundled, or loaded by the app.

## Generation

Run from the repository root:

```sh
python3 scripts/generate_exercise_catalog.py
python3 scripts/generate_exercise_catalog.py --check
```

The generator reads the committed snapshot without network access, verifies its checksum, and writes `LiftLog/Core/Resources/exercise-catalog.json`. Each record carries its upstream `sourceID` for audit. Swift decodes the existing `Exercise` fields, so no saved-data schema change is needed. Swift Package Manager and the Xcode app both bundle this resource.

The display category comes from the first primary muscle, rather than upstream's activity category (strength, stretching, etc.). Quadriceps, hamstrings, glutes, abductors, and adductors map to Legs; lats, traps, and middle/lower back map to Back. Other muscles retain their own category. All upstream activity types are included.

To update, choose and review an upstream commit, replace the vendor JSON and license from that exact revision, update the revision and checksum in `source.json`, review compatibility targets, regenerate, and run the checks and app build. Do not fetch an unpinned branch during builds.

## Compatibility

`vendor/free-exercise-db/legacy-ids.json` contains 103 reviewed upstream-to-existing UUID mappings. It contains identifiers and the original ten starter labels; it is not a second exercise dataset. Mapped exercises use upstream names and muscle categories except for those ten original app labels, which stay in the first ten positions to preserve starter templates and familiar naming.

The remaining 42 former entries have no confidently equivalent upstream target and are omitted from the bundled catalog. Saved instances of these entries become available in the picker through the personal catalog. Different equipment or execution variants are not automatically merged. For example, the upstream Goblet Squat uses a kettlebell, so it does not reuse the former Dumbbell Goblet Squat ID.

Templates, active workouts, and history embed complete exercise snapshots. Loading this catalog does not rename, delete, or rewrite those saved exercises, including the 42 retired picker entries. They can still be used through existing templates. The store backfills saved nonbundled exercises into a persistent personal catalog without changing their recorded snapshots. The picker and import matcher use the bundled catalog followed by personal entries, deduplicating case and whitespace with bundled names preferred. Newly saved custom exercises remain reusable after their source template is deleted or workout discarded; canceled drafts and imports do not add entries.

New exercises receive deterministic UUID v5 identities from a permanent namespace and the upstream ID. Names, sort order, and source array positions do not determine identity. Keep the namespace and compatibility mappings stable; if an upstream ID changes, explicitly preserve its previous UUID. Retired UUIDs must never be reassigned to unrelated movements.
