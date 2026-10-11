#if DEBUG
import Foundation

/// Local, reproducible dashboard data available only in an explicitly opted-in UI test.
@MainActor
enum HealthDashboardUITestFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--health-dashboard-ui-fixture")
    }

    static func seedWorkouts(in store: WorkoutStore, now: Date = Date()) {
        precondition(isEnabled, "Dashboard fixtures require an explicit UI test launch.")
        let names = ["Bench Press", "Barbell Row", "Squat", "Deadlift"]
        let exercises = names.map { name in
            guard let exercise = store.exercises.first(where: { $0.name == name }) else {
                preconditionFailure("The dashboard fixture requires the bundled exercise \(name).")
            }
            return exercise
        }
        let templates = (0..<2).map { index in
            WorkoutTemplate(id: identifier(100 + index), name: index == 0 ? "Fixture Upper Body" : "Fixture Lower Body",
                exercises: exercises[(index * 2)..<(index * 2 + 2)].enumerated().map { offset, exercise in
                    TemplateExercise(id: identifier(200 + index * 2 + offset), exercise: exercise,
                        sets: [TemplateSet(id: identifier(300 + index * 2 + offset), weight: 135, targetReps: 8)])
                })
        }
        for template in templates where !store.templates.contains(where: { $0.id == template.id }) {
            precondition(store.saveTemplate(template), "Could not save a dashboard fixture routine.")
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let dayOffsets = [1, 3, 5, 8, 12, 18, 24, 35, 50, 70, 105, 150]
        var sessions = dayOffsets.enumerated().map { index, daysAgo in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
            let templateIndex = index % 2
            let template = store.templates.first { $0.id == templates[templateIndex].id }!
            let unit: WeightUnit = index % 3 == 1 ? .kg : .lb
            let factor = unit == .kg ? 0.45359237 : 1
            let load = Double((templateIndex == 0 ? 185 : 225) - index * 5)
            let entries = exercises[(templateIndex * 2)..<(templateIndex * 2 + 2)].enumerated().map { offset, exercise in
                let weight = (load - Double(offset * 40)) * factor
                return WorkoutExercise(id: identifier(1_000 + index * 10 + offset), exercise: exercise, sets: [
                    WorkoutSet(id: identifier(2_000 + index * 10 + offset * 3), weight: weight, reps: 6,
                        targetReps: 8, targetWeight: weight, isCompleted: true),
                    WorkoutSet(id: identifier(2_001 + index * 10 + offset * 3), weight: weight - 5 * factor, reps: 8,
                        targetReps: 8, targetWeight: weight, isCompleted: true)
                ])
            }
            return WorkoutSession(id: identifier(10_000 + index), templateID: template.id,
                templateVersionID: template.currentVersion?.id, templateVersionNumber: template.currentVersion?.number,
                name: template.name, startedAt: start,
                finishedAt: start.addingTimeInterval(Double(32 + index % 5 * 4) * 60), unit: unit,
                importSourceKey: "health-dashboard-ui-fixture-\(index)", exercises: entries)
        }
        if ProcessInfo.processInfo.arguments.contains("--health-dashboard-overlap-ui-fixture") {
            // Simulate importing a workout already recorded locally, with distinct
            // record identities but an identical Health time window.
            var duplicate = sessions[0]
            duplicate.id = identifier(20_000)
            duplicate.importSourceKey = "health-dashboard-overlap-0"
            for index in duplicate.exercises.indices {
                duplicate.exercises[index].id = identifier(30_000 + index)
                for setIndex in duplicate.exercises[index].sets.indices {
                    duplicate.exercises[index].sets[setIndex].id = identifier(40_000 + index * 10 + setIndex)
                }
            }
            sessions.append(duplicate)
        }
        precondition(store.importWorkouts(sessions) != nil, "Could not save dashboard fixture workouts.")
    }

    static func makeHealthDataProvider() -> any WorkoutHealthDataProviding {
        precondition(isEnabled, "Dashboard fixtures require an explicit UI test launch.")
        return HealthDashboardFixtureProvider()
    }

    private static func identifier(_ suffix: Int) -> UUID {
        UUID(uuidString: "4845414C-5448-4000-8000-" + String(format: "%012d", suffix))!
    }
}

/// Synthetic session-scoped readings; this provider never touches HealthKit.
@MainActor
private struct HealthDashboardFixtureProvider: WorkoutHealthDataProviding {
    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: through)
        let index = Int(workout.importSourceKey?.split(separator: "-").last ?? "0") ?? 0
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
            startedAt: interval.start, endedAt: interval.end, fetchedAt: through, metrics: [
                WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [
                    WorkoutHealthSample(date: interval.start.addingTimeInterval(60), value: Double(110 + index * 5)),
                    WorkoutHealthSample(date: interval.start.addingTimeInterval(120), value: Double(130 + index * 5))
                ]),
                WorkoutHealthMetricSeries(metric: .heartRate, samples: [
                    WorkoutHealthSample(date: interval.start.addingTimeInterval(60), value: Double(112 + index)),
                    WorkoutHealthSample(date: interval.start.addingTimeInterval(120), value: Double(136 + index))
                ])
            ])
    }
}
#endif
