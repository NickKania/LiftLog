import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseHistoryDefaultsTests: XCTestCase {
    private let exercise = Exercise(name: "History Lift")

    private func session(_ sets: [WorkoutSet], date: Double = 100, unit: WeightUnit = .lb) -> WorkoutSession {
        WorkoutSession(startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: date), unit: unit,
            exercises: [WorkoutExercise(exercise: exercise, sets: sets)])
    }

    func testUsesLastPerformedSetInLatestFinishedSessionRegardlessOfArrayOrder() {
        let old = session([WorkoutSet(weight: 20, reps: 12, isCompleted: true)])
        let latest = session([
            WorkoutSet(weight: 40, reps: 8, isCompleted: true),
            WorkoutSet(weight: 50, reps: 6, targetReps: 10, targetWeight: 60, isCompleted: true),
            WorkoutSet(weight: 99, reps: 99)
        ], date: 200)
        let before = [old, latest]
        let result = ExerciseHistoryDefaults.set(for: exercise.id, history: before, unit: .lb)
        XCTAssertEqual(result.weight, 50)
        XCTAssertEqual(result.reps, 6)
        XCTAssertFalse(result.isCompleted)
        XCTAssertNil(result.targetWeight)
        XCTAssertNil(result.targetReps)
        XCTAssertNotEqual(result.id, latest.exercises[0].sets[1].id)
        XCTAssertEqual(before, [old, latest])
    }

    func testSkipsUnfinishedAndUncompletedHistoryAndMatchesIdentity() {
        let old = session([WorkoutSet(weight: 0, reps: 15, isCompleted: true)])
        var unfinished = session([WorkoutSet(weight: 90, reps: 2, isCompleted: true)], date: 400)
        unfinished.finishedAt = nil
        let noCompleted = session([WorkoutSet(weight: 80, reps: 3)], date: 300)
        let result = ExerciseHistoryDefaults.set(for: exercise.id, history: [unfinished, noCompleted, old], unit: .lb)
        XCTAssertEqual(result.weight, 0)
        XCTAssertEqual(result.reps, 15)
        let unknown = ExerciseHistoryDefaults.set(for: Exercise(name: exercise.name).id, history: [old], unit: .lb)
        XCTAssertEqual(unknown.weight, 0)
        XCTAssertEqual(unknown.reps, 10)
    }

    func testRepeatedEntriesAndUnitConversionBothDirections() {
        var workout = session([WorkoutSet(weight: 20, reps: 10, isCompleted: true)])
        workout.exercises.append(WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 100, reps: 5, isCompleted: true)]))
        let kg = ExerciseHistoryDefaults.set(for: exercise.id, history: [workout], unit: .kg)
        XCTAssertEqual(kg.weight, 45.359237, accuracy: 0.000001)
        XCTAssertEqual(kg.reps, 5)
        workout.unit = .kg
        let lb = ExerciseHistoryDefaults.set(for: exercise.id, history: [workout], unit: .lb)
        XCTAssertEqual(lb.weight, 100 / 0.45359237, accuracy: 0.000001)
    }

    @MainActor
    func testStoreAddsEditableDefaultsAndPersistsWithoutChangingHistoryOrExistingSets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workouts.sqlite")
        let store = WorkoutStore(fileURL: file)
        let movement = store.exercises[0]
        XCTAssertTrue(store.startWorkout())
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises = [WorkoutExercise(exercise: movement, sets: [WorkoutSet(weight: 135, reps: 7, isCompleted: true)])]
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertTrue(store.finishWorkout())
        let history = store.history
        XCTAssertTrue(store.startWorkout())
        let activeID = try XCTUnwrap(store.activeWorkout?.id)
        XCTAssertFalse(store.addActiveExercise(movement, to: UUID()))
        XCTAssertTrue(store.addActiveExercise(movement, to: activeID))
        let first = try XCTUnwrap(store.activeWorkout?.exercises.first)
        XCTAssertEqual(first.sets[0].weight, 135)
        XCTAssertEqual(first.sets[0].reps, 7)
        XCTAssertFalse(first.sets[0].isCompleted)
        XCTAssertTrue(store.addActiveExercise(movement, to: activeID))
        XCTAssertEqual(store.activeWorkout?.exercises.first, first)
        XCTAssertEqual(store.history, history)
        let restored = WorkoutStore(fileURL: file)
        XCTAssertEqual(restored.activeWorkout, store.activeWorkout)
        XCTAssertEqual(restored.history, history)
    }
}
