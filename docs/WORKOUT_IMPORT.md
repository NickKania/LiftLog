# Workout import

Import adds completed sessions to History. Strong CSV is the first supported format. Other applications should get their own parser that produces the same preview and completed-session models; accepting arbitrary CSV by guessing column meanings would risk changing workout data.

## Mapping

| Strong field | Lift Log representation |
| --- | --- |
| Date + Workout Name | A session group, with the name preserved and date interpreted in the time zone chosen during import |
| Duration | `finishedAt = startedAt + duration` |
| Exercise Name | An ordered `WorkoutExercise`, matched conservatively to the catalog or kept under its original name |
| Set Order | A completed set in source order; `Rest Timer` rows are excluded |
| Weight | Recorded weight in the explicitly selected source unit |
| Reps | Actual reps; integral decimal values such as `10.0` are accepted |
| Distance / Seconds | Unsupported timed or distance rows are excluded with a review warning |
| RPE | A review warning explains that RPE is not retained |

Imported sets have no target reps, and sessions have no template reference. Import does not create reusable templates or infer planned targets from completed work. Zero weight is valid for bodyweight exercises. Negative/nonfinite weights, fractional/nonpositive reps, and invalid dates or durations cannot become saved workout values.

The supplied example has one 55-minute session, five exercises, 20 completed sets, and 20 rest-timer rows. Strong's example header contains neither weight units nor a time zone. Both need user confirmation; current app/device preferences are only initial selections, not inferred source facts.

The file picker accepts UTF-8 CSV files up to 5 MB. Durations must be positive and no longer than seven days. Warning record numbers count parsed CSV records, including the header, rather than physical lines inside quoted fields.

## Flow

1. Open History and choose Import Workouts.
2. Select a Strong CSV using Files.
3. Confirm the export's weight unit and time zone.
4. Review workout and set totals, skipped rows, and warnings. Review exercise matches and choose a catalog exercise or retain the source name. Select one or multiple sessions and inspect their details.
5. Import the selection. A successful result reports the number saved and any duplicates skipped.

Nothing is persisted while choosing a file, changing matches, or reviewing sessions. Canceling leaves saved data unchanged. The store validates and saves the batch atomically before publishing it. Existing templates, the current workout, and unit preferences remain independent of the import.

## Identity and limitations

Imported sessions retain a source identity so importing an overlapping export again can skip previously imported sessions, including after relaunch. The identity is independent of catalog choices, the chosen unit, and time-zone interpretation. Strong's format has no session ID: its local date and workout name are the available session identity. Two distinct sessions sharing both cannot be distinguished reliably. Renaming a source session may make it appear new; corrections to an already imported session are not an update mechanism.

Saved unmatched exercises join the personal catalog in the same atomic commit as their imported sessions. They become searchable when adding exercises to templates or workouts and are available to the importer on subsequent launches. Names deduplicate case and whitespace, with bundled exercises preferred; newly saved custom entries reuse the existing identity. Skipped duplicates, canceled previews, and failed writes do not register exercises. Previously imported custom exercises are backfilled when loading older saved files without altering their historical snapshots.

Exercise matching is conservative. Ambiguous or unmatched names retain the original name unless the user selects a catalog entry. Mapping choices apply to the current import; matching searches the merged bundled and personal catalog. No fuzzy match silently equates different equipment or exercise variants.

The current workout model supports weight and reps. Review warnings make unsupported measurements visible before saving; this is not a lossless archival importer. Keep the source export if its rest timers, RPE, timed exercises, or distance measurements matter.
