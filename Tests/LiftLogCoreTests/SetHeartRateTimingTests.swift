import Foundation
import XCTest
@testable import LiftLogCore

final class SetHeartRateTimingTests: XCTestCase {
    private func time(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 1_000 + seconds) }

    private func fixture() -> WorkoutSession {
        WorkoutSession(startedAt: time(0), exercises: [
            WorkoutExercise(exercise: Exercise(name: "Row", category: "Back"), sets: [WorkoutSet(), WorkoutSet()]),
            WorkoutExercise(exercise: Exercise(name: "Curl", category: "Arms"), sets: [WorkoutSet()])
        ])
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    func testLegacyJSONDecodesWithoutTimingFields() throws {
        let json = #"{ "id":"00000000-0000-0000-0000-000000000001", "weight":20, "reps":8, "isCompleted":true }"#
        let set = try JSONDecoder().decode(WorkoutSet.self, from: Data(json.utf8))
        XCTAssertTrue(set.isCompleted)
        XCTAssertNil(set.startedAt)
        XCTAssertNil(set.completedAt)
        XCTAssertFalse(set.isMarkedForHeartRate)
    }

    @MainActor
    func testTimerExclusivityCompletionUndoAndRelaunch() throws {
        let workout = fixture()
        let url = try databaseURL()
        try WorkoutDatabase(url: url).save(WorkoutSnapshot(templates: [], history: [], activeWorkout: workout, unit: .lb))
        let store = WorkoutStore(fileURL: url)
        let row = workout.exercises[0]
        let curl = workout.exercises[1]
        XCTAssertTrue(store.startSetTimer(workoutID: workout.id, exerciseID: row.id, setID: row.sets[0].id, now: time(-5)))
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].startedAt, time(0))
        XCTAssertTrue(store.startSetTimer(workoutID: workout.id, exerciseID: curl.id, setID: curl.sets[0].id, now: time(12)))
        XCTAssertNil(store.activeWorkout?.exercises[0].sets[0].startedAt)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].isMarkedForHeartRate, true)
        XCTAssertFalse(store.startSetTimer(workoutID: workout.id, exerciseID: row.id, setID: row.sets[0].id,
                                           now: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(store.activeWorkout?.exercises[1].sets[0].startedAt, time(12))
        XCTAssertTrue(store.cancelSetTimer(workoutID: workout.id, exerciseID: curl.id, setID: curl.sets[0].id))
        XCTAssertNil(store.activeWorkout?.exercises[1].sets[0].startedAt)
        XCTAssertEqual(store.activeWorkout?.exercises[1].sets[0].isMarkedForHeartRate, true)

        XCTAssertTrue(store.startSetTimer(workoutID: workout.id, exerciseID: row.id, setID: row.sets[0].id, now: time(20)))
        var draft = try XCTUnwrap(store.activeWorkout)
        draft.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(draft, now: time(15)))
        draft = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(draft.exercises[0].sets[0].completedAt, time(20))
        draft.exercises[0].sets[0].startedAt = time(100)
        draft.exercises[0].sets[0].completedAt = nil
        draft.exercises[0].sets[0].isMarkedForHeartRate = false
        XCTAssertTrue(store.updateActiveWorkout(draft, now: time(30)))
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].startedAt, time(20))
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].completedAt, time(20))
        XCTAssertTrue(store.toggleSetHeartRateMark(workoutID: workout.id, exerciseID: row.id, setID: row.sets[0].id))
        draft = try XCTUnwrap(store.activeWorkout)
        draft.exercises[0].sets[0].isCompleted = false
        XCTAssertTrue(store.updateActiveWorkout(draft, now: time(31)))
        let undone = try XCTUnwrap(store.activeWorkout?.exercises[0].sets[0])
        XCTAssertNil(undone.startedAt)
        XCTAssertNil(undone.completedAt)
        XCTAssertTrue(undone.isMarkedForHeartRate)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
    }

    @MainActor
    func testWatchAndSiriCompletionAndFinishFloor() throws {
        let workout = fixture()
        let url = try databaseURL()
        try WorkoutDatabase(url: url).save(WorkoutSnapshot(templates: [], history: [], activeWorkout: workout, unit: .lb))
        let store = WorkoutStore(fileURL: url)
        let row = workout.exercises[0]
        let setID = row.sets[0].id
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: setID, weight: 30, reps: 8,
                                                           completedAt: time(45), restTimerID: UUID()), now: time(40)))
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].completedAt, time(40))
        _ = try SiriWorkoutActions.complete(store: store, entryID: row.id, setID: row.sets[1].id, expectedWorkoutID: workout.id)
        let latest = try XCTUnwrap(store.activeWorkout?.exercises[0].sets[1].completedAt)
        XCTAssertGreaterThan(latest, time(40))
        XCTAssertTrue(store.finishWorkout(now: time(-1)))
        XCTAssertEqual(store.history.first?.finishedAt, latest)
        XCTAssertEqual(store.history.first?.exercises.count, 1)
    }

    @MainActor
    func testUpdateActiveWorkoutProtectsTimestampOwnershipAndSingleActiveTimer() throws {
        let workout = fixture()
        let url = try databaseURL()
        try WorkoutDatabase(url: url).save(WorkoutSnapshot(templates: [], history: [], activeWorkout: workout, unit: .lb))
        let store = WorkoutStore(fileURL: url)
        var draft = workout
        // Ordinary updates cannot forge startedAt on incomplete sets or new completed sets.
        draft.exercises[0].sets[0].startedAt = time(12)
        draft.exercises[0].sets[1].isCompleted = true
        draft.exercises[0].sets[1].startedAt = time(15)
        draft.exercises[0].sets[1].completedAt = time(10)
        draft.exercises[0].sets.append(WorkoutSet(isCompleted: true, startedAt: time(5), completedAt: time(8)))
        XCTAssertTrue(store.updateActiveWorkout(draft, now: time(20)))
        XCTAssertNil(store.activeWorkout?.exercises[0].sets[0].startedAt)
        XCTAssertNil(store.activeWorkout?.exercises[0].sets[1].startedAt)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[1].completedAt, time(20))
        XCTAssertNil(store.activeWorkout?.exercises[0].sets[2].startedAt)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[2].completedAt, time(20))

        // Snapshot validation rejects multiple concurrent incomplete timers.
        var overlapping = fixture()
        overlapping.exercises[0].sets[0].startedAt = time(10)
        overlapping.exercises[0].sets[1].startedAt = time(15)
        XCTAssertThrowsError(try WorkoutStore.validate(WorkoutSnapshot(templates: [], history: [], activeWorkout: overlapping, unit: .lb)))
    }

    @MainActor
    func testReviewedWorkoutRejectsPreexistingSetTimestamps() throws {
        let store = WorkoutStore(fileURL: try databaseURL())
        var draft = fixture()
        draft.exercises[0].sets[0].startedAt = time(1)
        XCTAssertFalse(store.startReviewedWorkout(draft))
        XCTAssertNil(store.activeWorkout)
        draft.exercises[0].sets[0].startedAt = nil
        draft.exercises[0].sets[0].completedAt = time(1)
        XCTAssertFalse(store.startReviewedWorkout(draft))
        XCTAssertNil(store.activeWorkout)
        draft.exercises[0].sets[0].completedAt = nil
        XCTAssertTrue(store.startReviewedWorkout(draft))
    }

    func testValidationAndHistoryDateBounds() throws {
        var original = fixture()
        original.exercises.removeLast()
        original.finishedAt = time(60)
        original.exercises[0].sets = [WorkoutSet(isCompleted: true, startedAt: time(10), completedAt: time(20))]
        var draft = original
        draft.exercises[0].sets[0].isMarkedForHeartRate = true
        XCTAssertEqual(try WorkoutHistoryEditing.validated(draft, replacing: original), draft)
        draft.startedAt = time(11)
        XCTAssertThrowsError(try WorkoutHistoryEditing.validated(draft, replacing: original)) {
            XCTAssertTrue($0.localizedDescription.contains("include all recorded set times"))
        }
        draft = original
        draft.exercises[0].sets[0].startedAt = nil
        XCTAssertThrowsError(try WorkoutHistoryEditing.validated(draft, replacing: original))
        XCTAssertThrowsError(try WorkoutHistoryEditing.validated(original))
        for set in [
            WorkoutSet(isCompleted: true, startedAt: time(-1)),
            WorkoutSet(isCompleted: true, startedAt: time(30), completedAt: time(20)),
            WorkoutSet(isCompleted: true, completedAt: time(61)),
            WorkoutSet(isCompleted: true, completedAt: Date(timeIntervalSinceReferenceDate: .infinity))
        ] {
            draft = original
            draft.exercises[0].sets = [set]
            XCTAssertThrowsError(try WorkoutStore.validate(WorkoutSnapshot(templates: [], history: [draft], activeWorkout: nil, unit: .lb)))
        }
        draft.finishedAt = nil
        draft.exercises[0].sets = [WorkoutSet(completedAt: time(20))]
        XCTAssertThrowsError(try WorkoutStore.validate(WorkoutSnapshot(templates: [], history: [], activeWorkout: draft, unit: .lb)))
    }

    @MainActor
    func testV10ReadOnlyLoadV11MigrationAndBackupRoundTrip() async throws {
        let url = try databaseURL()
        let workout = fixture()
        var snapshot = WorkoutSnapshot(templates: [], history: [], activeWorkout: workout, unit: .lb)
        try WorkoutDatabase(url: url).save(snapshot)
        do {
            let db = try SQLiteConnection(url: url)
            try db.removeSetHeartRateSchema()
            try db.execute("PRAGMA user_version = 10")
        }
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("legacy.sqlite")
        try FileManager.default.copyItem(at: url, to: backupURL)
        let bytes = try Data(contentsOf: backupURL)
        XCTAssertEqual(try WorkoutDatabase(url: backupURL).load().activeWorkout, workout)
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)

        snapshot.activeWorkout?.exercises[0].sets[0].isMarkedForHeartRate = true
        snapshot.activeWorkout?.exercises[0].sets[0].startedAt = time(20)
        snapshot.activeWorkout?.exercises[0].sets[0].completedAt = time(25)
        snapshot.activeWorkout?.exercises[0].sets[0].isCompleted = true
        try WorkoutDatabase(url: url).save(snapshot)
        XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 11)
        XCTAssertEqual(try WorkoutDatabase(url: url).load().activeWorkout, snapshot.activeWorkout)

        let cloud = url.deletingLastPathComponent().appendingPathComponent("Cloud")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = CloudBackupManager(databaseURL: url, repository: CloudBackupRepository(directoryProvider: { cloud }),
                                         preferences: defaults)
        let store = WorkoutStore(fileURL: url, cloudBackup: manager)
        await manager.backUpNow()
        let backup = try XCTUnwrap(manager.backups.first)
        XCTAssertTrue(store.discardWorkout())
        await manager.restore(backup, into: store)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(store.activeWorkout, snapshot.activeWorkout)
    }
}
