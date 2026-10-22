# Testing

## Automated verification

Run the core tests from the repository root:

```sh
swift test
python3 scripts/generate_exercise_catalog.py --check
```

These tests exercise workout behavior and persistence through the `LiftLogCore` package. They do not validate SwiftUI layout, keyboards, navigation, signing, or device installation.

Catalog coverage verifies all 876 bundled entries load, original starter identities and order remain stable, matched exercises reuse existing IDs, and retired exercise snapshots survive in templates, active workouts, and history. The generator check verifies the resource matches the pinned upstream dataset and reviewed compatibility mappings without accessing the network.

Milestone 0 adds `ExerciseDetailTests` for the separate detail resource, missing equipment/instructions, full muscle lists, source wording/order, provenance, and unchanged snapshot encoding. Run the generator's negative policy tests with `python3 -B -m unittest discover -s scripts/tests -v`; they cover reproducibility, catalog-byte compatibility, source/license/mapping checksum changes, disallowed licenses, missing credit, unknown labels, false review claims, and excluded media in outputs and resource directories. `python3 scripts/generate_exercise_catalog.py --check` checks catalog, details, attribution, and the separate nonbundled provenance audit together.

`CatalogCreditsUITests` verifies Settings → Credits & Licenses without an account, the complete bundled Unlicense, back navigation, pinned revision, review limitations, and photo exclusions at accessibility XXXL. It uses only the existing isolated `--ui-testing --reset-ui-testing` storage flags. For visual verification, capture Settings, Credits, source/review information, and the full-license screen in light/dark appearance and accessibility text; inspect a smaller iPhone as well. These screens and catalog reads require no Health, iCloud, notification, or live assistant access.

Milestone 0 verification: all 265 core tests, nine generator tests, generator `--check`, and both `CatalogCreditsUITests` passed. The final generic iOS Simulator build passed after XcodeGen regeneration. Before/after Settings, Credits, provenance/review, and full-license screenshots were inspected on an isolated iPhone 17 (iOS 26.5), including dark appearance and accessibility XXXL. An isolated iPhone 13 mini (iOS 26.5) was also exercised at default and accessibility-large text. Physical-device integrations were not changed or reverified.

`ExerciseDiscoveryTests` covers combined metadata filters, case/diacritic/whitespace matching, Unknown versus bodyweight, primary/secondary muscle matching, unique featured rows, deterministic completed-history recents, deletion/reload, and filter reset semantics. `ExerciseFavoritesTests` covers bundled/personal favorites, no-op mutations, missing/orphan IDs, failed writes, restore blocking, legacy JSON, v1–4 read-only backups, transactional schema-7 migration/rollback, and backup/restore round trips.

`ExerciseDiscoveryUITests` uses synthetic UI actions and the existing isolated testing flags to cover filters/search/reset, detail cancellation versus explicit add, favorites across draft cancellation and relaunch, completed-only recents, reusable custom exercises with Unknown metadata, missing source instructions, and accessibility XXXL screenshots. Run the class serially on an isolated simulator, plus `PersonalCatalogUITests` and `WorkflowUITests/testSearchFiltersCatalogAndCustomExerciseSurvivesRelaunch` to check picker compatibility. Capture light/dark picker, filter, detail, featured-list, and unavailable states; inspect a small iPhone at accessibility text sizes. These tests never use live assistant credentials or read Health data.

Initial Milestone 1C verification: all 285 core tests, catalog generation `--check`, and the final generic iOS Simulator build passed. All seven discovery UI scenarios and both imported/custom-exercise compatibility scenarios passed across serial targeted runs on an isolated iPhone 17 (iOS 26.5). UI testing caught and fixed the search toolbar hiding filters and the empty-result view pushing custom creation below the keyboard. The custom-creation regression selects Add while the keyboard remains open. Test helpers terminate before fresh fixture launches, use the native search clear control, and scope navigation to the visible bar. Light/dark, missing-data, featured-list, and accessibility XXXL screenshots were inspected, including an iPhone 13 mini (iOS 26.5). The iOS 17.0 inline-filter fallback is compile-checked but was not run on that OS; physical-device integrations were not changed or reverified.

The core suite contains 68 XCTest cases, including six unit tests for the numeric parsing used by the SwiftUI set editor and ten additional backend flow tests. Coverage includes template validation and persistence, independent session snapshots, relaunch recovery, completion filtering, stale session edits, history ordering, unit conversion and overflow, atomic save failure recovery, and invalid saved-file protection. See the [workflow coverage map](WORKFLOWS.md) for the user and backend flows.
The original workout core has 56 XCTest cases, including six unit tests for the numeric parsing used by the SwiftUI set editor and ten additional backend flow tests. Coverage includes template validation and persistence, independent session snapshots, relaunch recovery, completion filtering, stale session edits, history ordering, unit conversion and overflow, atomic save failure recovery, and invalid saved-file protection. The assistant adds authentication, streaming, tool execution, and chart tests. See the [workflow coverage map](WORKFLOWS.md) for the user and backend flows.

Eleven import tests use `Tests/LiftLogCoreTests/Fixtures/strong_workouts.csv`, a hand-authored synthetic Strong-format CSV, to verify every exercise, weight, rep value, timestamp, duration, and excluded rest record. The fixture contains no exported user records; its provenance is documented in [Fixtures/README.md](../Tests/LiftLogCoreTests/Fixtures/README.md). Additional synthetic cases cover quoted CSV, BOM/CRLF, malformed data, unsupported measurements, explicit units/time zones, exercise overrides, selected subsets, duplicate imports after reload, and atomic write failures. `WorkoutImportUITests` adds three UI tests covering cancellation, single/multiple selection, matching, unit preservation during navigation, saving, relaunch, and duplicate detection using a DEBUG-only synthetic fixture.

All three import UI cases passed across targeted runs on a dedicated iPhone 17 Pro simulator (iOS 26.5). Run simulator suites on separate devices when working concurrently; two test runners installing the app on the same simulator interfere with each other.

Generate and build the iOS project separately:

```sh
xcodegen generate
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The `LiftLogUITests` Xcode target, under `Tests/LiftLogUITests`, exercises template creation and validation, set completion, resume after relaunch, finishing, history navigation, catalog search and custom exercises, discard confirmation, unit preferences, workout imports, and the assistant. Run it with an installed iPhone simulator, for example:

```sh
xcodebuild -project LiftLog.xcodeproj -scheme LiftLog -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

Replace `iPhone 17` with an available simulator name from `xcrun simctl list devices available`. The UI suite uses a data file separate from normal app data and resets it at the start of each test. Run the UI tests serially because they share that testing file in the app sandbox (`-parallel-testing-enabled NO`). The two existing UI tests and four workflow tests each passed on the iPhone 17 Pro simulator (iOS 26.5) across separate runs. A clean combined run was blocked by intermittent test-runner exits and a final simulator launch failure (`FBSOpenApplicationErrorDomain Code=6`, preflight reason `Busy`). The final per-test app cleanup change remains unverified because that launch failed before tests began; rerun the suite on an idle simulator.

For interactive verification, open the project in Xcode and run it on an iPhone simulator.

