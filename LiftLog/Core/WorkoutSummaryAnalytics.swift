import Foundation

struct WorkoutSummaryExerciseComparison: Equatable, Sendable {
    enum Verdict: String, CaseIterable, Equatable, Sendable {
        case improved, maintained, regressed, mixed, insufficientData
    }

    let exerciseName: String
    let verdict: Verdict
    let facts: [String]
}

struct WorkoutSummaryTotals: Equatable, Sendable {
    let completedSets: Int
    let totalReps: Int
    /// Sum of completed weight times reps, in the workout's recorded unit.
    let volume: Double
}

/// Deterministic evidence from completed sets, aggregating repeated catalog movements in recorded order.
enum WorkoutSummaryAnalytics {
    /// Counts all completed sets and reps in the recorded unit. Malformed non-finite volume
    /// contributions, including additions that overflow, are omitted rather than returning infinity.
    static func totals(for workout: WorkoutSession) -> WorkoutSummaryTotals {
        let performance = Performance(sets: workout.exercises.flatMap(\.sets))
        return WorkoutSummaryTotals(completedSets: performance.sets.count,
                                    totalReps: performance.totalReps, volume: performance.finiteVolume)
    }

    /// Returns movements in first-appearance order, using caller order to select the most recent prior.
    /// Empty completed-set collections return insufficientData with only a no-completed-sets fact.
    /// Missing history, differing units, or non-finite load metrics also yield insufficientData.
    /// Otherwise verdicts check improvement (higher top load with at least as many reps, or unchanged
    /// top load with at least 5% more volume), regression (lower top load with at least 5% less volume,
    /// or at least 15% less volume), conflicting signals, then maintenance. A lighter opener with
    /// more reps at the last shared set makes an otherwise regressed result mixed: changed loading
    /// confounds that comparison. Improvement retains precedence. Conflicting signals mean a higher
    /// top load with at least 5% less volume, or a lower top load with at least 5% more volume.
    /// A zero prior volume or non-finite percentage has no percentage evidence; only rules whose
    /// required metrics exist can apply. Every change in total reps is included as a fact.
    static func comparisons(workout: WorkoutSession, earlier: [WorkoutSession]) -> [WorkoutSummaryExerciseComparison] {
        let history = earlier.filter { candidate in
            guard candidate.id != workout.id, let finish = candidate.finishedAt,
                  finish.timeIntervalSinceReferenceDate.isFinite,
                  workout.startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }
            return finish <= workout.startedAt
        }
        var seen: Set<UUID> = []
        return workout.exercises.compactMap { entry in
            guard seen.insert(entry.exercise.id).inserted else { return nil }
            let current = performance(for: entry.exercise.id, in: workout)
            return comparison(exercise: entry.exercise, current: current, unit: workout.unit, history: history)
        }
    }

    private struct Performance {
        let sets: [WorkoutSet]
        let totalReps: Int
        let topSet: WorkoutSet?
        let finiteVolume: Double
        let volume: Double?

        init(sets: [WorkoutSet]) {
            self.sets = sets.filter(\.isCompleted)
            totalReps = self.sets.reduce(0) { $0 + $1.reps }
            var top: WorkoutSet?
            var volume = 0.0
            var validWeights = true
            var validVolume = true
            for set in self.sets {
                guard set.weight.isFinite else {
                    validWeights = false
                    validVolume = false
                    continue
                }
                if top == nil || set.weight > (top?.weight ?? 0) { top = set }
                let contribution = set.weight * Double(set.reps)
                let sum = volume + contribution
                guard contribution.isFinite, sum.isFinite else {
                    validVolume = false
                    continue
                }
                volume = sum
            }
            topSet = validWeights ? top : nil
            finiteVolume = volume
            self.volume = validVolume ? volume : nil
        }
    }

    private static func performance(for exerciseID: UUID, in workout: WorkoutSession) -> Performance {
        Performance(sets: workout.exercises.filter { $0.exercise.id == exerciseID }.flatMap(\.sets))
    }

    private static func comparison(exercise: Exercise, current: Performance, unit: WeightUnit,
                                   history: [WorkoutSession]) -> WorkoutSummaryExerciseComparison {
        func result(_ verdict: WorkoutSummaryExerciseComparison.Verdict,
                    _ facts: [String]) -> WorkoutSummaryExerciseComparison {
            WorkoutSummaryExerciseComparison(exerciseName: exercise.name, verdict: verdict, facts: facts)
        }
        guard !current.sets.isEmpty else {
            return result(.insufficientData, ["No completed sets were recorded."])
        }
        var facts = [currentFact(current, unit: unit)]
        facts += sessionFacts(current, unit: unit)
        guard let priorSession = history.first(where: { session in
            session.exercises.contains { $0.exercise.id == exercise.id }
        }) else { return result(.insufficientData, facts) }
        guard priorSession.unit == unit else {
            facts.append("Recorded units differ (\(unit.rawValue) versus \(priorSession.unit.rawValue) in earlier \(priorSession.name)); loads were not compared.")
            return result(.insufficientData, facts)
        }
        let prior = performance(for: exercise.id, in: priorSession)
        guard let currentTop = current.topSet, let priorTop = prior.topSet,
              let currentVolume = current.volume, let priorVolume = prior.volume else {
            facts.append(prior.sets.isEmpty
                ? "No completed sets were recorded for this movement in earlier \(priorSession.name)."
                : "Completed load data is unavailable or not finite; load comparisons are unavailable.")
            return result(.insufficientData, facts)
        }
        let topDelta = currentTop.weight - priorTop.weight
        guard topDelta.isFinite else {
            facts.append("The load difference is not finite; load comparisons are unavailable.")
            return result(.insufficientData, facts)
        }
        facts.append("Top set \(setFact(currentTop, unit: unit)) versus \(setFact(priorTop, unit: unit)) in earlier \(priorSession.name); difference \(topDelta >= 0 ? "+" : "")\(topDelta) \(unit.rawValue).")
        let percent = volumePercent(current: currentVolume, prior: priorVolume)
        let percentFact = percent.map { " (\(String(format: "%+.1f", locale: Locale(identifier: "en_US_POSIX"), $0))%)" } ?? ""
        facts.append("Volume \(currentVolume) \(unit.rawValue) versus \(priorVolume) \(unit.rawValue) earlier\(percentFact).")
        if current.sets.count != prior.sets.count {
            facts.append("\(current.sets.count) sets versus \(prior.sets.count) sets earlier.")
        }
        if current.totalReps != prior.totalReps {
            facts.append("\(current.totalReps) reps versus \(prior.totalReps) reps earlier.")
        }
        let sharedCount = min(current.sets.count, prior.sets.count)
        facts.append("Opening set \(setFact(current.sets[0], unit: unit)) versus \(setFact(prior.sets[0], unit: unit)) earlier.")
        if sharedCount > 1 {
            facts.append("Shared set \(sharedCount): \(setFact(current.sets[sharedCount - 1], unit: unit)) versus \(setFact(prior.sets[sharedCount - 1], unit: unit)) earlier.")
        }
        // A single shared set is both opener and "late" set, so the lighter-
        // opener confound only applies when at least two sets align.
        let confounded = sharedCount > 1 && current.sets[0].weight < prior.sets[0].weight &&
            current.sets[sharedCount - 1].reps > prior.sets[sharedCount - 1].reps
        // Bodyweight work has zero volume in both sessions; total reps are
        // then the only progression signal available to the verdict rules.
        let signalPercent = percent ?? (currentVolume == 0 && priorVolume == 0
            ? volumePercent(current: Double(current.totalReps), prior: Double(prior.totalReps)) : nil)
        let movementVerdict = verdict(topDelta: topDelta, currentTopReps: currentTop.reps,
                                      priorTopReps: priorTop.reps, volumePercent: signalPercent,
                                      confounded: confounded)
        // Never contradict an improved verdict with the confound caution: a
        // heavier top set already settles the strength question it qualifies.
        if confounded && movementVerdict != .improved {
            facts.append("Late-set reps rose from \(prior.sets[sharedCount - 1].reps) to \(current.sets[sharedCount - 1].reps), but opening load was lighter (\(current.sets[0].weight) \(unit.rawValue) versus \(prior.sets[0].weight) \(unit.rawValue)); not clear evidence of strength gain.")
        }
        let sameUnitHistory = history.filter { session in
            session.unit == unit && session.exercises.contains { $0.exercise.id == exercise.id }
        }
        if !sameUnitHistory.isEmpty && sameUnitHistory.allSatisfy({ session in
            guard let top = performance(for: exercise.id, in: session).topSet else { return false }
            return currentTop.weight > top.weight
        }) {
            facts.append("Heaviest top set in the supplied earlier sessions.")
        }
        if topDelta < 0 && current.sets.allSatisfy({ set in
            guard let target = set.targetWeight, target.isFinite else { return false }
            return set.weight == target
        }) {
            facts.append("Performed load matches the recorded plan for every completed set; the reason for the reduction is not in the evidence.")
        }
        return result(movementVerdict, facts)
    }

    private static func currentFact(_ performance: Performance, unit: WeightUnit) -> String {
        let top = performance.topSet.map { "Top set \(setFact($0, unit: unit))" } ?? "Top set unavailable"
        let volume = performance.volume.map { "\($0) \(unit.rawValue)" } ?? "unavailable"
        return "\(top); \(performance.sets.count) sets, \(performance.totalReps) reps, volume \(volume)."
    }

    private static func sessionFacts(_ performance: Performance, unit: WeightUnit) -> [String] {
        var facts: [String] = []
        let misses = performance.sets.enumerated().compactMap { index, set -> String? in
            guard let target = set.targetReps, set.reps < target else { return nil }
            return "set \(index + 1): \(set.reps) of \(target)"
        }
        if !misses.isEmpty {
            facts.append("Missed planned reps on \(misses.count) \(misses.count == 1 ? "set" : "sets"): \(misses.prefix(3).joined(separator: "; ")).")
        }
        if performance.sets.count >= 2, let first = performance.sets.first, let last = performance.sets.last,
           first.weight.isFinite, performance.sets.allSatisfy({ $0.weight == first.weight }), last.reps < first.reps {
            facts.append("Reps fell from \(first.reps) to \(last.reps) across sets at \(first.weight) \(unit.rawValue).")
        }
        return facts
    }

    private static func setFact(_ set: WorkoutSet, unit: WeightUnit) -> String {
        "\(set.weight) \(unit.rawValue) x \(set.reps)"
    }

    private static func volumePercent(current: Double, prior: Double) -> Double? {
        guard prior > 0 else { return nil }
        let percent = (current - prior) / prior * 100
        return percent.isFinite ? percent : nil
    }

    private static func verdict(topDelta: Double, currentTopReps: Int, priorTopReps: Int,
                                volumePercent: Double?, confounded: Bool) -> WorkoutSummaryExerciseComparison.Verdict {
        if (topDelta > 0 && currentTopReps >= priorTopReps) || (topDelta == 0 && (volumePercent.map { $0 >= 5 } ?? false)) {
            return .improved
        }
        if confounded { return .mixed }
        if (topDelta < 0 && (volumePercent.map { $0 <= -5 } ?? false)) || (volumePercent.map { $0 <= -15 } ?? false) {
            return .regressed
        }
        if (topDelta > 0 && (volumePercent.map { $0 <= -5 } ?? false)) || (topDelta < 0 && (volumePercent.map { $0 >= 5 } ?? false)) {
            return .mixed
        }
        return .maintained
    }
}
