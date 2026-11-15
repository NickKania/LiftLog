import Foundation

/// Suggestions use performed values only; they never become prescription targets.
enum ExerciseHistoryDefaults {
    static func set(for exerciseID: UUID, history: [WorkoutSession], unit: WeightUnit) -> WorkoutSet {
        let sessions = history.filter { $0.finishedAt != nil }.sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt! > $1.finishedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
        for session in sessions {
            // For repeated entries, use the last completed set in workout order.
            for entry in session.exercises.reversed() where entry.exercise.id == exerciseID {
                guard let set = entry.sets.last(where: { $0.isCompleted }) else { continue }
                let factor = session.unit == unit ? 1 : (unit == .kg ? 0.45359237 : 1 / 0.45359237)
                return WorkoutSet(weight: set.weight * factor, reps: set.reps)
            }
        }
        return WorkoutSet(weight: 0, reps: 10)
    }
}