Rest audio is covered by `LiftLogAppTests/RestTimerAudioTests`: a real countdown must activate a playback audio session that mixes with other music, the bundled chime must play to completion, skipping must cancel playback, returning must not repeat a successful chime, and failed playback must remain eligible for retry. Run the audio tests and the existing countdown UI flow with `-only-testing:LiftLogAppTests -only-testing:LiftLogUITests/RestTimerUITests` added to the Xcode test command above.

On a physical iPhone, complete a set and let rest expire with the app open. Verify the chime at a nonzero media volume with silent mode enabled, then with wired or Bluetooth earbuds connected and music playing. The chime should use the current audio output and leave music playing. Repeat after connecting or disconnecting earbuds during the countdown. Background/locked-screen alerts use the same bundled sound as a local notification and remain subject to iOS notification permission, sound, silent-mode, and Focus settings. Simulator audio tests cannot verify physical headphone routing.

The original chime is synthesized by `python3 scripts/generate_rest_chime.py`; its PCM WAV is bundled in the app and is short enough for notification playback.

`WorkoutHistoryQueryTests` covers combined workout/exercise search, case and accent matching, template identities and renamed templates, calendar-day boundaries across daylight saving, all four sort orders with deterministic ties, and clearing filters without changing the selected sort. `WorkoutHistoryUITests` reuses the synthetic dashboard workout fixture to verify date/template/search combinations, no-match recovery, sorting, detail navigation, deleting a filtered result, and empty-history import access.

In History, check the filter and sort menus at accessibility text sizes. Date ranges include today and the previous 6, 29, or 89 local calendar days. Verify that swiping a filtered result still deletes the selected session after confirmation and that importing workouts refreshes the current results.

History verification: all 236 core tests pass, and all four history UI cases passed across targeted runs on the dedicated LiftLog History Verification simulator (iOS 26.5). The iOS build succeeds.

History renaming is covered by three `WorkoutStoreFlowTests` cases for persistence, blank/missing-session validation, duplicate-name isolation, import identity preservation, and atomic save failure recovery. `WorkoutImportUITests.testRenameHistoryValidationCancellationAndPersistence` checks the swipe action, prefilled name, Cancel, disabled Save for blank names, detail navigation, relaunch, and duplicate import detection.

Rename verification: all 234 core tests and all five History/import UI cases passed across targeted runs on LiftLog Import Verification (iOS 26.5). The native rename dialog was also visually inspected. A stale synthetic `LiftLogUITests.json` fixture was removed from the simulator before UI verification because the existing test reset only deletes the SQLite file.

## Manual acceptance checklist

### Completed workout summaries

`WorkoutSummaryContextTests` checks completed-session validation, actual values and original targets, recorded units, repeated entry identities, earlier comparable history, bounded payloads, scoped Health intervals, and isolated prompt/automatic-generation preferences. `WorkoutSummaryStoreTests` uses captured synthetic requests and controlled transports/providers to exercise explicit Health sharing, ephemeral responses, cancellation, account changes, stale records, empty/error recovery, and read-only inference.

Run `WorkoutSummaryUITests` serially on an isolated simulator. Its DEBUG fixture requires `--ui-testing --assistant-ui-fixture --workout-summary-ui-fixture`; add `--reset-ui-testing` for a fresh fixture. It uses synthetic history, an active workout, a local inference transport, and synthetic Health data. It must never use live OAuth, Keychain credentials, or personal Health readings. Existing completion tests dismiss the new summary before proceeding to History.

Interactively inspect the completion summary, generated advice, Health disclosure, and Settings prompt draft in light/dark mode and accessibility Dynamic Type on a smaller iPhone. Verify Cancel and resetting an unsaved prompt leave committed settings intact, and that dismissing during generation clears the reply. On a signed iPhone, separately verify real subscription streaming and Health permission denial, missing samples, wearable sync delays, and actual recorded-session boundaries. Simulator mocks do not establish those behaviors.

Summary verification: all 357 core tests pass, XcodeGen regeneration and the generic iOS Simulator build succeed. After rebuilding the final shared tree, all six summary UI cases pass together in one serial run on the isolated iPhone 13 mini (iOS 26.5), including the accessibility XXXL prompt/keyboard case. Three existing completion/history regressions also pass in an earlier serial run. Initial summary test attempts exposed duplicate alert-button selectors, SwiftUI container identifiers overriding controls, and taps on the labelled switch row rather than its native control; the final tests verify the actual toggle value and request outcome. Native summary tests include automatic workout-only generation, explicit Health sharing, prompt draft/relaunch behavior, retry errors, Stop, dismissal, History reopening, and reachable Cancel/Save with accessibility text and the keyboard. The final bounded prompt editor passes both the normal draft/relaunch test and the accessibility XXXL keyboard test; its overlength warning and disabled Save were also checked interactively after bulk paste. Accessibility navigation scrolls the full Settings row above the tab bar before tapping. Muse Wonder Full reviewed three rounds and approved the resolved lifecycle and privacy fixes. Running-app light/dark and large-text captures were inspected; the prompt screen uses a shorter accessibility title to retain its actions. Live ChatGPT plan streaming, signed-device HealthKit permissions/readings, iOS 17 runtime, and manual VoiceOver gestures remain separate checks.

### Supersets

`SupersetTests` covers membership edits and moves, singleton cleanup, old JSON decoding, SQLite/backup round trips, transactional schema migration and rollback, template versioning, workout starts and completion filtering, and preservation through assistant edits. `SupersetUITests` covers the all-exercise selection sheet, Cancel, duplicate exercise entries, matching group labels, template and active-workout relaunch, membership edits/removal, and superset-only version changes. The UI suite captures the picker and grouped template for visual inspection.

Run the targeted simulator suite with `-only-testing:LiftLogUITests/SupersetUITests`. Supersets currently group and highlight exercise entries; rest countdowns and Live Activity next-set ordering retain their existing behavior.

Verification: all 251 core tests and all three superset UI cases passed on LiftLog Superset Verification (iPhone 17, iOS 26.5). The iOS test build succeeded. Picker and grouped-exercise screenshots were inspected; the decorative group icon is hidden from accessibility so group identifiers expose the actual superset label.

PR #15 regression verification: all 256 core tests pass. A store regression reproduced the unwanted version before the fix; group-membership comparison ignores group UUIDs. Targeted UI tests passed for restoring a removed group without enabling Save, renaming afterward without creating a version, and genuine membership edits still creating versions. The final regression also checks that adding an ungrouped exercise does not report a superset change. The final iOS build and regression rerun passed on the same isolated iPhone 17 simulator (iOS 26.5), with exported screenshots of the enabled and disabled save states.

PR #15 summary regression: all 260 core tests pass. Stable entry-ID group comparison covers ungrouped insertions/removals before, between, and after groups, regenerated group IDs, repeated catalog exercises, and real membership changes. The new native UI test failed on the spurious superset-summary row before the editor fix, then passed through version saving and relaunch with group membership preserved. The earlier undo/recreate regression also passed after waiting for the save control to update following removal. The generic iOS Simulator build passed. Light, dark, and accessibility-large summary screenshots were captured and inspected on the isolated iPhone 17 simulator (iOS 26.5).

