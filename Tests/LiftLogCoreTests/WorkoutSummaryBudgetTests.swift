import Foundation
import XCTest
@testable import LiftLogCore

enum SummaryBudgetFixtures {
    static func sessions() -> [WorkoutSession] {
        let templateID = UUID()
        let names = ["Bench Press", "Incline Dumbbell Press", "Barbell Row", "Lat Pulldown", "Biceps Curl", "Triceps Extension"]
        let exercises = names.map { Exercise(name: $0, category: "Strength") }
        let targetDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
        return (0...8).map { session in
            let startedAt = targetDate.addingTimeInterval(-Double(session) * 86_400)
            let firstSupersetID = UUID()
            let secondSupersetID = UUID()
            return WorkoutSession(templateID: templateID, templateVersionID: UUID(), templateVersionNumber: session + 1,
                name: "Upper Body", startedAt: startedAt, finishedAt: startedAt.addingTimeInterval(3_600),
                unit: session.isMultiple(of: 2) ? .lb : .kg, importSourceKey: "summary-budget-fixture-\(session)",
                exercises: exercises.enumerated().map { index, exercise in
                    WorkoutExercise(exercise: exercise, sets: (0..<4).map { set in
                        WorkoutSet(weight: Double(100 + index * 5 + set), reps: 8 - set,
                                   targetReps: 8, targetWeight: Double(100 + index * 5), isCompleted: true)
                    }, supersetID: index < 2 ? firstSupersetID : (index < 4 ? secondSupersetID : nil),
                    templateExerciseID: nil, notes: "Controlled movement \(index + 1).")
                }, notes: "Completed session \(session + 1), no missed sets.")
        }
    }

    static func health(for workout: WorkoutSession) -> WorkoutHealthSnapshot {
        let metrics = WorkoutHealthMetric.allCases.map { metric in
            WorkoutHealthMetricSeries(metric: metric, samples: (0..<600).map { index in
                let value: Double
                switch metric {
                case .heartRate: value = 100 + Double(index % 20)
                case .activeEnergy: value = 1.25
                case .steps: value = 2
                }
                return WorkoutHealthSample(date: workout.startedAt.addingTimeInterval(Double(index + 1) * 6), value: value)
            })
        }
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
            startedAt: workout.startedAt, endedAt: workout.startedAt.addingTimeInterval(3_600),
            fetchedAt: workout.startedAt.addingTimeInterval(3_600), metrics: metrics)
    }
}

