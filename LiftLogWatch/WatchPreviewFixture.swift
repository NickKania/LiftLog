#if DEBUG
import Foundation

/// Synthetic, memory-only screenshots. Never activates WCSession or requests notifications.
enum WatchPreviewFixture {
    private static let supersetID = UUID()
    /// Extra screenshot destinations require one of the three fixture launch arguments.
    static var screen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains(where: { ["--watch-preview-fixture", "--watch-preview-rest", "--watch-preview-start"].contains($0) }),
              let index = arguments.firstIndex(of: "--watch-preview-screen"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func state(arguments: [String]) -> WatchWorkoutState? {
        if arguments.contains("--watch-preview-start") {
            return .init(templates: screen == "unavailable" ? [] : templates, active: nil, unitRaw: "lb", revision: 0)
        }
        if arguments.contains("--watch-preview-rest") { return workoutState(resting: true) }
        if arguments.contains("--watch-preview-fixture") { return workoutState(resting: false) }
        return nil
    }

    static let templates = [WatchTemplateSummary(id: UUID(), name: "Push Day", exerciseCount: 4, setCount: 13),
                            WatchTemplateSummary(id: UUID(), name: "Pull Day", exerciseCount: 4, setCount: 12)]

    static func workoutState(resting: Bool) -> WatchWorkoutState {
        let now = Date()
        // Out-of-order completed sets keep Bench Set 2 next while total progress is 5/13.
        let exercises = [exercise("Bench Press", count: 4, weight: 135, reps: 8, completed: screen == "up-next" ? [0, 1, 2, 3] : [0], restSeconds: 45),
                         exercise("Overhead Press", count: 3, weight: 65, reps: 10, completed: screen == "up-next" ? [] : [0, 1, 2]),
                         exercise("Cable Fly", count: 3, weight: 25, reps: 12, completed: [0]),
                         exercise("Triceps Pushdown", count: 3, weight: 40, reps: 12, completed: [])]
        return .init(templates: templates,
                     active: .init(id: UUID(), name: "Push Day", startedAt: now.addingTimeInterval(-24 * 60 - 18),
                                   restSeconds: 120, restEndsAt: resting ? now.addingTimeInterval(screen == "rest-done" ? -1 : 32) : nil,
                                   restTimerID: resting ? UUID() : nil, exercises: screen == "empty" ? [] : exercises,
                                   restDurationSeconds: resting ? 45 : nil), unitRaw: "lb", revision: 5)
    }

    private static func exercise(_ name: String, count: Int, weight: Double, reps: Int, completed: Set<Int>, restSeconds: Int? = nil) -> WatchExerciseState {
        .init(id: UUID(), name: name, supersetID: screen == "superset" && ["Bench Press", "Overhead Press"].contains(name) ? supersetID : nil, sets: (0..<count).map { index in
            .init(id: UUID(), weight: weight, reps: reps, targetWeight: weight, targetReps: reps,
                  isCompleted: completed.contains(index))
        }, restSeconds: restSeconds)
    }
}
#endif
