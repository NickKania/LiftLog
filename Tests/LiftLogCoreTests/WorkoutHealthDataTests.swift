import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutHealthDataTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testIntervalUsesOnlyTheSelectedWorkoutAndStopsAtFinishOrRequestTime() throws {
        var workout = WorkoutSession(startedAt: start)
        let through = start.addingTimeInterval(600)
        XCTAssertEqual(try WorkoutHealthSnapshot.interval(for: workout, through: through), DateInterval(start: start, end: through))
        workout.finishedAt = start.addingTimeInterval(300)
        XCTAssertEqual(try WorkoutHealthSnapshot.interval(for: workout, through: through).end, workout.finishedAt)
        workout.finishedAt = start.addingTimeInterval(900)
        XCTAssertEqual(try WorkoutHealthSnapshot.interval(for: workout, through: through).end, through)
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: workout, through: start.addingTimeInterval(-1)))
        workout.finishedAt = start.addingTimeInterval(-1)
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: workout, through: through))
    }

    func testInvalidOrExcessiveTimeRangeIsRejected() {
        let workout = WorkoutSession(startedAt: start)
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: workout, through: start.addingTimeInterval(48 * 3600 + 1)))
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: workout, through: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: WorkoutSession(startedAt: Date(timeIntervalSinceReferenceDate: .nan)), through: start))
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: WorkoutSession(startedAt: start, finishedAt: Date(timeIntervalSinceReferenceDate: .nan)), through: start))
        XCTAssertThrowsError(try WorkoutHealthSnapshot.interval(for: WorkoutSession(startedAt: start, finishedAt: Date(timeIntervalSinceReferenceDate: .infinity)), through: start))
    }

    func testScopingRejectsWrongSessionAndFiltersInvalidValuesOrUnselectedTime() throws {
        let workout = WorkoutSession(name: "Selected workout", startedAt: start, finishedAt: start.addingTimeInterval(60))
        let through = start.addingTimeInterval(120)
        let snapshot = WorkoutHealthSnapshot(workoutID: workout.id, workoutName: "Untrusted name", startedAt: start, endedAt: through,
            fetchedAt: through, metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: [
                WorkoutHealthSample(date: start.addingTimeInterval(40), value: 110),
                WorkoutHealthSample(date: start.addingTimeInterval(-1), value: 100),
                WorkoutHealthSample(date: start.addingTimeInterval(61), value: 120),
                WorkoutHealthSample(date: start.addingTimeInterval(20), value: 90),
                WorkoutHealthSample(date: start, value: .nan),
                WorkoutHealthSample(date: start, value: .infinity),
                WorkoutHealthSample(date: start, value: -10),
                WorkoutHealthSample(date: start, value: 0)
            ])])
        let scoped = try snapshot.scoped(to: workout, through: through)
        XCTAssertEqual(scoped.endedAt, workout.finishedAt)
        XCTAssertEqual(scoped.workoutName, workout.name)
        XCTAssertEqual(scoped.metrics.first?.samples.map(\.value), [90, 110])
        XCTAssertTrue(scoped.hasSamples)
        XCTAssertThrowsError(try snapshot.scoped(to: WorkoutSession(startedAt: start), through: through))
        let alteredStart = WorkoutSession(id: workout.id, startedAt: start.addingTimeInterval(10))
        XCTAssertThrowsError(try snapshot.scoped(to: alteredStart, through: through))
        XCTAssertEqual(try JSONDecoder().decode(WorkoutHealthSnapshot.self, from: JSONEncoder().encode(scoped)), scoped)
    }

    func testBoundedSeriesPreserveCumulativeTotalsAndRepresentTheWholeWorkout() throws {
        let workout = WorkoutSession(startedAt: start)
        let through = start.addingTimeInterval(1200)
        let samples = (0..<1200).map { WorkoutHealthSample(date: start.addingTimeInterval(Double($0)), value: 1) }
        let snapshot = WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: start, endedAt: through,
            fetchedAt: through, metrics: [
                WorkoutHealthMetricSeries(metric: .steps, samples: Array(samples.prefix(600))),
                WorkoutHealthMetricSeries(metric: .steps, samples: Array(samples.suffix(600))),
                WorkoutHealthMetricSeries(metric: .heartRate, samples: samples.map { WorkoutHealthSample(date: $0.date, value: 120) })
            ])
        let scoped = try snapshot.scoped(to: workout, through: through)
        XCTAssertEqual(scoped.metrics.count, 2)
        let steps = try XCTUnwrap(scoped.metrics.first { $0.metric == .steps })
        XCTAssertEqual(steps.samples.count, WorkoutHealthSnapshot.maximumSamplesPerMetric)
        XCTAssertEqual(steps.samples.reduce(0) { $0 + $1.value }, 1200)
        XCTAssertEqual(steps.samples.first?.date, start.addingTimeInterval(1))
        XCTAssertEqual(steps.samples.last?.date, start.addingTimeInterval(1199))
        XCTAssertTrue(try XCTUnwrap(scoped.metrics.first { $0.metric == .heartRate }).samples.allSatisfy { $0.value == 120 })
    }

    func testEmptySnapshotDoesNotInventReadAuthorizationOrZeroValues() throws {
        let workout = WorkoutSession(startedAt: start)
        let snapshot = WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: start,
            endedAt: start.addingTimeInterval(60), fetchedAt: start.addingTimeInterval(60), metrics: [])
        XCTAssertFalse(try snapshot.scoped(to: workout, through: start.addingTimeInterval(60)).hasSamples)
        XCTAssertTrue(snapshot.metrics.isEmpty)
    }
}
