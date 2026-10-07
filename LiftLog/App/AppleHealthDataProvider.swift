#if os(iOS) && canImport(HealthKit)
import Foundation
import HealthKit

/// A one-shot, read-only Apple Health adapter. Constructing this object does not
/// request permission, start queries, or subscribe to background health updates.
@MainActor
final class AppleHealthDataProvider: WorkoutHealthDataProviding {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        try Task.checkCancellation()
        let interval = try WorkoutHealthSnapshot.interval(for: workout, through: min(through, Date()))
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutHealthDataError.unavailable }
        let types = Set(WorkoutHealthMetric.allCases.compactMap { $0.quantityType } as [HKObjectType])
        // A successful request only means the permission sheet completed. HealthKit
        // intentionally conceals denied read permission; empty results may indicate
        // denied access, missing source data, or delayed Apple Watch synchronization.
        try await healthStore.requestAuthorization(toShare: [], read: types)
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
                let collection = try await descriptor.result(for: healthStore)
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
