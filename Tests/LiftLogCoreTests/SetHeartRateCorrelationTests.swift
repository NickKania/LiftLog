import Foundation
import XCTest
@testable import LiftLogCore

final class SetHeartRateCorrelationTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000)
    private let row = Exercise(name: "Row", category: "Back")
    private let curl = Exercise(name: "Curl", category: "Arms")

    private func set(_ end: TimeInterval, start: TimeInterval? = nil, weight: Double = 100,
                     reps: Int = 8, marked: Bool = false, offset: TimeInterval = 0) -> WorkoutSet {
        WorkoutSet(weight: weight, reps: reps, isCompleted: true,
                   startedAt: start.map { epoch.addingTimeInterval($0 + offset) },
                   completedAt: epoch.addingTimeInterval(end + offset), isMarkedForHeartRate: marked)
    }

    private func workout(_ entries: [WorkoutExercise], unit: WeightUnit = .lb, offset: TimeInterval = 0) -> WorkoutSession {
        WorkoutSession(startedAt: epoch.addingTimeInterval(offset), finishedAt: epoch.addingTimeInterval(offset + 240),
                       unit: unit, exercises: entries)
    }

    private func snapshot(_ workout: WorkoutSession, samples: [(TimeInterval, Double)], end: TimeInterval = 240,
                          additionalMetrics: [WorkoutHealthMetricSeries] = []) -> WorkoutHealthSnapshot {
        WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: workout.startedAt,
                              endedAt: workout.startedAt.addingTimeInterval(end), fetchedAt: workout.startedAt,
                              metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: samples.map {
            WorkoutHealthSample(date: workout.startedAt.addingTimeInterval($0.0), value: $0.1)
        })] + additionalMetrics)
    }

    func testTimedEstimatedRecoveryAndChronologicalSupersetOrder() throws {
        let group = UUID()
        let timed = set(30, start: 10, marked: true)
        let estimated = set(105)
        let late = set(150, start: 129)
        let workout = workout([
            WorkoutExercise(exercise: row, sets: [estimated, timed], supersetID: group),
            WorkoutExercise(exercise: curl, sets: [late], supersetID: group)
        ])
        let health = snapshot(workout, samples: [(94, 115), (20, 140), (11, 120), (80, 125),
                                                 (103, 130), (145, 155), (212, 111)])
        let result = WorkoutHeartRateCorrelation.correlate(workout: workout, snapshot: health)
        XCTAssertEqual(result.sets.map(\.id), [timed.id, estimated.id, late.id])
        XCTAssertEqual(result.sets.map(\.setNumber), [2, 1, 1])
        XCTAssertEqual(result.sets.map(\.windowKind), [.timed, .estimated, .timed])
        XCTAssertEqual(result.sets.map(\.duration), [20, 45, 21])
        XCTAssertEqual(result.sets.map(\.sampleCount), [2, 3, 1])
        XCTAssertEqual(result.sets[0].averageHeartRate, 130)
        XCTAssertEqual(try XCTUnwrap(result.sets[1].averageHeartRate), 370.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(result.sets[2].averageHeartRate, 155)
        XCTAssertEqual(result.sets.map(\.peakHeartRate), [140, 130, 155])
        XCTAssertEqual(result.sets.map(\.recoveryHeartRate60s), [120, nil, 111])
        XCTAssertEqual(result.sets.map(\.recoveryDrop60s), [20, nil, 44])
        XCTAssertEqual(result.sessionPeakHeartRate, 155)
        XCTAssertEqual(result.exercises.map(\.id), workout.exercises.map(\.id))
        XCTAssertEqual(result.exercises[0].coveredSetCount, 2)
        XCTAssertEqual(result.exercises[0].markedSetCount, 1)
        XCTAssertEqual(result.exercises[0].timedSetCount, 1)
        XCTAssertTrue(result.hasTimestampedSets)
        XCTAssertTrue(result.hasMarkedSets)
    }

    func testEstimatedWindowUsesPreviousCompletionAndRecoveryStopsAtNextStart() {
        let first = set(30, start: 10)
        let second = set(95, start: 85)
        let third = set(110)
        let workout = workout([WorkoutExercise(exercise: row, sets: [third, first, second])])
        let health = snapshot(workout, samples: [(30, 150), (80, 113), (85, 117), (86, 180), (95, 140)])
        let result = WorkoutHeartRateCorrelation.correlate(workout: workout, snapshot: health)
        XCTAssertEqual(result.sets[0].recoveryHeartRate60s, 115)
        XCTAssertEqual(result.sets[0].recoveryDrop60s, 35)
        XCTAssertEqual(result.sets[2].windowStart, epoch.addingTimeInterval(95))
        XCTAssertEqual(result.sets[2].sampleCount, 1)
    }

    func testMissingAndInvalidSamplesStayMissingAndWrongWorkoutSamplesAreIgnored() {
        let workout = workout([WorkoutExercise(exercise: row, sets: [WorkoutSet(isCompleted: true), set(50, start: 20)])])
        let unrelated = WorkoutSession(startedAt: workout.startedAt)
        let health = snapshot(workout, samples: [(-1, 144), (30, .infinity), (30, 0), (110, 112), (300, 150)])
        let result = WorkoutHeartRateCorrelation.correlate(workout: workout, snapshot: health)
        XCTAssertEqual(result.heartRateSamples.map(\.value), [112])
        XCTAssertEqual(result.sets.count, 1)
        XCTAssertNil(result.sets[0].averageHeartRate)
        XCTAssertNil(result.sets[0].peakHeartRate)
        XCTAssertNil(result.sets[0].recoveryHeartRate60s)
        XCTAssertNil(result.sets[0].recoveryDrop60s)
        XCTAssertNil(result.exercises[0].averageHeartRate)
        XCTAssertTrue(WorkoutHeartRateCorrelation.correlate(workout: unrelated, snapshot: health).heartRateSamples.isEmpty)
    }

    func testCrossWorkoutTrendsFilterGroupRepeatedEntriesAndConvertUnits() throws {
        let pounds = workout([
            WorkoutExercise(exercise: row, sets: [set(30, start: 10, marked: true)]),
            WorkoutExercise(exercise: row, sets: [set(95, start: 85, weight: 150, reps: 5)]),
            WorkoutExercise(exercise: curl, sets: [set(140, start: 130, marked: true)])
        ])
        let kilograms = workout([
            WorkoutExercise(exercise: row, sets: [set(30, start: 10, weight: 67, offset: 500)])
        ], unit: .kg, offset: 500)
        let workouts = [kilograms, pounds]
        let snapshots = [
            pounds.id: snapshot(pounds, samples: [(15, 130), (90, 150)]),
            kilograms.id: snapshot(kilograms, samples: [(15, 140)])
        ]
        let marked = try XCTUnwrap(ExerciseHeartRateTrendAnalytics.trends(workouts: workouts, snapshots: snapshots,
                                                                           unit: .kg, filter: .markedOnly).first)
        XCTAssertEqual(marked.points.map(\.workoutID), [pounds.id])
        XCTAssertEqual(marked.points[0].heaviestWeight, 45.359237, accuracy: 0.000001)
        XCTAssertEqual(marked.overallAverageHeartRate, 130)
        let all = ExerciseHeartRateTrendAnalytics.trends(workouts: workouts, snapshots: snapshots,
                                                         unit: .kg, filter: .allTimestamped)
        XCTAssertEqual(all.map(\.id), [row.id])
        let trend = try XCTUnwrap(all.first)
        XCTAssertEqual(trend.points.map(\.workoutID), [pounds.id, kilograms.id])
        XCTAssertEqual(trend.points.map(\.setCount), [2, 1])
        XCTAssertEqual(trend.points.map(\.markedSetCount), [1, 0])
        XCTAssertEqual(trend.points[0].heaviestWeight, 150 * 0.45359237, accuracy: 0.000001)
        XCTAssertEqual(trend.points[0].repsAtHeaviest, 5)
        XCTAssertEqual(trend.points[1].heaviestWeight, 67)
        XCTAssertEqual(trend.totalCorrelatedSets, 3)
        XCTAssertEqual(trend.overallAverageHeartRate, 140)
        XCTAssertEqual(trend.overallPeakHeartRate, 150)
    }

    func testLongTimedSetInterruptsEarlierSetsRecoveryAcrossInterleavedCompletions() throws {
        // Repro: set A completes at t=100; timed set B starts at t=140 and finishes at t=300;
        // set C completes at t=160 while B is timing. A's recovery [150, 170] is interrupted at t=140 -> nil.
        let bench = Exercise(name: "Bench Press", category: "Chest")
        let at: (TimeInterval) -> Date = { self.epoch.addingTimeInterval($0) }
        let setA = WorkoutSet(weight: 185, reps: 5, isCompleted: true, startedAt: at(60), completedAt: at(100), isMarkedForHeartRate: true)
        let setB = WorkoutSet(weight: 135, reps: 10, isCompleted: true, startedAt: at(140), completedAt: at(300), isMarkedForHeartRate: true)
        let setC = WorkoutSet(weight: 135, reps: 8, isCompleted: true, completedAt: at(160))
        let session = WorkoutSession(name: "Interleaved", startedAt: epoch, finishedAt: at(400),
                                     exercises: [WorkoutExercise(exercise: bench, sets: [setA, setB, setC])])
        let health = snapshot(session, samples: [(80, 155), (155, 130), (220, 160), (360, 120)])
        let correlation = WorkoutHeartRateCorrelation.correlate(workout: session, snapshot: health)
        let metricsA = try XCTUnwrap(correlation.sets.first { $0.id == setA.id })
        XCTAssertNil(metricsA.recoveryHeartRate60s)
        XCTAssertNil(metricsA.recoveryDrop60s)

        // Also test timed set already in progress BEFORE A completed (t=90...300): A's recovery must be nil.
        let spanningB = WorkoutSet(weight: 135, reps: 10, isCompleted: true, startedAt: at(90), completedAt: at(300), isMarkedForHeartRate: true)
        let spanningSession = WorkoutSession(name: "Spanning", startedAt: epoch, finishedAt: at(400),
                                             exercises: [WorkoutExercise(exercise: bench, sets: [setA, spanningB])])
        let spanningCorrelation = WorkoutHeartRateCorrelation.correlate(workout: spanningSession, snapshot: snapshot(spanningSession, samples: [(80, 155), (155, 125)]))
        let spanningA = try XCTUnwrap(spanningCorrelation.sets.first { $0.id == setA.id })
        XCTAssertNil(spanningA.recoveryHeartRate60s)
        XCTAssertNil(spanningA.recoveryDrop60s)
    }

    func testTrendHeaviestSetUsesCoveredSetsOnly() throws {
        let squat = Exercise(name: "Squat", category: "Legs")
        let at: (TimeInterval) -> Date = { self.epoch.addingTimeInterval($0) }
        let coveredLighter = WorkoutSet(weight: 225, reps: 5, isCompleted: true, startedAt: at(20), completedAt: at(50), isMarkedForHeartRate: true)
        let uncoveredHeavier = WorkoutSet(weight: 315, reps: 3, isCompleted: true, startedAt: at(200), completedAt: at(230), isMarkedForHeartRate: true)
        let session = WorkoutSession(name: "Legs", startedAt: epoch, finishedAt: at(300),
                                     exercises: [WorkoutExercise(exercise: squat, sets: [coveredLighter, uncoveredHeavier])])
        let health = snapshot(session, samples: [(35, 150)])
        let trend = try XCTUnwrap(ExerciseHeartRateTrendAnalytics.trends(workouts: [session], snapshots: [session.id: health],
                                                                         unit: .lb, filter: .markedOnly).first)
        XCTAssertEqual(trend.points[0].heaviestWeight, 225)
        XCTAssertEqual(trend.points[0].repsAtHeaviest, 5)
    }

    @MainActor
    func testDefaultProviderScopesHeartRateUsingHighResolutionCap() async throws {
        let workout = workout([])
        let energy = WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [WorkoutHealthSample(date: epoch, value: 8)])
        let health = snapshot(workout, samples: (0..<4_001).map { (Double($0) / 20, 120) },
                              additionalMetrics: [energy])
        let provider = SeriesProvider(snapshot: health)
        let result = try await provider.fetchHeartRateSamples(for: workout, through: epoch.addingTimeInterval(195))
        XCTAssertEqual(result.metrics.map(\.metric), [.heartRate])
        XCTAssertEqual(result.metrics[0].samples.count, 3_600)
        XCTAssertEqual(result.endedAt, epoch.addingTimeInterval(195))
        XCTAssertEqual(result.metrics[0].samples.last?.date, result.endedAt)
        XCTAssertEqual(try health.scoped(to: workout, through: health.endedAt).metrics[0].samples.count, 600)
    }

    private struct SeriesProvider: WorkoutHealthDataProviding {
        let snapshot: WorkoutHealthSnapshot
        func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
            snapshot
        }
    }
}
