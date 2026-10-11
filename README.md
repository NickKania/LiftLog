# Lift Log

A native SwiftUI iPhone app for creating reusable workout templates and logging sets as you train. Inspired by the workout tracking features of [Strong](https://www.strong.app/#features); this project is independent and is not affiliated with Strong.

The first version focuses on templates, workout execution, and a local workout history. There are no app accounts. Workouts save locally, with optional backups through your Apple iCloud Drive account.
Templates, workout execution, and history work locally without an account. The optional Assistant connects to ChatGPT so eligible users can use their subscription for workout insights and planning.

## Features

- Plan your next workout by saving a new template version with increased weight or reps; the newest version becomes the default.
- Browse earlier template versions and start a workout from any saved prescription.
- Find exercises in the searchable, offline catalog of 876 bundled exercises plus your saved personal exercises, or add an exercise by name.
- Start a workout from a template and record the weight and actual reps for each set, with the original planned weight and reps shown alongside.
- Mark sets complete and save finished workouts to history.
- Delete a saved workout by swiping left in History and confirming Delete Workout.
- Resume a saved active workout after reopening the app.
- Follow rest countdowns, total workout time, and the next exercise and set on the Lock Screen and Dynamic Island with a Live Activity.
- Back up to iCloud Drive automatically or on demand, and restore a selected backup from Settings.
- Choose pounds or kilograms.
- Explore the Health dashboard for workout consistency, a calendar activity map, duration statistics, lifting-weight progression and records, and optional Apple Health calories and heart rate by template.
- Import completed workouts from Strong CSV exports, with exercise matching, session selection, and duplicate protection.
- Connect a ChatGPT account, select an available model, and ask questions about your workout data.
- Keep saved assistant chats with editable Luna-generated titles, and run several conversations at once.
- Generate graphs from recorded workouts and share them as images.
- Explicitly tag Apple Health data for an active or completed session to ask about heart rate, active energy, and steps or visualize those measurements.
- Review and apply assistant proposals to create workouts or templates and add, change, or remove their exercises.

The Workout tab holds templates and the current workout. The History tab shows finished sessions, the Health tab tracks training trends, and the Assistant tab contains saved ChatGPT conversations. The Settings tab holds weight units, assistant preferences, and iCloud Drive backups.

See [ChatGPT integration](docs/CHATGPT_ASSISTANT.md) for eligibility, sign-in, data sharing, and current image-generation limitations. The integration uses the documented subscription OAuth flow and does not require an API key.

Use **History → Import Workouts** to choose a Strong CSV, confirm its weight unit and time zone, and review the sessions before saving. See [workout import](docs/WORKOUT_IMPORT.md) for field mapping, unsupported data, and duplicate handling.

The first launch includes Upper Body and Lower Body templates. Changing units converts planned template weights; active and finished workouts retain their recorded unit.

## Build and run

Requirements: Xcode with an iOS simulator runtime, iOS 17 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open LiftLog.xcodeproj
```

Select the `LiftLog` scheme and an iPhone simulator, then Run. Public signing defaults live in `Config/Signing.xcconfig`: bundle ID `com.liftlog.app` and no development team. For a physical iPhone or distribution build, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`, then set your Apple development team and registered app bundle ID. The widget uses the app's bundle ID followed by `.Widgets`. The local file is ignored by Git and read at build time; do not commit it or copy its values into the generated project. See [storage and backup setup](docs/STORAGE.md) for iCloud provisioning.

For TestFlight, commit the generated project, `project.yml`, and public configuration files, then configure your archive/distribution workflow and tester group in App Store Connect or Xcode Cloud. A cloud checkout does not contain your ignored local signing file: supply `DEVELOPMENT_TEAM` and `LIFTLOG_BUNDLE_IDENTIFIER` as build-setting overrides, or create `Config/Signing.local.xcconfig` in your CI setup before the build. For Xcode Cloud, create that file from CI-provided values in a post-clone script. Register both your app bundle ID and its `.Widgets` extension ID in Apple Developer before building. Keep both HealthKit purpose strings (`NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription`) in `project.yml`, even though the integration only requests read access, so App Store upload validation succeeds.

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

Deleting the app removes local files. Uploaded iCloud backups remain available for restoration after reinstalling. The app does not include cloud sync, an Apple Watch app, or social features. ChatGPT credentials are stored separately in the iOS Keychain; disconnect from Settings before uninstalling if you want to end the renewable session.

Apple Health is read-only. In **Health → Activity**, explicitly load readings for the selected workout range to see available active calories and average heart rate by template. Dashboard readings stay in memory on the device; they are not added to chats or workout backups. Missing Health readings are shown as unavailable, not estimated. Overlapping calorie readings are excluded with a warning to avoid double-counting; partial overlaps can leave some calories uncounted. Switching the selected range clears readings even if it contains the same workouts. The Weight section tracks lifting weights from completed sets, converted to your preferred unit; it does not track body weight.

Apple Health is separately opt-in for each assistant message. In **Assistant → @ → Apple Health**, select a session, then send your question. Only that session’s available heart rate, active energy, and step measurements are read; an active session ends at the request time. Ordinary workout tags never include Health data. Health-based replies and charts are temporary and excluded from saved chats, automatic titles, later requests, and workout backups. Tag Health again to refresh or ask a follow-up. See [Health tagging](docs/CHATGPT_ASSISTANT.md#tagging-apple-health) for permissions and limitations.
