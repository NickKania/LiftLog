import Foundation

/// Reading health data is an explicit, per-attachment operation. Implementations must
/// not fetch or request authorization when initialized or when a workout starts.
@MainActor
protocol WorkoutHealthDataProviding {
    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot
}

enum WorkoutHealthMetric: String, Codable, CaseIterable, Sendable {
    case heartRate, activeEnergy, steps

    var displayName: String {
        switch self {
        case .heartRate: "Heart rate"
        case .activeEnergy: "Active energy"
        case .steps: "Steps"
        }
    }

    var unit: String {
        switch self {
        case .heartRate: "bpm"
        case .activeEnergy: "kcal"
        case .steps: "count"
        }
    }

    fileprivate func accepts(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && (self != .heartRate || value > 0)
    }
}

struct WorkoutHealthSample: Codable, Equatable, Sendable {
    let date: Date
    let value: Double
}

/// Heart rate values are averages; energy and step values are interval totals.
/// Empty intervals are omitted, so missing data is never represented as a zero.
struct WorkoutHealthMetricSeries: Codable, Equatable, Sendable {
    let metric: WorkoutHealthMetric
    let samples: [WorkoutHealthSample]
}

struct WorkoutHealthSnapshot: Codable, Equatable, Sendable {
    static let maximumSamplesPerMetric = 600
    static let maximumSessionDuration: TimeInterval = 48 * 60 * 60

    let workoutID: UUID
    let workoutName: String
    let startedAt: Date
    let endedAt: Date
    let fetchedAt: Date
    let metrics: [WorkoutHealthMetricSeries]

    var hasSamples: Bool { metrics.contains { !$0.samples.isEmpty } }

    static func interval(for workout: WorkoutSession, through: Date) throws -> DateInterval {
        let end = min(workout.finishedAt ?? through, through)
        guard workout.startedAt.timeIntervalSinceReferenceDate.isFinite,
              workout.finishedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              end.timeIntervalSinceReferenceDate.isFinite,
              through.timeIntervalSinceReferenceDate.isFinite,
              end >= workout.startedAt,
              end.timeIntervalSince(workout.startedAt) <= maximumSessionDuration else {
            throw WorkoutHealthDataError.invalidSession
        }
        return DateInterval(start: workout.startedAt, end: end)
    }

    /// Revalidate a provider's output before displaying or attaching it. This also
    /// protects assistant input when a provider is injected for tests or previews.
    func scoped(to workout: WorkoutSession, through: Date) throws -> WorkoutHealthSnapshot {
        let interval = try Self.interval(for: workout, through: through)
        guard workoutID == workout.id,
              startedAt == interval.start,
              endedAt.timeIntervalSinceReferenceDate.isFinite,
              endedAt >= startedAt,
              fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkoutHealthDataError.invalidSession
        }
        let end = min(endedAt, interval.end)
        let safeMetrics = WorkoutHealthMetric.allCases.compactMap { metric -> WorkoutHealthMetricSeries? in
            let validSamples = metrics.filter { $0.metric == metric }.flatMap(\.samples).filter {
                $0.date.timeIntervalSinceReferenceDate.isFinite && $0.date >= startedAt && $0.date <= end && metric.accepts($0.value)
            }.sorted { $0.date < $1.date }
            guard !validSamples.isEmpty else { return nil }
            return WorkoutHealthMetricSeries(metric: metric, samples: Self.bounded(validSamples, metric: metric))
        }
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: interval.start,
                                     endedAt: end, fetchedAt: fetchedAt, metrics: safeMetrics)
    }

    private static func bounded(_ samples: [WorkoutHealthSample], metric: WorkoutHealthMetric) -> [WorkoutHealthSample] {
        guard samples.count > maximumSamplesPerMetric else { return samples }
        // Preserve cumulative totals when reducing payload size; average heart rate
        // within each consecutive group instead of discarding older measurements.
        return (0..<maximumSamplesPerMetric).compactMap { index in
            let start = index * samples.count / maximumSamplesPerMetric
            let end = (index + 1) * samples.count / maximumSamplesPerMetric
            let group = samples[start..<end]
            let value: Double
            if metric == .heartRate {
                value = group.reduce(0) { $0 + $1.value / Double(group.count) }
            } else {
                value = group.reduce(0) { $0 + $1.value }
            }
            guard metric.accepts(value), let last = group.last else { return nil }
            return WorkoutHealthSample(date: last.date, value: value)
        }
    }
}

enum WorkoutHealthDataError: LocalizedError {
    case unavailable
    case invalidSession

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health is unavailable on this device."
        case .invalidSession: "Health data needs a valid workout time range of up to 48 hours."
        }
    }
}