final class WorkoutSummaryBudgetTests: XCTestCase {
    private func evidence(_ request: WorkoutSummaryRequest) throws -> [String: Any] {
        if let evidence = request.input.first?["evidence"] as? [String: Any] { return evidence }
        let content = try XCTUnwrap(request.input.first?["content"] as? String)
        let json = try XCTUnwrap(content.components(separatedBy: "Evidence JSON:\n").last)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testOrdinaryLocalEvidenceFitsRealProjectionWithWholeTargetAndExplicitCoverage() throws {
        let sessions = SummaryBudgetFixtures.sessions()
        var target = try XCTUnwrap(sessions.first)
        let literalNote = "Keep record_1 and \(UUID().uuidString) as literal notes."
        target.notes = literalNote
        target.exercises.append(WorkoutExercise(exercise: target.exercises[0].exercise, sets: [
            WorkoutSet(weight: 0, reps: 12, isCompleted: true)
        ], supersetID: target.exercises[2].supersetID, notes: "Repeated movement, separate entry and superset."))
        let request = try WorkoutSummaryRequest(workout: target, history: sessions,
            prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertFalse(projected.omittedEarlierTurns)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        XCTAssertNil(payload["setColumns"])
        XCTAssertEqual(payload["allSetsCompleted"] as? Bool, true)
        let encodedTarget = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        XCTAssertEqual(encodedTarget["notes"] as? String, literalNote)
        try assertFacts(encodedTarget, match: target)
        let targetExercises = try XCTUnwrap(encodedTarget["exercises"] as? [[String: Any]])
        XCTAssertEqual(targetExercises[0]["movement"] as? Int, targetExercises[6]["movement"] as? Int)
        XCTAssertEqual(encodedTarget["templateVersionNumber"] as? Int, target.templateVersionNumber)
        XCTAssertEqual(targetExercises[0]["supersetGroup"] as? Int, 1)
        XCTAssertEqual(targetExercises[1]["supersetGroup"] as? Int, 1)
        XCTAssertEqual(targetExercises[2]["supersetGroup"] as? Int, 2)
        XCTAssertEqual(targetExercises[3]["supersetGroup"] as? Int, 2)
        XCTAssertEqual(targetExercises[6]["supersetGroup"] as? Int, 2)
        XCTAssertNil(targetExercises[4]["supersetGroup"])
        XCTAssertNil(targetExercises[5]["supersetGroup"])
        XCTAssertEqual(targetExercises.last?["completedActual"] as? String, "1 sets: 0.0 lb x 12 reps each")
        XCTAssertNil(targetExercises.last?["recordedPlan"])

        let history = try XCTUnwrap(payload["earlierCompletedWorkouts"] as? [[String: Any]])
        let coverage = try XCTUnwrap(payload["coverage"] as? [String: Int])
        XCTAssertEqual(coverage["comparableSessionsAvailable"], 8)
        XCTAssertEqual(coverage["comparableSessionsIncluded"], history.count)
        XCTAssertEqual(coverage["comparableSessionsOmitted"], 8 - history.count)
        XCTAssertGreaterThan(history.count, 0)
        XCTAssertLessThan(history.count, 8)
        for (record, session) in zip(history, sessions.dropFirst()) {
            try assertFacts(record, match: session)
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        for key in ["templateVersionID", "templateExerciseID", "supersetID", "exerciseID"] {
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        XCTAssertNil(encodedTarget["id"])
        XCTAssertTrue(targetExercises.allSatisfy { $0["id"] == nil })
    }

    func testMissingVersionAndUngroupedExercisesStayAbsentUnderNativeBudget() throws {
        var target = try XCTUnwrap(SummaryBudgetFixtures.sessions().first)
        target.templateVersionNumber = nil
        for index in target.exercises.indices { target.exercises[index].supersetID = nil }
        let request = try WorkoutSummaryRequest(workout: target, history: [],
            prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        let encodedTarget = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        XCTAssertNil(encodedTarget["templateVersionNumber"])
        let exercises = try XCTUnwrap(encodedTarget["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, target.exercises.count)
        XCTAssertTrue(exercises.allSatisfy { $0["supersetGroup"] == nil })
        try assertFacts(encodedTarget, match: target)
    }

    func testLocalHealthFitsRealProjectionAndPreservesEveryIntervalContribution() throws {
        let sessions = SummaryBudgetFixtures.sessions()
        let target = try XCTUnwrap(sessions.first)
        let snapshot = SummaryBudgetFixtures.health(for: target)
        let request = try WorkoutSummaryRequest(workout: target, history: sessions, health: snapshot,
            prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
        let projected = try FoundationModelsRequest(input: request.input, tools: [], instructions: request.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        let payload = try evidence(request)
        let health = try XCTUnwrap(payload["health"] as? [String: Any])
        XCTAssertNil(health["sampleColumns"])
        XCTAssertEqual(health["intervalStart"] as? String, ISO8601DateFormatter().string(from: target.startedAt))
        XCTAssertEqual(health["intervalEnd"] as? String, ISO8601DateFormatter().string(from: target.startedAt.addingTimeInterval(3_600)))
        let metrics = try XCTUnwrap(health["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 3)
        for metric in metrics {
            let samples = try XCTUnwrap(metric["samples"] as? [[String: Double]])
            XCTAssertLessThan(samples.count, WorkoutSummaryContext.maximumHealthSamplesPerMetric)
            XCTAssertEqual(metric["sourceSampleCount"] as? Int, 600)
            XCTAssertEqual(samples.reduce(0) { $0 + ($1["sourceIntervals"] ?? 0) }, 600)
            XCTAssertEqual(samples.last?["endedAfterSeconds"], 3_600)
            switch metric["metric"] as? String {
            case "heartRate":
                XCTAssertEqual(metric["aggregation"] as? String, "mean_of_interval_means")
                XCTAssertEqual(samples.reduce(0) { $0 + ($1["value"] ?? 0) * ($1["sourceIntervals"] ?? 0) } / 600, 109.5, accuracy: 0.000_001)
                XCTAssertEqual(metric["overview"] as? String, "Observed heart rate: minimum 100.0 bpm; maximum 119.0 bpm; mean 109.5 bpm across 600 source interval means. No HRV measurements.")
            case "activeEnergy":
                XCTAssertEqual(metric["aggregation"] as? String, "interval_total")
                XCTAssertEqual(samples.reduce(0) { $0 + ($1["value"] ?? 0) }, 750, accuracy: 0.000_001)
                XCTAssertEqual(metric["overview"] as? String, "Active energy expended: 750.0 kcal total, not intake.")
            case "steps":
                XCTAssertEqual(samples.reduce(0) { $0 + ($1["value"] ?? 0) }, 1_200, accuracy: 0.000_001)
                XCTAssertEqual(metric["overview"] as? String, "Recorded steps: 1200.0 total.")
            default: XCTFail("Unexpected metric")
            }
        }
        let coverage = try XCTUnwrap(payload["coverage"] as? [String: Int])
        XCTAssertEqual(coverage["comparableSessionsIncluded"], 0, "Comparison sessions are omitted before reducing Health.")
        XCTAssertEqual(coverage["comparableSessionsOmitted"], 8)
        XCTAssertEqual(snapshot.metrics.first?.samples.count, 600, "The original scoped chart snapshot remains intact.")
        try assertFacts(XCTUnwrap(payload["completedWorkout"] as? [String: Any]), match: target)
    }

    func testOversizedLocalTargetFailsWithoutTruncatingNotesOrFacts() throws {
        var target = try XCTUnwrap(SummaryBudgetFixtures.sessions().first)
        target.notes = String(repeating: "Long recorded note. ", count: 500)
        let original = target
        XCTAssertThrowsError(try WorkoutSummaryRequest(workout: target, history: [],
            prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)) { error in
            XCTAssertEqual(error as? WorkoutSummaryContext.Error, .localPayloadTooLarge)
            XCTAssertTrue(error.localizedDescription.contains("Shorten your summary prompt in Settings"))
            XCTAssertFalse(error.localizedDescription.contains("start a new chat"))
        }
        XCTAssertEqual(target, original)
    }

    func testCloudEvidenceFormatAndHealthBudgetRemainUnchanged() throws {
        let sessions = SummaryBudgetFixtures.sessions()
        let target = try XCTUnwrap(sessions.first)
        let health = SummaryBudgetFixtures.health(for: target)
        let oldEvidence = try WorkoutSummaryContext.input(workout: target, history: sessions, health: health)
        let request = try WorkoutSummaryRequest(workout: target, history: sessions, health: health,
            prompt: "Keep the original cloud request.", provider: .chatGPT)
        let content = try XCTUnwrap(request.input.first?["content"] as? String)
        XCTAssertEqual(content.components(separatedBy: "Evidence JSON:\n").last, oldEvidence)
        let payload = try evidence(request)
        XCTAssertNil(payload["setColumns"])
        let encodedHealth = try XCTUnwrap(payload["health"] as? [String: Any])
        let metrics = try XCTUnwrap(encodedHealth["metrics"] as? [[String: Any]])
        XCTAssertEqual((metrics.first?["samples"] as? [[String: Any]])?.count,
                       WorkoutSummaryContext.maximumHealthSamplesPerMetric)
    }

    func testSharedHealthAggregationPreservesTotalsMeansMissingMetricsAndSource() throws {
        let target = try XCTUnwrap(SummaryBudgetFixtures.sessions().first)
        let snapshot = SummaryBudgetFixtures.health(for: target)
        let original = snapshot
        let reduced = snapshot.aggregated(maximumSamplesPerMetric: 7)
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(reduced.workoutID, snapshot.workoutID)
        XCTAssertEqual(reduced.startedAt, snapshot.startedAt)
        XCTAssertEqual(reduced.endedAt, snapshot.endedAt)
        for (source, series) in zip(snapshot.metrics, reduced.metrics) {
            XCTAssertEqual(series.samples.count, 7)
            XCTAssertEqual(series.samples.last?.date, source.samples.last?.date)
            if series.metric == .heartRate {
                for (index, sample) in series.samples.enumerated() {
                    let group = source.samples[(index * 600 / 7)..<((index + 1) * 600 / 7)]
                    XCTAssertEqual(sample.value, group.reduce(0) { $0 + $1.value / Double(group.count) }, accuracy: 0.000_001)
                }
            } else {
                XCTAssertEqual(series.samples.reduce(0) { $0 + $1.value }, source.samples.reduce(0) { $0 + $1.value }, accuracy: 0.000_001)
            }
        }
        let missing = WorkoutHealthSnapshot(workoutID: target.id, workoutName: target.name,
            startedAt: snapshot.startedAt, endedAt: snapshot.endedAt, fetchedAt: snapshot.fetchedAt,
            metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: [])])
        XCTAssertFalse(missing.aggregated(maximumSamplesPerMetric: 1).hasSamples)
        XCTAssertEqual(missing.aggregated(maximumSamplesPerMetric: 1).metrics.count, 1)
    }

    private func assertFacts(_ record: [String: Any], match workout: WorkoutSession) throws {
        XCTAssertEqual(record["name"] as? String, workout.name)
        XCTAssertEqual(record["unit"] as? String, workout.unit.rawValue)
        XCTAssertEqual(record["templateVersionNumber"] as? Int, workout.templateVersionNumber)
        XCTAssertEqual(record["notes"] as? String, workout.notes)
        XCTAssertEqual(record["startedAt"] as? String, ISO8601DateFormatter().string(from: workout.startedAt))
        XCTAssertEqual(record["finishedAt"] as? String, workout.finishedAt.map { ISO8601DateFormatter().string(from: $0) })
        let exercises = try XCTUnwrap(record["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.count, workout.exercises.count)
        var groups: [UUID: Int] = [:]
        for (encoded, original) in zip(exercises, workout.exercises) {
            XCTAssertEqual(encoded["exerciseName"] as? String, original.exercise.name)
            XCTAssertEqual(encoded["notes"] as? String, original.notes)
            if let id = original.supersetID {
                if groups[id] == nil { groups[id] = groups.count + 1 }
                XCTAssertEqual(encoded["supersetGroup"] as? Int, groups[id])
            } else {
                XCTAssertNil(encoded["supersetGroup"])
            }
            let actual = try XCTUnwrap(encoded["completedActual"] as? String)
            if original.sets.count == 1, let set = original.sets.first {
                XCTAssertEqual(actual, "1 sets: \(set.weight) \(workout.unit.rawValue) x \(set.reps) reps each")
            } else {
                XCTAssertEqual(actual, original.sets.map { "\($0.weight) \(workout.unit.rawValue) x \($0.reps) reps" }.joined(separator: "; "))
            }
            if original.sets.contains(where: { $0.targetWeight != nil || $0.targetReps != nil }) {
                let first = try XCTUnwrap(original.sets.first)
                let weight = try XCTUnwrap(first.targetWeight)
                let reps = try XCTUnwrap(first.targetReps)
                XCTAssertEqual(encoded["recordedPlan"] as? String,
                               "\(original.sets.count) sets: \(weight) \(workout.unit.rawValue) x \(reps) reps each")
            } else {
                XCTAssertNil(encoded["recordedPlan"])
            }
        }
    }
}