### Apple Health opt-in

`WorkoutHealthDataTests` covers session time windows, invalid dates/values, bounded interval series, and missing data. `AssistantHealthPrivacyTests` captures outgoing requests and tests explicit per-message consent, plain-workout isolation, canonical session resolution, chart scope, cancellation, account changes, deletion during reads, and exclusion from saved history, archives, and title requests. The reference UI suite includes Health-tag selection, cancellation/removal/new-chat behavior, untagged follow-ups, and native health-chart navigation. Its provider and network transport are synthetic and never read personal Health data.

Verification: all 210 core tests and all eight `AssistantReferenceUITests` passed on LiftLog Reference Verification (iOS 26.5), including the three new Health flows and existing large-text tag layout checks. The native chart screenshot was inspected for clear Health labeling and bpm values.

On a signed physical iPhone with the HealthKit capability enabled:

- Start a workout and open Assistant or the @ picker. Neither action should prompt for Health permission.
- Send a question with a normal workout tag. No Health permission or Health data should be requested.
- Select the session under **@ → Apple Health**, read the sharing disclosure, and send. Verify the system read-permission sheet appears when required, requesting heart rate, active energy, and steps only.
- Allow selected metrics, deny others, and chart available readings. Missing metrics must remain unavailable, without fabricated zeros or a claim that read access was granted.
- Check active-session boundaries against send time, and completed sessions against their recorded start/end. Compare interval averages/totals with available HealthKit data; samples crossing the session edges are excluded.
- Cancel while a permission/read request is pending, or switch accounts. No delayed assistant request should be sent.
- Ask a follow-up without a Health tag. The earlier readings and health-derived answer must not be included. Retag to read again.
- Relaunch the app. Health questions, replies, and charts must be absent from saved chats; ordinary messages and charts still restore.

Native permission behavior, wearable synchronization, actual statistics, and production signing require this physical-device pass; mocked tests cannot establish them.

### ChatGPT assistant

The core tests use synthetic signed ID tokens and mocked HTTP/SSE responses. They cover callback binding, signature/claim checks, grant permissions, model discovery, raw SSE framing, interrupted/failed streams, account changes, tool limits, proposal approval/discard/staleness, batch edit atomicity, and chart unit conversion.

Subscription streaming regression: the live service can emit canonical `response.output_item.done` events followed by `response.completed` with `output: []`. Native URLSession tests verify those completed items survive, tools continue only after successful completion, and genuinely empty responses produce a visible error. The delayed chart UI tests guard against scrolling/layout stalls during tool results and progress disappearing below the transcript.

`AssistantUITests` checks signed-out access and continued offline workout logging. `AssistantInteractionUITests` uses a DEBUG-only connection and local transport to check proposal review, Apply persistence, Discard, chart rendering, and chart image sharing. Its delayed fixture also checks visible progress across a chart tool round and cancellation. Both launch flags `--ui-testing` and `--assistant-ui-fixture` are required to activate that fixture; `--assistant-delayed-ui-fixture` adds a four-second delay per model request. UI tests use memory credential storage, never the real Keychain, and cannot initiate live OAuth.

`AssistantWorkoutReferenceTests` captures outgoing requests to verify exact template/session identities, selected-data isolation, original units, exercise/set IDs, current record resolution, active-to-completed transitions, deleted records, selection and payload limits, and follow-up context. `AssistantReferenceUITests` exercises picker search, template and completed-session selection, transcript tags, standalone `@`, cancellation, removal, and new-chat cleanup. Its additional `--assistant-reference-ui-fixture` flag acknowledges the actual submitted record IDs and set values through the local transport, so UI assertions verify request data without live inference.

Tagging verification: 134 core tests passed, including six reference tests. The iOS simulator build succeeded, all three reference UI cases passed across targeted runs on an isolated iPhone 17 simulator (iOS 26.5), and existing proposal-discard and response-cancellation UI checks passed. Long echoed-ID assertions use label predicates because XCTest identifier subscripts reject strings over 128 characters.

Rendering coverage in `AssistantRenderingTests` checks semantic Markdown, combined emphasis, nested lists, tables, literal code, unfinished streamed Markdown, and chart selection/filtering at sparse, duplicate, and empty points. The interaction suite also checks touch selection, Previous/Next, line/bar switching, the expandable workout list, native Markdown blocks and copy actions, and chart range filtering. `--assistant-dense-chart-ui-fixture`, alongside the two required fixture flags, seeds ten sessions across 180 days to exercise filtering and date ticks. Test screenshots cover light mode and accessibility-sized text in dark mode.

Initial integration verification: 109 core tests and five assistant UI tests passed on iPhone 17 (iOS 26.5), and Debug and Release simulator builds succeeded. After the streaming fix, all 116 core tests and all five interaction UI tests passed, including delayed progress/cancellation, chart sharing, and proposal Apply/Discard. A live chart request using the already-connected ChatGPT account on iPhone 17 Pro Max completed with a chart and explanatory text; this verifies live inference and tool continuation, not the initial OAuth sign-in flow. UI result bundles include screenshots of sign-in, proposal review, and charts.

- On a physical device with an eligible account, verify Continue with ChatGPT returns from the loopback browser callback and shows the selected account.
- Decline plan usage, then explicitly enable it; identity-only access must not send model requests.
- Ask a question about recorded history, graph a metric, and create or edit a workout through proposal review.
- Change the workout after receiving a proposal; applying the stale proposal must fail without overwriting the edit.
- Check account switching, token expiry/renewal, cancel, usage-limit recovery, and disconnect.
- Confirm general image requests explain the preview limitation rather than silently switching billing routes.

Live OAuth and subscription entitlement require manual verification; mocked tests cannot establish them.

### Personal exercise catalog

- Import a workout containing an unmatched exercise, relaunch, and search for that exercise when adding an exercise to a template or workout.
- Save a manually created custom exercise in a template or active workout and verify it appears in subsequent searches after relaunch.
- Search with different capitalization and repeated whitespace. The existing exercise should remain selectable without a duplicate create option.
- Cancel an import or a new template containing a custom exercise. It should not add that unsaved exercise to the catalog.
- Load older saved data with custom exercises. They should become reusable while the original workout and template snapshots remain unchanged.

`PersonalCatalogUITests` exercises importing, relaunching, normalized search, and reusing an imported custom exercise in a new template.

Seven core catalog tests cover merged identities, persisted personal entries, legacy backfill without history changes, bundled-name overlap, template/active-workout registration, cancellation and skipped duplicates, and atomic failures.

### Template versions

`TemplateVersionTests` covers immutable revision history, semantic no-op saves, stale/deleted drafts, archived and default version starts, independent planned/actual values, unit conversion, failed saves, JSON and SQLite v1 upgrades, read-only old backups, and transactional schema rollback. Agent tests cover reviewed progression, version reads, no-op rejection, target preservation, and proposal invalidation after unit changes or backup restore.

Verification for this change: all 161 core tests passed. The iOS simulator build succeeded, and three UI flows passed on the isolated LiftLog Reference Verification simulator (iOS 26.5): version planning/cancellation/archived start/history targets, template creation/completion/relaunch, and assistant review/Apply/relaunch. The version test uses `firstMatch` for the system confirmation button because iOS exposes nested accessibility matches.

