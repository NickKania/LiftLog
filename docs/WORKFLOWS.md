# Workflows and automated coverage

Lift Log is a local-first iOS app. Its backend is the Foundation-based `WorkoutStore` and transactional SQLite persistence. Optional iCloud Drive backups are managed by Apple’s document storage service.

## User workflows

| Workflow | Expected behavior | Automated coverage |
| --- | --- | --- |
| Create a routine | Name a template, select exercises, add sets, enter planned weights and target reps, save | `LiftLogUITests` template-to-history test; core template create/edit/delete tests |
| Validate or cancel a draft | Missing names/exercises and invalid set input prevent saving; cancel leaves no template | `WorkflowUITests` template validation/cancel test; `SetInputValidationTests` |
| Find or create an exercise | Search the offline catalog without case sensitivity, or add a custom name; selection survives relaunch | `WorkflowUITests` exercise search/custom test; core catalog and snapshot tests |
| Find common names or spelling suggestions | Search aliases such as OHP; see labeled possible matches for typos without automatic selection; keep filters and custom creation | `ExerciseSearchTests`; `ExerciseSearchUITests` |
| Replace an exercise | Review a metadata suggestion or searched candidate, confirm with zero load, save a template version or only the active session; protect completed sets and earlier versions | `ExerciseAlternativesTests`; `ExerciseReplacementTests`; `ExerciseSwapUITests` |
| Filter and inspect exercises | Combine equipment/muscle/type filters with search, inspect source metadata without selecting, recover from no matches, then explicitly add | `ExerciseDiscoveryTests`; `ExerciseDiscoveryUITests` |
| Personalize exercise steps | Read default steps immediately, edit/add/reorder/remove in a draft, cancel without changes, save across relaunch, restore defaults, or explicitly remove no-default personal steps; invalid drafts show inline feedback | `ExerciseInstructionTests`; `ExerciseInstructionsUITests` |
| Favorite and revisit exercises | Save favorites independently of drafts and retain preference order; find recent exercises ordered by completed-session finish time; preserve favorites through relaunch and backup/restore | `ExerciseFavoritesTests`; `ExerciseDiscoveryTests`; `ExerciseDiscoveryUITests` |
| Review catalog credits | Open Settings → Credits & Licenses, inspect the pinned source and review limits, and read the full bundled license without signing in | `CatalogCreditsUITests`; catalog content and generator regression tests |
| Edit supersets | Group exercise entries, revise membership, or remove a group; restoring the saved membership within a draft leaves the prescription unchanged; deleting ungrouped entries reports only the exercise removal | `SupersetTests`; `SupersetUITests`, including remove/recreate and rename without a new version |
| Plan progression | Open Plan Next Workout, compare the last session, adjust targets, and save a new default version; browse and start earlier versions | Template version core tests and version UI workflow |
| Log a session | Start from a template or empty workout; edit actual values across an exercise's remaining sets while preserving completed results, targets, and independent completion flags | `LiftLogUITests` propagation and template-to-history tests; core session snapshot tests |
| Reorder workout exercises | Identify entries by original number, targets, superset label, and template-link status, then drag in Reorder Exercises; Save updates the active order and matching template order atomically as a new default version; Cancel discards the draft | `ExerciseOrderTests`; `ExerciseOrderUITests` |
| Rest between sets | Set a workout rest period (default two minutes), override or disable it per exercise, and edit session-only settings; completion uses that exercise’s duration when sets remain; current countdowns retain their deadline after settings edits; skip, undo, finish, and discard cancel them | `WorkoutRestTimerTests`; `RestTimerUITests` |
| Resume training | Minimize or relaunch, then resume with saved values and completion state | `LiftLogUITests` relaunch tests; core persistence tests |
| Finish and review | Complete sets, confirm finish, open history; omit incomplete sets | `LiftLogUITests` template-to-history test; core completion filtering/history tests |
| Choose an assistant provider | Explicitly select ChatGPT or on-device Apple Intelligence; show availability reasons; keep conversations separate and prevent automatic cloud fallback | `AssistantProviderTests`; `FoundationModelsRequestTests`; `FoundationModelsUITests` |
| Ask for local workout guidance | Ask without an account, tag workout/template snapshots or per-message Health, create charts, review proposed edits, and retain local chats | `AssistantProviderTests`; `FoundationModelsRequestTests`; `FoundationModelsUITests` |
| Review workout insights | See saved stats and persisted workout-only insights from History offline after relaunch; explicitly regenerate feedback, optionally include temporary Health-assisted insights, or opt into future automatic workout-only insights | `WorkoutSummaryContextTests`; `WorkoutSummaryStoreTests`; `WorkoutSummaryUITests` |
| Customize summary coaching | Edit the summary prompt in Settings; Save or Cancel a draft, restore the default, and retain local preferences across relaunch | `WorkoutSummaryContextTests`; `WorkoutSummaryUITests` |
| Correct or add completed history | Open a workout → Edit, or History → Add Past Workout; independently edit completed rows, dates and notes, review, then save; Cancel discards the draft and Undo Last Correction restores the previous complete record after relaunch | `WorkoutHistoryEditingTests`; `WorkoutHistoryEditingUITests` |
| Rename a completed workout | Swipe left in History, choose Rename, edit the name, then Save or Cancel | `WorkoutImportUITests` rename test; core history rename persistence, validation, and save failure tests |
| Discard training | Cancel discard to keep training, or confirm to clear the session without history | `WorkflowUITests` discard test; core discard test |
| Back up or restore | Enable automatic backups, save on demand, or confirm replacement from a selected iCloud snapshot | `StorageAndBackupTests`; physical-device iCloud checks |
| Change weight units | Persist the preference and convert templates; existing sessions retain recorded units | `WorkflowUITests` settings test; core conversion tests |

