import Foundation
import Observation

struct HealthDashboardHealthFailure: Identifiable, Equatable {
    let id: UUID
    let workoutName: String
    let message: String
}

/// A dashboard-only, memory-only reader. Updating the selection never reads Health
/// or requests permission; only an explicit `load()` starts provider operations.
@MainActor @Observable
final class HealthDashboardHealthStore {
    private(set) var snapshots: [UUID: WorkoutHealthSnapshot] = [:]
    private(set) var failures: [HealthDashboardHealthFailure] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var completedCount = 0

    @ObservationIgnored private let provider: any WorkoutHealthDataProviding
    @ObservationIgnored private var workouts: [WorkoutSession] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var workoutCount: Int { workouts.count }
    var emptyWorkoutCount: Int { snapshots.values.filter { !$0.hasSamples }.count }

    init(provider: any WorkoutHealthDataProviding) {
        self.provider = provider
    }

    deinit { loadTask?.cancel() }

    func updateWorkouts(_ workouts: [WorkoutSession]) {
        let completed = workouts.filter { $0.finishedAt != nil }
        guard self.workouts != completed else { return }
        cancel()
        self.workouts = completed
    }

    /// Cancelling discards partial results, including results from providers that
    /// ignore cancellation and return after the selection has changed.
    func cancel() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        snapshots = [:]
        failures = []
        completedCount = 0
        isLoading = false
        hasLoaded = false
    }

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard !workouts.isEmpty else { return nil }
        cancel()
        isLoading = true
        let requestGeneration = generation
        let selection = workouts
        let provider = provider
        let task = Task { [weak self] in
            for workout in selection {
                guard !Task.isCancelled, self?.generation == requestGeneration else { return }
                // Only completed sessions are admitted by updateWorkouts(_:).
                guard let through = workout.finishedAt else { continue }
                do {
                    let snapshot = try await provider.fetchHealthData(for: workout, through: through)
                    try Task.checkCancellation()
                    guard self?.generation == requestGeneration else { return }
                    let scoped = try snapshot.scoped(to: workout, through: through)
                    self?.snapshots[workout.id] = scoped
                } catch is CancellationError {
                    guard self?.generation == requestGeneration else { return }
                    self?.cancel()
                    return
                } catch {
                    guard !Task.isCancelled, self?.generation == requestGeneration else { return }
                    self?.failures.append(HealthDashboardHealthFailure(
                        id: workout.id, workoutName: workout.name, message: error.localizedDescription
                    ))
                }
                self?.completedCount += 1
            }
            guard !Task.isCancelled, self?.generation == requestGeneration else { return }
            self?.isLoading = false
            self?.hasLoaded = true
            self?.loadTask = nil
        }
        loadTask = task
        return task
    }
}
