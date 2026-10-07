import Foundation

/// A persisted deadline, so suspension and relaunch cannot slow the countdown.
struct WorkoutRestTimer: Codable, Equatable, Identifiable {
    let id: UUID
    let completedSetID: UUID
    let endsAt: Date

    init(id: UUID = UUID(), completedSetID: UUID, endsAt: Date) {
        self.id = id
        self.completedSetID = completedSetID
        self.endsAt = endsAt
    }

    func remainingSeconds(at date: Date = Date()) -> Int {
        Int(max(0, min(3600, ceil(endsAt.timeIntervalSince(date)))))
    }

    static func updated(previous: WorkoutSession, current: WorkoutSession, now: Date) -> WorkoutRestTimer? {
        let sets = current.exercises.flatMap(\.sets)
        guard current.restSeconds > 0, sets.contains(where: { !$0.isCompleted }) else { return nil }
        let incompleteIDs = Set(previous.exercises.flatMap(\.sets).filter { !$0.isCompleted }.map(\.id))
        if let completed = sets.last(where: { $0.isCompleted && incompleteIDs.contains($0.id) }) {
            return WorkoutRestTimer(completedSetID: completed.id, endsAt: now.addingTimeInterval(TimeInterval(current.restSeconds)))
        }
        guard let timer = previous.restTimer, sets.contains(where: { $0.id == timer.completedSetID && $0.isCompleted }) else { return nil }
        return timer
    }
}
