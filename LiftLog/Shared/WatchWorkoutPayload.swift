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
    var restSeconds: Int? = nil
}

struct WatchWorkoutState: Codable, Equatable, Sendable {
    let templates: [WatchTemplateSummary]
    var active: WatchActiveWorkout?
    /// The active session's recorded unit, or the preferred unit when idle.
    let unitRaw: String
    /// Copied from WorkoutStore; increases after successful commits in that store's lifetime.
    let revision: UInt64
    var processedThroughOperationID: UUID? = nil
    var lastTerminalResult: WatchTerminalResult? = nil
    /// Store/fixture placeholder only; the phone service stamps its own lifetime ID.
    var phoneSessionID: UUID = unpublishedSessionID
    var publicationSequence: UInt64 = 0
    /// Echoed on every publication after a read-only recovery request is processed.
    var recoveryProbeID: UUID? = nil

    static let unpublishedSessionID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

struct WatchActiveWorkout: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let startedAt: Date
    let restSeconds: Int
    let restEndsAt: Date?
    let restTimerID: UUID?
    let exercises: [WatchExerciseState]
    /// Captured timer duration; nil supports older v2 snapshots and idle workouts.
    var restDurationSeconds: Int? = nil

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
    case completeSet(setID: UUID, weight: Double, reps: Int, completedAt: Date, restTimerID: UUID)
    case uncompleteSet(setID: UUID)
    case skipRest(workoutID: UUID, restTimerID: UUID)
    case extendRest(workoutID: UUID, restTimerID: UUID, seconds: Int, requestedAt: Date, resultingRestTimerID: UUID)
    case finish(workoutID: UUID)
    case discard(workoutID: UUID)
}

struct WatchActionRequest: Codable, Equatable, Sendable {
    let operationID: UUID
    let action: WatchAction
}

struct WatchTerminalResult: Codable, Equatable, Sendable {
    let operationID: UUID
    let workoutID: UUID
    let isFinish: Bool
    let succeeded: Bool

    init?(request: WatchActionRequest, succeeded: Bool) {
        switch request.action {
        case .finish(let id): workoutID = id; isFinish = true
        case .discard(let id): workoutID = id; isFinish = false
        default: return nil
        }
        operationID = request.operationID
        self.succeeded = succeeded
    }
}

/// Small phone-local receipt, independent of workout revision and delivery success.
struct WatchActionReceipt: Codable, Equatable, Sendable {
    var processedThroughOperationID: UUID?
    var lastTerminalResult: WatchTerminalResult?

    mutating func record(_ request: WatchActionRequest, succeeded: Bool) {
        processedThroughOperationID = request.operationID
        if let result = WatchTerminalResult(request: request, succeeded: succeeded) {
            lastTerminalResult = result
        }
    }
}

extension WatchWorkoutState {
    /// Reachability alone does not mean the phone has received an optimistic rest edit.
    func hasSameRest(as phoneState: Self) -> Bool {
        guard let active, let timerID = active.restTimerID, let endsAt = active.restEndsAt,
              let phoneWorkout = phoneState.active else { return false }
        return active.id == phoneWorkout.id && timerID == phoneWorkout.restTimerID
            && endsAt == phoneWorkout.restEndsAt
    }

    func shouldScheduleLocalRestAlert(isReachable: Bool, phoneHasCurrentRest: Bool, at now: Date) -> Bool {
        guard let active, active.restTimerID != nil, let endsAt = active.restEndsAt,
              endsAt > now else { return false }
        return !isReachable || !phoneHasCurrentRest
    }

    /// Rest ends on its own: once the deadline passes, the Watch rolls into
    /// the next set without asking the user to acknowledge it.
    func restExpiryAction(at now: Date) -> WatchAction? {
        guard let active, let restTimerID = active.restTimerID,
              let endsAt = active.restEndsAt, endsAt <= now else { return nil }
        return .skipRest(workoutID: active.id, restTimerID: restTimerID)
    }

    func restExtensionAction(by seconds: Int, at requestedAt: Date, newTimerID: UUID) -> WatchAction? {
        guard let active, let id = active.restTimerID, let deadline = active.restEndsAt else { return nil }
        return .extendRest(workoutID: active.id, restTimerID: id, seconds: seconds, requestedAt: requestedAt,
                           resultingRestTimerID: deadline > requestedAt ? id : newTimerID)
    }

    func applyingPending(_ actions: [WatchAction]) -> Self {
        actions.reduce(self) { $0.applyingOptimistically($1) }
    }

