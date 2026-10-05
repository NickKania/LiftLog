# Workflows and automated coverage

Lift Log is a local-first iOS app. Its backend is the Foundation-based `WorkoutStore` and transactional SQLite persistence. Optional iCloud Drive backups are managed by Apple’s document storage service.

## User workflows

| Workflow | Expected behavior | Automated coverage |
| --- | --- | --- |
| Create a routine | Name a template, select exercises, add sets, enter planned weights and target reps, save | `LiftLogUITests` template-to-history test; core template create/edit/delete tests |
| Validate or cancel a draft | Missing names/exercises and invalid set input prevent saving; cancel leaves no template | `WorkflowUITests` template validation/cancel test; `SetInputValidationTests` |
| Find or create an exercise | Search the offline catalog without case sensitivity, or add a custom name; selection survives relaunch | `WorkflowUITests` exercise search/custom test; core catalog and snapshot tests |
| Plan progression | Open Plan Next Workout, compare the last session, adjust targets, and save a new default version; browse and start earlier versions | Template version core tests and version UI workflow |
| Log a session | Start from a template or empty workout; edit actual values across an exercise's sets while preserving targets and independent completion flags | `LiftLogUITests` propagation and template-to-history tests; core session snapshot tests |
| Resume training | Minimize or relaunch, then resume with saved values and completion state | `LiftLogUITests` relaunch tests; core persistence tests |
| Finish and review | Complete sets, confirm finish, open history; omit incomplete sets | `LiftLogUITests` template-to-history test; core completion filtering/history tests |
| Discard training | Cancel discard to keep training, or confirm to clear the session without history | `WorkflowUITests` discard test; core discard test |
| Back up or restore | Enable automatic backups, save on demand, or confirm replacement from a selected iCloud snapshot | `StorageAndBackupTests`; physical-device iCloud checks |
| Change weight units | Persist the preference and convert templates; existing sessions retain recorded units | `WorkflowUITests` settings test; core conversion tests |

## Core flows

1. **Launch:** load and validate SQLite, migrate preserved legacy JSON if no database exists, or seed starter templates for a new installation. Corrupt, unsupported, or inconsistent saved files remain untouched and block mutations.
2. **Template mutation:** validate names, set values, and item IDs; trim the template name; create a template, append a changed version, or delete a template; atomically persist before updating published state.
3. **Start:** reject an invalid template or an existing active session; resolve the chosen saved version and copy the plan with fresh item IDs, version attribution, and weight/rep target snapshots; persist one active session.
4. **Update:** validate the active session identity and editable data; retain its original start time, template reference, and unit; persist edits without changing templates or history.
5. **Finish:** require completed work; filter incomplete sets and empty exercises; prepend the finished snapshot to history and clear the active session in the same commit.
6. **Discard:** clear the active session without recording history, then permit a new workout.
7. **Unit change:** convert template loads and persist the preference; leave active and finished session snapshots intact.
8. **Save failure:** report an error and retain prior in-memory state; allow a later valid operation to recover after the storage problem is removed.

`StorageAndBackupTests` covers JSON migration, SQLite rollback, unsupported database versions, standalone WAL backups, complete restore, damaged local recovery, corrupt backup rejection, edit blocking, offline backup failure, remote metadata listing, and per-installation retention.

`WorkoutStoreTests` covers the main lifecycle, catalog compatibility, legacy reps migration, conversion, and rollback. `WorkoutStoreFlowTests` extends boundary and persistence coverage. `SetInputValidationTests` directly tests the numeric parsing used by the SwiftUI set editor; these are unit tests, while `WorkflowUITests` and `LiftLogUITests` are simulator UI integration tests.

See [Testing](TESTING.md) for commands and remaining manual device, accessibility, and layout checks. UI automation covers representative paths; it does not replace those manual checks.
