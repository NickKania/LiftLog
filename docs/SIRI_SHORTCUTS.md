# Siri and Shortcuts

Lift Log exposes six App Shortcuts on iOS 17 and later. No account, Health authorization, or network connection is required to log workouts. Siri itself remains subject to system availability and language support.

- “Start a workout in Lift Log” starts an empty workout.
- “Start [template] in Lift Log” starts the latest default version of a saved template. “Start a template workout in Lift Log” asks for a template.
- “End my workout in Lift Log” asks for confirmation and saves completed sets to history. Incomplete sets are omitted. At least one completed set is required.
- “Add an exercise in Lift Log” asks for a catalog/personal exercise. “Add [exercise] in Lift Log” is registered only for the first 20 catalog exercises returned as suggestions; direct-name recognition still requires physical-device verification. For other catalog or personal exercises, use “Add an exercise in Lift Log” and search/select through the follow-up prompt. The exercise gets one set of 10 reps at zero weight, matching the native picker; edit weight/reps in the app.
- “Remove an exercise in Lift Log” asks for a current workout entry and confirmation. Entries with completed sets require review in the app and cannot be removed through Siri.
- “Complete a set in Lift Log” asks for an incomplete set. It uses the currently entered weight and reps (initially prefilled targets for template workouts) and follows normal rest-timer behavior.

The same actions appear in Shortcuts under Lift Log. Repeated exercises are distinguished by their exercise position, and sets by exercise position and set number. Set choices omit completed sets. Saved current-exercise and set parameters bind to the specific session/entry/set IDs: reuse after finishing, deleting, or replacing that workout fails rather than editing another session. Re-select a current parameter when this happens. Template parameters intentionally use stable template IDs and resolve the latest saved default. The app requests a system shortcut-parameter refresh at launch and whenever templates are saved, renamed, or deleted; system indexing may take time.

All actions open the app, requiring unlock when appropriate, and use the same main-actor store as SwiftUI and the Watch adapter. They do not open a second database writer or require an app group, Siri entitlement, credentials, or a new persistence schema. `AppWorkoutStore` initializes exactly once, even when Siri reaches a query before scene creation; existing isolated UI testing flags are retained. Intent errors avoid speaking database paths. Confirmation suspension is followed by a live workout-identity check before mutation. Numeric values and completed-set targets remain unchanged by completion.

## Validation

`SiriWorkoutActionsTests` covers transactional mutations, persistence/relaunch, invalid or stale selections, duplicate entries, targets, rest timers, completed-entry removal protection, empty finish, and save rollback. `WorkoutIntentEntityTests` checks session-bound identities, duplicate positions, incomplete-only sets, empty queries, and shortcut exposure in the iOS app target.

Run `swift test`, the generic Simulator build, and the `LiftLogAppTests/WorkoutIntentEntityTests` test class. On a physical iPhone, verify all six actions in Shortcuts and spoken Siri phrases, including template/exercise disambiguation, confirmation cancellation, a locked phone, cold launch, existing active workout, no active workout, renamed/deleted templates, and retrying a saved set after finishing. Confirm the app reflects changes immediately, values match the logged facts, rest alerts/Live Activity update, and changes survive relaunch. Voice recognition, locked-device behavior, and system shortcut indexing are not established by unit tests or metadata extraction alone.
