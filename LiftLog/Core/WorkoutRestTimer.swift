import Foundation

/// A persisted deadline, so suspension and relaunch cannot slow the countdown.
struct WorkoutRestTimer: Codable, Equatable, Identifiable {
    let id: UUID
    let completedSetID: UUID
    let endsAt: Date
    /// Captured when the timer starts so later settings edits cannot alter its progress.
    let durationSeconds: Int?

    init(id: UUID = UUID(), completedSetID: UUID, endsAt: Date, durationSeconds: Int? = nil) {
        self.id = id
        self.completedSetID = completedSetID
        self.endsAt = endsAt
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(at date: Date = Date()) -> Int {
        Int(max(0, min(3600, ceil(endsAt.timeIntervalSince(date)))))
    }

    static func updated(previous: WorkoutSession, current: WorkoutSession, now: Date) -> WorkoutRestTimer? {
        let sets = current.exercises.flatMap(\.sets)
        guard sets.contains(where: { !$0.isCompleted }) else { return nil }
        let incompleteIDs = Set(previous.exercises.flatMap(\.sets).filter { !$0.isCompleted }.map(\.id))
        if let completed = sets.last(where: { $0.isCompleted && incompleteIDs.contains($0.id) }) {
            let duration = current.exercises.first { $0.sets.contains { $0.id == completed.id } }?.restSeconds ?? current.restSeconds
            guard duration > 0 else { return nil }
            return WorkoutRestTimer(completedSetID: completed.id, endsAt: now.addingTimeInterval(TimeInterval(duration)), durationSeconds: duration)
        }
        guard let timer = previous.restTimer, sets.contains(where: { $0.id == timer.completedSetID && $0.isCompleted }) else { return nil }
        return timer
    }
}

extension WorkoutSession {
    func restDuration(for timer: WorkoutRestTimer) -> Int {
        timer.durationSeconds ?? restSeconds
    }
}