### Templates

- Create a named template, add exercises, and configure multiple sets with weights and target reps.
- Save it, leave the screen, and confirm its entries remain intact.
- Edit the template and verify the changes appear when starting a new workout.
- Search for a catalog exercise, add a custom exercise by name, and remove an exercise or set from a template.
- Try blank names, negative weights, and zero reps; invalid values should not be saved.

### Workout execution

`WorkoutActivitySnapshotTests` covers ordered next-set selection, out-of-order completion and undo, exercise removal, actual prescriptions and units, stable rest deadlines, persistence/relaunch, skip, and finish. The `LiftLogWidgets` extension is embedded by the app build.

Live Activity verification: all 197 core tests and the existing `RestTimerUITests` flow passed, and the simulator app/extension build succeeded. The Lock Screen presentation was inspected on iPhone 17 Pro (iOS 26.5): rest progress and elapsed time continued outside the app, the next set matched the workout, tapping opened the workout, and finishing removed the activity. Compact and expanded Dynamic Island content was confirmed through accessibility; screenshots from this simulator omitted the Island content, so its visual layout still needs physical-device acceptance testing alongside signing and Lock Screen privacy settings.

Live Activity acceptance checks on an iPhone with Live Activities enabled:

- Start a workout, complete a set, and lock the phone. Confirm the rest bar counts down to zero, total workout time increases, and the next exercise, weight/reps, and set number match the app.
- Complete another set, undo a completion, edit remaining weights/reps, skip rest, or remove an exercise. Confirm the Live Activity follows the saved workout.
- Check compact, expanded, and minimal Dynamic Island presentations. Tap the activity and confirm it opens the active workout.
- Relaunch during rest and confirm the original deadline and one activity remain. Finish or discard and confirm the activity disappears.
- Dismiss the activity and reopen the app; it should remain dismissed for that workout. Disable Live Activities in system Settings and confirm logging still works.

- Start a template and confirm its exercise order and planned sets are copied into the workout.
- Complete a set, then change an incomplete set’s weight and reps. Verify both values appear only across the remaining sets of that exercise and the completed set retains its recorded values after relaunch. Completed numeric fields stay disabled until marked incomplete. Confirm original targets remain visible and unchanged, other exercises retain their values, and each set keeps its own completion state.
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
- Review the synthetic example: one invented 30-minute workout, five exercises, 20 sets, and 20 excluded rest-timer rows. Inspect actual reps and weights before import.
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

Use a simulator installation for acceptance testing. Its local SQLite state is separate from a physical iPhone’s app data. Removing the app resets its stored state, so only reset an installation whose data can be discarded.


### SQLite migration and iCloud Drive backups

The SQLite and backup change passed all 68 core tests, a simulator build, and two targeted UI flows: template completion/relaunch and unit preference persistence with an active workout. Real iCloud transfers still require the signed-device checks below.

The twelve `StorageAndBackupTests` use isolated databases, UserDefaults suites, and a local directory in place of the iCloud container. They exercise migration and backup/restore behavior without signing in to iCloud. They do not prove actual iCloud upload, remote discovery, account changes, signing, or downloads.

- Upgrade an installation with version-1 JSON and check templates, personal exercises, weight preference, history, and active workout. Verify the JSON remains untouched and later launches use SQLite.
- On a signed physical device with iCloud Drive enabled, turn on automatic backups, edit a workout, and leave the app. Confirm a backup appears in Files under Lift Log → Backups and eventually reports uploaded.
- Use Back Up Now, then refresh the restore picker. Confirm dates, sizes, and upload state update.
- On another signed device or a reinstall using the same Apple account, discover and download that backup, cancel the restore confirmation, then confirm restoration and verify all data.
- Disable iCloud Drive or disconnect the network. Local saves must continue; backup errors must remain separate, and queued uploads must complete when connectivity returns.
- Select a corrupt or unsupported backup and verify local data stays intact. Restore over a damaged local database and verify normal saving resumes.
- Check that retention removes only older uploaded backups from the same installation. Pending uploads and other devices’ backups must remain.

### Saved assistant chats

`AssistantChatPersistenceTests` covers exact message identities, Markdown, chart data, reference snapshots, applied/stale proposal cards, canonical continuation items, independent concurrent streams and cancellation, account changes, interrupted relaunch, rename/title races, and corrupt or unwritable archives. `AssistantChatTitleGeneratorTests` checks numeric Luna version selection, absence of unrelated-model fallback, bounded prompts, and title cleanup. These tests use synthetic transports and temporary archives.

`AssistantChatUITests` uses `--assistant-chat-ui-fixture` with the existing required fixture flags to expose a local Luna model. It verifies generated titles, renaming, chart/Markdown restoration after relaunch, saved proposal status, two simultaneous row spinners, and cancelling only the selected chat. `--assistant-concurrent-ui-fixture` delays response requests while keeping title requests fast. UI archives are isolated from normal app chats and reset only with `--reset-ui-testing`.

Verification: all 180 core tests passed, the simulator build succeeded, and all six selected UI tests passed on LiftLog Rendering Verification (iOS 26.5): the three saved-chat flows plus default-model preference/relaunch, response cancellation, and new-chat tag cleanup. Luna calls were mocked; this run did not consume live subscription usage.

Saved-chat deletion verification: all 184 core tests and all four `AssistantChatUITests` passed on LiftLog Rendering Verification (iOS 26.5). Coverage includes deletion persistence and selection, last-chat replacement, account isolation, cancelling response/title tasks, failed-save rollback, and the swipe confirmation Cancel/Delete/relaunch flow.

### Health dashboard

`HealthDashboardAnalyticsTests` covers calendar range boundaries and DST, daily and weekday counts, completed-set filtering, repeated exercise entries, mixed-unit progression and maxima, duration totals, template identity, and missing versus zero Health measurements. `HealthDashboardHealthStoreTests` covers explicit loading, bounded concurrent summary reads, cancellation, stale refresh/history results, partial failures in selection order, and invalid provider snapshots. `WorkoutHealthDataTests` also covers reducing a series snapshot to its dashboard summary.

`HealthDashboardUITests` uses `--ui-testing --health-dashboard-ui-fixture` with synthetic workout and Health data. It checks empty history, range counts, exercise selection, preferred-unit conversion, and explicit Health loading/reset on range changes. The fixture never requests HealthKit permission or reads personal data.

On a signed device, verify **Health → Activity → Load Apple Health** requests read permission when needed and shows available calories and heart rate. Compare source readings for the recorded workout windows. Denied or absent readings must remain unavailable; changing the range or leaving Activity clears the in-memory readings and requires another explicit load. Check all three dashboard sections in light/dark mode and at accessibility text sizes.

Dashboard verification: 222 core tests pass. All four dashboard UI cases passed across targeted simulator runs on LiftLog Rendering Verification (iOS 26.5); the Activity case was rerun after correcting an inherited accessibility identifier. The iOS build succeeds. Light/dark screenshots and accessibility-sized consistency layout were inspected, including the corrected heatmap spacing. Actual HealthKit permission and wearable data still require the signed-device checks above.

