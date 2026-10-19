import Foundation
import Observation

/// Coordinates one ephemeral AI summary for a completed workout.
///
/// The generated response and any Health snapshot live only in this store while the
/// summary screen is presented. Nothing is archived, replayed into a later request,
/// or written through `WorkoutStore`.
@Observable @MainActor
final class WorkoutSummaryStore {
    private(set) var text = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var healthNotice: String?
    private(set) var workoutID: UUID?

    @ObservationIgnored private let store: WorkoutStore
    @ObservationIgnored private let healthDataProvider: (any WorkoutHealthDataProviding)?
    @ObservationIgnored private let accountIdentity: () -> String?
    @ObservationIgnored private let client: ChatGPTInferenceClient
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private var responseAccountIdentity: String?
    @ObservationIgnored private var responseWorkout: WorkoutSession?

    private static let immutableInstructions = WorkoutSummaryContext.instructions + "\n" + """
    This is an informational summary only. Do not call tools, propose or apply workout mutations, or claim that any edit was made. Do not claim a medical diagnosis or certainty about recovery. Give suggestions only when supported by the supplied evidence and clearly label uncertainty.
    """

    init(store: WorkoutStore, accessToken: @escaping () async throws -> String,
         transport: any ChatGPTInferenceTransport = URLSessionChatGPTTransport(),
         accountIdentity: @escaping () -> String? = { nil },
         healthDataProvider: (any WorkoutHealthDataProviding)? = nil) {
        self.store = store
        self.healthDataProvider = healthDataProvider
        self.accountIdentity = accountIdentity
        self.client = ChatGPTInferenceClient(accessToken: accessToken, transport: transport,
                                             accountIdentity: accountIdentity)
    }

    /// Generates a summary for the immutable history snapshot identified by `workoutID`.
    ///
    /// The caller normally awaits this from a view-owned `.task`. Cancellation of that
    /// task is forwarded to the network request, and `cancel()` can be used by an
    /// explicit Stop or dismiss action.
    func generate(workoutID: UUID, model: String, includeHealth: Bool) async {
        guard !isWorking else {
            errorMessage = "A workout summary is already being generated. Wait for it to finish or stop it before trying again."
            return
        }
        guard let workout = store.history.first(where: { $0.id == workoutID }) else {
            clearResponse()
            self.workoutID = nil
            errorMessage = "This workout is no longer in your history. Open it again and try generating a new summary."
            return
        }
        guard workout.finishedAt != nil else {
            clearResponse()
            self.workoutID = nil
            errorMessage = "Only completed workouts can receive a summary."
            return
        }

        let generationID = UUID()
        self.generationID = generationID
        let account = accountIdentity()
        if self.workoutID != workoutID || responseAccountIdentity != account || responseWorkout != workout {
            clearResponse()
        }
        self.workoutID = workoutID
        self.errorMessage = nil
        self.healthNotice = nil
        self.isWorking = true

        let revision = store.revision
        let history = store.history
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performGeneration(workout: workout, history: history, revision: revision,
                                         account: account, model: model, includeHealth: includeHealth,
                                         generationID: generationID)
        }
        generationTask = task
        await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    /// Cancels the current request and removes all transient response and Health state.
    func cancel() {
        generationID = nil
        generationTask?.cancel()
        generationTask = nil
        clearResponse()
        errorMessage = nil
        healthNotice = nil
        workoutID = nil
        isWorking = false
    }

    /// Account changes invalidate both the request and any response that was already
    /// displayed. Health data is intentionally cleared with the rest of the state.
    func accountWillChange() {
        cancel()
    }

