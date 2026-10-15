# Open exercise-data sources

Research date: October 11, 2026. free-exercise-db has been selected for the implementation plan. Other sources below are retained as research findings, not planned imports or verified matches between catalogs.

## Decision

Use **free-exercise-db as the sole external exercise-data source in the implementation plan**, retaining the existing pinned snapshot and stable exercise IDs. Expose its declared openly licensed text and metadata, without importing its photographs. Everkinetic, wger and Wikimedia Commons were researched but are not selected for implementation. Missing content remains missing rather than being filled from another catalog.

The requirement is **openly reusable content**, including the ability to modify and redistribute it, rather than simply a public download or a free API. Software and content licenses must be evaluated separately. This policy applies to exercise instructions, translations, starter-program descriptions and media.

## Selected source and researched alternatives

| Source | Suitable material | Licensing evidence | Proposed role |
| --- | --- | --- | --- |
| [free-exercise-db](https://github.com/yuhonas/free-exercise-db) | Names, equipment, muscles, categories, levels, mechanics and instructions | Repository publishes an [Unlicense](https://github.com/yuhonas/free-exercise-db/blob/f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5/LICENSE.md); photos have a separate unresolved provenance concern | Retain the existing catalog and IDs; enrich text/metadata first |
| [Everkinetic](https://github.com/everkinetic/data) | Steps, tips, muscle/equipment metadata and SVG/PNG pose illustrations | [CC BY-SA 4.0](https://github.com/everkinetic/data/blob/446bb9a3d0c3beb6b84f7c9d77dfc8af707a2ab6/LICENSE.md) | Researched alternative; not selected |
| [wger](https://github.com/wger-project/wger) | Community descriptions, translations, exercise metadata, images and videos | [Content licenses are per entry](https://github.com/wger-project/wger/blob/d09dd5e50e7dbeafe492b1a9b7c5cb1f1e89c73e/README.md#license), distinct from its AGPL application code | Researched alternative; not selected |
| [Wikimedia Commons](https://commons.wikimedia.org/wiki/Category:Fitness_animations) | Selected diagrams, photographs or movement animations | [Each file has its own license and creator information](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia) | Researched alternative; not selected |

### Existing free-exercise-db snapshot

The app already vendors commit `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`, with a recorded SHA-256 and bundled license. The local snapshot contains 876 entries. An audit of nonempty fields found:

| Field | Present | Product behavior when missing |
| --- | --- | --- |
| Instructions | 871 / 876 | Show that instructions are unavailable; do not invent them |
| Equipment | 799 / 876 | Preserve unknown as distinct from bodyweight or no equipment |
| Primary muscles | 876 / 876 | Show normalized source labels |
| Secondary muscles | 604 / 876 | Preserve an empty list; do not infer coverage |
| Level | 876 / 876 | Available for later filtering |
| Force | 846 / 876 | Optional metadata |
| Mechanic | 789 / 876 | Optional metadata |

These figures measure source-field presence, not professional validation or accuracy. Existing broad categories are derived from the first primary muscle; enrichment should preserve the full lists.

The maintainer states that the images' origins and royalty-free status are unknown in [image-license issue #2](https://github.com/yuhonas/free-exercise-db/issues/2). That prevents treating its repository-level license as sufficient evidence for those photos. The app currently neither bundles nor downloads them; maintain that boundary. The issue concerns imagery and is not, by itself, evidence that all text has the same problem. Record the declared text license and review any specific provenance concerns before promoting disputed content.

### Everkinetic

The following considerations apply only if this unselected source is reconsidered in a future plan.

Inspected revision: `446bb9a3d0c3beb6b84f7c9d77dfc8af707a2ab6`. Its [combined JSON](https://raw.githubusercontent.com/everkinetic/data/446bb9a3d0c3beb6b84f7c9d77dfc8af707a2ab6/dist/exercises.json) has 289 exercise records, with steps, tips, equipment, muscles and optional pose-image references. Some movements lack illustrations. This is a supplementary catalog, not a replacement promising 876 matching demonstrations.

Credit Everkinetic/Greg Priday, retain the source and license links, and record modifications. Any adapted artwork or text must retain the applicable ShareAlike terms. Keep the attributed content pack separately identifiable from app code. See the [CC BY-SA 4.0 terms](https://creativecommons.org/licenses/by-sa/4.0/).

Pilot 10–20 common movements before wider import. Verify that the drawing matches the exact equipment, position and variation; inspect legibility on light/dark backgrounds and narrow screens. Do not present alternating static poses as a validated demonstration of tempo or full movement. Review source text for terminology errors and unsuitable cues.

### wger

The following considerations apply only if this unselected source is reconsidered in a future plan.

Inspected application/schema revision: `d09dd5e50e7dbeafe492b1a9b7c5cb1f1e89c73e`. This pins the schema evidence, not the continuously changing hosted exercise database. Its [API serializers](https://github.com/wger-project/wger/blob/d09dd5e50e7dbeafe492b1a9b7c5cb1f1e89c73e/wger/exercises/api/serializers.py) expose license and attribution fields, including author, original object URL and derivative-source URL. Text translations, images and videos are separately licensed objects.

Use the [documented REST API](https://wger.readthedocs.io/en/latest/api/api.html) or an official export in a developer-run ingest process, then snapshot the approved subset for offline use. Resolve each license ID to its actual name and terms. Reject unapproved or incomplete attribution records; do not assume every record is CC BY-SA because wger is an open-source project.

The public site's bot-protection page prevented direct website inspection during this research. Official repository models, serializers and documentation were inspected; the live catalog count, completeness and mapping quality were not measured. Obtaining and reviewing a content snapshot remains implementation work.

### Wikimedia Commons

The following considerations apply only if this unselected source is reconsidered in a future plan.

Useful for a few missing illustrations, rather than a consistent replacement dataset. For every selected file, capture the file-description page, creator, exact license/version, original source and revision. Prefer CC0/public-domain, CC BY or CC BY-SA assets that pass the policy below. A page's general text license is not evidence of an embedded file's license. Review movement accuracy and any depicted-person restrictions separately.

## Sources to exclude or hold

| Candidate | Decision | Evidence |
| --- | --- | --- |
| openGym / Gym visual animations | Exclude from this open-content plan | [openGym's notices](https://github.com/DuarteSantos8/openGym/blob/464355ef43d4c8f8a4e0bb6db9c2af7f240593b5/NOTICE.md) separate commercial media rights from its code license |
| RepDB free dataset | Exclude under our redistribution requirement | Its [data license](https://github.com/RepDB/exercise-dataset/blob/d86f9612bee19db1069557bcac5c957021057eb9/LICENSE-DATA.md) permits attributed in-app use but prohibits redistribution as a dataset or dataset API; its code license does not override that |
| Flow Exercise Dataset | Hold for further provenance and content review | Its [own notice](https://github.com/ozansozuozgit/flow-exercise-dataset/blob/main/NOTICE.md) declares MIT data and CC0 artwork but documents missing generation records and unresolved origin/form-validation limits |
| ExerciseDB-derived mirrors and Kaggle reposts | No blanket approval | Evaluate the original text and media rights, not just a mirror's repository license or “free” label; downstream republishing does not establish authorship |
| Arbitrary website/YouTube scraping | Exclude | Public viewing is not an open-content license; references may be linked without copying their instructions or media |

## Content policy and ingest requirements

1. Accept documented public-domain/CC0 material, the existing Unlicense declaration, and explicit CC BY or CC BY-SA material whose precise version and requirements are recorded. MIT/BSD/Apache declarations can also qualify when they explicitly cover the data itself and provenance supports the grant. A license on API/client code alone does not qualify.
2. Exclude noncommercial-only, no-derivatives, app-only, no-dataset-redistribution, trial/evaluation and unknown-rights content. Attribution and ShareAlike are acceptable obligations. Preserve separately licensed packs and publish adapted content under its applicable terms.
3. Capture provenance separately for metadata, instructions/translations and each media asset. Minimum fields: source name/record ID, upstream URL, revision or retrieval date, content checksum, author, license identifier/URL, attribution, modifications and review status. The maintainer's declaration is evidence to retain, not a universal guarantee of underlying rights.
4. Run ingest only when deliberately updating the vendored snapshot. Generate bundles from committed inputs; no runtime dependence on a third-party exercise API, hotlinked media, API credentials or build-time downloads.
5. Keep stable Lift Log exercise UUIDs. Use reviewed crosswalks to attach supplemental source IDs. Never equate variants solely by similar names, silently overwrite history, or mix instructions from one variant with imagery from another.
6. Keep missing/ambiguous content missing. New instructions may be independently authored and reviewed, then released with an explicit open-content license; copying or translating restricted text does not make it open.
7. Generate an offline Credits/Licenses screen and a machine-readable attribution manifest from the same inputs. Exported shared content must carry the required attribution and licensing information.
8. Add meaningful generator checks for disallowed licenses, missing authors/attribution where required, changed checksums, unreviewed mappings, asset-path/hash mismatches and accidental inclusion of blocked image directories. Content correctness still needs a human review beyond these mechanical checks.

The product displays the pinned source steps as defaults without a user-facing review or approval requirement. Users may save personal edits separately from the source content and restore defaults. Source review status remains truthful audit metadata; displaying or customizing steps does not promote it to reviewed. Missing steps offer personal entry without fabricated defaults. Media coverage must not block this behavior.

## Instruction presentation decision

The current product deliberately exposes the pinned source guidance immediately, with optional personal edits and no review/approval task for the user. It contains 876 exercise records, of which 871 have nonempty instruction lists. Field presence is not a correctness assessment. The instruction section labels defaults as Default source steps and directly states that imported guidance has not been individually reviewed or professionally validated, including when personal edits derive from that guidance. Credits retain the same limitations; no source field is promoted from `pendingReview` by displaying or editing it.

Complete field-level hashes, modifications and review states live in the generated, committed `vendor/free-exercise-db/exercise-provenance.json` audit. The app bundles the smaller runtime content plus source/record IDs and the attribution manifest. The generator validates both outputs together; moving the audit out of the bundle does not remove provenance or imply review approval.