PR review regressions cover identical and partially overlapping calorie windows, touching window endpoints, missing energy data, consistent cross-template exclusions, and range changes with identical workout lists (including cancellation of suspended reads). The dashboard UI fixture's optional `--health-dashboard-overlap-ui-fixture` flag adds a separate imported record for the same time window; its UI test checks unchanged calorie totals, reduced coverage, and the overlap warning. The Activity range test includes Year → All time, where both ranges contain the same twelve sessions.

PR #7 follow-up verification: all 231 core tests pass. The targeted simulator run passed weight selection/unit conversion, identical-workout range reset/reload, and overlapping calorie totals/coverage/warning checks (three UI tests). The iOS simulator build succeeds.

### Default and personal exercise steps

`ExerciseInstructionTests` covers immediately available catalog defaults, custom-exercise steps, normalized edits, default reset, idempotent saves, invalid text, orphan identities, failed-write rollback, blocked restore mutations, legacy JSON, schema-1–6 migration to schema 7, migration rollback, and backup/restore. Template versions and workout snapshots remain unchanged by instruction edits.

`ExerciseInstructionsUITests` covers visible default steps without review or adding an exercise, personal edit/save/relaunch, Cancel, reset-draft cancellation and saved reset, missing-default Add Steps, blank validation, adding/removing/reordering, and accessibility XXXL detail/editor layouts. It uses only isolated `--ui-testing --reset-ui-testing` data. Repeat layout checks in light/dark appearance and on a small iPhone.

Verification: all 297 core tests pass, including 12 instruction regression tests. The iOS simulator build succeeds. All four instruction UI tests and two related discovery tests pass across targeted serial runs on LiftLog Catalog Verification (iPhone 17, iOS 26.5). Running-app screenshots were inspected on an iPhone 13 mini simulator in light/dark appearance and accessibility XXXL; the instruction header stacks vertically at accessibility sizes. Physical-device iCloud transfers still need the signed-device checklist above.

## Alias search and explicit replacements

`ExerciseSearchTests` covers source/common-name aliases, variant identities, direct-match precedence, bounded spelling edits and transpositions, metadata filters, featured sections, personal exercises, and unchanged query text. `ExerciseAlternativesTests` checks conservative metadata matching and deterministic ordering. `ExerciseReplacementTests` checks fresh identities, zero loads, preserved reps/groups/order, cleared workout targets, stale/completed/missing candidates, immutable versions/history, failed-write rollback, restore blocking, relaunch, and backup snapshots.

Run `ExerciseSearchUITests` and `ExerciseSwapUITests` serially on the isolated simulator. They cover alias and spelling reasons, metadata filters, explicit custom creation, template draft cancellation and version retention, active-session cancellation/persistence/target clearing, completed-set protection, and accessibility XXXL replacement review. Helpers scope scrolling to the visible list and use the native search clear action. Capture real-app alias/typo results, replacement suggestions/review, template and active results, and the disabled completed-set action; include light/dark and accessibility text on a smaller iPhone.

Verification for the search/replacement slice: all 318 core tests pass (21 new search/alternative/replacement tests). All five new native UI scenarios pass serially on the isolated iPhone 17 simulator, iOS 26.5. The existing combined-filter, detail-cancel/explicit-add, and superset create/cancel/save/relaunch/active-edit UI regressions also pass (eight native scenarios total). The final generic iOS Simulator build and catalog generator `--check` pass. Before/after screenshots were inspected on iPhone 13 mini, iOS 26.5, including light/dark and accessibility XXXL. Visual inspection caught and fixed truncation of the large-text replacement confirmation button. No storage migration was added. The iOS 17 runtime and physical-device integrations were not reverified.

### Exercise reordering

`ExerciseOrderTests` covers repeated exercise identities, immutable versions, supersets, logged values and targets, rest timers, mixed units, archived starts, newer template prescriptions, session-only additions/removals, unlinked/deleted templates, no-ops, stale and invalid orders, persistence/backups, save rollback, and transactional schema-7 migration from a read-only schema-4 file. Legacy ambiguous source entries remain unlinked.

`ExerciseOrderUITests.testCancelSaveRelaunchAndFutureTemplateWorkoutOrder` drags an exercise to the top, cancels and checks the original order, saves a changed order, relaunches, and starts the updated default template. Run serially with `-only-testing:LiftLogUITests/ExerciseOrderUITests`. Inspect the active workout and reorder sheet in light/dark mode and at accessibility text sizes; use VoiceOver's native reorder actions as an alternative to dragging.

Reordering verification: all 268 core tests passed, the generic iOS Simulator build succeeded, and the native order/cancel/save/relaunch/default-template flow passed on a fresh iPhone 13 mini simulator (iOS 26.5). Running-app light/dark captures and accessibility-large captures were inspected on iPhone 17 and iPhone 13 mini; the sheet uses a shorter title at accessibility sizes to keep Cancel and Save visible. The UI test asserts the first exercise heading so its checks work when set controls begin below the smaller screen's viewport. Manual VoiceOver gesture testing remains outstanding.


Exercise-order review regressions cover pre-version JSON and v1 database/backup link inference and source-file preservation, invalid persisted movement links, and a reviewed assistant set edit followed by a movement replacement, relaunch, and reorder. The native sheet fixture (`--ui-testing --exercise-order-ui-fixture`, with `--reset-ui-testing` for a fresh test installation) includes three Bench Press entries with distinct and identical targets plus a superset. `--exercise-order-unlinked-ui-fixture` makes the entries workout-only. Native regressions verify targets and membership stay with the same original entry number during moves, survive relaunch, and show accurate workout-only footer text. These fixtures use no account or personal data.

Review-fix verification: all 273 core tests and all three `ExerciseOrderUITests` passed; the generic iOS Simulator build succeeded. The native tests ran serially on a fresh iPhone 13 mini simulator (LiftLog Reorder Review, iOS 26.5) with simulator diagnostic collection disabled. Light/dark, accessibility-large, and workout-only screenshots were captured from the running synthetic fixture. Manual VoiceOver gesture testing remains outstanding.

## PR #17 integration with main

The merged schema uses version 5 for source template-entry links, version 6 for favorites, and version 7 for personal steps. `ExerciseSchemaMergeTests` covers both pre-merge schema lineages, read-only source preservation, exact failed-migration rollback and retry, damaged-current-layout rejection, and replacement followed by reorder. Old catalog-branch sessions without source links remain workout-only; they cannot gain template provenance from a prior replacement.

Integration core verification: all 334 tests pass, including four new cross-branch regressions. XcodeGen regeneration, the generic iOS Simulator build, and catalog generator `--check` pass. The merged active editor retains both replacement and reordering sheets and routes errors to the presented sheet.

All three exercise-order UI scenarios and the active replacement cancellation/persistence scenario pass on the isolated iPhone 17 simulator (iOS 26.5). The personal-step lifecycle assertion failed after relaunch in the first combined run, then passed the full focused rerun; inspection confirmed the saved override remained in the schema-7 database after relaunch. Five targeted scenarios therefore pass across those runs, rather than one clean combined run. Running-app captures on iPhone 13 mini (iOS 26.5) verify the merged menus, reorder sheet, replacement review, light/dark appearance and accessibility-large controls. Physical-device integrations were not reverified.

