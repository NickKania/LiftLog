import AppIntents
import XCTest
@testable import LiftLog

final class WorkoutIntentEntityTests: XCTestCase {
    @MainActor
    func testQueriesPreserveRepeatedEntryIdentityAndOmitCompletedSets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        XCTAssertTrue(ActiveExerciseQuery.values(store).isEmpty)
        XCTAssertTrue(ActiveSetQuery.values(store).isEmpty)
        XCTAssertEqual(WorkoutTemplateQuery.values(store).map(\.id), store.templates.map(\.id))
        XCTAssertTrue(store.startWorkout())
        let exercise = try XCTUnwrap(store.exercises.first)
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises = [
            WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 10, reps: 8), WorkoutSet(weight: 10, reps: 8)]),
            WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 20, reps: 5)])
        ]
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let entries = ActiveExerciseQuery.values(store)
        let sets = ActiveSetQuery.values(store)
        XCTAssertEqual(entries.map(\.position), [1, 2])
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertEqual(Set(sets.map(\.id)).count, 3)
        XCTAssertEqual(sets.map(\.setNumber), [1, 2, 1])
        XCTAssertEqual(sets.map(\.exercisePosition), [1, 1, 2])
        _ = try SiriWorkoutActions.complete(store: store, entryID: sets[0].entryID, setID: sets[0].setID, expectedWorkoutID: sets[0].workoutID)
        XCTAssertEqual(ActiveSetQuery.values(store).map(\.id), Array(sets.dropFirst()).map(\.id))
        XCTAssertTrue(store.discardWorkout())
        XCTAssertTrue(ActiveExerciseQuery.values(store).isEmpty)
        XCTAssertTrue(ActiveSetQuery.values(store).isEmpty)
    }

    func testShortcutCatalogExposesAllRequestedActions() {
        XCTAssertEqual(LiftLogShortcuts.appShortcuts.count, 6)
        XCTAssertTrue(StartWorkoutIntent.openAppWhenRun)
        XCTAssertTrue(StartTemplateWorkoutIntent.openAppWhenRun)
        XCTAssertTrue(EndWorkoutIntent.openAppWhenRun)
        XCTAssertTrue(AddWorkoutExerciseIntent.openAppWhenRun)
        XCTAssertTrue(RemoveWorkoutExerciseIntent.openAppWhenRun)
        XCTAssertTrue(CompleteWorkoutSetIntent.openAppWhenRun)
    }
}
