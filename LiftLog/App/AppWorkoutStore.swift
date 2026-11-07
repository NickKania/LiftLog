import Foundation

/// One in-process owner, including when an intent initializes before the SwiftUI scene.
@MainActor
enum AppWorkoutStore {
    static let shared: WorkoutStore = makeStore()

    private static func makeStore() -> WorkoutStore {
        let workoutStore: WorkoutStore
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogUITests.sqlite")
            if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
                try? FileManager.default.removeItem(at: url)
            }
            if ProcessInfo.processInfo.arguments.contains("--history-long-workout-ui-fixture") {
                do { try HealthDashboardUITestFixture.seedLongWorkoutIfNeeded(at: url) }
                catch { preconditionFailure("Could not seed the synthetic long workout: \(error.localizedDescription)") }
            }
            workoutStore = WorkoutStore(fileURL: url)
        } else {
            workoutStore = WorkoutStore()
        }
        #else
        workoutStore = WorkoutStore()
        #endif
        #if DEBUG
        if HealthDashboardUITestFixture.isEnabled {
            HealthDashboardUITestFixture.seedWorkouts(in: workoutStore)
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--exercise-order-ui-fixture") {
            ExerciseOrderUITestFixture.seed(in: workoutStore)
        }
        #endif
        return workoutStore
    }
}
