# Exercise catalog

The app's sole external catalog source is [yuhonas/free-exercise-db](https://github.com/yuhonas/free-exercise-db), published under the Unlicense. The previous website-derived catalog and guide links have been removed. The app ships 876 exercises, works offline, and makes no catalog network requests.

## Provenance and licensing

- Pinned upstream commit: `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`.
- Original dataset: `vendor/free-exercise-db/exercises.json`, copied unchanged from upstream `dist/exercises.json`.
- Repository, revision, and SHA-256 checksum: `vendor/free-exercise-db/source.json`.
- Upstream license: `LiftLog/Core/Resources/free-exercise-db-LICENSE.txt`, bundled with the app and Swift package.

The upstream repository declares its text and metadata under the Unlicense. This declaration is recorded separately from individual content review and photograph rights. Photo origins and rights remain unresolved; no photographs or image references are generated, downloaded, or bundled. See [the content policy](EXERCISE_DATA_SOURCES.md). No website scraping is part of generation.

The complete upstream JSON is retained for audit. The original `exercise-catalog.json` keeps its IDs, names, categories, source IDs, and ordering. A compact runtime `exercise-details.json`, keyed by the same exercise UUIDs, supplies normalized equipment, full primary/secondary muscle lists, activity type, level, force, mechanic, and source instruction text. Unknown equipment stays null, distinct from bodyweight; missing instructions remain an empty list. Personal and retired exercise snapshots have no fabricated detail record.

Details are replaceable bundled content, never part of saved template/session exercise snapshots. Imported content retains its `pendingReview` provenance status; that audit field does not gate the exercise detail screen. The bundled source steps appear immediately as Default source steps, without asking users to review or approve them. A notice directly beside the instructions states that imported guidance has not been individually reviewed or professionally validated; it remains visible with personal edits derived from that source. This explicit product choice keeps default guidance usable without presenting it as professionally validated. Source attribution does not claim professional validation. Personal edits are stored separately and never mark the source content as reviewed.

Settings → Credits & Licenses reads the generated attribution manifest and displays the source, credit, pinned revision, review limitations, excluded photo policy, and full bundled license offline, without an account.

## Offline discovery

Add Exercise, in both template drafts and active workouts, searches names and recorded categories without case, diacritic, or repeated-whitespace sensitivity. Equipment, muscle, and activity-type filters combine with that search. Muscle matches either the primary or secondary source list; Unknown explicitly selects missing metadata and is not interpreted as bodyweight. Clearing metadata filters retains search; the no-results action clears both. Search preserves substring matching and adds punctuation-insensitive, reordered-token matches. Source record names and whole-phrase abbreviations (OHP, RDL, DB, BB) are searchable aliases; equipment and execution variants retain separate names and IDs. Alias rows explain the matched name. When no direct or alias match exists in the available catalog, bounded spelling suggestions appear as Possible Matches with Similar spelling labels. Search never changes the query or selects an exercise automatically. Metadata filters apply to those resolved results; incompatible filters do not trigger new spelling guesses. Queries longer than 80 characters or eight tokens skip fuzzy search; unmatched tokens shorter than four characters are not guessed.

The picker groups matching rows as Favorites, Recently Trained, and All Exercises without duplicating an exercise. Favorites save immediately as a separate preference, including when a draft is later canceled, and display in their persisted preference order after search/filter selection. All Exercises retains search relevance order. Recently Trained uses the latest eight unique available exercise IDs with completed sets in completed history, ordered by recorded workout finish time; active exercises and unfinished sets do not qualify. Filtered recent rows are selected from that latest-eight list. Deleting history or restoring a backup recomputes the section.

The info button opens metadata without adding an exercise. Add Exercise is explicit on the detail page; returning or canceling does not select it. Details show default or personal steps first, followed by the selected name/category, equipment, full muscle lists, type, level, force, mechanic, and source credit. Unknown/custom metadata stays unavailable. Missing source steps stay empty and offer Add Steps; no guidance is fabricated. Images remain excluded. Existing custom creation remains available from a nonmatching search and registers only when its template or active workout is saved.

## Explicit replacements

Exercise options in template drafts and active workouts offer Replace Exercise. Similar Movements uses known matching activity type, overlapping primary muscles, compatible recorded force/mechanic, and at least one positively shared force/mechanic field. Shared equipment improves ranking. Rows explain the recorded metadata; unknown metadata does not imply equivalence. Search and Browse All include available personal exercises so users can choose alternatives outside the suggestions.

