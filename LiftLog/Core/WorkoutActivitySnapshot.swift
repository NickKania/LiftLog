import Foundation

/// Small, self-contained payload shared with the widget extension. Dates let iOS
/// animate the timers without waking the app or scheduling per-second updates.
struct WorkoutActivitySnapshot: Codable, Hashable {
    struct NextSet: Codable, Hashable {
        let exerciseName: String
        let weight: Double
        let unit: String
        let reps: Int
        let number: Int
        let total: Int

        var prescription: String {
            "\(weight.formatted(.number.precision(.fractionLength(0...2)))) \(unit) × \(reps)"
        }

        var position: String { "Set \(number) of \(total)" }
    }

    let workoutID: UUID
    let workoutName: String
    let startedAt: Date
    let restInterval: ClosedRange<Date>?
    let nextSet: NextSet?
    let completedSets: Int
    let totalSets: Int
}
