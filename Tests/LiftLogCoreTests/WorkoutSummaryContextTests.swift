import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSummaryContextTests: XCTestCase {
    private let exercise = Exercise(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, name: "Bench Press", category: "Chest")

    private func workout(id: UUID = UUID(), date: Date, templateID: UUID? = nil,
                         unit: WeightUnit = .lb, finished: Bool = true,
                         weight: Double = 135, reps: Int = 8) -> WorkoutSession {
        let set = WorkoutSet(weight: weight, reps: reps, targetReps: reps + 1, targetWeight: weight - 5, isCompleted: finished)
        return WorkoutSession(id: id, templateID: templateID, name: "Upper Body", startedAt: date,
                              finishedAt: finished ? date.addingTimeInterval(1_800) : nil, unit: unit,
                              exercises: [WorkoutExercise(exercise: exercise, sets: [set])])
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiftLogSummaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    func testInputIncludesRecordedUnitsTargetsRepeatedEntriesAndOnlyEarlierComparableHistory() throws {
        let templateID = UUID()
        let targetDate = Date(timeIntervalSinceReferenceDate: 10_000)
        var target = workout(date: targetDate, templateID: templateID, unit: .kg, weight: 60)
        let repeated = WorkoutExercise(exercise: exercise, sets: [
            WorkoutSet(weight: 20, reps: 12, targetReps: 10, targetWeight: 17.5, isCompleted: true)
        ], templateExerciseID: UUID())
        target.exercises.append(repeated)

        let earlier = workout(date: targetDate.addingTimeInterval(-3_600), templateID: templateID)
        let later = workout(date: targetDate.addingTimeInterval(3_600), templateID: templateID)
        let sharedMovement = workout(date: targetDate.addingTimeInterval(-7_200), templateID: UUID())
        var unrelated = workout(date: targetDate.addingTimeInterval(-10_800), templateID: UUID())
        unrelated.exercises = [WorkoutExercise(
            exercise: Exercise(name: "Squat", category: "Legs"),
            sets: [WorkoutSet(weight: 135, reps: 8, isCompleted: true)]
        )]

        let input = try WorkoutSummaryContext.input(workout: target, history: [later, unrelated, sharedMovement, earlier])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let encodedTarget = try XCTUnwrap(object["targetWorkout"] as? [String: Any])
        XCTAssertEqual(encodedTarget["unit"] as? String, "kg")
        XCTAssertEqual((encodedTarget["exercises"] as? [[String: Any]])?.count, 2)
        let sets = try XCTUnwrap((encodedTarget["exercises"] as? [[String: Any]])?.first?["sets"] as? [[String: Any]])
        XCTAssertEqual(sets.first?["plannedWeight"] as? Double, 55)
        XCTAssertEqual(sets.first?["plannedReps"] as? Int, 9)
        let targetExercises = try XCTUnwrap(encodedTarget["exercises"] as? [[String: Any]])
        XCTAssertNotEqual(targetExercises[0]["id"] as? String, targetExercises[1]["id"] as? String)
        let history = try XCTUnwrap(object["comparableHistory"] as? [[String: Any]])
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first?["id"] as? String, earlier.id.uuidString)
        XCTAssertEqual(history.last?["id"] as? String, sharedMovement.id.uuidString)
    }

    func testInputRejectsIncompleteTargetAndWrongHealthSnapshot() throws {
        let date = Date(timeIntervalSinceReferenceDate: 10_000)
        let incomplete = workout(date: date, finished: false)
        XCTAssertThrowsError(try WorkoutSummaryContext.input(workout: incomplete, history: []))

        let target = workout(date: date)
        let wrongHealth = WorkoutHealthSnapshot(workoutID: UUID(), workoutName: target.name,
                                                startedAt: date, endedAt: date.addingTimeInterval(1_800),
                                                fetchedAt: date.addingTimeInterval(2_000), metrics: [])
        XCTAssertThrowsError(try WorkoutSummaryContext.input(workout: target, history: [], health: wrongHealth))
    }

    func testInputBoundsComparableHistoryWithoutDroppingTarget() throws {
        let targetDate = Date(timeIntervalSinceReferenceDate: 100_000)
        let templateID = UUID()
        let target = workout(date: targetDate, templateID: templateID)
        let history = (0..<30).map { index in
            workout(date: targetDate.addingTimeInterval(Double(index - 40) * 3_600), templateID: templateID)
        }

        let input = try WorkoutSummaryContext.input(workout: target, history: history)
        XCTAssertLessThan(input.utf8.count, WorkoutSummaryContext.maximumPayloadBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertNotNil(object["targetWorkout"])
        XCTAssertEqual((object["comparableHistory"] as? [[String: Any]])?.count,
                       WorkoutSummaryContext.maximumHistorySessions)
    }

    func testHealthContextKeepsFinalIntervalsAndDoesNotInventZeros() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100_000)
        let target = workout(date: date)
        let snapshot = WorkoutHealthSnapshot(workoutID: target.id, workoutName: "ignored provider name",
                                             startedAt: date, endedAt: date.addingTimeInterval(1_800),
                                             fetchedAt: date.addingTimeInterval(2_000), metrics: [
            WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [
                WorkoutHealthSample(date: date.addingTimeInterval(60), value: 12),
                WorkoutHealthSample(date: date.addingTimeInterval(1_800), value: 34)
            ]),
            WorkoutHealthMetricSeries(metric: .steps, samples: [])
        ])
        let input = try WorkoutSummaryContext.input(workout: target, history: [], health: snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let health = try XCTUnwrap(object["health"] as? [String: Any])
        let metrics = try XCTUnwrap(health["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?["unit"] as? String, "kcal")
        XCTAssertEqual((metrics.first?["samples"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue((metrics.first?["samples"] as? [[String: Any]])?.allSatisfy { ($0["value"] as? Double) != 0 } == true)
    }

    func testLargeHealthContextAggregatesEveryMetricAndRetainsTotalsAndFinalInterval() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100_000)
        let target = workout(date: date)
        let heartRate = (0..<600).map { index in
            WorkoutHealthSample(date: date.addingTimeInterval(Double(index + 1)), value: 100 + Double(index % 20))
        }
        let energy = (0..<600).map { index in
            WorkoutHealthSample(date: date.addingTimeInterval(Double(index + 1)), value: 1.25)
        }
        let steps = (0..<600).map { index in
            WorkoutHealthSample(date: date.addingTimeInterval(Double(index + 1)), value: 2)
        }
        let snapshot = WorkoutHealthSnapshot(workoutID: target.id, workoutName: target.name,
                                             startedAt: date, endedAt: date.addingTimeInterval(1_800),
                                             fetchedAt: date.addingTimeInterval(2_000), metrics: [
            WorkoutHealthMetricSeries(metric: .heartRate, samples: heartRate),
            WorkoutHealthMetricSeries(metric: .activeEnergy, samples: energy),
            WorkoutHealthMetricSeries(metric: .steps, samples: steps)
        ])

        let input = try WorkoutSummaryContext.input(workout: target, history: [], health: snapshot)
        XCTAssertLessThan(input.utf8.count, WorkoutSummaryContext.maximumPayloadBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let health = try XCTUnwrap(object["health"] as? [String: Any])
        let metrics = try XCTUnwrap(health["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 3)
        let expectedFinalDate = ISO8601DateFormatter().string(from: date.addingTimeInterval(600))
        for metric in metrics {
            XCTAssertEqual(metric["intervalStart"] as? String, ISO8601DateFormatter().string(from: date))
            XCTAssertEqual(metric["intervalEnd"] as? String, ISO8601DateFormatter().string(from: date.addingTimeInterval(1_800)))
            XCTAssertEqual(metric["aggregation"] as? String,
                           metric["metric"] as? String == "heartRate" ? "interval_mean" : "interval_total")
            XCTAssertEqual((metric["samples"] as? [[String: Any]])?.count, WorkoutSummaryContext.maximumHealthSamplesPerMetric)
            XCTAssertEqual((metric["samples"] as? [[String: Any]])?.last?["date"] as? String,
                           expectedFinalDate)
        }
        let energyRecord = try XCTUnwrap(metrics.first { $0["metric"] as? String == "activeEnergy" })
        let stepsRecord = try XCTUnwrap(metrics.first { $0["metric"] as? String == "steps" })
        let energyTotal = (energyRecord["samples"] as? [[String: Any]])?.compactMap { $0["value"] as? Double }.reduce(0, +)
        let stepsTotal = (stepsRecord["samples"] as? [[String: Any]])?.compactMap { $0["value"] as? Double }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(energyTotal), 600 * 1.25, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(stepsTotal), 1_200, accuracy: 0.000_001)
    }

    func testMalformedHistoryIsExcludedAndOversizedTargetThrows() throws {
        let date = Date(timeIntervalSinceReferenceDate: 100_000)
        let target = workout(date: date, templateID: UUID())
        let malformed = workout(date: date.addingTimeInterval(-3_600), templateID: target.templateID, finished: false)
        let valid = workout(date: date.addingTimeInterval(-7_200), templateID: target.templateID)
        let input = try WorkoutSummaryContext.input(workout: target, history: [malformed, valid])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual((object["comparableHistory"] as? [[String: Any]])?.count, 1)

        var oversized = target
        oversized.name = String(repeating: "x", count: WorkoutSummaryContext.maximumPayloadBytes)
        XCTAssertThrowsError(try WorkoutSummaryContext.input(workout: oversized, history: []))
    }

    @MainActor
    func testSummaryPreferencesPersistValidateAndReset() throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertEqual(store.workoutSummaryPrompt, WorkoutSummaryPrompt.defaultPrompt)
        XCTAssertFalse(store.automaticWorkoutSummaries)

        let custom = "Focus on consistency and the next top set."
        XCTAssertTrue(store.setWorkoutSummaryPrompt(custom))
        XCTAssertTrue(store.setAutomaticWorkoutSummaries(true))
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.workoutSummaryPrompt, custom)
        XCTAssertTrue(reloaded.automaticWorkoutSummaries)

        XCTAssertFalse(store.setWorkoutSummaryPrompt(String(repeating: "x", count: WorkoutSummaryPrompt.maximumLength + 1)))
        XCTAssertEqual(store.workoutSummaryPrompt, custom)
        XCTAssertTrue(store.setWorkoutSummaryPrompt(" \n\t "))
        XCTAssertEqual(store.workoutSummaryPrompt, WorkoutSummaryPrompt.defaultPrompt)
        XCTAssertTrue(store.setAutomaticWorkoutSummaries(false))
        XCTAssertEqual(WorkoutStore(fileURL: file).workoutSummaryPrompt, WorkoutSummaryPrompt.defaultPrompt)
        XCTAssertFalse(WorkoutStore(fileURL: file).automaticWorkoutSummaries)

        let otherFile = try temporaryFile()
        XCTAssertEqual(WorkoutStore(fileURL: otherFile).workoutSummaryPrompt, WorkoutSummaryPrompt.defaultPrompt)
    }
}