## PR #17 review follow-up

Runtime exercise details contain content and source/record IDs; full record and per-field hashes remain in `vendor/free-exercise-db/exercise-provenance.json`, outside app and Swift package resources. Generator tests check lean runtime keys, full audit parity, and missing/stale outputs in both locations. Details shrink from 3,236,966 to 984,084 bytes (69.6%); the built app contains no provenance-audit resource.

Discovery regressions cover finish-time recency for long/imported sessions, deterministic ties, deduplication/limits, persisted favorite order after search/filter selection, and independent All Exercises relevance. `ExerciseDiscoveryUITests.testFavoritesPreserveSavedOrderAcrossSearchFiltersAndRelaunch` verifies that Overhead Press saved before Bench Press stays first in both filtered and unfiltered views after relaunch.

Instruction UI coverage verifies the adjacent unreviewed-source notice, including personal edits derived from source guidance, and source-less custom removal confirmation, draft cancellation, Save and relaunch. Delete-all/blank drafts show inline validation without changing saved text; adding a valid step recovers. Defaults remain immediately usable without approval. The core validator is shared with the editor and still guards persistence.

Review-follow-up verification: all 338 core tests and 11 Python generator tests pass, along with catalog `--check`, XcodeGen regeneration and the generic iOS Simulator build. All eight selected native UI scenarios pass across serial runs on LiftLog Catalog Verification (iPhone 17, iOS 26.5): six instruction cases plus favorite ordering and completed-history recents. The initial run passed five cases; three test helpers assumed an already-created offscreen list row, an onscreen editor field at accessibility XXXL, or a visible Cancel row in the native confirmation popover. After correcting those helpers, the focused three-case rerun passed with no failures. This is eight successful scenarios across runs, not one clean combined run.

Before/after running-app screenshots were inspected on iPhone 13 mini, iOS 26.5, including light/dark guidance and validation, accessibility XXXL source notices, accessibility-large removal controls, confirmation, cleared draft and saved removal after relaunch. The same saved favorite data was captured under the previous and updated binaries. iOS 17 runtime, manual VoiceOver gestures and physical-device integrations were not reverified.


## Completed-history correction and manual entry (Milestone 1A)

`WorkoutHistoryEditingTests` covers independent actual-value edits, backdated start/finish and duration, trimmed session/exercise notes, retained set/exercise IDs and targets, immutable recorded units and source references, manual custom-exercise registration, validation and stale/deleted drafts, restore blocking, atomic failed correction/undo with retry, orphan superset cleanup, import duplicate protection, relaunch, backup/restore, legacy JSON defaults, invalid recovery payloads, and read-only schema-7 loading with exact failed-migration rollback. Existing migration fixtures remove schema-8 fields before constructing older layouts, preserving coverage of versions 1–6 and both pre-merge lineages. Dashboard records and assistant charts are checked after correction, undo and deletion; recovery records never contribute to metrics.

Run `WorkoutHistoryEditingUITests` serially with the existing isolated `--ui-testing --reset-ui-testing` launch arguments. The correction case reuses the synthetic dashboard fixture, checks Cancel, independent numeric rows, both note types, review, save, relaunch and persisted undo. The manual case checks empty-history access, invalid reps, returning from review without saving, a completed manual record and relaunch. Run `WorkoutHistoryUITests` and the import rename and selected-workout preview cases for compatibility. Import previews use the read-only record view; saved history details resolve the current record from the store. Tests and screenshots contain synthetic data only.

For visual checks, open Edit from completed history and Add Past Workout from empty history. Inspect the editor, review, saved detail, validation and Undo confirmation in light/dark appearance and at accessibility XXXL on a small iPhone. Review and Cancel remain visible; workout names wrap, date/time controls stack, and the accessibility titles shorten to Correct and Past. Undo appears beside Edit in the navigation bar, since a bottom toolbar is hidden by the native tab layout on this OS. The review footer explains recovery without consuming the screen at large text sizes. Notes longer than 10,000 characters cannot save. Manual records and added rows do not claim planned targets.

Milestone 1A verification: all 348 core tests pass, including ten history-editing regressions. XcodeGen regeneration and the final generic iOS Simulator build succeed. Both new native UI cases pass together in the final run on LiftLog History Verification (iPhone 17 Pro, iOS 26.5). The four history filter/sort/delete/empty-state cases, import rename/duplicate case, and selected-import preview case also passed across earlier serial targeted runs (eight successful native scenarios across runs). Initial failures exposed test selectors behind sheets, list scrolling and cursor-position assumptions; native Select All now replaces multiline names. UI testing also caught an invisible bottom Undo toolbar, which moved beside Edit and passed save/relaunch/undo verification. Running-app screenshots use only synthetic fixtures. iOS 17 runtime, manual VoiceOver gestures and physical-device iCloud transfers remain unverified.

The final repeat core run also exposed an inherited test-fixture nondeterminism: synthetic discovery movements copied the source alias from an arbitrary catalog dictionary entry. The fixture now clears that borrowed alias, so synthetic Squat never matches a press query; the complete 348-test suite passes after the fix. Final screenshot inspection shortened the accessibility titles to Correct/Past/Review and made the name field wrap. The review title is supplied directly to the shared record view so the workout-name preference cannot override it.

Running-app PNGs were exported to `/Users/nkania/.t3/artifacts/history-correction-2026-10-18/` and inspected on iPhone 13 mini and iPhone 17 Pro, both iOS 26.5. They cover light/dark editor and review, accessibility XXXL, independent edited rows/notes, saved correction, manual entry, invalid reps, empty history, and undo confirmation. At accessibility sizes the review uses a short recovery message and Save label with full VoiceOver labels to keep the record visible. The final correction/manual native rerun also passes after the editor's captured original moved into owned state, preventing presenter refreshes from silently rebasing a draft.

## PR #19 — Rename sessions left open longer than a week

`testForgottenWorkoutOverSevenDaysCanBeRenamedAndUndoneAfterRelaunch` reproduces a persisted active workout left open for eight days, completes it through the normal finish flow, and verifies a name-only correction, exact preservation of dates/notes/targets/source identities, independent active/template state, relaunch and undo. `testLongHistoryRenameRetainsProvenanceAndRollsBackFailedWrites` checks legacy imported provenance, failed-write rollback, restore blocking, no-op renames and unchanged date limits for full edits/manual entry. Rename uses stored-record validation independently of the full editor's seven-day entry limit.

The DEBUG-only `--ui-testing --history-long-workout-ui-fixture` flag seeds a synthetic eight-day completed workout only if the isolated UI-test database is absent. Use `--reset-ui-testing` for a fresh run; relaunch preserves corrections. `WorkoutHistoryEditingUITests.testRenameWorkoutOverSevenDaysPreservesDurationAndUndoAfterRelaunch` checks the native swipe Rename action, unchanged duration/notes, relaunch and Undo Last Correction. It uses no personal data or credentials.

