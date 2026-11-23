import Foundation

enum SetHeartRateWindowKind: String, Codable, Equatable, Sendable {
    case timed, estimated
}

enum SetHeartRateFilter: String, CaseIterable, Identifiable, Sendable {
    case markedOnly, allTimestamped

    var id: String { rawValue }
    var label: String { self == .markedOnly ? "Marked sets" : "All sets" }
}

struct SetHeartRateMetrics: Identifiable, Equatable, Sendable {
    let id: UUID
    let exerciseEntryID: UUID
    let exerciseID: UUID
    let exerciseName: String
    let setNumber: Int
    let weight: Double
    let reps: Int
    let unit: WeightUnit
    let isMarked: Bool
    let windowKind: SetHeartRateWindowKind
    let windowStart: Date
    let windowEnd: Date
    let averageHeartRate: Double?
    let peakHeartRate: Double?
    let sampleCount: Int
    let recoveryHeartRate60s: Double?
    let recoveryDrop60s: Double?

    var duration: TimeInterval { max(0, windowEnd.timeIntervalSince(windowStart)) }
}

struct ExerciseHeartRateSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let exerciseID: UUID
    let exerciseName: String
    let sets: [SetHeartRateMetrics]
    let averageHeartRate: Double?
    let peakHeartRate: Double?
    let averageRecoveryDrop60s: Double?
    let markedSetCount: Int
    let timedSetCount: Int
    let coveredSetCount: Int
}

struct WorkoutHeartRateCorrelation: Equatable, Sendable {
    let workoutID: UUID
    let startedAt: Date
    let endedAt: Date
    let heartRateSamples: [WorkoutHealthSample]
    let sessionAverageHeartRate: Double?
    let sessionPeakHeartRate: Double?
    let sets: [SetHeartRateMetrics]
    let exercises: [ExerciseHeartRateSummary]

    var hasTimestampedSets: Bool { !sets.isEmpty }
    var hasMarkedSets: Bool { sets.contains(where: \.isMarked) }

