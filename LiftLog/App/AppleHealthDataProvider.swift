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
    private var authorizedMetrics: Set<WorkoutHealthMetric> = []
    private var authorizationTask: Task<Void, Error>?

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Concurrent fetches from one provider share a single authorization
    /// request. A completed request is remembered; a failed one may be retried.
    /// A successful request only means the permission sheet completed. HealthKit
    /// intentionally conceals denied read permission; empty results may indicate
    /// denied access, missing source data, or delayed Apple Watch synchronization.
    private func requestAuthorization(for metrics: Set<WorkoutHealthMetric>) async throws {
        while !metrics.isSubset(of: authorizedMetrics) {
            try Task.checkCancellation()
            if let authorizationTask {
                try await authorizationTask.value
                continue
            }
            let pending = metrics.subtracting(authorizedMetrics)
            let types = Set<HKObjectType>(pending.compactMap(\.quantityType))
            let task = Task {
                defer { authorizationTask = nil }
                let state = Self.signposter.beginInterval("HealthKitAuthorization")
                defer { Self.signposter.endInterval("HealthKitAuthorization", state) }
                try await healthStore.requestAuthorization(toShare: [], read: types)
                authorizedMetrics.formUnion(pending)
            }
            authorizationTask = task
            try await task.value
        }
    }

    func fetchHeartRateSamples(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        let metric = WorkoutHealthMetric.heartRate
        guard HKHealthStore.isHealthDataAvailable(), let type = metric.quantityType else {
            throw WorkoutHealthDataError.unavailable
        }
        try await requestAuthorization(for: [.heartRate])
        try Task.checkCancellation()

        let limit = WorkoutHealthSnapshot.maximumHeartRateSamples
        var samples: [WorkoutHealthSample] = []
        if interval.duration > 0 {
            let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                        options: [.strictStartDate, .strictEndDate])
            let descriptor = HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)],
                limit: limit + 1
            )
            let raw = try await descriptor.result(for: healthStore)
            try Task.checkCancellation()
            if raw.count <= limit {
                // Collapse duplicate-source samples sharing an identical timestamp so
                // overlapping recorders do not double-weight set averages or sample counts.
                let normalized = raw.compactMap { item -> (date: Date, value: Double)? in
                    let value = item.quantity.doubleValue(for: metric.healthKitUnit)
                    guard value.isFinite && value > 0 else { return nil }
                    return (min(item.endDate, interval.end), value)
                }.sorted { $0.date < $1.date }
                var grouped: [(date: Date, total: Double, count: Int)] = []
                for item in normalized {
                    if let last = grouped.last, last.date == item.date {
                        grouped[grouped.count - 1] = (item.date, last.total + item.value, last.count + 1)
                    } else {
                        grouped.append((item.date, item.value, 1))
                    }
                }
                samples = grouped.map { WorkoutHealthSample(date: $0.date, value: $0.total / Double($0.count)) }
            } else {
                samples = try await seriesSamples(for: metric, type: type, interval: interval, limit: limit)
            }
        }
        try Task.checkCancellation()
        return try WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: interval.start,
                                         endedAt: interval.end, fetchedAt: Date(),
                                         metrics: [WorkoutHealthMetricSeries(metric: metric, samples: samples)])
            .scoped(to: workout, through: interval.end, maximumSamplesPerMetric: limit)
    }

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutHealthDataError.unavailable }
        try await requestAuthorization(for: Set(WorkoutHealthMetric.allCases))
        try Task.checkCancellation()

        var metrics: [WorkoutHealthMetricSeries] = []
        if interval.duration > 0 {
            for metric in WorkoutHealthMetric.allCases {
                try Task.checkCancellation()
                guard let type = metric.quantityType else { continue }
                let samples = try await seriesSamples(for: metric, type: type, interval: interval,
                                                      limit: WorkoutHealthSnapshot.maximumSamplesPerMetric)
                if !samples.isEmpty { metrics.append(WorkoutHealthMetricSeries(metric: metric, samples: samples)) }
            }
        }
        try Task.checkCancellation()
        return try WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: interval.start,
                                         endedAt: interval.end, fetchedAt: Date(), metrics: metrics)
            .scoped(to: workout, through: interval.end)
    }

    private func seriesSamples(for metric: WorkoutHealthMetric, type: HKQuantityType,
                               interval: DateInterval, limit: Int) async throws -> [WorkoutHealthSample] {
        let predicate = HKQuery.predicateForSamples(withStart: interval.start, end: interval.end,
                                                    options: [.strictStartDate, .strictEndDate])
        // Bound chart and assistant payloads while keeping HealthKit's source
        // merging for cumulative quantities. No raw history leaves the store.
        let seconds = max(1, Int(ceil(interval.duration / Double(limit))))
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
            guard statistics.startDate < interval.end, samples.count < limit else { stop.pointee = true; return }
            let quantity = metric == .heartRate ? statistics.averageQuantity() : statistics.sumQuantity()
            guard let quantity else { return }
            samples.append(WorkoutHealthSample(date: min(statistics.endDate, interval.end),
                                               value: quantity.doubleValue(for: metric.healthKitUnit)))
        }
        return samples
    }

    /// The dashboard only displays per-session aggregates, so read one statistic
    /// per needed metric instead of up to 600 interval buckets per metric.
    /// Heart rate is HealthKit's average for the session; active energy keeps
    /// HealthKit's source-merged cumulative sum. Steps are not read.
    func fetchHealthSummary(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutHealthDataError.unavailable }
        try await requestAuthorization(for: [.heartRate, .activeEnergy])
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