Verification: all 350 core tests pass, the generic iOS Simulator build succeeds, and both the new eight-day rename/relaunch/undo native test and the existing rename validation/cancellation/persistence native test pass serially on iPhone 17 Pro, iOS 26.5. The running detail screen was also exercised interactively. Exported screenshots of the renamed and restored records were inspected at `/Users/nkania/.t3/artifacts/pr19-long-workout-rename/`. No production UI layout or text changed. iOS 17 and physical-device integrations were not rerun for this store-only behavior fix.

## PR #20 integration with main

Merged main's history corrections, manual entries, notes, schema-8 recovery, and long-session rename fix with completed-workout summaries. Saved History detail owns the summary presentation; the reusable record view used for unsaved review drafts omits that action. The correction UI regression opens saved-record stats, verifies the covered summary action is not tappable from review, saves and relaunches, then restores the previous record.

Integration verification: all 369 core tests pass, XcodeGen regeneration succeeds, and the generic iOS Simulator build succeeds. Four targeted native scenarios pass across serial runs on the isolated iPhone 13 mini, iOS 26.5: correction/review/relaunch/undo, manual entry, eight-day rename/relaunch/undo, and summary Stop/dismiss/History reopening. The correction case passed its focused rerun after its new assertion was corrected to distinguish covered background accessibility elements from the active review sheet. Running-app light/dark saved-record and review screenshots, plus accessibility-large summary-action layout, were inspected with synthetic data. iOS 17 runtime and physical-device integrations were not reverified.


## Apple Foundation Models provider

Run the core suite and a generic iOS Simulator build after XcodeGen regeneration. Provider tests cover local inference routing, archive separation, no ChatGPT credential/network access, availability errors, validated chart/proposal tools, local titles, and the existing ephemeral Health boundary. `WorkoutSummaryProviderTests` compares local and ChatGPT evidence, prompts, and safeguards and checks cancellation, late output, optional Health, and account independence.

`FoundationModelsBudgetTests`, `FoundationModelsSchemaTests`, and `FoundationModelsMutationSchemaTests` exercise stage reservations, answer completion, schema references/conditional variants, all edit modes, and target-scoped ID provenance. Chat tests cover model-visible dispatch recovery and bounded retries without executing a rejected call. `WorkoutSummaryBudgetTests` exercises the real local request projection with ordinary comparable history, dense Health data, preserved grouping/version facts, and an intact target.

Run `FoundationModelsUITests` and `WorkoutSummaryUITests` serially on an isolated simulator, plus the existing Assistant suites for compatibility. The DEBUG fixture requires `--ui-testing --foundation-models-ui-fixture`; add `--reset-ui-testing` for fresh storage. This selects a synthetic available local provider with no connected ChatGPT account. It reuses only in-memory synthetic inference responses, never the real framework, URLSession transport, credentials, or personal Health data. Add `--foundation-models-unavailable-ui-fixture` for model-not-ready, or `--assistant-reference-ui-fixture` for explicit Health acknowledgements. Local summary fixtures also use `--assistant-ui-fixture --workout-summary-ui-fixture`; the Foundation Models flag keeps ChatGPT signed out. Existing delayed/error summary flags apply to either provider.

Add `--foundation-models-corrupt-archive-ui-fixture` with fresh isolated storage to verify that an unreadable synthetic chat archive is preserved and provider selection explains the blocked save. This flag never touches the production archive.

Capture the provider selector, local chat/chart/proposal/Health states, availability message, Settings, and local workout summary. Inspect light/dark appearance, accessibility text, and a smaller iPhone. Real Foundation Models generation needs separate native verification on supported hardware; deterministic fixtures establish app workflows rather than model quality, language support, download readiness, or actual HealthKit permissions. Verify the iOS 17 fallback and Apple Intelligence disabled/unsupported-device states on their respective systems before distribution.

Verification (2026-10-21): all 441 Core tests pass, XcodeGen regeneration and the final generic iOS Simulator build succeed, and 24 distinct native UI scenarios pass across serial targeted runs on the isolated iPhone 13 mini, iOS 26.5. This is successful coverage across runs, not one combined all-green UI run; the summary retry case passed after correcting its native confirmation helper. Running-app screenshots were inspected in light/dark appearance and accessibility XXXL, including unavailable models and preserved unreadable archives.

The production-identical adapter also passes both tests in a separate temporary native package against the available macOS host system model. These cover text, workout/Health charts, a new-template proposal, ordinary and dense-Health summaries, and an exact ten-template progression workflow. Normal Apply changes all four first-exercise sets from eight to nine reps, preserves the other five exercises exactly, and retains every prior version. Local requests never read ChatGPT credentials. Real-model checks use synthetic records and Health snapshots, not personal readings.

Native prose was inspected as well as completion: the final summaries correctly distinguish 145 lb actual from 135 lb earlier (+10 lb), 108 lb actual from a 100 lb plan, and source Health ranges, means and totals. Completion tests do not establish semantic accuracy. The same run still inferred unsupported peak effort/strength adaptation and stable Health totals, and chat prose said a version was saved before Apply despite the pending proposal and unchanged store. Treat generated interpretations and completion claims as fallible; the proposal card and explicit Apply determine saved state. Muse approved the frozen implementation with these prose limitations disclosed. Dense local summaries can omit all comparable history to fit the context, with explicit coverage counts. Signed-iPhone availability/download/language states, actual HealthKit authorization/readings, iOS 17 runtime and live ChatGPT OAuth remain unverified.

Repeat native prose inspection after changing instructions or evidence projection. A controlled temperature-zero comparison remains an optional quality experiment; the approved adapter retains its verified generation settings.

## Exercise rest overrides

`WorkoutRestTimerTests` covers per-entry inheritance and Off, different overrides for repeated movements, global Off with an enabled override, final-set behavior, immutable template versions, archived-version starts, unit changes, stale logging edits, session-only changes, captured Live Activity progress, relaunch/history/backup/restore, validation, failed writes, restore blocking, legacy JSON, and read-only schema-8 loading with transactional schema-9 migration rollback/retry.

Run `RestTimerUITests` serially on an isolated simulator with the existing `--ui-testing --reset-ui-testing` storage flags. The override flow creates a synthetic burnout routine, cancels and saves a template rest draft, changes the session default, verifies the exercise override and timer after relaunch, restores inheritance, and explicitly disables exercise rest. The existing flow checks inline placement, expiration, restart, minimize/resume, skip and final completion. For visual review, inspect the template exercise Rest row, saved-version details, workout default, exercise draft with inheritance on/off, and an active override countdown in light/dark appearance and accessibility text on a smaller iPhone. Physical-device notification/audio routing and Live Activity delivery still require the existing device checks.

