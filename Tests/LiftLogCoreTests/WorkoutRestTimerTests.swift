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
        XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 3)
    }

    @MainActor
    func testInvalidRestDurationsCannotSave() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertFalse(store.saveTemplate(template(rest: -1)))
        XCTAssertFalse(store.saveTemplate(template(rest: 3601)))
    }
}
