# Local-first training implementation plan

Last reconciled with the working checkout: **October 14, 2026**. Milestone 0 and Milestone 1C are implemented. Other milestones remain incomplete; existing foundations and outstanding scope are identified below. “Implemented” describes this checkout, including uncommitted work, and does not imply a released build.

Based on weight-app commit `997aef7` and the [openGym v1.4.1 source](https://github.com/DuarteSantos8/openGym/tree/464355ef43d4c8f8a4e0bb6db9c2af7f240593b5), researched October 11, 2026. The implementation remains native SwiftUI with local SQLite. Adopt useful training behavior while preserving versioned prescriptions and trustworthy actual-work records.

## Implementation status

| Milestone | Status | Currently implemented | Remaining scope |
| --- | --- | --- | --- |
| 0 — Catalog policy and provenance | **Implemented** | Pinned catalog, generated metadata/instructions/provenance, license attribution, offline Credits & Licenses at the bottom of Settings | No remaining implementation in this milestone; individual source-content review and photo rights remain unresolved |
| 1A — History correction | **Partial foundation** | History viewing, rename/delete, Strong CSV import with preview and duplicate protection | Completed-set edits, date/duration correction, notes, manual past-workout entry, recovery/undo for corrections |
| 1B — Native progress | **Partial foundation** | Health dashboard lifting-load trends, maximum completed-set weights, consistency heatmap and activity summaries | Dedicated Progress view, broader load/rep trends and defined PRs, optional estimated 1RM, metric definitions shared with assistant tools |
| 1C — Catalog discovery | **Implemented** | Filters, details, default/personal steps, favorites/recents, aliases, spelling suggestions, explicit template/active-workout replacements | No remaining implementation in this milestone |
| 1D — Exports and sharing | **Planned** | SQLite backup/restore exists as the recovery mechanism | Versioned JSON, completed-set CSV, template/version sharing, printing/PDF |
| 2 — Faithful training records | **Partial foundation** | Template versions, active target snapshots, independent completion flags, basic supersets, persisted rest timers and Live Activities | Independent numeric row edits, retained skipped/unperformed outcomes, set roles/effort, load semantics, advanced structures and round rest |
| 3 — Explainable progression | **Planned** | Manual Plan Next Workout and immutable version saves with stale-draft protection | Deterministic progression rules, equipment-aware rounding, explanations and acceptance flow |
| 4 — Programs and scheduling | **Planned** | Starter Upper Body/Lower Body templates | Routine rotation, calendar scheduling, starter programs and workout-day reminders |
| 5 — Equipment and measurement modes | **Planned** | Weight/reps logging, exercise reordering, basic set add/delete and rest-end sound | Equipment profiles/calculator, timed/cardio modes, remaining training controls and undo |
| 6 — Body, muscle and media | **Planned** | Read-only, session-scoped Health data; catalog muscle metadata | Body records/photos, body-weight reads, muscle-volume views and labeled estimates |
| 7 — Interoperability and extensions | **Planned** | Strong CSV import, ChatGPT assistant and standalone iCloud backups | Additional adapters/exports, optional assistant integrations and separately designed cross-device sync |

“Partial foundation” means related behavior is usable today, but the milestone's acceptance criteria are not yet met. Existing foundations in planned milestones do not implement their proposed new behavior. See [architecture](ARCHITECTURE.md), [workflow coverage](WORKFLOWS.md), and [catalog behavior](EXERCISE_CATALOG.md) for the current contracts.

## Product constraints

- All basic logging, discovery, progress and deterministic planning work offline without an assistant account.
- **free-exercise-db is the selected external exercise-data source for this plan.** Use its existing pinned 876-exercise snapshot for names, instructions, equipment, muscles and other catalog metadata. Retain commit `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`, its checksum and existing UUID mappings; update the upstream revision only through the documented catalog-update workflow.
- Exercise content must be openly reusable. Follow [Open exercise-data sources](EXERCISE_DATA_SOURCES.md) for separate text/media rights, attribution and provenance. Everkinetic, wger and Wikimedia Commons remain research alternatives and are not planned imports.
- Preserve stable exercise/template/session identities, immutable template versions, recorded units and historical snapshots.
- Keep transactional mutations, active-session recovery, standalone iCloud backups and explicit review of assistant proposals.
- Treat backup restoration and multi-device synchronization as different operations. Restoration continues to replace the complete dataset until a separately designed merge system exists.
- Derived metrics and next-workout suggestions share one local implementation between SwiftUI and assistant tools. Stored workout facts remain authoritative.

## Milestone 0 — Catalog policy and provenance

**Status: implemented.** The content foundation enriches the selected free-exercise-db catalog without rewriting saved exercise snapshots.

- [x] Retain the pinned 876-exercise snapshot, original starter identities/order and existing UUID mappings.
- [x] Record field-level provenance, source revision/checksums, the bundled Unlicense and content review status.
- [x] Generate separate UUID-keyed equipment, muscle, instruction and source-detail resources plus an attribution manifest; check generation offline against pinned inputs.
- [x] Normalize metadata with explicit mappings and preserve unknown values.
- [x] Provide offline Credits & Licenses, including the full license, at the bottom of Settings.
- [x] Exclude catalog photographs and document unresolved media rights separately from declared text/data licensing.

Remaining content work: imported instructions and metadata retain `pendingReview` provenance; implementation completion does not mean each source field has been professionally reviewed. Default steps are visible immediately, with optional personal editing and no user review/approval gate. Photo-rights clearance is not an outstanding implementation requirement because redistributed catalog photos remain excluded from this plan.

Acceptance: reproducible generation from committed snapshots, no catalog network requests, existing identities unchanged, unknown/disallowed media absent, credits accessible offline. Every surfaced new instruction has recorded source/license and content review status. A separate reviewer can trace it back to a pinned input.

## Milestone 1 — More useful history and discovery

These slices can ship separately once their own prerequisites pass.

### 1A. Correct and complete history

**Status: partial foundation; correction features remain.** History viewing, rename/delete and reviewed Strong CSV import already exist. They do not provide arbitrary completed-workout editing or manual past-workout entry.

Add completed-workout editing, date/duration correction, session/exercise notes and manual past-workout entry. Preserve IDs and import provenance. Save validated corrections atomically, with review and a recoverable previous record or undo path. Do not use reimporting as the correction mechanism.

Acceptance: edit/backdate a workout, relaunch and recover the result; invalid input or a failed save changes nothing; active workouts and templates are unaffected; duplicates remain protected; derived progress recalculates after correction or deletion.

### 1B. Native progress

**Status: partial foundation; expanded progress features remain.** The existing Health dashboard shows per-exercise heaviest completed-set trends, maximum weights within a date range, a consistency heatmap and activity summaries, with recorded-unit conversion. Its Weight section refers to lifting weight, not body weight. The dedicated Progress experience, broader PR/rep metrics, estimated 1RM and shared metric definitions below remain to be implemented.

Add a dedicated Progress view with exercise load/rep trends, transparently defined PRs, a conservative estimated-1RM option and an activity calendar. Start with completed sets in the existing model. Version or label metric definitions so later warm-up and measurement semantics do not silently change their meaning.

Acceptance: results agree across mixed pounds/kilograms, exercise identity variants remain separate, missing dates stay missing, and corrections/deletions recompute records. Charts and PR lookup work without ChatGPT or a network connection. Assistant graph tools use the same calculations.

### 1C. Make the existing catalog easier to use

**Status: implemented.** All planned discovery slices are available offline, using the existing 876 entries and reusable personal exercises.

- [x] Combine equipment, muscle and activity-type filters with search, including explicit Unknown values and clear/reset actions.
- [x] Inspect metadata, source credits and missing-content states without automatically adding an exercise.
- [x] Show default source steps immediately; edit/add/remove/reorder personal steps in a draft, cancel changes or reset to defaults, and save across relaunch and backup/restore.
- [x] Save favorites independently of template drafts and show Recently Trained from completed history sets.
- [x] Search source names and common abbreviations (OHP, RDL, DB, BB), with alias explanations and distinct exercise identities.
- [x] Offer bounded typo-tolerant results labeled Possible Matches/Similar spelling while retaining filters, the typed query and explicit custom creation.
- [x] Suggest similar movements from recorded metadata, with search/browse alternatives and explicit replacement confirmation.
- [x] Replace an exercise in a template draft; save a new version through the existing editor or cancel the draft without changing the template.
- [x] Replace an active entry only when it has no completed sets; persist only to the current workout.
- [x] Preserve set count, reps, order and superset membership, reset replacement loads to zero, clear active targets, and protect earlier versions/history against stale choices and failed writes.

Remaining implementation: none within the planned 1C scope. Missing source instructions stay unavailable rather than being fabricated; users can supply their own steps. Additional external catalogs and catalog artwork are not part of this milestone.

Acceptance: searches and details work offline; custom exercises remain reusable; existing templates/history retain their names and IDs; unknown fields have clear fallbacks; suggested swaps never silently rewrite a plan. Missing instruction coverage does not require fabricated text.

### 1D. Portable exports and plan sharing

**Status: planned; not implemented.** Standalone SQLite backup/restore already exists, but is not the portable JSON/CSV or template-sharing workflow described here.

Add versioned full-data JSON and completed-set CSV export through Files/Share. Share a template/version as a small file, with attributed exercise content when included. Keep SQLite snapshots as the recovery format. Add plan printing/PDF as a follow-up export.

Acceptance: JSON round-trip preserves units, IDs, version history and supported fields; CSV documents time zones and semantics; an old supported archive remains importable; no account credentials or temporary Health attachments enter exports.

## Milestone 2 — Faithful training records

**Status: partial foundation; richer record semantics remain.** Immutable template versions, copied active-session targets, completion flags, basic superset membership, persisted rest countdowns and Live Activities already exist. Numeric edits currently propagate across an exercise's sets (only incomplete sets during a workout), and finishing removes incomplete sets. Basic grouping does not yet drive round order/rest. Those behaviors still need the changes below.

This is the prerequisite for reliable progression and effort-based muscle views.

- Make row values independently editable. An intentional “apply to remaining sets” action can preserve the existing convenience without forcing it on every edit.
- Preserve the full started prescription and explicit skipped/unperformed outcomes. Keep actual completed work distinct, rather than counting an unchecked set as zero performance or deleting all evidence of planned work.
- Add work/warm-up roles, optional RIR/RPE, set failure flags, per-exercise rest and named supersets with round rest.
- Represent load meaning explicitly for bodyweight/added weight, assisted exercises, unilateral reps and one-dumbbell versus combined load.
- Add drop, rest-pause, pyramid and back-off structures incrementally after the basic set roles/grouping are reliable.
- Extend persistence, backups, import warnings/retained measurements, assistant schemas and Live Activity next-set/rest projection together.

Acceptance: editing one row preserves others; warm-ups are excluded from work-set metrics by definition; incomplete workouts cannot be mistaken for completed prescriptions; existing backups migrate without inferred effort or invented targets; supersets drive the expected order and rest timer.

Imported or legacy sessions with unknown prescriptions must not be used to prove full target completion. Show that limitation rather than inferring planned sets from a later template.

## Milestone 3 — Explainable progression

**Status: planned; rules not implemented.** Plan Next Workout already supports manual comparison/editing and version saves. It does not yet calculate deterministic raise/hold/deload suggestions.

Start with opt-in linear and double progression. A pure core function reads the selected rule, original prescription and completed/skipped outcomes to produce raise/hold/deload targets and a plain-language reason. Respect equipment increments and explicit unit/load semantics.

Present the result in Plan Next Workout. Review and acceptance saves a new immutable template version, using the existing stale-draft protection. Starting from an older version or correcting history must not mutate an existing prescription implicitly.

Follow with Greyskull, triple progression and timed progression after their measurement modes exist. Add planned deload weeks when program scheduling is available.

Acceptance: missed reps or skipped prescribed sets cannot raise load; unqualified history does not claim success; rounding respects equipment; corrections can change the next suggestion; rejection leaves the default unchanged; a stale review cannot overwrite newer planning. Assistant and manual planning show the same rule result.

## Milestone 4 — Programs and flexible scheduling

**Status: planned; not implemented.** Existing Upper Body/Lower Body starter templates do not provide a program rotation or schedule. Rest-end notifications exist; workout-day reminders remain new work.

Add a routine rotation first, referencing stable template IDs. Then add fixed weekday scheduling, date-specific moves, configurable week start, rest days, missed-day notes and optional local workout-day reminders. Provide editable PPL, Upper/Lower, Full Body and 5×5 starter programs written or imported under documented open-content terms.

Acceptance: a skipped day does not advance a rotation; only a qualifying finish advances it; duplicate imports do not advance twice; edits/backdated sessions have defined effects; deleting a scheduled template produces a repairable state; moving one session does not change the weekly definition; reminders follow local dates and permissions.

## Milestone 5 — Equipment and more measurement modes

**Status: planned; new modes and equipment features not implemented.** Current training supports weight/reps, exercise reordering, basic set add/delete and a rest-end sound. Equipment inventories, timed/cardio records, undo and the additional controls below remain.

Add gym equipment profiles, owned dumbbell loads and bar/plate inventories with a plate calculator. Add timed holds/carries and cardio duration/distance/speed, then incline where applicable. Extend import adapters only when their fields have a faithful destination.

Add focus/card display options, exercise jump navigation, collapse completed exercises, set copy/delete with Undo and configurable rest-end sounds/flash where they improve native training flows.

Acceptance: targets land on achievable loads; assisted progression follows the correct direction; timed/cardio work is not forced into reps or estimated-1RM calculations; undo restores identity and values; Live Activities still show the correct next action; import limitations remain visible.

## Milestone 6 — Body, muscle and media

**Status: planned; body/media features not implemented.** Catalog muscle metadata and read-only session-scoped heart-rate/energy/steps access exist. Manual body records, body-weight Health reads, progress photos and muscle-volume/recovery views remain. Existing lifting-weight charts are not body-weight tracking.

- Add manual weigh-ins and goal trends, followed by body measurements and local progress photos with a timeline/before-after view. Keep measurement records separate from workout sessions.
- Add optional, separately consented Apple Health body-weight reads. Existing session-scoped heart-rate/energy/steps tagging remains available; workout/weight writes are a separate extension.
- Define photo/media file retention, deletion and backup/export inclusion before shipping capture. User-owned custom media is separate from redistributed catalog content.
- Add muscle-volume views once catalog mappings and set types are trustworthy. Follow with clearly labeled recovery/detraining estimates and, later, structural-balance ratios. Do not present inferred recovery as a measured medical fact.
- Keep catalog discovery and instructions based on free-exercise-db. External catalog artwork is not part of this plan; retain text-only exercise details where media is unavailable. User-owned custom media remains planned as a separate feature.

Acceptance: local body records and photos survive relaunch/backup round-trips; missing measurements are not zero-filled; Health permission refusal preserves manual use; media attribution survives exports; charts identify estimates; artwork always matches its exercise variant.

## Milestone 7 — Interoperability and optional extensions

**Status: planned; extensions not implemented.** Strong CSV import, the ChatGPT assistant and standalone iCloud backup/restore already exist. Additional adapters, providers/exports and cross-device merge/sync remain separate work.

Add FitNotes/Hevy and Apple Health weight-file adapters; follow with shared workout images, richer plan PDF and optional Garmin `.fit` export. Evaluate more assistant providers/local endpoints and a read-only local assistant interface only when there is a concrete need.

Design cross-device sync separately, including edit/deletion conflict rules, provenance, offline retries and migrations. Keep it optional. Server administration, invite/passkey accounts, Docker infrastructure, broader platform support and localization are later product choices rather than prerequisites for this iOS plan.

## Validation and sequencing

Latest completed implementation validation (October 14, 2026): **318 core tests passed**, including 21 new search/alternative/replacement tests; **eight targeted native UI scenarios passed** (five new search/swap tests and three discovery/superset regressions). The final iOS Simulator build, catalog generator `--check` and diff checks passed. Earlier catalog, credits and personal-step UI verification is recorded in [Testing](TESTING.md).

Before/after running-app screenshots were captured and inspected on iPhone 13 mini, iOS 26.5, including light/dark appearance and accessibility XXXL; native UI tests ran on an isolated iPhone 17, iOS 26.5. The iOS 17 runtime and physical-device integrations were not reverified. These results describe the completed implementation runs, not a fresh test run for this documentation update.

Use the existing [testing workflow](TESTING.md). For each slice, cover its new core rules, persistence/backup compatibility and one representative native user flow. Run physical-device checks for notifications, Live Activities, iCloud, Health and media capture when those features change. Do not repeat the entire test matrix for documentation-only work.

Milestones 0 and 1C are complete. The remaining independent Milestone 1 slices are **1A history correction, 1B expanded native progress and 1D exports/sharing**. The critical chain is **preserved prescription + richer set semantics → progression → equipment-aware expansion and effort-based muscle estimates**. Scheduling is a separate layer over stable template IDs. Media expansion is optional and must not delay an offline text/metadata release.
