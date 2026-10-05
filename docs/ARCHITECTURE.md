# Architecture

## Product model

Lift Log is a local-first SwiftUI iPhone application targeting iOS 17 or later. Its primary loop is create a template → start a workout → enter weight and reps → complete sets → finish and review history.

The app is inspired by [Strong’s workout tracking features](https://www.strong.app/#features). It uses its own implementation and name.

## Code organization

- `LiftLog/Core`: Foundation-based models, workout operations, validation, and local storage.
- `LiftLog/App`: SwiftUI application entry point and store initialization.
- `LiftLog/Views`: native screens and reusable interface components.
- `Tests/LiftLogCoreTests`: automated tests for the core behavior.
- `Tests/LiftLogUITests`: Xcode UI tests for the template-to-history flow and relaunch recovery.
- `project.yml`: XcodeGen configuration for the iOS application.
- `Package.swift`: Swift package configuration for testing the core without launching an iOS simulator.

The iOS target compiles the core sources alongside the app sources. The Swift package exposes the same core code as `LiftLogCore` for tests. `WorkoutStore` is a main-actor observable object shared by the SwiftUI screens.

## Templates and sessions

An exercise has an identifier, name, and category. A template contains an ordered list of exercise entries, each with planned sets. A planned set specifies a weight and `targetReps`.

`ExerciseCatalog` loads 876 exercises from a bundled JSON resource generated from the public-domain free-exercise-db dataset. It is available offline on every launch, independently of saved workout data. Original starter identities and ordering are retained, and reviewed equivalent exercises reuse existing IDs. See [Exercise catalog](EXERCISE_CATALOG.md) for provenance, generation, and compatibility details.

`WorkoutStore.exercises` exposes the bundled catalog in its original order followed by persisted `personalExercises`. Personal entries deduplicate names by lowercasing and collapsing whitespace, with bundled entries preferred. New picker-created and unmatched imported exercises reuse an existing catalog identity when saved. Other supplied exercise snapshots keep their recorded metadata. Existing history is never rewritten.

A workout session is a separate snapshot with its own exercise entries and sets. Session sets store actual `reps` separately from an optional `targetReps` snapshot and carry a completion flag, while the session records its starting time, optional finishing time, and weight unit. Starting a workout copies target reps into the session and initially prefills actual reps with that target. Editing actual reps never changes the target. Starting a workout does not mutate the source template. A later template edit does not rewrite past workouts.

Only one workout is active at a time. Completed sessions are kept in history. Finishing filters out uncompleted sets and exercise entries with no completed sets, so history represents work actually performed.

Strong CSV imports create completed history sessions through a separate preview and batch-save flow. Import provenance is optional so existing snapshots remain compatible. Source units and time zones are explicitly confirmed, and exercise mappings are reviewed before saving. See [workout import](WORKOUT_IMPORT.md) for the adapter boundary, mapping rules, duplicate identity, and unsupported measurements.

Editing weight or target reps in the template editor, or weight or actual reps in the workout editor, applies both values to every set in that exercise entry. Set identifiers and completion flags remain independent. Other exercise entries, source templates, and past sessions are unaffected by active workout edits.

## Persistence

The store saves a relational SQLite database in `Application Support/LiftLog/workouts.sqlite` inside the app sandbox, using Apple’s system SQLite library. `WorkoutDatabase` handles version-1 tables for preferences, template/session records, ordered exercise snapshots, ordered sets, and personal exercises. `SQLiteConnection` owns short-lived connections and bound SQL parameters. Startup opens the working database with write access so SQLite can recover an interrupted transaction’s hot journal; incoming backup files are inspected read-only. Valid changes to the active workout are saved so that a user can resume after the app is closed.

On first launch after upgrading, the store decodes and validates an existing version-1 `workouts.json`, writes a complete database to a staging file, and moves it into place only after the transaction succeeds. The original JSON is preserved. An existing SQLite database takes precedence over JSON. A corrupt or unsupported database is never silently replaced by the legacy file.

Older version-1 files without `personalExercises` decode with an empty catalog. Migration backfills reusable nonbundled exercises from history, templates, and the active workout without rewriting their recorded exercise snapshots. The catalog joins the migrated database transaction. Saved personal entries are retained independently of their originating template or workout.

Legacy template `reps` fields decode as `targetReps` and are written using the new name on the next save. Older sessions retain their recorded reps with no target snapshot; targets are not inferred from templates that may have changed.

Template saves, active-workout saves, and imports register personal exercises only in the proposed snapshot. Import registration occurs after duplicate detection. Previewing or canceling drafts and skipped duplicate imports cannot add entries. Mutations validate and commit all affected tables in one SQLite transaction before publishing the next snapshot to in-memory state. A failed write leaves the prior state intact and exposes an error. On first launch, the store seeds Upper Body and Lower Body templates and an exercise catalog.

If an existing database or legacy JSON cannot be read, has an unsupported schema version, or fails validation, the store preserves the file and rejects mutations. A valid backup can be restored from Settings to recover during the same launch.

The core validates values before committing mutations. Weight must be finite and nonnegative; reps must be positive. Template and exercise names must contain non-whitespace text. Templates require at least one exercise and one set per exercise. Session and item identifiers must be unique within their respective collections.

Changing the unit preference converts template weights using `1 lb = 0.45359237 kg`. Active and finished sessions preserve their original unit and recorded weights. The active session’s start time and template reference also remain fixed when its editable values change.

`CloudBackupManager` owns observable backup settings, progress, scheduling, and errors. `CloudBackupRepository` performs iCloud file coordination and SQLite snapshot creation on a background actor. Automatic backups are optional, debounce edits for five seconds, and run at most once per 15 minutes while foregrounded; leaving the app flushes pending changes. Local saves succeed independently of cloud availability. The app never opens its working database inside iCloud Drive.

Backups are immutable SQLite files in the iCloud container’s `Documents/Backups` directory. SQLite’s backup API captures committed journaled data and converts the result to a standalone rollback-journal database. Unique names include creation time, installation identity, and a UUID so devices never overwrite one another. A metadata query discovers undownloaded backups; explicit download and coordinated reads stage restore files locally.

Restoring blocks edits, checks database identity/schema/integrity and workout validation, preserves the previous local data in a `before-restore-<UUID>.sqlite` recovery file, and atomically replaces the database before publishing state. Restores replace the complete dataset; there is no cross-device merge. Retention keeps the newest 30 uploaded snapshots per installation and all pending uploads, leaving other installations’ files alone. Backup preference, installation identity, and last-save time live in device-local UserDefaults. See [storage and backup setup](STORAGE.md) for signing, cloud behavior, and physical-device checks.
The optional Assistant adds direct OpenAI networking and protected ChatGPT account registrations. Workout data remains local; signing in does not synchronize it or import ChatGPT conversations. See [ChatGPT assistant](CHATGPT_ASSISTANT.md) for the authentication and agent boundaries. Backup/export and migration policies will need explicit design before adding sync or materially changing the saved schema.

## Boundaries for later work

The core contains workout rules and persistence; SwiftUI screens own navigation and temporary form input. Keep new business rules in the core so they can be tested without simulator UI automation.

Rest timers, personal-record tracking, cloud sync, Apple Health, and Apple Watch remain outside the implementation. Unit handling must preserve the meaning of saved weights when adding conversion or additional measurement types.