Choosing a candidate opens a replacement summary and optional Instructions & Details. Only Replace Exercise confirms the change. A template replacement remains a draft until Save Version; canceling the template discards it. An active replacement saves only to that session. Both preserve set count, reps, order, and superset membership, create fresh entry/set identities, and reset loads to zero. Active replacements clear original prescription targets. Templates, earlier versions, completed history, and session attribution stay unchanged. An active entry with any completed set cannot be replaced. Stale entries, unavailable candidates, blocked restore, and failed writes leave saved state intact. No additional storage migration is required.

## Personal steps

Edit Steps opens a local draft prefilled with the effective instructions. Users can edit, add, remove, and reorder steps. Save validates and atomically persists a personal override for that stable exercise UUID; Cancel discards the draft. Reset to Default Steps changes only the editor draft until Save, so Cancel also cancels a reset. Where no catalog defaults exist, Remove Personal Steps accurately describes an explicit, confirmed removal; Save commits it and Cancel discards it. Empty or invalid ordinary edits show actionable inline validation before persistence, while the core retains final validation. Identical default steps remove the personal override. A custom exercise or source entry without steps can receive personal instructions.

Personal steps apply wherever that exercise is inspected, independently of a template draft. They survive relaunch and SQLite backup/restore without rewriting the bundled catalog, immutable template versions, or recorded workout snapshots. Older snapshots have no overrides. The UI identifies default versus personal steps and preserves source attribution for the bundled content.

## Generation

Run from the repository root:

```sh
python3 scripts/generate_exercise_catalog.py
python3 scripts/generate_exercise_catalog.py --check
```

The generator reads committed inputs without network access and writes `exercise-catalog.json`, `exercise-details.json`, and `exercise-attribution.json` under `LiftLog/Core/Resources`, plus the nonbundled `vendor/free-exercise-db/exercise-provenance.json` audit. Swift Package Manager and the Xcode app bundle only the three runtime resources. No saved-data schema change is needed.

`vendor/free-exercise-db/content-policy.json` records the declared license, license checksum, credit, review state, exclusions, modifications, and checksum of the existing reviewed identity mappings. `normalization.json` contains explicit mappings for each supported source label; new unmapped labels fail generation. The generator verifies source/license/mapping checksums and rejects disallowed licenses, incomplete credit, unreviewed identity mappings, and generated media references. `--check` verifies all four outputs, including the offline license text in the manifest and the full nonbundled audit.

Runtime details retain only the source ID and upstream record ID needed by discovery, credits and aliases. The generated audit, keyed by the same exercise UUID, retains the pinned record URL/checksum and each content field's source field, original-value checksum, modifications and review state. Source ID resolves to the runtime manifest's revision, source checksum, declared author, license and credit. The audit is committed and checked for reproducibility, but is outside both app and Swift package resource directories; it is never decoded when opening the picker. Canonical field/record hashes use UTF-8 JSON with sorted keys, compact separators, and unescaped Unicode. The manifest also records the normalization input checksum, making the generated content traceable to its inputs.

The display category comes from the first primary muscle, rather than upstream's activity category (strength, stretching, etc.). Quadriceps, hamstrings, glutes, abductors, and adductors map to Legs; lats, traps, and middle/lower back map to Back. Other muscles retain their own category. All upstream activity types are included.

To update, choose and review an upstream commit, replace the vendor JSON and license from that exact revision, update the revision and checksum in `source.json`, review compatibility targets, regenerate, and run the checks and app build. Do not fetch an unpinned branch during builds.

## Compatibility

`vendor/free-exercise-db/legacy-ids.json` contains 103 reviewed upstream-to-existing UUID mappings. It contains identifiers and the original ten starter labels; it is not a second exercise dataset. Mapped exercises use upstream names and muscle categories except for those ten original app labels, which stay in the first ten positions to preserve starter templates and familiar naming.

The remaining 42 former entries have no confidently equivalent upstream target and are omitted from the bundled catalog. Saved instances of these entries become available in the picker through the personal catalog. Different equipment or execution variants are not automatically merged. For example, the upstream Goblet Squat uses a kettlebell, so it does not reuse the former Dumbbell Goblet Squat ID.

Templates, active workouts, and history embed complete exercise snapshots. Loading this catalog does not rename, delete, or rewrite those saved exercises, including the 42 retired picker entries. They can still be used through existing templates. The store backfills saved nonbundled exercises into a persistent personal catalog without changing their recorded snapshots. The picker and import matcher use the bundled catalog followed by personal entries, deduplicating case and whitespace with bundled names preferred. Newly saved custom exercises remain reusable after their source template is deleted or workout discarded; canceled drafts and imports do not add entries.

New exercises receive deterministic UUID v5 identities from a permanent namespace and the upstream ID. Names, sort order, and source array positions do not determine identity. Keep the namespace and compatibility mappings stable; if an upstream ID changes, explicitly preserve its previous UUID. Retired UUIDs must never be reassigned to unrelated movements.
