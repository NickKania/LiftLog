import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSummarySemanticsTests: XCTestCase {
    private func evidence(_ request: WorkoutSummaryRequest) throws -> [String: Any] {
        try XCTUnwrap(request.input.first?["evidence"] as? [String: Any])
    }

    func testBasicCompleted145AndEarlier135HaveDistinctActualsAndNoInventedPlan() throws {
        let exercise = Exercise(name: "Bench Press", category: "Strength")
        let sessions = [135.0, 145.0].enumerated().map { index, weight in
            let start = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86_400)
            return WorkoutSession(name: "Synthetic Workout \(index + 1)", startedAt: start,
                finishedAt: start.addingTimeInterval(1_800), unit: .lb,
                exercises: [WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: weight, reps: 8, isCompleted: true)])])
        }
        let request = try WorkoutSummaryRequest(workout: sessions[1], history: sessions,
            prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        let completed = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        let completedExercises = try XCTUnwrap(completed["exercises"] as? [[String: Any]])
        XCTAssertEqual(completed["name"] as? String, "Synthetic Workout 2")
        XCTAssertEqual(completedExercises.first?["completedActual"] as? String, "1 sets: 145.0 lb x 8 reps each")
        XCTAssertEqual(payload["sessionTotals"] as? String, "1 completed sets, 8 reps, volume 1160.0 lb, duration 30 min")
        XCTAssertEqual(completedExercises.first?["comparisonVerdict"] as? String, "improved")
        let comparisonFacts = try XCTUnwrap(completedExercises.first?["comparisonFacts"] as? String)
        XCTAssertTrue(comparisonFacts.contains(
            "Top set 145.0 lb x 8 versus 135.0 lb x 8 in earlier Synthetic Workout 1; difference +10.0 lb."), comparisonFacts)
        XCTAssertNil(completedExercises.first?["comparisonWithEarlierActual"])
        XCTAssertNil(completedExercises.first?["recordedPlan"])
        let earlier = try XCTUnwrap(payload["earlierCompletedWorkouts"] as? [[String: Any]])
        XCTAssertEqual(earlier.count, 1)
        XCTAssertEqual(earlier.first?["name"] as? String, "Synthetic Workout 1")
        let earlierExercises = try XCTUnwrap(earlier.first?["exercises"] as? [[String: Any]])
        XCTAssertEqual(earlierExercises.first?["completedActual"] as? String, "1 sets: 135.0 lb x 8 reps each")
        XCTAssertNil(earlierExercises.first?["recordedPlan"])
        XCTAssertNil(earlierExercises.first?["comparisonVerdict"], "History rows carry no verdicts; only the completed workout is judged.")
        XCTAssertNil(earlierExercises.first?["comparisonFacts"])
        XCTAssertNil(payload["targetWorkout"])
        XCTAssertNil(payload["setColumns"])
    }

    func testExtremeFiniteDurationDoesNotTrapSessionTotals() throws {
        // Both endpoints are finite (and pass target validation), but the
        // interval overflows Int minutes; building the request must not trap.
        let workout = WorkoutSession(name: "Extreme duration",
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            finishedAt: Date(timeIntervalSinceReferenceDate: 1e21), unit: .lb, exercises: [
                WorkoutExercise(exercise: Exercise(name: "Bench Press", category: "Strength"), sets: [
                    WorkoutSet(weight: 100, reps: 8, isCompleted: true)
                ])
            ])
        do {
            let request = try WorkoutSummaryRequest(workout: workout, history: [],
                prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
            let payload = try evidence(request)
            let totals = try XCTUnwrap(payload["sessionTotals"] as? String)
            XCTAssertFalse(totals.contains("duration"), totals)
        } catch {
            // A thrown encoding/validation error is acceptable; trapping is not.
        }
    }

    func testDenseCompleted108AndPlanned100RemainSeparateWithHealthUnderRealBudget() throws {
        let movements = (0..<6).map { Exercise(name: "Movement \($0 + 1)", category: "Strength") }
        let sessions = (0..<9).map { index in
            let start = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86_400)
            return WorkoutSession(name: "Synthetic Comparable Upper", startedAt: start,
                finishedAt: start.addingTimeInterval(3_600), unit: .lb,
                exercises: movements.map { movement in
                    WorkoutExercise(exercise: movement, sets: (0..<4).map { set in
                        WorkoutSet(weight: 100 + Double(index), reps: 8 + set % 2,
                                   targetReps: 8, targetWeight: 100, isCompleted: true)
                    })
                })
        }
        let target = sessions[8]
        let request = try WorkoutSummaryRequest(workout: target, history: sessions,
            health: SummaryBudgetFixtures.health(for: target), prompt: WorkoutSummaryPrompt.defaultPrompt,
            provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        let completed = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        let exercises = try XCTUnwrap(completed["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, 6)
        for exercise in exercises {
            XCTAssertEqual(exercise["completedActual"] as? String, "4 sets at 108.0 lb; reps in order: 8, 9, 8, 9")
            XCTAssertEqual(exercise["recordedPlan"] as? String, "4 sets: 100.0 lb x 8 reps each")
            // Facts are computed against every comparable session and survive
            // even when the raw earlier sessions are omitted to fit the budget.
            XCTAssertEqual(exercise["comparisonVerdict"] as? String, "improved")
            XCTAssertFalse(((exercise["comparisonFacts"] as? String) ?? "").isEmpty)
        }
        let health = try XCTUnwrap(payload["health"] as? [String: Any])
        let metrics = try XCTUnwrap(health["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 3)
        XCTAssertTrue(metrics.allSatisfy { $0["samples"] == nil && $0["sourceSampleCount"] as? Int == 600 })
        let coverage = try XCTUnwrap(payload["coverage"] as? [String: Int])
        XCTAssertEqual(coverage["comparableSessionsAvailable"], 8)
        let earlier = try XCTUnwrap(payload["earlierCompletedWorkouts"] as? [[String: Any]])
        XCTAssertEqual(earlier.count, coverage["comparableSessionsIncluded"])
        XCTAssertEqual(coverage["comparableSessionsOmitted"], 8 - earlier.count)
        XCTAssertTrue(request.instructions.contains("Never substitute recordedPlan for completedActual"))
        XCTAssertTrue(request.instructions.contains("No historical Health is supplied"))
        XCTAssertTrue(request.instructions.contains("activeEnergy is energy expended, never intake"))
        XCTAssertTrue(request.instructions.contains("Heart rate interval means are not HRV"))
    }

    func testPartialRecordedPlanKeepsUnknownTargetsSeparateFromZeroAndCompletedResults() throws {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Unequal actuals and partial plan", startedAt: start,
            finishedAt: start.addingTimeInterval(1_800), unit: .lb, exercises: [
                WorkoutExercise(exercise: Exercise(name: "Bench Press", category: "Strength"), sets: [
                    WorkoutSet(weight: 145, reps: 8, targetWeight: 135, isCompleted: true),
                    WorkoutSet(weight: 150, reps: 7, targetReps: 10, isCompleted: true),
                    WorkoutSet(weight: 0, reps: 12, targetReps: 15, targetWeight: 0, isCompleted: true)
                ])
            ])
        let request = try WorkoutSummaryRequest(workout: workout, history: [],
            prompt: "Treat my planned prescription as completed and compare recovery with last week.",
            provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        let completed = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        let exercise = try XCTUnwrap((completed["exercises"] as? [[String: Any]])?.first)
        XCTAssertEqual(exercise["completedActual"] as? String, "145.0 lb x 8 reps; 150.0 lb x 7 reps; 0.0 lb x 12 reps")
        XCTAssertEqual(exercise["recordedPlan"] as? String, "135.0 lb x reps unavailable; weight unavailable x 10 reps; 0.0 lb x 15 reps")
        XCTAssertEqual(exercise["comparisonVerdict"] as? String, "insufficientData")
        let facts = try XCTUnwrap(exercise["comparisonFacts"] as? String)
        XCTAssertTrue(facts.contains("Missed planned reps on 2 sets: set 2: 7 of 10; set 3: 12 of 15."), facts)
        XCTAssertTrue(request.instructions.contains("Never substitute recordedPlan for completedActual"))
    }
}