    /// Replay is deterministic: timestamps and timer identities belong to the action.
    func applyingOptimistically(_ action: WatchAction) -> Self {
        guard let active else { return self }
        var exercises = active.exercises
        var endsAt = active.restEndsAt
        var timerID = active.restTimerID
        var durationSeconds = active.restDurationSeconds
        switch action {
        case .completeSet(let setID, let weight, let reps, let completedAt, let restTimerID):
            guard completedAt.timeIntervalSinceReferenceDate.isFinite, weight.isFinite, weight >= 0, reps > 0,
                  let index = exercises.firstIndex(where: { $0.sets.contains { $0.id == setID && !$0.isCompleted } }) else { return self }
            let exercise = exercises[index]
            exercises[index] = .init(id: exercise.id, name: exercise.name, supersetID: exercise.supersetID,
                                    sets: exercise.sets.map { set in
                guard !set.isCompleted else { return set }
                return .init(id: set.id, weight: weight, reps: reps, targetWeight: set.targetWeight,
                             targetReps: set.targetReps, isCompleted: set.id == setID)
            }, restSeconds: exercise.restSeconds)
            let duration = exercise.restSeconds ?? active.restSeconds
            if duration > 0 && exercises.contains(where: { $0.sets.contains { !$0.isCompleted } }) {
                endsAt = completedAt.addingTimeInterval(TimeInterval(duration))
                timerID = restTimerID
                durationSeconds = duration
            } else {
                endsAt = nil
                timerID = nil
                durationSeconds = nil
            }
        case .uncompleteSet(let setID):
            guard let index = exercises.firstIndex(where: { $0.sets.contains { $0.id == setID && $0.isCompleted } }) else { return self }
            let exercise = exercises[index]
            exercises[index] = .init(id: exercise.id, name: exercise.name, supersetID: exercise.supersetID,
                                    sets: exercise.sets.map { set in
                guard set.id == setID else { return set }
                return .init(id: set.id, weight: set.weight, reps: set.reps, targetWeight: set.targetWeight,
                             targetReps: set.targetReps, isCompleted: false)
            }, restSeconds: exercise.restSeconds)
            // The payload has no completedSetID for the timer. Conservatively clear the local
            // alert on undo; the phone restores a still-valid timer in its next snapshot.
            endsAt = nil
            timerID = nil
            durationSeconds = nil
        case .skipRest(let workoutID, let restTimerID):
            guard workoutID == active.id, timerID == restTimerID else { return self }
            endsAt = nil
            timerID = nil
            durationSeconds = nil
        case .extendRest(let workoutID, let restTimerID, let seconds, let requestedAt, let resultingRestTimerID):
            guard requestedAt.timeIntervalSinceReferenceDate.isFinite, workoutID == active.id, timerID == restTimerID, seconds > 0, let deadline = endsAt else { return self }
            let expired = deadline <= requestedAt
            let extended = min((expired ? requestedAt : deadline).addingTimeInterval(TimeInterval(seconds)), requestedAt.addingTimeInterval(3600))
            guard extended > deadline else { return self }
            endsAt = extended
            timerID = resultingRestTimerID
            durationSeconds = expired ? min(seconds, 3600) : min(3600, (active.restDurationSeconds ?? active.restSeconds) + Int(ceil(extended.timeIntervalSince(deadline))))
        default:
            // Starts and terminal actions need the phone's authoritative persistence result.
            return self
        }
        return .init(templates: templates,
                     active: .init(id: active.id, name: active.name, startedAt: active.startedAt,
                                   restSeconds: active.restSeconds, restEndsAt: endsAt, restTimerID: timerID,
                                   exercises: exercises, restDurationSeconds: durationSeconds), unitRaw: unitRaw, revision: revision,
                     processedThroughOperationID: processedThroughOperationID, lastTerminalResult: lastTerminalResult,
                     phoneSessionID: phoneSessionID, publicationSequence: publicationSequence,
                     recoveryProbeID: recoveryProbeID)
    }
}

/// The same ledger drives the Watch client and deterministic reconciliation tests.
struct WatchWorkoutReconciler: Codable {
    private(set) var baseState: WatchWorkoutState
    private(set) var pending: [WatchActionRequest] = []
    private(set) var pendingTerminal: WatchActionRequest?
    private(set) var showSaved = false
    private(set) var savedConfirmed = false
    private(set) var errorMessage: String?
    private var hasAcceptedSnapshot = false
    /// Optional for journals created before transfer checkpoints were introduced.
    private var transferredOperationIDs: Set<UUID>?
    private(set) var transferRecoveryProbeID: UUID?

    var state: WatchWorkoutState { baseState.applyingPending(pending.map(\.action)) }
    var terminalWorkoutID: UUID? {
        pendingTerminal.flatMap { WatchTerminalResult(request: $0, succeeded: false)?.workoutID }
    }

    var requestsAwaitingTransfer: [WatchActionRequest] {
        pending.filter { !(transferredOperationIDs?.contains($0.operationID) ?? false) }
    }

    mutating func beginTransferRecovery(probeID: UUID) {
        transferRecoveryProbeID = requestsAwaitingTransfer.isEmpty ? nil : probeID
    }

