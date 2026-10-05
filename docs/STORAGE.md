# SQLite storage and iCloud Drive backups

Workouts are stored on the device in `Application Support/LiftLog/workouts.sqlite`. The app uses the system SQLite library, with no additional package dependencies. Templates, exercise snapshots, sets, history, personal exercises, and the current workout save in one transaction. A failed save leaves both the database and published state unchanged.

## Upgrade from JSON

When no SQLite database exists, the app reads an existing `workouts.json`, validates it, and builds the database in a staging file before installing it. The original JSON remains untouched. Legacy template `reps` fields and snapshots without personal exercises or target reps are supported. Once SQLite exists, the legacy JSON never replaces it. Damaged data blocks writes and displays an error rather than resetting workouts.

## Template version migration

Schema version 2 stores template revision history, session version attribution, and planned set weights. Version-1 SQLite files and backups remain readable. On launch, templates without revisions gain a baseline version in one migration transaction; later saves also upgrade older database schemas transactionally. An unsuccessful write leaves the original schema and data intact. Restore reads the source backup without modifying it and writes the upgraded working database through staging.

Existing templates receive an initial version from their saved prescription. Existing sessions retain their recorded values; missing version references or planned weights are left unknown rather than inferred from a template that may have changed. Versions preserve their original weight units, including in backups.

## Enable iCloud for a signed app

1. Open `LiftLog.xcodeproj` after running `xcodegen generate`.
2. Select the LiftLog app target and your Apple development team in Signing & Capabilities. That team must support iCloud provisioning.
3. Enable iCloud with **iCloud Documents** and register/select **`iCloud.com.liftlog.app`**. Ensure the App ID and provisioning profile include that container and the CloudDocuments entitlement.
4. If changing the bundle or container identifier, update `project.yml`, `CloudBackupRepository.containerIdentifier`, and `LiftLog/Info.plist` together, then regenerate the project.
5. Install on an iPhone signed in to iCloud with iCloud Drive enabled for Lift Log. Open Settings → iCloud Drive Backups.

The entitlements and public iCloud Drive folder metadata are checked into the project. A simulator build with signing disabled validates compilation, but does not provision the Apple container or verify real iCloud transfers.

## Backup behavior

Automatic backups start disabled. Turning them on schedules a snapshot after changes. Edits debounce for five seconds, with a 15-minute interval between foreground automatic snapshots; leaving the app flushes pending changes. Back Up Now creates a snapshot immediately. Cloud errors do not block saving workouts locally. Failed automatic attempts retry on a later edit or foreground transition.

Backups are standalone SQLite files under `iCloud Drive/Lift Log/Backups`. The app creates a consistent local snapshot using the [SQLite backup API](https://www.sqlite.org/backup.html), then writes it through [Apple file coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator). Filename timestamps and unique installation/file identifiers prevent two devices from overwriting each other.

“Last backup saved” means a file was written to the local iCloud container. Apple uploads it asynchronously when connectivity and account state permit. The restore picker reports waiting, uploading, uploaded, or upload-failed status. Data is protected by the user’s iCloud account and the device’s normal file protection; no separate app encryption key is created.

Retention keeps the newest 30 uploaded snapshots from each installation, plus all snapshots still awaiting upload. Cleanup runs on backup and refresh. Files from other installations remain untouched. Users can manage files in iCloud Drive. Deleting the app removes its local database and device preferences; already uploaded cloud files remain available after reinstalling.

## Restore behavior

Settings → Restore from Backup searches the app’s iCloud Documents container, including remote files that are not downloaded yet. Select a backup and confirm replacement. The app downloads it, stages a coordinated copy locally, checks SQLite identity/version/integrity and workout values, and blocks edits during the operation.

Before replacement, the current database is saved as `Application Support/LiftLog/before-restore-<UUID>.sqlite`. If the current file is damaged, its raw bytes are preserved instead. A failed download or invalid backup cannot replace local data. A successful restore replaces the entire dataset and immediately updates the screens, including any active workout. Local recovery files remain in the sandbox for manual recovery; they are not automatically uploaded or listed in the cloud restore picker.

Backups support recovery and transferring a dataset between devices. They do not merge simultaneous edits. Local data remains the source used while logging workouts, and restore is always an explicit action.

See [testing](TESTING.md) for the signed-device acceptance checklist.
