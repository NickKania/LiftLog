# Lift Log

A native SwiftUI iPhone app for creating reusable workout templates and logging sets as you train. Inspired by the workout tracking features of [Strong](https://www.strong.app/#features); this project is independent and is not affiliated with Strong.

The first version focuses on templates, workout execution, and a local workout history. There are no accounts or backend services.

## Features

- Create and edit templates with exercises, set weights, and repetition counts.
- Find exercises in the searchable catalog or add an exercise by name.
- Start a workout from a template and record the weight and reps for each set.
- Mark sets complete and save finished workouts to history.
- Resume a saved active workout after reopening the app.
- Choose pounds or kilograms.

The Workout tab holds templates and the current workout. The History tab shows finished sessions; settings are available from the Workout screen.

The first launch includes Upper Body and Lower Body templates. Changing units converts planned template weights; active and finished workouts retain their recorded unit.

## Build and run

Requirements: Xcode with an iOS simulator runtime, iOS 17 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open LiftLog.xcodeproj
```

Select the `LiftLog` scheme and an iPhone simulator, then Run. For a physical iPhone, select your development team under the app target’s Signing & Capabilities settings. The project does not prescribe a signing team.

The XcodeGen configuration in `project.yml` is the project source of truth; regenerate the Xcode project after changing it.

## Tests

The Foundation-based workout core also builds as a Swift package:

```sh
swift test
```

See [testing guidance](docs/TESTING.md) for the Xcode UI test command, simulator checks, and manual acceptance checklist. See [architecture](docs/ARCHITECTURE.md) for the data model and persistence decisions.

## Data and scope

Templates, settings, history, and the active workout are stored on the device in `Application Support/LiftLog/workouts.json` inside the app sandbox. Finishing a workout saves only completed sets to history. Uncompleted sets are excluded from the finished record; templates remain reusable.

This initial app does not include cloud sync, Apple Health integration, Apple Watch support, charts, or social features. Local data is tied to the app installation; deleting the app removes its local files.