    static func correlate(workout: WorkoutSession, snapshot: WorkoutHealthSnapshot,
                          estimatedWindowSeconds: TimeInterval = 45) -> WorkoutHeartRateCorrelation {
        let start = workout.startedAt
        let candidateEnd = min(workout.finishedAt ?? snapshot.endedAt, snapshot.endedAt)
        let validInterval = start.timeIntervalSinceReferenceDate.isFinite &&
            snapshot.endedAt.timeIntervalSinceReferenceDate.isFinite &&
            (workout.finishedAt?.timeIntervalSinceReferenceDate.isFinite ?? true) && candidateEnd >= start
        let end = validInterval ? candidateEnd : start
        let samples = validInterval && snapshot.workoutID == workout.id && snapshot.startedAt == start
            ? snapshot.metrics.filter { $0.metric == .heartRate }.flatMap(\.samples).filter {
                $0.date >= start && $0.date <= end && $0.date.timeIntervalSinceReferenceDate.isFinite &&
                    $0.value.isFinite && $0.value > 0
            }.sorted { ($0.date, $0.value) < ($1.date, $1.value) }
            : []

        let chronological = workout.exercises.enumerated().flatMap { exerciseIndex, entry in
            entry.sets.enumerated().compactMap { setIndex, set -> TimedSet? in
                guard validInterval,
                      set.isCompleted, let completion = set.completedAt, completion >= start,
                      completion.timeIntervalSinceReferenceDate.isFinite,
                      set.startedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else { return nil }
                return TimedSet(exerciseIndex: exerciseIndex, setIndex: setIndex, set: set, completion: completion)
            }
        }.sorted {
            ($0.completion, $0.exerciseIndex, $0.setIndex) < ($1.completion, $1.exerciseIndex, $1.setIndex)
        }

        let estimate = estimatedWindowSeconds.isFinite ? max(0, estimatedWindowSeconds) : 45
        var results = chronological.indices.compactMap { index -> (TimedSet, SetHeartRateMetrics)? in
            let item = chronological[index]
            let entry = workout.exercises[item.exerciseIndex]
            let completion = item.completion
            let windowEnd = min(end, completion)
            let previousCompletion = index > 0 ? chronological[index - 1].completion : start
            let windowStart = item.set.startedAt.map { max(start, $0) }
                ?? max(start, previousCompletion, completion.addingTimeInterval(-estimate))
            guard windowStart <= windowEnd else { return nil }

            let inSet = samples.inWindow(from: windowStart, through: windowEnd)
            let peak = inSet.map(\.value).max()
            var nextBoundary = end
            for (otherIndex, other) in chronological.enumerated() where otherIndex != index {
                if let otherStart = other.set.startedAt, otherStart <= completion && other.completion > completion {
                    // Another timed set was already in progress past this completion.
                    nextBoundary = completion
                    break
                }
                let candidate = other.set.startedAt ?? other.completion
                if candidate > completion {
                    nextBoundary = min(nextBoundary, candidate)
                }
            }
            let recoveryStart = completion.addingTimeInterval(50)
            let recoveryEnd = min(completion.addingTimeInterval(70), nextBoundary, end)
            let recovery = peak != nil && recoveryStart <= recoveryEnd
                ? meanHeartRate(samples.inWindow(from: recoveryStart, through: recoveryEnd).map(\.value))
                : nil
            return (item, SetHeartRateMetrics(id: item.set.id, exerciseEntryID: entry.id, exerciseID: entry.exercise.id,
                exerciseName: entry.exercise.name, setNumber: item.setIndex + 1, weight: item.set.weight,
                reps: item.set.reps, unit: workout.unit, isMarked: item.set.isMarkedForHeartRate,
                windowKind: item.set.startedAt == nil ? .estimated : .timed, windowStart: windowStart, windowEnd: windowEnd,
                averageHeartRate: meanHeartRate(inSet.map(\.value)), peakHeartRate: peak, sampleCount: inSet.count,
                recoveryHeartRate60s: recovery, recoveryDrop60s: peak.flatMap { peak in recovery.map { peak - $0 } }))
        }
        results.sort {
            ($0.1.windowEnd, $0.0.exerciseIndex, $0.0.setIndex) < ($1.1.windowEnd, $1.0.exerciseIndex, $1.0.setIndex)
        }
        let sets = results.map { $0.1 }
        let byEntry = Dictionary(grouping: sets, by: \.exerciseEntryID)
        let exercises = workout.exercises.compactMap { entry -> ExerciseHeartRateSummary? in
            guard let sets = byEntry[entry.id] else { return nil }
            return ExerciseHeartRateSummary(id: entry.id, exerciseID: entry.exercise.id, exerciseName: entry.exercise.name,
                sets: sets, averageHeartRate: meanHeartRate(sets.compactMap(\.averageHeartRate)),
                peakHeartRate: sets.compactMap(\.peakHeartRate).max(),
                averageRecoveryDrop60s: meanHeartRate(sets.compactMap(\.recoveryDrop60s)),
                markedSetCount: sets.filter(\.isMarked).count, timedSetCount: sets.filter { $0.windowKind == .timed }.count,
                coveredSetCount: sets.filter { $0.sampleCount > 0 }.count)
        }
        return WorkoutHeartRateCorrelation(workoutID: workout.id, startedAt: start, endedAt: end,
            heartRateSamples: samples, sessionAverageHeartRate: meanHeartRate(samples.map(\.value)),
            sessionPeakHeartRate: samples.map(\.value).max(), sets: sets, exercises: exercises)
    }

    private struct TimedSet {
        let exerciseIndex: Int
        let setIndex: Int
        let set: WorkoutSet
        let completion: Date
    }
}

