#if DEBUG
import Foundation

/// Synthetic prescriptions for duplicate-entry and superset ordering acceptance tests.
@MainActor
enum ExerciseOrderUITestFixture {
    static func seed(in store: WorkoutStore) {
        guard store.activeWorkout == nil else { return }
        let group = UUID()
        let plan = WorkoutTemplate(name: "Exercise order review", exercises: [
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 100, targetReps: 5)], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[4], sets: [TemplateSet(weight: 70, targetReps: 8)], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 50, targetReps: 12)]),
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 100, targetReps: 5)])
        ])
        guard store.saveTemplate(plan), store.startWorkout(template: plan) else { return }
        if ProcessInfo.processInfo.arguments.contains("--exercise-order-unlinked-ui-fixture"), var workout = store.activeWorkout {
            workout.exercises = workout.exercises.map {
                WorkoutExercise(exercise: $0.exercise, sets: $0.sets, supersetID: $0.supersetID)
            }
            store.updateActiveWorkout(workout)
        }
    }
}
#endif
