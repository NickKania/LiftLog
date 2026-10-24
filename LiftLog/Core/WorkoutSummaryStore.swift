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
    @ObservationIgnored private let selectedProvider: () -> AssistantProvider
    @ObservationIgnored private let localInferenceClient: any AppleFoundationModelsProviding
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var generationID: UUID?
    @ObservationIgnored private var generationScope: RequestScope?
    @ObservationIgnored private var responseScope: RequestScope?
    @ObservationIgnored private var responseWorkout: WorkoutSession?

    private struct RequestScope: Equatable {
        let provider: AssistantProvider
        let account: String?
    }

    init(store: WorkoutStore, accessToken: @escaping () async throws -> String,
         transport: any ChatGPTInferenceTransport = URLSessionChatGPTTransport(),
         accountIdentity: @escaping () -> String? = { nil },
         healthDataProvider: (any WorkoutHealthDataProviding)? = nil,
         selectedProvider: @escaping () -> AssistantProvider = { .chatGPT },
         localInferenceClient: (any AppleFoundationModelsProviding)? = nil) {
        self.store = store
        self.healthDataProvider = healthDataProvider
        self.accountIdentity = accountIdentity
        self.selectedProvider = selectedProvider
        self.localInferenceClient = localInferenceClient ?? UnavailableAppleFoundationModelsProvider()
        self.client = ChatGPTInferenceClient(accessToken: accessToken, transport: transport,
                                             accountIdentity: accountIdentity)
    }

    /// Generates a summary for the immutable history snapshot identified by `workoutID`.
    ///
    /// The caller normally awaits this from a view-owned `.task`. Cancellation of that
    /// task is forwarded to the selected inference provider, and `cancel()` can be used by an
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
        let scope = currentScope
        generationScope = scope
        if self.workoutID != workoutID || responseScope != scope || responseWorkout != workout {
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
                                         scope: scope, model: model, includeHealth: includeHealth,
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
        generationScope = nil
        generationTask?.cancel()
        generationTask = nil
        clearResponse()
        errorMessage = nil
        healthNotice = nil
        workoutID = nil
        isWorking = false
    }

    /// ChatGPT connection changes do not invalidate on-device requests or responses.
    func accountWillChange() {
        guard selectedProvider() == .chatGPT || generationScope?.provider == .chatGPT
                || responseScope?.provider == .chatGPT else { return }
        cancel()
    }

    /// Called synchronously before changing providers, including while acquiring a
    /// credential or reading Health. Consent and responses never follow a provider switch.
    func providerWillChange() {
        cancel()
    }

    private func performGeneration(workout: WorkoutSession, history: [WorkoutSession], revision: UInt64,
                                  scope: RequestScope, model: String, includeHealth: Bool,
                                  generationID: UUID) async {
        defer { finish(generationID: generationID) }

        do {
            try Task.checkCancellation()
            try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
            if scope.provider == .appleFoundationModels, !localInferenceClient.availability.isAvailable {
                throw WorkoutSummaryGenerationError.unavailable(localInferenceClient.availability.explanation)
            }
            var health: WorkoutHealthSnapshot?
            if includeHealth {
                guard let healthDataProvider else {
                    healthNotice = "Apple Health is unavailable, so this summary uses workout data only."
                    health = nil
                    try Task.checkCancellation()
                    try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
                    try await request(workout: workout, history: history, health: health, model: model,
                                      scope: scope, revision: revision, generationID: generationID)
                    return
                }
                do {
                    try Task.checkCancellation()
                    let fetched = try await healthDataProvider.fetchHealthData(for: workout, through: workout.finishedAt ?? Date())
                    try Task.checkCancellation()
                    try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
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
                    guard isSnapshotCurrent(workout: workout, revision: revision, scope: scope) else {
                        throw WorkoutSummaryGenerationError.stale
                    }
                    healthNotice = "Apple Health data was unavailable, so this summary uses workout data only."
                    health = nil
                }
            }

            try Task.checkCancellation()
            try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
            try await request(workout: workout, history: history, health: health, model: model,
                              scope: scope, revision: revision, generationID: generationID)
        } catch is CancellationError {
            cancelIfActive(generationID: generationID)
            return
        } catch {
            guard isGenerationActive(generationID) else { return }
            if selectedProvider() != scope.provider {
                cancelIfActive(generationID: generationID)
                return
            }
            if case WorkoutSummaryGenerationError.stale = error {
                clearResponse()
                healthNotice = nil
            }
            if scope.provider == .appleFoundationModels, let error = error as? AppleFoundationModelsError,
               error.kind == .contextTooLarge {
                errorMessage = WorkoutSummaryContext.Error.localPayloadTooLarge.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func request(workout: WorkoutSession, history: [WorkoutSession], health: WorkoutHealthSnapshot?,
                         model: String, scope: RequestScope, revision: UInt64, generationID: UUID) async throws {
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
        let request = try WorkoutSummaryRequest(workout: workout, history: history, health: health,
                                                prompt: store.workoutSummaryPrompt, provider: scope.provider,
                                                contextTokens: localInferenceClient.contextTokens)
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)

        let inferenceClient: any AssistantInferenceClient = scope.provider == .chatGPT ? client : localInferenceClient
        let requestModel = scope.provider == .chatGPT ? model : AppleFoundationModelsModel.slug
        let response = try await inferenceClient.respond(model: requestModel,
                                                         input: request.input,
                                                         tools: [], instructions: request.instructions) { _ in }
        try Task.checkCancellation()
        try validateSnapshot(workout: workout, revision: revision, scope: scope, generationID: generationID)
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkoutSummaryGenerationError.emptyResponse(scope.provider)
        }
        errorMessage = nil
        // Only publish canonical completed output. Streaming deltas stay local to the
        // inference client so a failed or stale request cannot replace a prior answer.
        text = response.text
        responseScope = scope
        responseWorkout = workout
    }

    private func validateSnapshot(workout: WorkoutSession, revision: UInt64, scope: RequestScope,
                                 generationID: UUID) throws {
        guard isGenerationActive(generationID), isSnapshotCurrent(workout: workout, revision: revision, scope: scope) else {
            throw WorkoutSummaryGenerationError.stale
        }
    }

    private var currentScope: RequestScope {
        let provider = selectedProvider()
        return RequestScope(provider: provider, account: provider == .chatGPT ? accountIdentity() : nil)
    }

    private func isSnapshotCurrent(workout: WorkoutSession, revision: UInt64, scope: RequestScope) -> Bool {
        currentScope == scope && store.revision == revision
            && store.history.first(where: { $0.id == workout.id }) == workout
    }

    private func isGenerationActive(_ generationID: UUID) -> Bool {
        self.generationID == generationID
    }

    private func finish(generationID: UUID) {
        guard self.generationID == generationID else { return }
        self.generationID = nil
        let provider = generationScope?.provider ?? selectedProvider()
        generationScope = nil
        generationTask = nil
        isWorking = false
        if errorMessage == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = WorkoutSummaryGenerationError.emptyResponse(provider).localizedDescription
        }
    }

    private func cancelIfActive(generationID: UUID) {
        guard self.generationID == generationID else { return }
        self.generationID = nil
        generationScope = nil
        generationTask = nil
        clearResponse()
        errorMessage = nil
        healthNotice = nil
        workoutID = nil
        isWorking = false
    }

    private func clearResponse() {
        text = ""
        responseScope = nil
        responseWorkout = nil
    }
}

private enum WorkoutSummaryGenerationError: LocalizedError {
    case stale
    case unavailable(String)
    case emptyResponse(AssistantProvider)

    var errorDescription: String? {
        switch self {
        case .stale:
            return "This workout changed while the summary was being generated. Try again to summarize the latest saved workout."
        case .unavailable(let explanation):
            return explanation
        case .emptyResponse(let provider):
            return "\(provider.displayName) returned an empty workout summary. Try again."
        }
    }
}
