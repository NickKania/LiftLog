import Foundation
import Observation

/// Holds explicitly requested heart rate samples in memory for the current selection.
@MainActor @Observable
final class HealthDashboardSetHeartRateStore {
    static let maximumConcurrentReads = 4
    static let maximumWorkoutsToRead = 20

    private(set) var snapshots: [UUID: WorkoutHealthSnapshot] = [:]
    private(set) var failures: [HealthDashboardHealthFailure] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var completedCount = 0
    private(set) var eligibleWorkoutCount = 0
    private(set) var hasMarkedSetsInEligibleWorkouts = false
    private(set) var hasMarkedSetsInSelectedWorkouts = false

    var selectedWorkoutCount: Int { min(eligibleWorkoutCount, Self.maximumWorkoutsToRead) }
    var omittedWorkoutCount: Int { eligibleWorkoutCount - selectedWorkoutCount }

    @ObservationIgnored private let provider: any WorkoutHealthDataProviding
    @ObservationIgnored private var selection: [WorkoutSession] = []
    @ObservationIgnored private var range = HealthDashboardRange.all
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(provider: any WorkoutHealthDataProviding) {
        self.provider = provider
    }

    deinit { loadTask?.cancel() }

    func updateWorkouts(_ workouts: [WorkoutSession], range: HealthDashboardRange) {
        let completed = HealthDashboardAnalytics(workouts: workouts, unit: .lb, range: range).workouts
        let eligible = completed.reversed().filter { workout in
            workout.exercises.contains { entry in
                entry.sets.contains(where: Self.isTimestamped)
            }
        }
        let selected = Array(eligible.prefix(Self.maximumWorkoutsToRead))
        if selected != selection || range != self.range { cancel() }
        selection = selected
        self.range = range
        eligibleWorkoutCount = eligible.count
        hasMarkedSetsInEligibleWorkouts = eligible.contains(where: Self.hasMarkedSets)
        hasMarkedSetsInSelectedWorkouts = selected.contains(where: Self.hasMarkedSets)
    }

    func cancel() {
        generation = UUID()
        loadTask?.cancel()
        snapshots = [:]
        failures = []
        completedCount = 0
        isLoading = false
        hasLoaded = false
    }

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard !selection.isEmpty, !isLoading else { return nil }
        let previousLoad = loadTask
        cancel()
        isLoading = true
        let requestGeneration = generation
        let provider = provider
        let jobs = selection.enumerated().compactMap { index, workout in
            workout.finishedAt.map { (index: index, workout: workout, through: $0) }
        }
        let task = Task { [weak self] in
            // Drain cancelled reads before starting a new batch so even a provider
            // that returns late cannot exceed the concurrency limit.
            await previousLoad?.value
            var indexedFailures: [Int: HealthDashboardHealthFailure] = [:]
            await withTaskGroup(of: FetchOutcome.self) { group in
                var iterator = jobs.makeIterator()
                for _ in 0..<min(Self.maximumConcurrentReads, jobs.count) {
                    guard let job = iterator.next() else { break }
                    _ = group.addTaskUnlessCancelled { await Self.fetch(job, provider: provider) }
                }
                for await outcome in group {
                    guard !Task.isCancelled, self?.generation == requestGeneration else {
                        group.cancelAll()
                        return
                    }
                    switch outcome {
                    case .loaded(let snapshot):
                        self?.snapshots[snapshot.workoutID] = snapshot
                    case .failed(let index, let failure):
                        indexedFailures[index] = failure
                        self?.failures = indexedFailures.keys.sorted().compactMap { indexedFailures[$0] }
                    case .cancelled:
                        self?.cancel()
                        group.cancelAll()
                        return
                    }
                    self?.completedCount += 1
                    if let job = iterator.next() {
                        _ = group.addTaskUnlessCancelled { await Self.fetch(job, provider: provider) }
                    }
                }
            }
            guard self?.generation == requestGeneration else { return }
            self?.loadTask = nil
            if Task.isCancelled {
                self?.cancel()
            } else {
                self?.isLoading = false
                self?.hasLoaded = true
            }
        }
        loadTask = task
        return task
    }

    private static func isTimestamped(_ set: WorkoutSet) -> Bool {
        set.isCompleted && set.completedAt != nil
    }

    private static func hasMarkedSets(_ workout: WorkoutSession) -> Bool {
        workout.exercises.contains { entry in
            entry.sets.contains { isTimestamped($0) && $0.isMarkedForHeartRate }
        }
    }

    private nonisolated static func fetch(_ job: (index: Int, workout: WorkoutSession, through: Date),
                                          provider: any WorkoutHealthDataProviding) async -> FetchOutcome {
        do {
            try Task.checkCancellation()
            let snapshot = try await provider.fetchHeartRateSamples(for: job.workout, through: job.through)
            try Task.checkCancellation()
            let heartRateOnly = WorkoutHealthSnapshot(workoutID: snapshot.workoutID, workoutName: snapshot.workoutName,
                startedAt: snapshot.startedAt, endedAt: snapshot.endedAt, fetchedAt: snapshot.fetchedAt,
                metrics: snapshot.metrics.filter { $0.metric == .heartRate })
            return .loaded(try heartRateOnly.scoped(to: job.workout, through: job.through,
                maximumSamplesPerMetric: WorkoutHealthSnapshot.maximumHeartRateSamples))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(job.index, HealthDashboardHealthFailure(id: job.workout.id,
                workoutName: job.workout.name, message: error.localizedDescription))
        }
    }

    private enum FetchOutcome: Sendable {
        case loaded(WorkoutHealthSnapshot)
        case failed(Int, HealthDashboardHealthFailure)
        case cancelled
    }
}
