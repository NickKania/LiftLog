# Testing

## Automated verification

Run the core tests from the repository root:

```sh
swift test
python3 scripts/generate_exercise_catalog.py --check
```

These tests exercise workout behavior and persistence through the `LiftLogCore` package. They do not validate SwiftUI layout, keyboards, navigation, signing, or device installation.

Catalog coverage verifies all 876 bundled entries load, original starter identities and order remain stable, matched exercises reuse existing IDs, and retired exercise snapshots survive in templates, active workouts, and history. The generator check verifies the resource matches the pinned upstream dataset and reviewed compatibility mappings without accessing the network.

The core suite passes 49 XCTest cases, including six unit tests for the numeric parsing used by the SwiftUI set editor and ten additional backend flow tests. Coverage includes template validation and persistence, independent session snapshots, relaunch recovery, completion filtering, stale session edits, history ordering, unit conversion and overflow, atomic save failure recovery, and invalid saved-file protection. See the [workflow coverage map](WORKFLOWS.md) for the user and backend flows.

Eleven import tests use `Tests/LiftLogCoreTests/Fixtures/strong_workouts.csv`, the supplied Strong export, to verify every exercise, weight, rep value, timestamp, duration, and excluded rest record. Synthetic cases cover quoted CSV, BOM/CRLF, malformed data, unsupported measurements, explicit units/time zones, exercise overrides, selected subsets, duplicate imports after reload, and atomic write failures. `WorkoutImportUITests` adds three UI tests covering cancellation, single/multiple selection, matching, unit preservation during navigation, saving, relaunch, and duplicate detection using a DEBUG-only synthetic fixture.

Generate and build the iOS project separately:

```sh
xcodegen generate
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The `LiftLogUITests` Xcode target, under `Tests/LiftLogUITests`, contains nine simulator UI integration tests. They exercise template creation and validation, set completion, resume after relaunch, finishing, history navigation, catalog search and custom exercises, discard confirmation, unit preferences, and workout imports. Run it with an installed iPhone simulator, for example:

```sh
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Replace `iPhone 17` with an available simulator name from `xcrun simctl list devices available`. The UI suite uses a data file separate from normal app data and resets it at the start of each test. Run the UI tests serially because they share that testing file in the app sandbox (`-parallel-testing-enabled NO`). The two existing UI tests and four workflow tests each passed on the iPhone 17 Pro simulator (iOS 26.5) across separate runs. A clean combined run was blocked by intermittent test-runner exits and a final simulator launch failure (`FBSOpenApplicationErrorDomain Code=6`, preflight reason `Busy`). The final per-test app cleanup change remains unverified because that launch failed before tests began; rerun the suite on an idle simulator.

For interactive verification, open the project in Xcode and run it on an iPhone simulator.

## Manual acceptance checklist

### Templates

- Create a named template, add exercises, and configure multiple sets with weights and target reps.
- Save it, leave the screen, and confirm its entries remain intact.
- Edit the template and verify the changes appear when starting a new workout.
- Search for a catalog exercise, add a custom exercise by name, and remove an exercise or set from a template.
- Try blank names, negative weights, and zero reps; invalid values should not be saved.

### Workout execution

- Start a template and confirm its exercise order and planned sets are copied into the workout.
- Change any set’s weight and reps and verify both values appear across all sets of that exercise. Confirm original target reps remain visible and unchanged, other exercises retain their values, and each set keeps its own completion state.
- Toggle a set back to incomplete and verify it can be completed again.
- Add and remove exercises and sets in the active workout without changing the source template.
- Close and reopen the app during a workout; confirm valid edits and completion flags resume.
- Finish a workout with a mix of completed and uncompleted sets. Confirm only completed sets appear in history.
- Verify the source template still contains its original planned sets after finishing.
- Try finishing with no completed sets and confirm it does not create an empty history entry.
- Discard an active workout through its confirmation and verify no history entry is created.

### History, settings, and persistence

- Open a saved workout and verify its recorded weights, reps, and completed set count.
- Change pounds to kilograms and verify template weights convert. Confirm an already active or finished workout retains its original values and unit.
- Reopen the app and verify templates, history, settings, and any active workout persist.
- Confirm an active workout cannot be silently overwritten by starting another one.

### Workout imports

- Open History → Import Workouts and choose a Strong CSV from Files. Confirm units and the time zone used by the original export.
- Review the supplied example: one 55-minute workout, five exercises, 20 sets, and 20 excluded rest-timer rows. Inspect actual reps and weights before import.
- Change an exercise match, inspect its workout details, select a subset of a multi-session export, and verify only selected sessions are saved.
- Cancel during review and verify History is unchanged. Import successfully, relaunch, and verify the sessions persist; choosing the same export again must identify duplicates.
- Try malformed CSV, invalid numeric values, and timed/distance sets. Verify the flow displays errors or skipped-data warnings before saving.
- Check Files selection on a device or simulator with a CSV available. The synthetic UI-test fixture exercises review and saving without automating the system document provider.

### iPhone interface

- Check a small iPhone screen and a larger iPhone screen in the simulator.
- Enter decimal weights and integer reps with the on-screen keyboard; ensure save/complete controls remain reachable.
- Check light mode, dark mode, and larger Dynamic Type settings for clipped labels and controls.
- Use VoiceOver to check that set completion controls and numeric inputs have meaningful labels.

## Data isolation

Use a simulator installation for acceptance testing. Its local JSON state is separate from a physical iPhone’s app data. Removing the app resets its stored state, so only reset an installation whose data can be discarded.