    mutating func recordTransfer(operationID: UUID) {
        guard pending.contains(where: { $0.operationID == operationID }) else { return }
        if transferredOperationIDs == nil { transferredOperationIDs = [] }
        transferredOperationIDs?.insert(operationID)
    }

    /// Resume the durable outbox in FIFO order. An outstanding transfer covers the
    /// crash window between queueing and saving its checkpoint. Keep delivered
    /// requests pending for receipts without submitting them a second time.
    mutating func transferPending(outstandingOperationIDs: Set<UUID>,
                                  transfer: (WatchActionRequest) throws -> Void,
                                  checkpoint: (Self) throws -> Void) throws {
        // Cached context may predate a phone restart and omit receipts for already
        // applied operations. Never replay an ambiguous outbox until a fresh response.
        guard transferRecoveryProbeID == nil else { return }
        for request in requestsAwaitingTransfer {
            if !outstandingOperationIDs.contains(request.operationID) { try transfer(request) }
            var updated = self
            updated.recordTransfer(operationID: request.operationID)
            try checkpoint(updated)
            self = updated
        }
    }

    mutating func enqueue(_ request: WatchActionRequest) {
        pending.append(request)
        if let terminal = WatchTerminalResult(request: request, succeeded: false) {
            pendingTerminal = request
            showSaved = terminal.isFinish
            savedConfirmed = false
        }
    }

    @discardableResult
    mutating func accept(_ incoming: WatchWorkoutState) -> Bool {
        if hasAcceptedSnapshot, incoming.phoneSessionID == baseState.phoneSessionID,
           incoming.publicationSequence <= baseState.publicationSequence { return false }
        hasAcceptedSnapshot = true
        baseState = incoming
        if let watermark = incoming.processedThroughOperationID,
           let index = pending.firstIndex(where: { $0.operationID == watermark }) {
            pending.removeFirst(index + 1)
            transferredOperationIDs?.formIntersection(pending.map(\.operationID))
        }
        if requestsAwaitingTransfer.isEmpty || incoming.recoveryProbeID == transferRecoveryProbeID {
            transferRecoveryProbeID = nil
        }
        if let request = pendingTerminal, let result = incoming.lastTerminalResult,
           result.operationID == request.operationID,
           let expected = WatchTerminalResult(request: request, succeeded: result.succeeded), result == expected {
            pendingTerminal = nil
            if result.succeeded {
                showSaved = result.isFinish
                savedConfirmed = result.isFinish
            } else {
                showSaved = false
                savedConfirmed = false
                errorMessage = "iPhone couldn’t \(result.isFinish ? "save" : "discard") this workout. Review it on iPhone and try again."
            }
        }
        return true
    }

    /// Transport failures affect only edits still awaiting an acknowledgement.
    @discardableResult
    mutating func fail(operationID: UUID) -> Bool {
        guard let index = pending.firstIndex(where: { $0.operationID == operationID }) else { return false }
        pending.remove(at: index)
        transferredOperationIDs?.remove(operationID)
        if pendingTerminal?.operationID == operationID {
            pendingTerminal = nil
            showSaved = false
            savedConfirmed = false
        }
        errorMessage = "A queued change couldn’t sync. Check your workout on iPhone and try again."
        return true
    }

    mutating func dismissSaved() { showSaved = false }
    mutating func clearError() { errorMessage = nil }
}

/// Property-list-safe dictionaries for application context, messages and queued user info.
enum WatchWorkoutTransport {
    static let payloadVersion = 2
    static let versionKey = "watchPayloadVersion"
    static let stateKey = "watchState"
    static let actionKey = "watchAction"
    static let recoveryProbeKey = "watchRecoveryProbe"

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

    static func encode(request: WatchActionRequest) throws -> [String: Any] {
        [versionKey: payloadVersion, actionKey: try JSONEncoder().encode(request)]
    }

    static func decodeRequest(from dictionary: [String: Any]) throws -> WatchActionRequest {
        try JSONDecoder().decode(WatchActionRequest.self, from: data(in: dictionary, key: actionKey))
    }

    static func encodeRecoveryProbe(id: UUID) -> [String: Any] {
        [versionKey: payloadVersion, recoveryProbeKey: id.uuidString]
    }

    static func decodeRecoveryProbe(from dictionary: [String: Any]) throws -> UUID {
        guard dictionary[versionKey] as? Int == payloadVersion else { throw PayloadError.unsupportedVersion }
        guard let value = dictionary[recoveryProbeKey] as? String,
              let id = UUID(uuidString: value) else { throw PayloadError.missingData }
        return id
    }

    private static func data(in dictionary: [String: Any], key: String) throws -> Data {
        guard dictionary[versionKey] as? Int == payloadVersion else { throw PayloadError.unsupportedVersion }
        guard let data = dictionary[key] as? Data else { throw PayloadError.missingData }
        return data
    }
}
