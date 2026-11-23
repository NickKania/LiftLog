import Foundation
import Observation

/// Explicit, memory-only Apple Health access for one completed workout.
@MainActor @Observable
final class WorkoutHeartRateStore {
    private(set) var correlation: WorkoutHeartRateCorrelation?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let provider: any WorkoutHealthDataProviding
    @ObservationIgnored private var workout: WorkoutSession?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(provider: any WorkoutHealthDataProviding) {
        self.provider = provider
    }

    deinit { loadTask?.cancel() }

    func updateWorkout(_ workout: WorkoutSession) {
        guard self.workout != workout else { return }
        cancel()
        self.workout = workout
    }

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard let workout, let through = workout.finishedAt else { return nil }
        cancel()
        isLoading = true
        let generation = generation
        let task = Task { [weak self, provider] in
            defer {
                if let self, self.generation == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }

            do {
                try Task.checkCancellation()
                _ = try WorkoutHealthSnapshot.interval(for: workout, through: through)
                let snapshot = try await provider.fetchHeartRateSamples(for: workout, through: through)
                try Task.checkCancellation()
                let correlation = try await Self.correlate(workout, snapshot: snapshot, through: through)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.correlation = correlation
                self.hasLoaded = true
            } catch is CancellationError {
                // Cancelled reads leave the opt-in state available.
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.hasLoaded = true
            }
        }
        loadTask = task
        return task
    }

    func cancel() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        correlation = nil
        errorMessage = nil
        isLoading = false
        hasLoaded = false
    }

    private nonisolated static func correlate(_ workout: WorkoutSession, snapshot: WorkoutHealthSnapshot,
                                              through: Date) async throws -> WorkoutHeartRateCorrelation {
        try Task.checkCancellation()
        let scoped = try snapshot.scoped(to: workout, through: through,
                                         maximumSamplesPerMetric: WorkoutHealthSnapshot.maximumHeartRateSamples)
        return WorkoutHeartRateCorrelation.correlate(workout: workout, snapshot: scoped)
    }
}