Exercise-rest verification: all 381 core tests pass, XcodeGen generation succeeds, and the final generic iOS Simulator build succeeds. Both native rest scenarios pass across serial runs on LiftLog Exercise Order Small (iPhone 13 mini, iOS 26.5). The initial small-screen run exposed offscreen set/add-set assumptions; selectors now scroll controls into view and bind the selected start action by stable template ID. A later repeat encountered a pre-existing app process with a starter session instead of the isolated fixture; initial launches now explicitly terminate first, and the focused countdown rerun passes. The override flow separately passes cancellation, save, session-only edits, relaunch, inheritance and Off on the final production build. Running-app captures at `/Users/nkania/.t3/artifacts/exercise-rest-2026-10-21/` were inspected for template edits, saved-version detail, workout defaults/overrides, countdowns, inherited/custom drafts, light/dark appearance and accessibility XXXL. Inspection fixed cramped duration controls and workout metrics at accessibility sizes. Screens use isolated synthetic data. iOS 17 runtime, manual VoiceOver gestures, physical-device alert/audio routing, real iCloud transfers and Live Activity delivery were not reverified.

## PR #24 integration with main

Merged main’s exercise rest overrides and schema-9 persistence with the Apple Foundation Models provider, retaining both feature verification sections above. The only textual conflict was the appended testing documentation; no additional UI behavior was changed during resolution. Integration verification: all 449 core tests pass, XcodeGen regeneration succeeds without further project changes, and the generic iOS Simulator build succeeds. Native UI and physical-device checks were not rerun for this merge.


## PR #23 integration with main

Merged main’s exercise rest overrides/schema-9 persistence and Apple Foundation Models provider with the Watch companion. Foreground activation retains both Watch synchronization and provider availability refresh. XcodeGen regenerated the project with both target/source sets. Watch snapshots and optimistic replay retain per-exercise rest overrides; phone completion retains the Watch-supplied timer identity and captured exercise duration, including through active timer extension.

`WatchWorkoutActionTests.testWatchCompletionPreservesExerciseRestOverridesAndTimerIdentity` checks exercise Off, nil inheritance, a 45-second override against a 120-second workout default, an override with the workout default Off, delayed optimistic/authoritative parity, adopted timer identity, and database reload. Extension tests retain captured rest after settings edits, grow active duration by the actual extension, and capture the added rest on expired restart, including one-hour caps. Payload tests round-trip these fields and decode earlier v2 snapshots without them. The Watch ring uses the projected captured duration. All 491 core tests pass. XcodeGen regeneration and the generic iOS and watchOS Simulator builds succeed. Native rest verification and refreshed running-Watch screenshots are recorded below; physical-device connectivity, notifications, HealthKit, and local-model availability still require separate verification.


Follow-up verification (2026-10-21): both `RestTimerUITests` scenarios pass together, serially, on the isolated LiftLog Watch Phone Verification simulator (iPhone 17, iOS 26.5). The first run exposed a test-only visibility assumption: after inserting rest below set 3, set 4 could be offscreen and lack a usable accessibility frame. The positioning helper now scrolls the next row into view before asserting the countdown remains between those rows. The exercise override scenario passed both runs. The final suite has two tests and zero failures. An interactive phone smoke check also saved a 45-second exercise override against a one-minute session default, undid and recompleted a set, and visually confirmed the 45-second countdown. The final generic iOS Simulator rebuild succeeds.

Rebuilt and installed the Watch app on LiftLog Watch Verification (Apple Watch Series 11, 46 mm, watchOS 27.0; `9DC34CF2-9D14-4220-9829-0C3A02C58E57`) and the 41 mm Series 9 simulator. Running-app Now and 45-second-override Rest captures, accessibility text with scrolled continuation, and smaller-screen Rest were inspected at `/Users/nkania/.t3/artifacts/watch-rest-merge-2026-10-21/`. The Watch app explicitly uses dark appearance. The T3 Device panel does not discover these Watch simulators, so installation, launch, and captures used their explicit simctl UDIDs. Review images remain outside source control. Signed pairing/delivery, haptics, background alert handoff, real HealthKit and Foundation Models, and older OS runtimes were not reverified.


## PR #23 Watch offline review fixes

`WatchWorkoutReconcilerTests` now round-trips the production `WatchWorkoutJournal` to cover delivered-but-unacknowledged set edits, partial receipts, pending finish/discard across relaunch, a terminal watermark without a result, confirmed results and saved-screen dismissal. They also check preservation of unreadable/future archives and prior data on failed encoding/filesystem writes. Rest-alert policy tests keep local coverage for a reachable but unacknowledged phone, require the exact workout/timer/deadline before handoff, retain coverage after an extension with the same timer ID, and suppress absent/expired rest.

Verification (2026-10-21): all 495 core tests pass; XcodeGen regeneration and final generic iOS and watchOS Simulator builds succeed. Both `RestTimerUITests` pass serially on LiftLog Watch Phone Verification (iPhone 17, iOS 26.5). The final Watch app was installed and launched against synthetic journal files on the isolated 46 mm and 41 mm Watch simulators (watchOS 27.0), exercising actual journal recovery without the in-memory preview fixture. Restored progress, pending finish (still “Saving…”), pending discard (workout hidden), accessibility text and scrolled continuation captures were inspected at `artifacts/screenshots/watch-review/` and remain uncommitted. The offline banner now occupies its own layout space rather than overlapping workout content. `--watch-preview-accessibility` and `--watch-preview-scroll-bottom` can independently assist DEBUG journal-recovery captures. The Watch app uses dark appearance. The T3 Device panel does not discover Watch simulators, so Watch installation/launch/capture used explicit simctl UDIDs. Signed-device transport delivery, wrist-down/background notification delivery and actual phone/Watch alert handoff still need physical-device verification.


PR #23 transfer-recovery follow-up (2026-10-21): `testTransferRecoveryRetainsFIFOAndIDsAcrossBothCrashWindows` exercises the production outbox drain with injected queue/checkpoint operations. It restores requests saved before queueing, simulates an exit after queueing but before checkpoint, recognizes the existing outstanding transfer, submits only the remaining requests in order, and verifies delivered requests are not resubmitted while awaiting receipts. `testPreCheckpointJournalRecoversOnlyRequestsNotRetiredByCachedReceipt` covers earlier journals without submission metadata and cached receipt retirement. All 497 core tests and final generic iOS/watchOS Simulator builds pass. The Watch journal-recovery screenshots were refreshed on the final build with synthetic delivered-but-unacknowledged requests (saved transfer checkpoints), including 46 mm/41 mm and accessibility text. The two native phone rest UI tests passed on df239c1 and were not rerun for this Watch transport-only follow-up. Signed-device transport recovery and actual notification handoff remain unverified.


PR #23 replay-safety follow-up (2026-10-21): restored requests lacking submission checkpoints now wait for a fresh, matching read-only recovery response from the phone before any replay. `testLegacyOutboxWaitsForFreshPhoneReceiptAfterRestartBeforeReplayingExtensions` uses the real workout store and a decoded journal without checkpoints, restarts the phone after zero/one/two +30s extensions, rejects unrelated probe identities, queues only the unapplied suffix, and verifies exactly 60 seconds added with the final watermark clearing all pending requests. Payload tests cover property-list probe transport, malformed/unsupported probes and decoding snapshots without probe metadata. All 499 core tests and final generic iOS/watchOS Simulator builds pass. Running-app recovery captures were refreshed on the final build; phone rest UI tests were not repeated for this transport-only change. Physical-device background delivery and full phone/Watch connectivity recovery remain unverified.
