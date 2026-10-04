# Testing

## Automated verification

Run the core tests from the repository root:

```sh
swift test
```

These tests exercise workout behavior and persistence through the `LiftLogCore` package. They do not validate SwiftUI layout, keyboards, navigation, signing, or device installation.

The initial core verification passed 16 XCTest cases with no failures. Coverage includes template validation and persistence, independent session snapshots, relaunch recovery, completion filtering, active workout protection, unit conversion, atomic save failure rollback, and invalid saved-file protection.

Generate and build the iOS project separately:

```sh
xcodegen generate
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The `LiftLogUITests` Xcode target, under `Tests/LiftLogUITests`, exercises template creation, set completion, resume after relaunch, finishing, and history navigation. Run it with an installed iPhone simulator, for example:

```sh
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test
```

Replace `iPhone 17` with an available simulator name from `xcrun simctl list devices available`. The UI test uses a separate testing data file and resets that test file at the start of the flow. The end-to-end UI test passed on the iPhone 17 Pro simulator (iOS 26.5), covering template creation, weight entry, completion, relaunch recovery, finishing, and history detail navigation.

For interactive verification, open the project in Xcode and run it on an iPhone simulator.

## Manual acceptance checklist

### Templates

- Create a named template, add exercises, and configure multiple sets with weights and rep counts.
- Save it, leave the screen, and confirm its entries remain intact.
- Edit the template and verify the changes appear when starting a new workout.
- Search for a catalog exercise, add a custom exercise by name, and remove an exercise or set from a template.
- Try blank names, negative weights, and zero reps; invalid values should not be saved.

### Workout execution

- Start a template and confirm its exercise order and planned sets are copied into the workout.
- Change a set’s weight and reps, complete it, and verify its completion state is visible.
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

### iPhone interface

- Check a small iPhone screen and a larger iPhone screen in the simulator.
- Enter decimal weights and integer reps with the on-screen keyboard; ensure save/complete controls remain reachable.
- Check light mode, dark mode, and larger Dynamic Type settings for clipped labels and controls.
- Use VoiceOver to check that set completion controls and numeric inputs have meaningful labels.

## Data isolation

Use a simulator installation for acceptance testing. Its local JSON state is separate from a physical iPhone’s app data. Removing the app resets its stored state, so only reset an installation whose data can be discarded.