struct ExerciseHeartRateTrendPoint: Identifiable, Equatable, Sendable {
    var id: UUID { workoutID }
    let workoutID: UUID
    let workoutName: String
    let date: Date
    let unit: WeightUnit
    let heaviestWeight: Double
    let repsAtHeaviest: Int
    let averageHeartRate: Double?
    let peakHeartRate: Double?
    let averageRecoveryDrop60s: Double?
    let setCount: Int
    let markedSetCount: Int
}

struct ExerciseHeartRateTrend: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let points: [ExerciseHeartRateTrendPoint]
    let overallAverageHeartRate: Double?
    let overallPeakHeartRate: Double?
    let overallAverageRecoveryDrop60s: Double?
    let sessionCount: Int
    let totalCorrelatedSets: Int
}

enum ExerciseHeartRateTrendAnalytics {
    static func trends(workouts: [WorkoutSession], snapshots: [UUID: WorkoutHealthSnapshot],
                       unit: WeightUnit, filter: SetHeartRateFilter) -> [ExerciseHeartRateTrend] {
        var pointsByExercise: [UUID: [ExerciseHeartRateTrendPoint]] = [:]
        var setsByExercise: [UUID: [SetHeartRateMetrics]] = [:]
        var names: [UUID: String] = [:]
        let chronological = workouts.sorted {
            ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString)
        }
        for workout in chronological {
            guard let snapshot = snapshots[workout.id] else { continue }
            let correlation = WorkoutHeartRateCorrelation.correlate(workout: workout, snapshot: snapshot)
            let matching = correlation.sets.filter { filter == .allTimestamped || $0.isMarked }
            let factor = workout.unit == unit ? 1 : (unit == .kg ? 0.45359237 : 1 / 0.45359237)
            for (id, sets) in Dictionary(grouping: matching, by: \.exerciseID) {
                let covered = sets.filter { $0.sampleCount > 0 }
                guard !covered.isEmpty, let best = covered.filter({ ($0.weight * factor).isFinite }).max(by: {
                    ($0.weight, $0.reps) < ($1.weight, $1.reps)
                }) else { continue }
                names[id] = best.exerciseName
                setsByExercise[id, default: []].append(contentsOf: covered)
                pointsByExercise[id, default: []].append(ExerciseHeartRateTrendPoint(workoutID: workout.id,
                    workoutName: workout.name, date: workout.startedAt, unit: unit, heaviestWeight: best.weight * factor,
                    repsAtHeaviest: best.reps, averageHeartRate: meanHeartRate(covered.compactMap(\.averageHeartRate)),
                    peakHeartRate: covered.compactMap(\.peakHeartRate).max(),
                    averageRecoveryDrop60s: meanHeartRate(covered.compactMap(\.recoveryDrop60s)),
                    setCount: sets.count, markedSetCount: sets.filter(\.isMarked).count))
            }
        }
        return pointsByExercise.compactMap { id, points -> ExerciseHeartRateTrend? in
            guard let name = names[id], let covered = setsByExercise[id] else { return nil }
            return ExerciseHeartRateTrend(id: id, name: name, points: points,
                overallAverageHeartRate: meanHeartRate(covered.compactMap(\.averageHeartRate)),
                overallPeakHeartRate: covered.compactMap(\.peakHeartRate).max(),
                overallAverageRecoveryDrop60s: meanHeartRate(covered.compactMap(\.recoveryDrop60s)),
                sessionCount: points.count, totalCorrelatedSets: covered.count)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

private func meanHeartRate(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0) { $0 + $1 / Double(values.count) }
}

private extension Array where Element == WorkoutHealthSample {
    func inWindow(from start: Date, through end: Date) -> ArraySlice<Element> {
        let first = boundary { $0.date >= start }
        let last = boundary { $0.date > end }
        return self[first..<last]
    }

    func boundary(where matches: (Element) -> Bool) -> Int {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if matches(self[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
