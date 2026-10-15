import Foundation

/// Explicit draft operations. Fresh entry/set identities discard any stale numeric
/// editor input, while immutable source versions remain independent value snapshots.
enum ExerciseReplacement {
    static func replacing(_ template: WorkoutTemplate, expectedEntry: TemplateExercise, with exercise: Exercise) throws -> WorkoutTemplate {
        guard let index = template.exercises.firstIndex(where: { $0.id == expectedEntry.id }),
              template.exercises[index] == expectedEntry else { throw ReplacementError.staleEntry }
        guard expectedEntry.exercise.id != exercise.id else { throw ReplacementError.sameExercise }
        var updated = template
        updated.exercises[index] = TemplateExercise(
            exercise: exercise,
            sets: expectedEntry.sets.map { TemplateSet(weight: 0, targetReps: $0.targetReps) },
            supersetID: expectedEntry.supersetID
        )
        return updated
    }

    static func replacing(_ workout: WorkoutSession, expectedEntry: WorkoutExercise, with exercise: Exercise) throws -> WorkoutSession {
        guard workout.finishedAt == nil else { throw ReplacementError.finishedWorkout }
        guard let index = workout.exercises.firstIndex(where: { $0.id == expectedEntry.id }),
              workout.exercises[index] == expectedEntry else { throw ReplacementError.staleEntry }
        guard !expectedEntry.sets.contains(where: \.isCompleted) else { throw ReplacementError.completedSets }
        guard expectedEntry.exercise.id != exercise.id else { throw ReplacementError.sameExercise }
        var updated = workout
        updated.exercises[index] = WorkoutExercise(
            exercise: exercise,
            sets: expectedEntry.sets.map { WorkoutSet(weight: 0, reps: $0.reps) },
            supersetID: expectedEntry.supersetID
        )
        return updated
    }

    private enum ReplacementError: LocalizedError {
        case staleEntry, completedSets, sameExercise, finishedWorkout

        var errorDescription: String? {
            switch self {
            case .staleEntry: "This exercise changed after you opened the swap. Reopen it before choosing a replacement."
            case .completedSets: "An exercise with completed sets cannot be swapped. Add another exercise to log a different movement."
            case .sameExercise: "Choose a different exercise to swap."
            case .finishedWorkout: "Completed workouts cannot have their exercises swapped."
            }
        }
    }
}
