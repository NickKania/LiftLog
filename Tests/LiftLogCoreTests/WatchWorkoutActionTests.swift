import Foundation
import XCTest
@testable import LiftLogCore

final class WatchWorkoutActionTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatchTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func start(_ store: WorkoutStore) throws -> WorkoutSession {
        let group = UUID()
        let template = WorkoutTemplate(name: "Watch routine", exercises: [
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: (0..<3).map { _ in
                TemplateSet(weight: 50, targetReps: 8)
            }, supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[1], sets: [TemplateSet(weight: 20, targetReps: 10)], supersetID: group)
        ], restSeconds: 75)
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.applyWatchAction(.startTemplate(id: template.id)))
        return try XCTUnwrap(store.activeWorkout)
    }

    @MainActor
    func testStartTemplateCopiesPrescriptionAndRejectsUnknownOrAlreadyActiveStart() async throws {
        let store = WorkoutStore(fileURL: try file())
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: UUID())))
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.errorMessage)
        let workout = try start(store)
        let template = try XCTUnwrap(store.templates.first { $0.id == workout.templateID })
        XCTAssertEqual(workout.name, template.name)
        XCTAssertEqual(workout.templateVersionID, template.currentVersion?.id)
        XCTAssertEqual(workout.restSeconds, 75)
        XCTAssertEqual(workout.exercises[0].sets[0].targetWeight, 50)
        XCTAssertEqual(workout.exercises[0].sets[0].targetReps, 8)
        XCTAssertNotEqual(workout.exercises[0].sets[0].id, template.exercises[0].sets[0].id)
        let activeRevision = store.revision
        XCTAssertFalse(store.applyWatchAction(.startEmpty))
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: template.id)))
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: UUID())))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.revision, activeRevision)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStartEmptyAndFinishRequiresCompletedWork() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertTrue(store.applyWatchAction(.startEmpty))
        let empty = try XCTUnwrap(store.activeWorkout)
        XCTAssertTrue(empty.exercises.isEmpty)
        XCTAssertFalse(store.applyWatchAction(.finish(workoutID: empty.id)))
        XCTAssertEqual(store.activeWorkout, empty)
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor
    func testCompletePropagatesLikePhonePreservingCompletedSetsTargetsAndOtherEntries() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let sets = workout.exercises[0].sets
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 55, reps: 7)))
        let firstCompleted = try XCTUnwrap(store.activeWorkout?.exercises[0].sets[0])
        // Complete out of order: phone numeric edits affect earlier incomplete sets too.
        let before = Date()
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[2].id, weight: 60, reps: 6)))
        let updated = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(updated.exercises[0].sets[0], firstCompleted)
        XCTAssertEqual(updated.exercises[0].sets[1].weight, 60)
        XCTAssertEqual(updated.exercises[0].sets[1].reps, 6)
        XCTAssertFalse(updated.exercises[0].sets[1].isCompleted)
        XCTAssertEqual(updated.exercises[0].sets[2].weight, 60)
        XCTAssertTrue(updated.exercises[0].sets[2].isCompleted)
        XCTAssertEqual(updated.exercises[0].sets.map(\.targetWeight), [50, 50, 50])
        XCTAssertEqual(updated.exercises[0].sets.map(\.targetReps), [8, 8, 8])
        XCTAssertEqual(updated.exercises[1], workout.exercises[1])
        let timer = try XCTUnwrap(updated.restTimer)
        XCTAssertEqual(timer.completedSetID, sets[2].id)
        XCTAssertGreaterThanOrEqual(timer.endsAt, before.addingTimeInterval(75))
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, updated)
    }

    @MainActor
    func testDuplicateCompletionIsFalseWithoutWritesOrRestRestartEvenWithDifferentValues() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        let action = WatchAction.completeSet(setID: id, weight: 55, reps: 7)
        XCTAssertTrue(store.applyWatchAction(action))
        let completed = store.activeWorkout
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(action))
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 1, reps: 1)))
        XCTAssertEqual(store.activeWorkout, completed)
        XCTAssertEqual(store.revision, revision)
    }

    @MainActor
    func testFinalCompletionClearsRestAndUndoTriggerClearsRest() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let sets = workout.exercises.flatMap(\.sets)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 50, reps: 8)))
        XCTAssertNotNil(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.uncompleteSet(setID: sets[0].id)))
        XCTAssertNil(store.activeWorkout?.restTimer)
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.uncompleteSet(setID: sets[0].id)))
        XCTAssertEqual(store.revision, revision)
        for set in sets {
            XCTAssertTrue(store.applyWatchAction(.completeSet(setID: set.id, weight: set.weight, reps: set.reps)))
        }
        XCTAssertNil(store.activeWorkout?.restTimer)
        XCTAssertTrue(try XCTUnwrap(store.watchWorkoutState.active).isFinished)
    }

    @MainActor
    func testStaleSetIDsIgnoredWithoutMutatingCurrentWorkout() async throws {
        let store = WorkoutStore(fileURL: try file())
        let old = try start(store)
        let id = old.exercises[0].sets[0].id
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: old.id)))
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 50, reps: 8)))
        let current = try start(store)
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 50, reps: 8)))
        XCTAssertFalse(store.applyWatchAction(.uncompleteSet(setID: id)))
        XCTAssertEqual(store.activeWorkout, current)
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testInvalidValuesAndFailedPersistenceDoNotPublishWatchChanges() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        let revision = store.revision
        for action in [WatchAction.completeSet(setID: id, weight: -1, reps: 8),
                       .completeSet(setID: id, weight: .infinity, reps: 8),
                       .completeSet(setID: id, weight: 50, reps: 0)] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.activeWorkout, workout)
            XCTAssertEqual(store.revision, revision)
        }
        let db = try SQLiteConnection(url: url)
        try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 55, reps: 7)))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, workout)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testExtendAndSkipRestActionsUseExistingTimer() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8)))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30)))
        XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, timer.endsAt.addingTimeInterval(30))
        XCTAssertEqual(store.activeWorkout?.restTimer?.id, timer.id)
        XCTAssertEqual(store.activeWorkout?.restSeconds, 75)
        XCTAssertTrue(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testRestActionsRejectEarlierTimerInSameWorkoutWithoutWrites() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let sets = workout.exercises[0].sets
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 50, reps: 8)))
        let oldTimer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[1].id, weight: 50, reps: 8)))
        let current = store.watchWorkoutState
        XCTAssertNotEqual(current.active?.restTimerID, oldTimer.id)
        for action in [WatchAction.skipRest(workoutID: workout.id, restTimerID: oldTimer.id),
                       .extendRest(workoutID: workout.id, restTimerID: oldTimer.id, seconds: 30)] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.watchWorkoutState, current)
            XCTAssertNil(store.errorMessage)
        }
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        let skipped = store.watchWorkoutState
        XCTAssertFalse(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        XCTAssertFalse(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30)))
        XCTAssertEqual(store.watchWorkoutState, skipped)
    }

    @MainActor
    func testFinishSavesOnlyCompletedAndDiscardClearsWithoutHistory() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: id, weight: 55, reps: 7)))
        XCTAssertTrue(store.applyWatchAction(.finish(workoutID: workout.id)))
        XCTAssertNil(store.activeWorkout)
        let saved = try XCTUnwrap(store.history.first)
        XCTAssertEqual(saved.exercises.count, 1)
        XCTAssertEqual(saved.exercises[0].sets.map(\.id), [id])
        XCTAssertEqual(saved.exercises[0].sets[0].weight, 55)
        XCTAssertNil(saved.restTimer)
        XCTAssertNotNil(saved.finishedAt)
        let second = try start(store)
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: second.id)))
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.history, [saved])
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertNil(reloaded.activeWorkout)
        XCTAssertEqual(reloaded.history, [saved])
    }
    @MainActor
    func testQueuedWorkoutActionsCannotAffectALaterWorkout() async throws {
        let store = WorkoutStore(fileURL: try file())
        let old = try start(store)
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: old.id)))
        let current = try start(store)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: current.exercises[0].sets[0].id, weight: 50, reps: 8)))
        let before = store.watchWorkoutState
        let history = store.history
        for action in [WatchAction.finish(workoutID: old.id), .discard(workoutID: old.id),
                       .skipRest(workoutID: old.id, restTimerID: UUID()), .extendRest(workoutID: old.id, restTimerID: UUID(), seconds: 30)] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.watchWorkoutState, before)
            XCTAssertEqual(store.history, history)
            XCTAssertNil(store.errorMessage)
        }
    }

}
