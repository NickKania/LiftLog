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

    /// HealthKit round-trips are slow enough that strictly sequential reads make
    /// even a handful of workouts take minutes; overlap a few, not all of them.
    static let maximumConcurrentReads = 4

    @ObservationIgnored private let provider: any WorkoutHealthDataProviding
    @ObservationIgnored private var workouts: [WorkoutSession] = []
    @ObservationIgnored private var range = HealthDashboardRange.all
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var workoutCount: Int { workouts.count }
    var emptyWorkoutCount: Int { snapshots.values.filter { !$0.hasSamples }.count }

    init(provider: any WorkoutHealthDataProviding) {
        self.provider = provider
    }

    deinit { loadTask?.cancel() }

    /// The selected range is part of the explicit read context, even when two
    /// ranges happen to contain exactly the same completed sessions.
    func updateWorkouts(_ workouts: [WorkoutSession], range: HealthDashboardRange = .all) {
        let completed = workouts.filter { $0.finishedAt != nil }
        guard self.workouts != completed || self.range != range else { return }
        cancel()
        self.workouts = completed
        self.range = range
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
            // Only completed sessions are admitted by updateWorkouts(_:).
            let jobs = selection.enumerated().compactMap { index, workout in
                workout.finishedAt.map { (index: index, workout: workout, through: $0) }
            }
            var indexedFailures: [(index: Int, failure: HealthDashboardHealthFailure)] = []
            await withTaskGroup(of: HealthDashboardFetchOutcome.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<min(Self.maximumConcurrentReads, jobs.count) {
                    guard let job = iterator.next() else { break }
                    group.addTask { await Self.fetch(job, provider: provider) }
                }
                for await outcome in group {
                    guard !Task.isCancelled, self?.generation == requestGeneration else {
                        group.cancelAll()
                        return
                    }
                    switch outcome {
                    case .loaded(let snapshot):
                        self?.snapshots[snapshot.workoutID] = snapshot
                    case .failed(let index, let workout, let message):
                        // Concurrent reads finish out of order; failures are
                        // reported in selection order regardless.
                        indexedFailures.append((index, HealthDashboardHealthFailure(
                            id: workout.id, workoutName: workout.name, message: message)))
                        self?.failures = indexedFailures.sorted { $0.index < $1.index }.map(\.failure)
                    case .cancelled:
                        self?.cancel()
                        group.cancelAll()
                        return
                    }
                    self?.completedCount += 1
                    if let job = iterator.next() {
                        group.addTask { await Self.fetch(job, provider: provider) }
                    }
                }
            }
            guard !Task.isCancelled, self?.generation == requestGeneration else { return }
            self?.isLoading = false
            self?.hasLoaded = true
            self?.loadTask = nil
        }
        loadTask = task
        return task
    }

    private static func fetch(_ job: (index: Int, workout: WorkoutSession, through: Date),
                              provider: any WorkoutHealthDataProviding) async -> HealthDashboardFetchOutcome {
        do {
            let snapshot = try await provider.fetchHealthSummary(for: job.workout, through: job.through)
            try Task.checkCancellation()
            return .loaded(try snapshot.scoped(to: job.workout, through: job.through))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(index: job.index, workout: job.workout, message: error.localizedDescription)
        }
    }
}

private enum HealthDashboardFetchOutcome: Sendable {
    case loaded(WorkoutHealthSnapshot)
    case failed(index: Int, workout: WorkoutSession, message: String)
    case cancelled
}
