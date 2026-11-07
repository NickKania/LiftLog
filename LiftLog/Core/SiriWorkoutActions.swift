import Foundation

/// Voice actions resolve captured identities against current local data immediately before saving.
/// All mutations share the phone's transactional persistence and rest-timer rules.
@MainActor
enum SiriWorkoutActions {
    struct ActionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func start(store: WorkoutStore, templateID: UUID?) throws -> String {
        guard store.activeWorkout == nil else {
            throw ActionError(message: "Finish or discard your current workout before starting another.")
        }
        let template: WorkoutTemplate?
        if let templateID {
            guard let saved = store.templates.first(where: { $0.id == templateID }) else {
                throw ActionError(message: "That template is no longer available. Choose a template again.")
            }
            template = saved
        } else {
            template = nil
        }
        try saved(store.startWorkout(template: template))
        return "Started \(store.activeWorkout?.name ?? "Workout")."
    }

    static func finish(store: WorkoutStore, expectedWorkoutID: UUID) throws -> String {
        let workout = try active(store: store, expectedWorkoutID: expectedWorkoutID)
        guard workout.exercises.contains(where: { $0.sets.contains(where: \.isCompleted) }) else {
            throw ActionError(message: "Complete at least one set before finishing your workout.")
        }
        try saved(store.finishWorkout())
        return "Finished \(workout.name)."
    }

    static func add(store: WorkoutStore, exerciseID: UUID, expectedWorkoutID: UUID) throws -> String {
        var workout = try active(store: store, expectedWorkoutID: expectedWorkoutID)
        guard let exercise = store.exercises.first(where: { $0.id == exerciseID }) else {
            throw ActionError(message: "That exercise is no longer available. Choose an exercise again.")
        }
        // Match the native active-workout picker, including allowing repeated movements.
        workout.exercises.append(WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 0, reps: 10)]))
        try saved(store.updateActiveWorkout(workout))
        return "Added \(exercise.name)."
    }

    static func remove(store: WorkoutStore, entryID: UUID, expectedWorkoutID: UUID) throws -> String {
        var workout = try active(store: store, expectedWorkoutID: expectedWorkoutID)
        guard let index = workout.exercises.firstIndex(where: { $0.id == entryID }) else {
            throw ActionError(message: "That exercise is no longer in this workout. Choose an exercise again.")
        }
        let entry = workout.exercises[index]
        guard !entry.sets.contains(where: \.isCompleted) else {
            throw ActionError(message: "This exercise has completed sets. Open LiftLog to review it before removing it.")
        }
        workout.exercises.remove(at: index)
        try saved(store.updateActiveWorkout(workout))
        return "Removed \(entry.exercise.name)."
    }

    static func complete(store: WorkoutStore, entryID: UUID, setID: UUID, expectedWorkoutID: UUID) throws -> String {
        var workout = try active(store: store, expectedWorkoutID: expectedWorkoutID)
        guard let entry = workout.exercises.firstIndex(where: { $0.id == entryID }),
              let set = workout.exercises[entry].sets.firstIndex(where: { $0.id == setID }) else {
            throw ActionError(message: "That set is no longer in this workout. Choose a set again.")
        }
        guard !workout.exercises[entry].sets[set].isCompleted else {
            throw ActionError(message: "That set is already complete.")
        }
        workout.exercises[entry].sets[set].isCompleted = true
        try saved(store.updateActiveWorkout(workout))
        return "Completed set \(set + 1) of \(workout.exercises[entry].exercise.name)."
    }

    private static func active(store: WorkoutStore, expectedWorkoutID: UUID) throws -> WorkoutSession {
        guard let workout = store.activeWorkout, workout.id == expectedWorkoutID else {
            throw ActionError(message: "That workout is no longer active. Choose the current workout again.")
        }
        return workout
    }

    private static func saved(_ success: Bool) throws {
        // Database errors may contain internal paths; keep the spoken failure useful and private.
        guard success else {
            throw ActionError(message: "Your change could not be saved. Open LiftLog to check your local storage and try again.")
        }
    }
}
