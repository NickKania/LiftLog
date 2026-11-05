import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutRestTimerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RestTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    private func template(rest: Int = 120) -> WorkoutTemplate {
        WorkoutTemplate(name: "Rest routine", exercises: [TemplateExercise(exercise: ExerciseCatalog.all[0],
            sets: (0..<3).map { _ in TemplateSet(weight: 50, targetReps: 8) })], restSeconds: rest)
    }

    @MainActor
    private func start(_ store: WorkoutStore, rest: Int = 120) throws -> WorkoutSession {
        let plan = template(rest: rest)
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        return try XCTUnwrap(store.activeWorkout)
    }

    func testOldTemplateVersionAndSessionJSONDefaultToTwoMinutes() throws {
        func oldJSON<T: Encodable>(_ value: T) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            object.removeValue(forKey: "restSeconds")
            object.removeValue(forKey: "restTimer")
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(try JSONDecoder().decode(WorkoutTemplate.self, from: oldJSON(template())).restSeconds, 120)
        let version = WorkoutTemplateVersion(number: 1, name: "Old", exercises: template().exercises, unit: .lb)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutTemplateVersion.self, from: oldJSON(version)).restSeconds, 120)
        let session = try JSONDecoder().decode(WorkoutSession.self, from: oldJSON(WorkoutSession()))
        XCTAssertEqual(session.restSeconds, 120)
        XCTAssertNil(session.restTimer)
    }

    @MainActor
    func testChangingOnlyRestVersionsAndCopiesSelectedVersionWithoutChangingActiveSession() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        var plan = try XCTUnwrap(store.templates.first { $0.id == workout.templateID })
        let oldVersion = try XCTUnwrap(plan.currentVersion)
        plan.restSeconds = 45
        XCTAssertTrue(store.saveTemplate(plan))
        plan = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        XCTAssertEqual(plan.versions.map(\.restSeconds), [120, 45])
        workout.restSeconds = 1
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertEqual(store.activeWorkout?.restSeconds, 120)
        XCTAssertTrue(store.discardWorkout())
        XCTAssertTrue(store.startWorkout(template: plan))
        XCTAssertEqual(store.activeWorkout?.restSeconds, 45)
        XCTAssertTrue(store.discardWorkout())
        XCTAssertTrue(store.startWorkout(template: plan, versionID: oldVersion.id))
        XCTAssertEqual(store.activeWorkout?.restSeconds, 120)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(store.templates.first { $0.id == plan.id }?.restSeconds, 45)
    }

    @MainActor
    func testCompletionStartsRestNumericEditsKeepDeadlineNextCompletionRestartsAndFinalSetClears() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store, rest: 90)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let first = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertEqual(first.endsAt, now.addingTimeInterval(90))
        XCTAssertEqual(first.completedSetID, workout.exercises[0].sets[0].id)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].weight = 60
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now.addingTimeInterval(20)))
        XCTAssertEqual(store.activeWorkout?.restTimer, first)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now.addingTimeInterval(40)))
        let restarted = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertNotEqual(restarted.id, first.id)
        XCTAssertEqual(restarted.endsAt, now.addingTimeInterval(130))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[2].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now.addingTimeInterval(50)))
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testUndoDeleteSkipOffFinishAndDiscardCancelRest() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = false
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertTrue(store.skipRest())
        XCTAssertNil(store.activeWorkout?.restTimer)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets.remove(at: 1)
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets.append(WorkoutSet())
        workout.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNotNil(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertNil(store.activeWorkout)
        XCTAssertNil(store.history[0].restTimer)
        workout = try start(store)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertTrue(store.discardWorkout())
        XCTAssertNil(store.activeWorkout)
        workout = try start(store, rest: 0)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testFailureCannotStartOrCancelRestAndReloadBackupPreserveExactDeadline() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var workout = try start(store, rest: 75)
        workout.exercises[0].sets[0].isCompleted = true
        store.beginRestore()
        XCTAssertFalse(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer)
        store.endRestore()
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        store.beginRestore()
        XCTAssertFalse(store.skipRest())
        XCTAssertFalse(store.finishWorkout())
        XCTAssertFalse(store.discardWorkout())
        XCTAssertEqual(store.activeWorkout?.restTimer, timer)
        store.endRestore()
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout?.restTimer, timer)
        XCTAssertEqual(try WorkoutDatabase(url: backup).load().activeWorkout?.restTimer, timer)
        XCTAssertTrue(store.skipRest())
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.activeWorkout?.restTimer, timer)
        XCTAssertEqual(store.activeWorkout?.restSeconds, 75)
        XCTAssertEqual(timer.remainingSeconds(at: now.addingTimeInterval(10.1)), 65)
        XCTAssertEqual(timer.remainingSeconds(at: now.addingTimeInterval(1000)), 0)
    }

    @MainActor
    func testReadOnlyV2BackupDefaultsAndV3MigrationIsTransactional() async throws {
        let url = try file()
        let plan = template()
        let version = WorkoutTemplateVersion(number: 1, name: plan.name, exercises: plan.exercises, unit: .lb)
        var savedPlan = plan
        savedPlan.versions = [version]
        let saved = WorkoutSnapshot(templates: [savedPlan], history: [], activeWorkout: WorkoutSession(), unit: .lb)
        let database = WorkoutDatabase(url: url)
        try database.save(saved)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("ALTER TABLE records DROP COLUMN rest_seconds")
            try db.execute("ALTER TABLE records DROP COLUMN rest_timer")
            try db.execute("DROP TABLE exercise_instruction_overrides")
            try db.execute("DROP TABLE favorite_exercises")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN superset_id")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.removeHistoryEditingSchema()
            try db.execute("PRAGMA user_version = 2")
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'failed upgrade'); END")
        }
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(try database.load().templates[0].restSeconds, 120)
        XCTAssertEqual(try database.load().activeWorkout?.restSeconds, 120)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try database.save(saved))
        do {
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 2)
            XCTAssertFalse(try db.rows("PRAGMA table_info(records)").contains { try $0.text("name") == "rest_seconds" })
            try db.execute("DROP TRIGGER reject_records")
        }
        let store = WorkoutStore(fileURL: url)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 10)
    }

    @MainActor
    func testExtendRestPersistsDeadlineAndPreservesTimerIdentityAndRestSetting() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var workout = try start(store, rest: 90)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        let revision = store.revision
        XCTAssertTrue(store.extendRest(by: 30))
        let extended = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertEqual(extended.endsAt, timer.endsAt.addingTimeInterval(30))
        XCTAssertEqual(extended.id, timer.id)
        XCTAssertEqual(extended.completedSetID, timer.completedSetID)
        XCTAssertEqual(extended.durationSeconds, 120)
        XCTAssertEqual(store.activeWorkout?.restSeconds, 90)
        XCTAssertEqual(store.revision, revision + 1)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout?.restTimer, extended)
    }

    @MainActor
    func testExtendRestWithoutWorkoutOrTimerAndNonpositiveDurationsAreNoOps() async throws {
        let store = WorkoutStore(fileURL: try file())
        let idleRevision = store.revision
        XCTAssertFalse(store.extendRest(by: 30))
        XCTAssertFalse(store.skipRest())
        XCTAssertEqual(store.revision, idleRevision)
        var workout = try start(store)
        let activeRevision = store.revision
        XCTAssertFalse(store.extendRest(by: 30))
        XCTAssertFalse(store.skipRest())
        XCTAssertEqual(store.revision, activeRevision)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let resting = store.activeWorkout
        let restingRevision = store.revision
        XCTAssertFalse(store.extendRest(by: 0))
        XCTAssertFalse(store.extendRest(by: -30))
        XCTAssertEqual(store.activeWorkout, resting)
        XCTAssertEqual(store.revision, restingRevision)
    }

    @MainActor
    func testExtendRestClampsHugeExtensionsToOneHourRemaining() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let before = Date()
        XCTAssertTrue(store.extendRest(by: Int.max))
        let after = Date()
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertGreaterThanOrEqual(timer.endsAt, before.addingTimeInterval(3600))
        XCTAssertLessThanOrEqual(timer.endsAt, after.addingTimeInterval(3600))
        XCTAssertEqual(timer.remainingSeconds(at: before), 3600)
        XCTAssertEqual(timer.durationSeconds, 3600)
    }

    @MainActor
    func testExtendExpiredDeadlineStartsNewTimerFromNowAndRestoreBlocksWrites() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let original = try XCTUnwrap(store.activeWorkout?.restTimer)
        store.beginRestore()
        XCTAssertFalse(store.extendRest(by: 30))
        XCTAssertEqual(store.activeWorkout?.restTimer, original)
        store.endRestore()
        let before = Date()
        XCTAssertTrue(store.extendRest(by: 30))
        let after = Date()
        let restarted = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertNotEqual(restarted.id, original.id)
        XCTAssertEqual(restarted.completedSetID, original.completedSetID)
        XCTAssertEqual(restarted.durationSeconds, 30)
        XCTAssertGreaterThanOrEqual(restarted.endsAt, before.addingTimeInterval(30))
        XCTAssertLessThanOrEqual(restarted.endsAt, after.addingTimeInterval(30))
        XCTAssertEqual(store.activeWorkout?.restSeconds, 120)
    }

    @MainActor
    func testInvalidRestDurationsCannotSave() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertFalse(store.saveTemplate(template(rest: -1)))
        XCTAssertFalse(store.saveTemplate(template(rest: 3601)))
    }
    @MainActor
    func testExerciseOverridesVersionIndependentlyAndCopyIntoSelectedSession() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var plan = template()
        XCTAssertTrue(store.saveTemplate(plan))
        plan = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        let originalVersion = try XCTUnwrap(plan.currentVersion)
        plan.exercises[0].restSeconds = 30
        XCTAssertTrue(store.saveTemplate(plan))
        plan = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        XCTAssertEqual(plan.versions.count, 2)
        XCTAssertNil(plan.versions[0].exercises[0].restSeconds)
        XCTAssertEqual(plan.versions[1].exercises[0].restSeconds, 30)
        XCTAssertTrue(store.startWorkout(template: plan))
        XCTAssertEqual(store.activeWorkout?.exercises[0].restSeconds, 30)
        plan.exercises[0].restSeconds = 0
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertEqual(store.activeWorkout?.exercises[0].restSeconds, 30)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(store.templates.first { $0.id == plan.id }?.exercises[0].restSeconds, 0)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout?.exercises[0].restSeconds, 30)
        XCTAssertTrue(store.discardWorkout())
        XCTAssertTrue(store.startWorkout(template: plan, versionID: originalVersion.id))
        XCTAssertNil(store.activeWorkout?.exercises[0].restSeconds)
    }

    @MainActor
    func testCompletedExerciseDeterminesDurationIncludingDuplicateEntriesAndOff() async throws {
        let store = WorkoutStore(fileURL: try file())
        var plan = template(rest: 90)
        let movement = plan.exercises[0].exercise
        plan.exercises[0].restSeconds = 30
        plan.exercises.append(TemplateExercise(exercise: movement, restSeconds: 0))
        plan.exercises.append(TemplateExercise(exercise: movement))
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertEqual(timer.endsAt, now.addingTimeInterval(30))
        XCTAssertEqual(timer.durationSeconds, 30)
        XCTAssertEqual(store.activeWorkout?.activitySnapshot.restInterval?.lowerBound, now)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[1].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer, "Completing an Off exercise clears the previous rest")
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[2].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, now.addingTimeInterval(90))
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, restSeconds: 0))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertEqual(store.activeWorkout?.restTimer?.durationSeconds, 30, "Override works even with the workout default Off")
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[2].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertNil(store.activeWorkout?.restTimer, "The final set never starts rest")
    }

    @MainActor
    func testSessionSettingsPreserveCountdownAndStaleLoggingCannotRevertThem() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        let stale = workout
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, restSeconds: 60))
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, exerciseID: workout.exercises[0].id, restSeconds: 15))
        XCTAssertEqual(store.activeWorkout?.restTimer, timer)
        XCTAssertEqual(store.activeWorkout?.activitySnapshot.restInterval?.lowerBound, now)
        XCTAssertEqual(store.templates.first { $0.id == workout.templateID }?.restSeconds, 120)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.restSeconds = stale.restSeconds
        workout.exercises[0].restSeconds = stale.exercises[0].restSeconds
        workout.exercises[0].sets[1].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        XCTAssertEqual(store.activeWorkout?.restSeconds, 60)
        XCTAssertEqual(store.activeWorkout?.exercises[0].restSeconds, 15)
        XCTAssertEqual(store.activeWorkout?.restTimer?.durationSeconds, 15)
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, exerciseID: workout.exercises[0].id, restSeconds: nil))
        XCTAssertNil(store.activeWorkout?.exercises[0].restSeconds)
        XCTAssertEqual(store.activeWorkout?.restTimer?.durationSeconds, 15)
    }

    @MainActor
    func testRestSettingsPersistThroughHistoryBackupAndRestoreWithAtomicFailures() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var workout = try start(store)
        let id = workout.exercises[0].id
        let before = store.activeWorkout
        let db = try SQLiteConnection(url: url)
        try db.execute("CREATE TRIGGER reject_rest BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertFalse(store.updateRestSettings(workoutID: workout.id, exerciseID: id, restSeconds: 30))
        XCTAssertEqual(store.activeWorkout, before)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, before)
        try db.execute("DROP TRIGGER reject_rest")
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, exerciseID: id, restSeconds: 30))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let saved = try XCTUnwrap(store.activeWorkout)
        let backup = url.deletingLastPathComponent().appendingPathComponent("rest-backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, saved)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history[0].exercises[0].restSeconds, 30)
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.activeWorkout, saved)
        store.beginRestore()
        XCTAssertFalse(store.updateRestSettings(workoutID: saved.id, exerciseID: id, restSeconds: nil))
        store.endRestore()
        XCTAssertEqual(store.activeWorkout, saved)
        XCTAssertFalse(store.updateRestSettings(workoutID: UUID(), restSeconds: 30))
        XCTAssertFalse(store.updateRestSettings(workoutID: saved.id, exerciseID: UUID(), restSeconds: 30))
        XCTAssertFalse(store.updateRestSettings(workoutID: saved.id, restSeconds: nil))
        XCTAssertFalse(store.updateRestSettings(workoutID: saved.id, exerciseID: id, restSeconds: -1))
        XCTAssertFalse(store.updateRestSettings(workoutID: saved.id, exerciseID: id, restSeconds: 3601))
        var invalid = template()
        invalid.exercises[0].restSeconds = -1
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid.exercises[0].restSeconds = 3601
        XCTAssertFalse(store.saveTemplate(invalid))
    }

    func testLegacyExerciseAndTimerJSONInheritWithoutChangingDeadlines() throws {
        let exercise = template().exercises[0]
        XCTAssertNil(try JSONDecoder().decode(TemplateExercise.self, from: JSONEncoder().encode(exercise)).restSeconds)
        let entry = WorkoutExercise(exercise: exercise.exercise)
        XCTAssertNil(try JSONDecoder().decode(WorkoutExercise.self, from: JSONEncoder().encode(entry)).restSeconds)
        let timer = WorkoutRestTimer(completedSetID: entry.sets[0].id, endsAt: now)
        let decoded = try JSONDecoder().decode(WorkoutRestTimer.self, from: JSONEncoder().encode(timer))
        XCTAssertNil(decoded.durationSeconds)
        XCTAssertEqual(decoded.endsAt, now)
        XCTAssertEqual(WorkoutSession(restSeconds: 75).restDuration(for: decoded), 75)
    }

    func testSchemaEightRemainsReadOnlyAndFailedNineMigrationRollsBack() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        var plan = template()
        plan.versions = [WorkoutTemplateVersion(number: 1, name: plan.name, exercises: plan.exercises, unit: .lb)]
        let snapshot = WorkoutSnapshot(templates: [plan], history: [], activeWorkout: WorkoutSession(exercises: [WorkoutExercise(exercise: plan.exercises[0].exercise)]), unit: .lb)
        try database.save(snapshot)
        let db = try SQLiteConnection(url: url)
        try db.execute("ALTER TABLE exercise_entries DROP COLUMN rest_seconds")
        try db.execute("ALTER TABLE records DROP COLUMN summary")
        try db.execute("PRAGMA user_version = 8")
        try db.execute("CREATE TRIGGER reject_rest BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(try database.load().templates, snapshot.templates)
        XCTAssertEqual(try database.load().activeWorkout, snapshot.activeWorkout)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try database.save(snapshot))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 8)
        XCTAssertFalse(try db.rows("PRAGMA table_info(exercise_entries)").contains { try $0.text("name") == "rest_seconds" })
        try db.execute("DROP TRIGGER reject_rest")
        try database.save(snapshot)
        XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 10)
        XCTAssertEqual(try database.load().templates, snapshot.templates)
        XCTAssertEqual(try database.load().activeWorkout, snapshot.activeWorkout)
    }

    @MainActor
    func testChangingLegacyTimerSettingsPreservesItsOriginalActivityInterval() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var workout = try start(store, rest: 90)
        workout.exercises[0].sets[0].isCompleted = true
        workout.restTimer = WorkoutRestTimer(completedSetID: workout.exercises[0].sets[0].id, endsAt: now.addingTimeInterval(90))
        try WorkoutDatabase(url: url).save(WorkoutSnapshot(templates: store.templates, history: [], activeWorkout: workout, unit: .lb))
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertTrue(reloaded.updateRestSettings(workoutID: workout.id, restSeconds: 0))
        XCTAssertEqual(reloaded.activeWorkout?.restTimer?.endsAt, workout.restTimer?.endsAt)
        XCTAssertEqual(reloaded.activeWorkout?.restTimer?.durationSeconds, 90)
        XCTAssertEqual(reloaded.activeWorkout?.activitySnapshot.restInterval?.lowerBound, now)
    }

    func testReplacementRetainsEntryRestAndHistoryCorrectionsCannotRewriteIt() throws {
        var plan = template()
        plan.exercises[0].restSeconds = 30
        let replacement = try ExerciseReplacement.replacing(plan, expectedEntry: plan.exercises[0], with: ExerciseCatalog.all[1])
        XCTAssertEqual(replacement.exercises[0].restSeconds, 30)
        var workout = WorkoutSession(exercises: [WorkoutExercise(exercise: plan.exercises[0].exercise, restSeconds: 30)])
        let swapped = try ExerciseReplacement.replacing(workout, expectedEntry: workout.exercises[0], with: ExerciseCatalog.all[1])
        XCTAssertEqual(swapped.exercises[0].restSeconds, 30)
        workout.finishedAt = workout.startedAt.addingTimeInterval(60)
        workout.exercises[0].sets[0].isCompleted = true
        var correction = workout
        correction.exercises[0].restSeconds = 60
        XCTAssertThrowsError(try WorkoutHistoryEditing.validated(correction, replacing: workout))
    }

}
