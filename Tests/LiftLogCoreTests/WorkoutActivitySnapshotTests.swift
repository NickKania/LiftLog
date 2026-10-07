import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutActivitySnapshotTests: XCTestCase {
    func testNextSetFollowsExerciseOrderAndRetainsActualPrescriptionAndSessionUnit() throws {
        var workout = WorkoutSession(unit: .kg, exercises: [
            WorkoutExercise(exercise: ExerciseCatalog.all[0], sets: [
                WorkoutSet(weight: 35, reps: 10, isCompleted: true),
                WorkoutSet(weight: 37.5, reps: 8, targetReps: 10, targetWeight: 35),
                WorkoutSet(weight: 37.5, reps: 8)
            ]),
            WorkoutExercise(exercise: ExerciseCatalog.all[1], sets: [WorkoutSet(weight: 60, reps: 5)])
        ])
        var snapshot = workout.activitySnapshot
        XCTAssertEqual(snapshot.workoutID, workout.id)
        XCTAssertEqual(snapshot.startedAt, workout.startedAt)
        XCTAssertEqual(snapshot.nextSet?.exerciseName, workout.exercises[0].exercise.name)
        XCTAssertEqual(snapshot.nextSet?.weight, 37.5)
        XCTAssertEqual(snapshot.nextSet?.reps, 8)
        XCTAssertEqual(snapshot.nextSet?.unit, "kg")
        XCTAssertEqual(snapshot.nextSet?.number, 2)
        XCTAssertEqual(snapshot.nextSet?.total, 3)
        XCTAssertEqual(snapshot.completedSets, 1)
        XCTAssertEqual(snapshot.totalSets, 4)

        workout.exercises[0].sets[2].isCompleted = true // Out-of-order completion still picks the first incomplete set.
        XCTAssertEqual(workout.activitySnapshot.nextSet?.number, 2)
        workout.exercises[0].sets[1].isCompleted = true
        snapshot = workout.activitySnapshot
        XCTAssertEqual(snapshot.nextSet?.exerciseName, workout.exercises[1].exercise.name)
        XCTAssertEqual(snapshot.nextSet?.number, 1)
        workout.exercises[1].sets[0].isCompleted = true
        XCTAssertNil(workout.activitySnapshot.nextSet)
        XCTAssertEqual(workout.activitySnapshot.completedSets, 4)
        workout.exercises[0].sets[0].isCompleted = false
        XCTAssertEqual(workout.activitySnapshot.nextSet?.number, 1)
        workout.exercises.removeFirst()
        XCTAssertNil(workout.activitySnapshot.nextSet)
    }

    func testRestRangePreservesOriginalDeadlineEvenAfterExpiryAndRoundTrips() throws {
        let deadline = Date(timeIntervalSinceReferenceDate: 1000)
        let workout = WorkoutSession(restSeconds: 90,
                                     restTimer: WorkoutRestTimer(completedSetID: UUID(), endsAt: deadline))
        let state = workout.activitySnapshot
        XCTAssertEqual(state.restInterval?.lowerBound, deadline.addingTimeInterval(-90))
        XCTAssertEqual(state.restInterval?.upperBound, deadline)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutActivitySnapshot.self, from: JSONEncoder().encode(state)), state)
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 4096)
    }

    func testLongCustomNamesFitActivityKitPayloadLimitWithoutChangingSavedWorkout() throws {
        let name = String(repeating: "🏋", count: 5000)
        let workout = WorkoutSession(name: name, exercises: [
            WorkoutExercise(exercise: Exercise(name: name), sets: [WorkoutSet(weight: 37.5, reps: 10)])
        ])
        let state = workout.activitySnapshot
        XCTAssertTrue(state.workoutName.hasSuffix("…"))
        XCTAssertTrue(try XCTUnwrap(state.nextSet).exerciseName.hasSuffix("…"))
        XCTAssertEqual(workout.name, name)
        XCTAssertEqual(workout.exercises[0].exercise.name, name)
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 3500)
    }

    @MainActor
    func testPersistedEditsSkipReloadAndFinishProduceCurrentActivityState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workouts.sqlite")
        let store = WorkoutStore(fileURL: url)
        let template = WorkoutTemplate(name: "Live workout", exercises: [TemplateExercise(exercise: ExerciseCatalog.all[0],
            sets: [TemplateSet(weight: 37.5, targetReps: 10), TemplateSet(weight: 37.5, targetReps: 10)])])
        XCTAssertTrue(store.startWorkout(template: template))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let resting = try XCTUnwrap(store.activeWorkout?.activitySnapshot)
        XCTAssertNotNil(resting.restInterval)
        XCTAssertEqual(resting.nextSet?.number, 2)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout?.activitySnapshot, resting)
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[1].weight = 40
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertEqual(store.activeWorkout?.activitySnapshot.nextSet?.weight, 40)
        XCTAssertEqual(store.activeWorkout?.activitySnapshot.restInterval, resting.restInterval)
        XCTAssertTrue(store.skipRest())
        XCTAssertNil(store.activeWorkout?.activitySnapshot.restInterval)
        XCTAssertEqual(store.activeWorkout?.activitySnapshot.nextSet?.number, 2)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertNil(store.activeWorkout?.activitySnapshot)
    }
}
