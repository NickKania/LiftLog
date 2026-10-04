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

A workout session is a separate snapshot with its own exercise entries and sets. Session sets store actual `reps` separately from an optional `targetReps` snapshot and carry a completion flag, while the session records its starting time, optional finishing time, and weight unit. Starting a workout copies target reps into the session and initially prefills actual reps with that target. Editing actual reps never changes the target. Starting a workout does not mutate the source template. A later template edit does not rewrite past workouts.

Only one workout is active at a time. Completed sessions are kept in history. Finishing filters out uncompleted sets and exercise entries with no completed sets, so history represents work actually performed.

Strong CSV imports create completed history sessions through a separate preview and batch-save flow. Import provenance is optional so existing snapshots remain compatible. Source units and time zones are explicitly confirmed, and exercise mappings are reviewed before saving. See [workout import](WORKOUT_IMPORT.md) for the adapter boundary, mapping rules, duplicate identity, and unsupported measurements.

Editing weight or target reps in the template editor, or weight or actual reps in the workout editor, applies both values to every set in that exercise entry. Set identifiers and completion flags remain independent. Other exercise entries, source templates, and past sessions are unaffected by active workout edits.

## Persistence

The store saves a Codable JSON snapshot in `Application Support/LiftLog/workouts.json` inside the app sandbox. The snapshot carries schema version `1`, templates, unit preference, workout history, and the current active workout. Valid changes to the active workout are saved so that a user can resume after the app is closed.

Legacy template `reps` fields decode as `targetReps` and are written using the new name on the next save. Older sessions retain their recorded reps with no target snapshot; targets are not inferred from templates that may have changed.

Mutations validate and atomically write the next snapshot before publishing it to in-memory state. A failed write leaves the prior state intact and exposes an error. On first launch, the store seeds Upper Body and Lower Body templates and an exercise catalog.

If an existing file cannot be decoded, has an unsupported schema version, or fails validation, the store preserves the file and rejects mutations for that launch. Restore or move the affected file and relaunch to recover; it is not automatically replaced with fresh data.

The core validates values before committing mutations. Weight must be finite and nonnegative; reps must be positive. Template and exercise names must contain non-whitespace text. Templates require at least one exercise and one set per exercise. Session and item identifiers must be unique within their respective collections.

Changing the unit preference converts template weights using `1 lb = 0.45359237 kg`. Active and finished sessions preserve their original unit and recorded weights. The active session’s start time and template reference also remain fixed when its editable values change.

This version has no networking, account model, or remote synchronization. Backup/export and migration policies will need explicit design before adding sync or materially changing the saved schema.

## Boundaries for later work

The core contains workout rules and persistence; SwiftUI screens own navigation and temporary form input. Keep new business rules in the core so they can be tested without simulator UI automation.

Rest timers, exercise analytics, personal records, cloud sync, Apple Health, and Apple Watch are outside the initial implementation. Unit handling must preserve the meaning of saved weights when adding conversion or additional measurement types.