## Core flows

1. **Launch:** load and validate SQLite, migrate preserved legacy JSON if no database exists, or seed starter templates for a new installation. Corrupt, unsupported, or inconsistent saved files remain untouched and block mutations.
2. **Template mutation:** validate names, set values, and item IDs; trim the template name; create a template, rename without changing saved versions, append a version for prescription changes, or delete a template; atomically persist before updating published state.
3. **Start:** reject an invalid template or an existing active session; resolve the chosen saved version and copy the plan with fresh item IDs, version attribution, and weight/rep target snapshots; persist one active session.
4. **Update:** validate the active session identity and editable data; retain its original start time, template reference, and unit; persist ordinary logged edits without changing templates or history. Explicit exercise-order saves also reorder matching template entries and append a default version atomically.
5. **Finish:** require completed work; filter incomplete sets and empty exercises; prepend the finished snapshot to history and clear the active session in the same commit.
6. **Discard:** clear the active session without recording history, then permit a new workout.
7. **Unit change:** convert template loads and persist the preference; leave active and finished session snapshots intact.
8. **History correction/manual entry:** validate a separate completed-record draft, compare the captured original for corrections, preserve source identities and targets, then commit the record and its recovery slot atomically. Manual entries leave active workouts and templates unchanged. Undo restores the prior full record and removes its recovery slot.
9. **Save failure:** report an error and retain prior in-memory state; allow a later valid operation to recover after the storage problem is removed.

`StorageAndBackupTests` covers JSON migration, SQLite rollback, unsupported database versions, standalone WAL backups, complete restore, damaged local recovery, corrupt backup rejection, edit blocking, offline backup failure, remote metadata listing, and per-installation retention.

`WorkoutStoreTests` covers the main lifecycle, catalog compatibility, legacy reps migration, conversion, and rollback. `WorkoutStoreFlowTests` extends boundary and persistence coverage. `SetInputValidationTests` directly tests the numeric parsing used by the SwiftUI set editor; these are unit tests, while `WorkflowUITests` and `LiftLogUITests` are simulator UI integration tests.

See [Testing](TESTING.md) for commands and remaining manual device, accessibility, and layout checks. UI automation covers representative paths; it does not replace those manual checks.

Workout rest defaults and per-exercise overrides are saved with each template version and copied into independent sessions. Exercises inherit the default unless explicitly overridden, including Off. Session-only settings affect future completions without changing templates or an existing countdown. Countdown deadlines persist across minimizing, suspension, relaunch, and backups. Foreground tones work without notification permission; background alerts require notification permission and enabled sounds, and follow system notification settings. Completing the last planned set does not start a rest timer.


Watch offline recovery is covered by `WatchWorkoutReconcilerTests`: restored progress and finish/discard requests survive relaunch even after transport delivery; partial acknowledgements retain later requests; terminal results and dismissal persist. Reachable phones take over rest alerts only after matching the workout, timer and deadline, including extensions with unchanged timer IDs. Physical-device delivery and wrist-down alert handoff remain separate acceptance checks.

The Watch outbox tests also cover saved-but-unqueued request recovery, exits before the transfer checkpoint, matching outstanding transfers without duplicate submission, FIFO operation identity, cached receipt retirement and decoding journals created before transfer checkpoints.

Recovered Watch requests without transfer checkpoints wait for a matching fresh, read-only phone recovery response before replay. The restarted-phone regression applies zero, one or two rest extensions before relaunch and verifies that only the unapplied suffix is sent, rest grows by exactly 60 seconds, and the final receipt clears the pending ledger.

Enriched Markdown rendering is shared by assistant replies and workout summaries. `AssistantMarkdownRenderingTests` covers generated-content image/link privacy and partial Markdown; the native formatting/copy and summary wide-table tests cover the rendered screens. See [Testing](TESTING.md#enriched-markdown-assistant-and-summaries) for fixture and visual checks.
