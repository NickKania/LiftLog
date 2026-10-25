import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSummaryAnalyticsTests: XCTestCase {
    private let bench = Exercise(name: "Bench Press", category: "Strength")

    private func set(_ weight: Double, _ reps: Int, targetReps: Int? = nil,
                     targetWeight: Double? = nil, completed: Bool = true) -> WorkoutSet {
        WorkoutSet(weight: weight, reps: reps, targetReps: targetReps,
                   targetWeight: targetWeight, isCompleted: completed)
    }

    private func session(_ exercises: [WorkoutExercise], day: Int = 1,
                         name: String = "Current", unit: WeightUnit = .lb) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_750_000_000 + Double(day) * 86_400)
        return WorkoutSession(name: name, startedAt: start, finishedAt: start.addingTimeInterval(1_800),
                              unit: unit, exercises: exercises)
    }

    private func comparison(_ workout: WorkoutSession, earlier: [WorkoutSession] = []) throws -> WorkoutSummaryExerciseComparison {
        let comparisons = WorkoutSummaryAnalytics.comparisons(workout: workout, earlier: earlier)
        XCTAssertEqual(comparisons.count, 1)
        return try XCTUnwrap(comparisons.first)
    }

    func testSimpleProgressionIncludesComputedDifferenceAndHistoryBest() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(135, 8)])], day: 0, name: "Earlier Bench")
        let current = session([WorkoutExercise(exercise: bench, sets: [set(145, 8)])])
        let result = try comparison(current, earlier: [prior])
        XCTAssertEqual(result.verdict, .improved)
        XCTAssertEqual(result.exerciseName, "Bench Press")
        XCTAssertEqual(result.facts.first, "Top set 145.0 lb x 8; 1 sets, 8 reps, volume 1160.0 lb.")
        XCTAssertTrue(result.facts.contains("Top set 145.0 lb x 8 versus 135.0 lb x 8 in earlier Earlier Bench; difference +10.0 lb."))
        XCTAssertTrue(result.facts.contains("Volume 1160.0 lb versus 1080.0 lb earlier (+7.4%)."))
        XCTAssertTrue(result.facts.contains("Heaviest top set in the supplied earlier sessions."))
    }

    func testLighterLatPulldownOpenerConfoundsHigherLateReps() throws {
        let movement = Exercise(name: "Lat Pulldown")
        let prior = session([WorkoutExercise(exercise: movement, sets: [set(120, 10), set(120, 10), set(100, 10), set(100, 6)])], day: 0)
        let current = session([WorkoutExercise(exercise: movement, sets: [set(80, 10), set(90, 10), set(90, 10), set(100, 10)])])
        let result = try comparison(current, earlier: [prior])
        // The explicit confound golden case takes precedence over an otherwise regressed result.
        XCTAssertEqual(result.verdict, .mixed)
        XCTAssertEqual(result.facts.first, "Top set 100.0 lb x 10; 4 sets, 40 reps, volume 3600.0 lb.")
        XCTAssertTrue(result.facts.contains("Volume 3600.0 lb versus 4000.0 lb earlier (-10.0%)."))
        XCTAssertTrue(result.facts.contains("40 reps versus 36 reps earlier."))
        XCTAssertTrue(result.facts.contains("Opening set 80.0 lb x 10 versus 120.0 lb x 10 earlier."))
        XCTAssertTrue(result.facts.contains("Shared set 4: 100.0 lb x 10 versus 100.0 lb x 6 earlier."))
        XCTAssertTrue(result.facts.contains { $0.contains("not clear evidence of strength gain") && $0.contains("opening load was lighter") })
    }

    func testCurlDropOffAndMissedPlanRemainAvailableWithoutHistory() throws {
        let curl = Exercise(name: "Dumbbell Curl")
        let current = session([WorkoutExercise(exercise: curl, sets: [
            set(20, 15, targetReps: 10), set(20, 10, targetReps: 10), set(20, 8, targetReps: 10)
        ])])
        let result = try comparison(current)
        XCTAssertEqual(result.verdict, .insufficientData)
        XCTAssertEqual(result.facts.first, "Top set 20.0 lb x 15; 3 sets, 33 reps, volume 660.0 lb.")
        XCTAssertTrue(result.facts.contains("Reps fell from 15 to 8 across sets at 20.0 lb."))
        XCTAssertTrue(result.facts.contains("Missed planned reps on 1 set: set 3: 8 of 10."))
    }

    func testSeatedRowReductionMatchesPlanWithoutInventingReason() throws {
        let row = Exercise(name: "Seated Row")
        let prior = session([WorkoutExercise(exercise: row, sets: (0..<4).map { _ in set(90, 10) })], day: 0)
        let current = session([WorkoutExercise(exercise: row, sets: (0..<4).map { _ in set(60, 10, targetWeight: 60) })])
        let result = try comparison(current, earlier: [prior])
        XCTAssertEqual(result.verdict, .regressed)
        XCTAssertEqual(result.facts.first, "Top set 60.0 lb x 10; 4 sets, 40 reps, volume 2400.0 lb.")
        XCTAssertTrue(result.facts.contains("Volume 2400.0 lb versus 3600.0 lb earlier (-33.3%)."))
        XCTAssertTrue(result.facts.contains("Performed load matches the recorded plan for every completed set; the reason for the reduction is not in the evidence."))
    }

    func testIdenticalPerformanceIsMaintained() throws {
        let entries = [WorkoutExercise(exercise: bench, sets: [set(100, 10), set(100, 10)])]
        let result = try comparison(session(entries), earlier: [session(entries, day: 0)])
        XCTAssertEqual(result.verdict, .maintained)
        XCTAssertEqual(result.facts.first, "Top set 100.0 lb x 10; 2 sets, 20 reps, volume 2000.0 lb.")
        XCTAssertTrue(result.facts.contains("Volume 2000.0 lb versus 2000.0 lb earlier (+0.0%)."))
        XCTAssertFalse(result.facts.contains("Heaviest top set in the supplied earlier sessions."))
    }

    func testUnitMismatchDoesNotFallBackToOlderMatchingUnitOrEmitNumericComparisons() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(50, 8)])], day: 0, name: "Metric", unit: .kg)
        let older = session([WorkoutExercise(exercise: bench, sets: [set(100, 8)])], day: -1)
        let current = session([WorkoutExercise(exercise: bench, sets: [set(145, 8)])])
        let result = try comparison(current, earlier: [prior, older])
        XCTAssertEqual(result.verdict, .insufficientData)
        XCTAssertEqual(result.facts, [
            "Top set 145.0 lb x 8; 1 sets, 8 reps, volume 1160.0 lb.",
            "Recorded units differ (lb versus kg in earlier Metric); loads were not compared."
        ])
    }

    func testNoHistoryContainsOnlyCurrentPerformanceWhenNoPlanOrDropOffExists() throws {
        let current = session([WorkoutExercise(exercise: bench, sets: [set(40, 5)])])
        let result = try comparison(current)
        XCTAssertEqual(result.verdict, .insufficientData)
        XCTAssertEqual(result.facts, ["Top set 40.0 lb x 5; 1 sets, 5 reps, volume 200.0 lb."])
    }

    func testDuplicateMovementsAggregateBothSessionsAndPreserveFirstAppearanceOrder() throws {
        let curl = Exercise(name: "Curl")
        var renamedBench = bench
        renamedBench.name = "Renamed Bench"
        let current = session([
            WorkoutExercise(exercise: bench, sets: [set(50, 10)]),
            WorkoutExercise(exercise: curl, sets: [set(20, 5)]),
            WorkoutExercise(exercise: renamedBench, sets: [set(70, 8), set(60, 6)])
        ])
        let prior = session([
            WorkoutExercise(exercise: bench, sets: [set(40, 10)]),
            WorkoutExercise(exercise: bench, sets: [set(60, 8)])
        ], day: 0)
        let results = WorkoutSummaryAnalytics.comparisons(workout: current, earlier: [prior])
        XCTAssertEqual(results.map(\.exerciseName), ["Bench Press", "Curl"])
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.verdict, .improved)
        XCTAssertEqual(result.facts.first, "Top set 70.0 lb x 8; 3 sets, 24 reps, volume 1420.0 lb.")
        XCTAssertTrue(result.facts.contains("Volume 1420.0 lb versus 880.0 lb earlier (+61.4%)."))
        XCTAssertTrue(result.facts.contains("3 sets versus 2 sets earlier."))
        XCTAssertTrue(result.facts.contains("Shared set 2: 70.0 lb x 8 versus 60.0 lb x 8 earlier."))
        XCTAssertEqual(results.last?.verdict, .insufficientData)
        XCTAssertEqual(WorkoutSummaryAnalytics.totals(for: current), WorkoutSummaryTotals(completedSets: 4, totalReps: 29, volume: 1520))
    }

    func testTotalsExcludeIncompleteSetsAcrossExercisesInRecordedUnit() {
        let current = session([
            WorkoutExercise(exercise: bench, sets: [set(100, 8), set(200, 10, completed: false)]),
            WorkoutExercise(exercise: Exercise(name: "Row"), sets: [set(50, 12)])
        ], unit: .kg)
        XCTAssertEqual(WorkoutSummaryAnalytics.totals(for: current), WorkoutSummaryTotals(completedSets: 2, totalReps: 20, volume: 1400))
    }

    func testEmptyAndUncompletedMovementsReturnSingleFactWithoutCrashing() throws {
        for sets in [[], [set(200, 8, completed: false)]] {
            let current = session([WorkoutExercise(exercise: bench, sets: sets)])
            let prior = session([WorkoutExercise(exercise: bench, sets: [set(100, 8)])], day: 0)
            let result = try comparison(current, earlier: [prior])
            XCTAssertEqual(result.verdict, .insufficientData)
            XCTAssertEqual(result.facts, ["No completed sets were recorded."])
            XCTAssertEqual(WorkoutSummaryAnalytics.totals(for: current), WorkoutSummaryTotals(completedSets: 0, totalReps: 0, volume: 0))
        }
        XCTAssertEqual(WorkoutSummaryAnalytics.comparisons(workout: session([]), earlier: []), [])
    }

    func testMostRecentMovementWithNoCompletedSetsDoesNotFallBackToOlderSession() throws {
        let current = session([WorkoutExercise(exercise: bench, sets: [set(100, 8)])])
        let emptyPrior = session([WorkoutExercise(exercise: bench, sets: [])], day: 0, name: "Empty Earlier")
        let older = session([WorkoutExercise(exercise: bench, sets: [set(90, 8)])], day: -1)
        let result = try comparison(current, earlier: [emptyPrior, older])
        XCTAssertEqual(result.verdict, .insufficientData)
        XCTAssertEqual(result.facts, [
            "Top set 100.0 lb x 8; 1 sets, 8 reps, volume 800.0 lb.",
            "No completed sets were recorded for this movement in earlier Empty Earlier."
        ])
    }

    func testHistoryFilteringUsesCatalogIdentityAndRetainsCallerOrderIncludingBoundary() throws {
        let current = session([WorkoutExercise(exercise: bench, sets: [set(145, 8)])], day: 5)
        var sameID = session([WorkoutExercise(exercise: bench, sets: [set(500, 8)])], day: 0)
        sameID.id = current.id
        var unfinished = sameID
        unfinished.id = UUID()
        unfinished.finishedAt = nil
        let future = session([WorkoutExercise(exercise: bench, sets: [set(500, 8)])], day: 6)
        let unrelated = session([WorkoutExercise(exercise: Exercise(name: bench.name), sets: [set(500, 8)])], day: 4)
        var boundary = session([WorkoutExercise(exercise: bench, sets: [set(135, 8)])], day: 0, name: "Chosen Earlier")
        boundary.finishedAt = current.startedAt
        let laterInArray = session([WorkoutExercise(exercise: bench, sets: [set(140, 8)])], day: 4, name: "Not Chosen")
        let result = try comparison(current, earlier: [sameID, unfinished, future, unrelated, boundary, laterInArray])
        XCTAssertEqual(result.verdict, .improved)
        XCTAssertTrue(result.facts.contains { $0.contains("in earlier Chosen Earlier; difference +10.0 lb") })
        XCTAssertFalse(result.facts.contains { $0.contains("Not Chosen") })
        XCTAssertTrue(result.facts.contains("Heaviest top set in the supplied earlier sessions."))
    }

    func testBestClaimRequiresStrictlyHeavierThanAllSameUnitHistory() throws {
        let current = session([WorkoutExercise(exercise: bench, sets: [set(145, 8)])])
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(135, 8), set(999, 8, completed: false)])], day: 0)
        let metric = session([WorkoutExercise(exercise: bench, sets: [set(500, 8)])], day: -1, unit: .kg)
        let bestFact = "Heaviest top set in the supplied earlier sessions."
        XCTAssertTrue(try comparison(current, earlier: [prior, metric]).facts.contains(bestFact))
        for olderWeight in [145.0, 150.0] {
            let older = session([WorkoutExercise(exercise: bench, sets: [set(olderWeight, 8)])], day: -2)
            let result = try comparison(current, earlier: [prior, metric, older])
            XCTAssertEqual(result.verdict, .improved)
            XCTAssertFalse(result.facts.contains(bestFact))
        }
    }

    func testVerdictThresholdsAndPrecedence() throws {
        let cases: [(String, [WorkoutSet], [WorkoutSet], WorkoutSummaryExerciseComparison.Verdict, String)] = [
            ("same top and five percent more volume", [set(100, 20)], [set(100, 21)], .improved, "+5.0%"),
            ("same top and ten percent less volume", [set(100, 20)], [set(100, 18)], .maintained, "-10.0%"),
            ("same top and fifteen percent less volume", [set(100, 20)], [set(100, 17)], .regressed, "-15.0%"),
            ("higher top fewer reps lower volume", [set(100, 10), set(100, 10)], [set(120, 8), set(80, 10)], .mixed, "-12.0%"),
            ("regression precedes conflicting signals", [set(100, 20)], [set(120, 10)], .regressed, "-40.0%"),
            ("improvement precedes volume regression", [set(100, 10), set(100, 10), set(100, 10)], [set(120, 10)], .improved, "-60.0%"),
            ("lower top more volume", [set(100, 10)], [set(90, 10), set(90, 10)], .mixed, "+80.0%"),
            ("lower top five percent less volume", [set(100, 20)], [set(95, 20)], .regressed, "-5.0%")
        ]
        for (name, priorSets, currentSets, verdict, percent) in cases {
            let prior = session([WorkoutExercise(exercise: bench, sets: priorSets)], day: 0)
            let current = session([WorkoutExercise(exercise: bench, sets: currentSets)])
            let result = try comparison(current, earlier: [prior])
            XCTAssertEqual(result.verdict, verdict, name)
            XCTAssertTrue(result.facts.contains { $0.contains("(\(percent))") }, name)
        }
    }

    func testTopSetUsesFirstTieAndIncompleteSetsDoNotAffectAlignmentOrPlan() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(100, 10)])], day: 0)
        let current = session([WorkoutExercise(exercise: bench, sets: [
            set(999, 99, targetReps: 100, completed: false), set(110, 9), set(110, 12)
        ])])
        let result = try comparison(current, earlier: [prior])
        XCTAssertEqual(result.verdict, .maintained)
        XCTAssertEqual(result.facts.first, "Top set 110.0 lb x 9; 2 sets, 21 reps, volume 2310.0 lb.")
        XCTAssertTrue(result.facts.contains("Opening set 110.0 lb x 9 versus 100.0 lb x 10 earlier."))
        XCTAssertFalse(result.facts.contains { $0.contains("Missed planned reps") })
    }

    func testZeroVolumeHasNoPercentageAndCanStillShowTopLoadProgression() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(0, 10)])], day: 0)
        for (weight, verdict) in [(0.0, WorkoutSummaryExerciseComparison.Verdict.maintained), (10.0, .improved)] {
            let current = session([WorkoutExercise(exercise: bench, sets: [set(weight, 10)])])
            let result = try comparison(current, earlier: [prior])
            XCTAssertEqual(result.verdict, verdict)
            XCTAssertFalse(result.facts.contains { $0.contains("%") })
        }
        let current = session([WorkoutExercise(exercise: bench, sets: [set(10, 10)])])
        XCTAssertTrue(try comparison(current, earlier: [prior]).facts.contains("Volume 100.0 lb versus 0.0 lb earlier."))
    }

    func testPlanMissesUseAggregatedCompletedOrderAndLimitExamplesToThree() throws {
        let current = session([
            WorkoutExercise(exercise: bench, sets: [set(20, 100, targetReps: 101, completed: false), set(20, 9, targetReps: 10)]),
            WorkoutExercise(exercise: bench, sets: [set(20, 8, targetReps: 10), set(20, 7, targetReps: 10), set(20, 6, targetReps: 10)])
        ])
        let result = try comparison(current)
        XCTAssertEqual(result.verdict, .insufficientData)
        XCTAssertTrue(result.facts.contains("Missed planned reps on 4 sets: set 1: 9 of 10; set 2: 8 of 10; set 3: 7 of 10."))
        XCTAssertFalse(result.facts.contains { $0.contains("set 4: 6 of 10") })
    }

    func testPartialOrNonFiniteWeightPlansDoNotClaimPlanMatchedReduction() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(90, 10), set(90, 10)])], day: 0)
        for target in [nil, 65.0, Double.nan, Double.infinity] as [Double?] {
            let current = session([WorkoutExercise(exercise: bench, sets: [set(60, 10, targetWeight: 60), set(60, 10, targetWeight: target)])])
            let result = try comparison(current, earlier: [prior])
            XCTAssertEqual(result.verdict, .regressed)
            XCTAssertFalse(result.facts.contains { $0.contains("matches the recorded plan") })
        }
    }

    func testNonFiniteWeightsAndVolumeOverflowDoNotProduceNonFiniteEvidenceOrTotals() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(10, 1)])], day: 0)
        for invalidWeight in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            let current = session([WorkoutExercise(exercise: bench, sets: [set(10, 1), set(invalidWeight, 2)])])
            let result = try comparison(current, earlier: [prior])
            XCTAssertEqual(result.verdict, .insufficientData)
            XCTAssertTrue(try XCTUnwrap(result.facts.first).contains("volume unavailable"))
            XCTAssertFalse(result.facts.contains { $0.contains("nan") || $0.contains("inf lb") || $0.contains("difference") })
            XCTAssertEqual(WorkoutSummaryAnalytics.totals(for: current), WorkoutSummaryTotals(completedSets: 2, totalReps: 3, volume: 10))
        }
        let overflow = session([WorkoutExercise(exercise: bench, sets: [set(.greatestFiniteMagnitude, 1), set(.greatestFiniteMagnitude, 1)])])
        XCTAssertEqual(try comparison(overflow, earlier: [prior]).verdict, .insufficientData)
        XCTAssertEqual(WorkoutSummaryAnalytics.totals(for: overflow).volume, .greatestFiniteMagnitude)
        let invalidPrior = session([WorkoutExercise(exercise: bench, sets: [set(.nan, 8)])], day: -1)
        let invalidPriorResult = try comparison(prior, earlier: [invalidPrior])
        XCTAssertEqual(invalidPriorResult.verdict, .insufficientData)
        XCTAssertTrue(invalidPriorResult.facts.contains("Completed load data is unavailable or not finite; load comparisons are unavailable."))
    }

    func testSingleSetComparisonDoesNotClaimLateSetConfound() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(120, 10)])], day: 0, name: "Earlier Bench")
        let current = session([WorkoutExercise(exercise: bench, sets: [set(80, 15)])])
        let result = try comparison(current, earlier: [prior])
        XCTAssertFalse(result.facts.contains { $0.contains("Late-set reps rose") }, result.facts.joined(separator: " | "))
    }

    func testImprovedVerdictSuppressesContradictoryConfoundCaution() throws {
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(120, 10), set(100, 6)])], day: 0, name: "Earlier Bench")
        let current = session([WorkoutExercise(exercise: bench, sets: [set(80, 10), set(130, 10)])])
        let result = try comparison(current, earlier: [prior])
        XCTAssertEqual(result.verdict, .improved)
        XCTAssertFalse(result.facts.contains { $0.contains("not clear evidence of strength gain") }, result.facts.joined(separator: " | "))
    }

    func testBodyweightRepProgressionUsesRepsWhenBothVolumesAreZero() throws {
        let pushUp = Exercise(name: "Push-Up")
        let prior = session([WorkoutExercise(exercise: pushUp, sets: [set(0, 10)])], day: 0, name: "Earlier Push-Up")
        let current = session([WorkoutExercise(exercise: pushUp, sets: [set(0, 20)])], name: "Current Push-Up")
        let result = try comparison(current, earlier: [prior])
        XCTAssertEqual(result.verdict, .improved, result.facts.joined(separator: " | "))
        let regressed = session([WorkoutExercise(exercise: pushUp, sets: [set(0, 5)])], day: 2, name: "Later Push-Up")
        XCTAssertEqual(try comparison(regressed, earlier: [current]).verdict, .regressed)
    }

    func testNonFiniteHistoryDatesAndPercentageAreGuarded() throws {
        let current = session([WorkoutExercise(exercise: bench, sets: [set(1, 1)])])
        var invalidDate = session([WorkoutExercise(exercise: bench, sets: [set(999, 1)])], day: 0)
        invalidDate.finishedAt = Date(timeIntervalSince1970: .infinity)
        let prior = session([WorkoutExercise(exercise: bench, sets: [set(.leastNonzeroMagnitude, 1)])], day: 0)
        let result = try comparison(current, earlier: [invalidDate, prior])
        XCTAssertEqual(result.verdict, .improved)
        XCTAssertFalse(result.facts.contains { $0.contains("%") || $0.contains("inf lb") })
    }
}