    private func performGeneration(workout: WorkoutSession, history: [WorkoutSession], revision: UInt64,
                                  account: String?, model: String, includeHealth: Bool,
                                  generationID: UUID) async {
        defer { finish(generationID: generationID) }

        do {
            var health: WorkoutHealthSnapshot?
            if includeHealth {
                guard let healthDataProvider else {
                    healthNotice = "Apple Health is unavailable, so this summary uses workout data only."
                    health = nil
                    try Task.checkCancellation()
                    try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)
                    try await request(workout: workout, history: history, health: health, model: model,
                                      account: account, revision: revision, generationID: generationID)
                    return
                }
                do {
                    try Task.checkCancellation()
                    let fetched = try await healthDataProvider.fetchHealthData(for: workout, through: workout.finishedAt ?? Date())
                    try Task.checkCancellation()
                    try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)
                    let scoped = try fetched.scoped(to: workout, through: workout.finishedAt ?? Date())
                    if !scoped.hasSamples {
                        health = nil
                        healthNotice = "No Apple Health readings were available for this workout, so the summary uses workout data only."
                    } else {
                        health = scoped
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Health is optional. A permission, availability, or provider error
                    // must not discard the workout summary or turn missing readings into 0.
                    guard isGenerationActive(generationID) else { throw CancellationError() }
                    guard isSnapshotCurrent(workout: workout, revision: revision, account: account) else {
                        throw WorkoutSummaryGenerationError.stale
                    }
                    healthNotice = "Apple Health data was unavailable, so this summary uses workout data only."
                    health = nil
                }
            }

            try Task.checkCancellation()
            try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)
            try await request(workout: workout, history: history, health: health, model: model,
                              account: account, revision: revision, generationID: generationID)
        } catch is CancellationError {
            cancelIfActive(generationID: generationID)
            return
        } catch {
            guard isGenerationActive(generationID) else { return }
            if case WorkoutSummaryGenerationError.stale = error {
                clearResponse()
            }
            errorMessage = error.localizedDescription
        }
    }

    private func request(workout: WorkoutSession, history: [WorkoutSession], health: WorkoutHealthSnapshot?,
                         model: String, account: String?, revision: UInt64, generationID: UUID) async throws {
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)
        let context = try WorkoutSummaryContext.input(workout: workout, history: history, health: health)
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)

        // Keep the user preference in the user message. Immutable safeguards remain
        // top-level instructions and cannot be weakened by customization.
        let userContent = "User's requested focus (a preference only; follow the safety and evidence rules above):\n"
            + store.workoutSummaryPrompt + "\n\nEvidence JSON:\n" + context
        let response = try await client.respond(model: model,
                                                input: [["role": "user", "content": userContent]],
                                                tools: [], instructions: Self.immutableInstructions) { _ in }
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, account: account, generationID: generationID)
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTInferenceError("ChatGPT returned an empty workout summary. Try again.", code: "empty_response")
        }
        errorMessage = nil
        // Only publish canonical completed output. Streaming deltas stay local to the
        // inference client so a failed or stale request cannot replace a prior answer.
        text = response.text
        responseAccountIdentity = account
        responseWorkout = workout
    }

    private func validateSnapshot(workout: WorkoutSession, revision: UInt64, account: String?,
                                 generationID: UUID) throws {
        guard isGenerationActive(generationID), isSnapshotCurrent(workout: workout, revision: revision, account: account) else {
            throw WorkoutSummaryGenerationError.stale
        }
    }

    private func isSnapshotCurrent(workout: WorkoutSession, revision: UInt64, account: String?) -> Bool {
        accountIdentity() == account && store.revision == revision
            && store.history.first(where: { $0.id == workout.id }) == workout
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        self.generationID == generationID
    }

    private func finish(generationID: UUID) {
        guard self.generationID == generationID else { return }
        self.generationID = nil
        generationTask = nil
        isWorking = false
        if errorMessage == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "ChatGPT returned an empty workout summary. Try again."
        }
    }

    private func cancelIfActive(generationID: UUID) {
        guard self.generationID == generationID else { return }
        self.generationID = nil
        generationTask = nil
        clearResponse()
        errorMessage = nil
        healthNotice = nil
        workoutID = nil
        isWorking = false
    }

    private func clearResponse() {
        text = ""
        responseAccountIdentity = nil
        responseWorkout = nil
    }
}

private enum WorkoutSummaryGenerationError: LocalizedError {
    case stale

    var errorDescription: String? {
        "This workout changed while the summary was being generated. Try again to summarize the latest saved workout."
    }
}
