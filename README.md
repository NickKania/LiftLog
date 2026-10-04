# Lift Log

A native SwiftUI iPhone app for creating reusable workout templates and logging sets as you train. Inspired by the workout tracking features of [Strong](https://www.strong.app/#features); this project is independent and is not affiliated with Strong.

The first version focuses on templates, workout execution, and a local workout history. There are no app accounts. Workouts save locally, with optional backups through your Apple iCloud Drive account.

## Features

- Create and edit templates with exercises, set weights, and target reps.
- Find exercises in the searchable, offline catalog of 876 bundled exercises plus your saved personal exercises, or add an exercise by name.
- Start a workout from a template and record the weight and actual reps for each set, with the original target shown alongside.
- Mark sets complete and save finished workouts to history.
- Resume a saved active workout after reopening the app.
- Back up to iCloud Drive automatically or on demand, and restore a selected backup from Settings.
- Choose pounds or kilograms.
- Import completed workouts from Strong CSV exports, with exercise matching, session selection, and duplicate protection.

The Workout tab holds templates and the current workout. The History tab shows finished sessions. The Settings tab holds weight units and iCloud Drive backups.

Use **History → Import Workouts** to choose a Strong CSV, confirm its weight unit and time zone, and review the sessions before saving. See [workout import](docs/WORKOUT_IMPORT.md) for field mapping, unsupported data, and duplicate handling.

The first launch includes Upper Body and Lower Body templates. Changing units converts planned template weights; active and finished workouts retain their recorded unit.

## Build and run

Requirements: Xcode with an iOS simulator runtime, iOS 17 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open LiftLog.xcodeproj
```

Select the `LiftLog` scheme and an iPhone simulator, then Run. For a physical iPhone, select your development team under the app target’s Signing & Capabilities settings. Enable iCloud Documents and register/select the `iCloud.com.liftlog.app` container for that team. The project includes the entitlements but does not prescribe a signing team. See [storage and backup setup](docs/STORAGE.md).

The XcodeGen configuration in `project.yml` is the project source of truth; regenerate the Xcode project after changing it.

## Tests

The Foundation-based workout core also builds as a Swift package:

```sh
swift test
```

See [testing guidance](docs/TESTING.md) for the Xcode UI test command, simulator checks, and manual acceptance checklist. See [architecture](docs/ARCHITECTURE.md) for the data model and persistence decisions.

## Data and scope

The exercise catalog comes from [free-exercise-db](https://github.com/yuhonas/free-exercise-db), published under the Unlicense. A pinned dataset and its license are included in this repository. See [catalog provenance and generation](docs/EXERCISE_CATALOG.md) for source details and compatibility with saved workouts.

Custom exercises become reusable after saving a template, active workout, or import. They remain in your personal catalog after deleting a template or discarding its workout. Canceling a draft or import review adds nothing.

Templates, personal exercises, settings, history, and the active workout are stored on the device in `Application Support/LiftLog/workouts.sqlite` inside the app sandbox. Finishing a workout saves only completed sets to history. Uncompleted sets are excluded from the finished record; templates remain reusable.

Existing `workouts.json` data migrates automatically on first launch; the original JSON remains untouched. Open **Settings → iCloud Drive Backups** to enable automatic backups, back up now, or restore a saved snapshot. Backups include your active workout and can be restored on another device using the same Apple account. iCloud handles upload after the snapshot is saved, including when connectivity returns.

Deleting the app removes local files. Uploaded iCloud backups remain available for restoration after reinstalling. This version does not merge changes between devices or include Apple Health integration, Apple Watch support, charts, or social features.
