#if os(iOS) && canImport(HealthKit)
import Foundation
import HealthKit
import OSLog

/// A one-shot, read-only Apple Health adapter. Constructing this object does not
/// request permission, start queries, or subscribe to background health updates.
@MainActor
final class AppleHealthDataProvider: WorkoutHealthDataProviding {
    /// Timings only: signposts and logs never carry health values or session dates.
    private static let signposter = OSSignposter(subsystem: "com.liftlog.app", category: "HealthKit")

    private let healthStore: HKHealthStore
    private var authorizationTask: Task<Void, Error>?

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Concurrent fetches from one provider share a single authorization
    /// request. A completed request is remembered; a failed one may be retried.
    /// A successful request only means the permission sheet completed. HealthKit
    /// intentionally conceals denied read permission; empty results may indicate
    /// denied access, missing source data, or delayed Apple Watch synchronization.
    private func requestAuthorizationOnce() async throws {
        if let authorizationTask {
            try await authorizationTask.value
            return
        }
        let types = Set(WorkoutHealthMetric.allCases.compactMap { $0.quantityType } as [HKObjectType])
        let healthStore = healthStore
        let task = Task {
            let state = Self.signposter.beginInterval("HealthKitAuthorization")
            defer { Self.signposter.endInterval("HealthKitAuthorization", state) }
            try await healthStore.requestAuthorization(toShare: [], read: types)
        }
        authorizationTask = task
        do {
            try await task.value
        } catch {
            // The task has finished, so a later fetch may safely start a new one.
            authorizationTask = nil
            throw error
        }
    }

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutHealthDataError.unavailable }
        try await requestAuthorizationOnce()
        try Task.checkCancellation()

        var metrics: [WorkoutHealthMetricSeries] = []
        if interval.duration > 0 {
            for metric in WorkoutHealthMetric.allCases {
                try Task.checkCancellation()
                guard let type = metric.quantityType else { continue }
                let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                            options: [.strictStartDate, .strictEndDate])
                // Bound chart and assistant payloads while keeping HealthKit's source
                // merging for cumulative quantities. No raw history leaves the store.
                let seconds = max(1, Int(ceil(interval.duration / Double(WorkoutHealthSnapshot.maximumSamplesPerMetric))))
                let descriptor = HKStatisticsCollectionQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: predicate),
                    options: metric == .heartRate ? .discreteAverage : .cumulativeSum,
                    anchorDate: interval.start,
                    intervalComponents: DateComponents(second: seconds)
                )
                let queryState = Self.signposter.beginInterval("HealthKitSeriesQuery", id: Self.signposter.makeSignpostID(),
                                                               "metric \(metric.rawValue, privacy: .public)")
                let collection: HKStatisticsCollection
                do {
                    collection = try await descriptor.result(for: healthStore)
                } catch {
                    Self.signposter.endInterval("HealthKitSeriesQuery", queryState)
                    throw error
                }
                Self.signposter.endInterval("HealthKitSeriesQuery", queryState)
                try Task.checkCancellation()
                var samples: [WorkoutHealthSample] = []
                collection.enumerateStatistics(from: interval.start, to: interval.end) { statistics, stop in
                    guard statistics.startDate < interval.end else { stop.pointee = true; return }
                    let quantity = metric == .heartRate ? statistics.averageQuantity() : statistics.sumQuantity()
                    guard let quantity else { return }
                    samples.append(WorkoutHealthSample(date: min(statistics.endDate, interval.end),
                                                       value: quantity.doubleValue(for: metric.healthKitUnit)))
                }
                if !samples.isEmpty { metrics.append(WorkoutHealthMetricSeries(metric: metric, samples: samples)) }
            }
        }
        try Task.checkCancellation()
        return try WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: interval.start,
                                         endedAt: interval.end, fetchedAt: Date(), metrics: metrics)
            .scoped(to: workout, through: interval.end)
    }

    /// The dashboard only displays per-session aggregates, so read one statistic
    /// per needed metric instead of up to 600 interval buckets per metric.
    /// Heart rate is HealthKit's average for the session; active energy keeps
    /// HealthKit's source-merged cumulative sum. Steps are not read.
    func fetchHealthSummary(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutHealthDataError.unavailable }
        try await requestAuthorizationOnce()
        try Task.checkCancellation()

        var metrics: [WorkoutHealthMetricSeries] = []
        if interval.duration > 0 {
            for metric in [WorkoutHealthMetric.heartRate, .activeEnergy] {
                try Task.checkCancellation()
                guard let type = metric.quantityType else { continue }
                let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                            options: [.strictStartDate, .strictEndDate])
                let descriptor = HKStatisticsQueryDescriptor(
                    predicate: .quantitySample(type: type, predicate: predicate),
                    options: metric == .heartRate ? .discreteAverage : .cumulativeSum
                )
                let queryState = Self.signposter.beginInterval("HealthKitSummaryQuery", id: Self.signposter.makeSignpostID(),
                                                               "metric \(metric.rawValue, privacy: .public)")
                let statistics: HKStatistics?
                do {
                    statistics = try await descriptor.result(for: healthStore)
                } catch {
                    Self.signposter.endInterval("HealthKitSummaryQuery", queryState)
                    throw error
                }
                Self.signposter.endInterval("HealthKitSummaryQuery", queryState)
                try Task.checkCancellation()
                let quantity = metric == .heartRate ? statistics?.averageQuantity() : statistics?.sumQuantity()
                guard let quantity else { continue }
                metrics.append(WorkoutHealthMetricSeries(metric: metric, samples: [
                    WorkoutHealthSample(date: interval.end, value: quantity.doubleValue(for: metric.healthKitUnit))
                ]))
            }
        }
        try Task.checkCancellation()
        return try WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: interval.start,
                                         endedAt: interval.end, fetchedAt: Date(), metrics: metrics)
            .scoped(to: workout, through: interval.end)
    }
}

private extension WorkoutHealthMetric {
    var quantityType: HKQuantityType? {
        switch self {
        case .heartRate: HKObjectType.quantityType(forIdentifier: .heartRate)
        case .activeEnergy: HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case .steps: HKObjectType.quantityType(forIdentifier: .stepCount)
        }
    }

    var healthKitUnit: HKUnit {
        switch self {
        case .heartRate: HKUnit.count().unitDivided(by: .minute())
        case .activeEnergy: .kilocalorie()
        case .steps: .count()
        }
    }
}
#endif
