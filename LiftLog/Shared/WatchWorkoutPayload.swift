import Foundation

// Compile this file into both apps. It has no dependency on the phone's store or UI.
struct WatchTemplateSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let exerciseCount: Int
    let setCount: Int
}

struct WatchSetState: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let weight: Double
    let reps: Int
    let targetWeight: Double?
    let targetReps: Int?
    let isCompleted: Bool
}

struct WatchExerciseState: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let supersetID: UUID?
    let sets: [WatchSetState]
}

struct WatchWorkoutState: Codable, Equatable, Sendable {
    let templates: [WatchTemplateSummary]
    let active: WatchActiveWorkout?
    /// The active session's recorded unit, or the preferred unit when idle.
    let unitRaw: String
    /// Copied from WorkoutStore; increases after successful commits in that store's lifetime.
    let revision: UInt64
}

struct WatchActiveWorkout: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let startedAt: Date
    let restSeconds: Int
    let restEndsAt: Date?
    let restTimerID: UUID?
    let exercises: [WatchExerciseState]

    struct NextIncompleteSet: Equatable, Sendable {
        let exerciseIndex: Int
        let setIndex: Int
        let set: WatchSetState
    }

    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    var completedSets: Int { exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count } }
    var canFinish: Bool { completedSets > 0 }
    /// An empty workout has no completed work and is not finished.
    var isFinished: Bool { totalSets > 0 && nextIncompleteSet == nil }

    /// Matches the phone and Live Activity: exercise order, then set order, including supersets.
    var nextIncompleteSet: NextIncompleteSet? {
        for (exerciseIndex, exercise) in exercises.enumerated() {
            if let setIndex = exercise.sets.firstIndex(where: { !$0.isCompleted }) {
                return .init(exerciseIndex: exerciseIndex, setIndex: setIndex, set: exercise.sets[setIndex])
            }
        }
        return nil
    }
}

enum WatchAction: Codable, Equatable, Sendable {
    case startTemplate(id: UUID)
    case startEmpty
    case completeSet(setID: UUID, weight: Double, reps: Int)
    case uncompleteSet(setID: UUID)
    case skipRest(workoutID: UUID, restTimerID: UUID)
    case extendRest(workoutID: UUID, restTimerID: UUID, seconds: Int)
    case finish(workoutID: UUID)
    case discard(workoutID: UUID)
}

extension WatchWorkoutState {
    /// A bounded, ephemeral mirror. Every phone snapshot replaces it, including lower revisions.
    /// Dates and timer identity are inputs so offline behavior can be tested deterministically.
    func applyingOptimistically(_ action: WatchAction, at now: Date, newTimerID: UUID) -> Self {
        guard let active else { return self }
        var exercises = active.exercises
        var endsAt = active.restEndsAt
        var timerID = active.restTimerID
        switch action {
        case .completeSet(let setID, let weight, let reps):
            guard weight.isFinite, weight >= 0, reps > 0,
                  let index = exercises.firstIndex(where: { $0.sets.contains { $0.id == setID && !$0.isCompleted } }) else { return self }
            let exercise = exercises[index]
            exercises[index] = .init(id: exercise.id, name: exercise.name, supersetID: exercise.supersetID,
                                    sets: exercise.sets.map { set in
                guard !set.isCompleted else { return set }
                return .init(id: set.id, weight: weight, reps: reps, targetWeight: set.targetWeight,
                             targetReps: set.targetReps, isCompleted: set.id == setID)
            })
            if active.restSeconds > 0 && exercises.contains(where: { $0.sets.contains { !$0.isCompleted } }) {
                endsAt = now.addingTimeInterval(TimeInterval(active.restSeconds))
                timerID = newTimerID
            } else {
                endsAt = nil
                timerID = nil
            }
        case .uncompleteSet(let setID):
            guard let index = exercises.firstIndex(where: { $0.sets.contains { $0.id == setID && $0.isCompleted } }) else { return self }
            let exercise = exercises[index]
            exercises[index] = .init(id: exercise.id, name: exercise.name, supersetID: exercise.supersetID,
                                    sets: exercise.sets.map { set in
                guard set.id == setID else { return set }
                return .init(id: set.id, weight: set.weight, reps: set.reps, targetWeight: set.targetWeight,
                             targetReps: set.targetReps, isCompleted: false)
            })
            // The payload has no completedSetID for the timer. Conservatively clear the local
            // alert on undo; the phone restores a still-valid timer in its next snapshot.
            endsAt = nil
            timerID = nil
        case .skipRest(let workoutID, let restTimerID):
            guard workoutID == active.id, timerID == restTimerID else { return self }
            endsAt = nil
            timerID = nil
        case .extendRest(let workoutID, let restTimerID, let seconds):
            guard workoutID == active.id, timerID == restTimerID, seconds > 0, let deadline = endsAt else { return self }
            let expired = deadline <= now
            let extended = min((expired ? now : deadline).addingTimeInterval(TimeInterval(seconds)), now.addingTimeInterval(3600))
            guard extended > deadline else { return self }
            endsAt = extended
            if expired { timerID = newTimerID }
        default:
            // Starts and terminal actions need the phone's authoritative persistence result.
            return self
        }
        return .init(templates: templates,
                     active: .init(id: active.id, name: active.name, startedAt: active.startedAt,
                                   restSeconds: active.restSeconds, restEndsAt: endsAt, restTimerID: timerID,
                                   exercises: exercises), unitRaw: unitRaw, revision: revision)
    }
}

/// Property-list-safe dictionaries for application context, messages and queued user info.
enum WatchWorkoutTransport {
    static let payloadVersion = 1
    static let versionKey = "watchPayloadVersion"
    static let stateKey = "watchState"
    static let actionKey = "watchAction"

    enum PayloadError: Error, Equatable {
        case unsupportedVersion
        case missingData
    }

    static func encode(state: WatchWorkoutState) throws -> [String: Any] {
        [versionKey: payloadVersion, stateKey: try JSONEncoder().encode(state)]
    }

    static func decodeState(from dictionary: [String: Any]) throws -> WatchWorkoutState {
        try JSONDecoder().decode(WatchWorkoutState.self, from: data(in: dictionary, key: stateKey))
    }

    static func encode(action: WatchAction) throws -> [String: Any] {
        [versionKey: payloadVersion, actionKey: try JSONEncoder().encode(action)]
    }

    static func decodeAction(from dictionary: [String: Any]) throws -> WatchAction {
        try JSONDecoder().decode(WatchAction.self, from: data(in: dictionary, key: actionKey))
    }

    private static func data(in dictionary: [String: Any], key: String) throws -> Data {
        guard dictionary[versionKey] as? Int == payloadVersion else { throw PayloadError.unsupportedVersion }
        guard let data = dictionary[key] as? Data else { throw PayloadError.missingData }
        return data
    }
}
