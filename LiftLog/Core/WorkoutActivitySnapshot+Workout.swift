import Foundation

extension WorkoutSession {
    var activitySnapshot: WorkoutActivitySnapshot {
        let nextSet = exercises.lazy.compactMap { exercise -> WorkoutActivitySnapshot.NextSet? in
            guard let index = exercise.sets.firstIndex(where: { !$0.isCompleted }) else { return nil }
            let set = exercise.sets[index]
            return .init(exerciseName: Self.activityLabel(exercise.exercise.name), weight: set.weight, unit: unit.rawValue,
                         reps: set.reps, number: index + 1, total: exercise.sets.count)
        }.first
        let interval = restTimer.map { timer in
            timer.endsAt.addingTimeInterval(-Double(max(1, restSeconds)))...timer.endsAt
        }
        let sets = exercises.flatMap(\.sets)
        return .init(workoutID: id, workoutName: Self.activityLabel(name), startedAt: startedAt,
                     restInterval: interval, nextSet: nextSet,
                     completedSets: sets.filter(\.isCompleted).count, totalSets: sets.count)
    }

    private static func activityLabel(_ name: String) -> String {
        // ActivityKit limits combined attributes and state to 4 KB. Keep even
        // unusually long custom exercise names within that budget.
        let scalars = name.unicodeScalars
        return String(String.UnicodeScalarView(scalars.prefix(120))) + (scalars.count > 120 ? "…" : "")
    }
}
