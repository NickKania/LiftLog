import Foundation
import XCTest
@testable import LiftLogCore

final class HealthDashboardAnalyticsTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        value.firstWeekday = 2
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func workout(_ start: Date, duration: TimeInterval = 1800, unit: WeightUnit = .lb,
                         templateID: UUID? = nil, name: String = "Workout", exercises: [WorkoutExercise] = []) -> WorkoutSession {
        WorkoutSession(templateID: templateID, name: name, startedAt: start,
                       finishedAt: start.addingTimeInterval(duration), unit: unit, exercises: exercises)
    }

    func testCalendarRangesIncludeBoundaryDayAndRejectActiveFutureAndInvalidSessions() {
        let now = date(2026, 3, 31)
        let boundary = workout(date(2026, 2, 28, 0))
        let older = workout(date(2026, 2, 27, 23))
        let today = workout(date(2026, 3, 31, 10))
        let active = WorkoutSession(startedAt: date(2026, 3, 30))
        let futureFinish = workout(now, duration: 1)
        let backwards = workout(date(2026, 3, 30), duration: -1)
        let invalidStart = workout(Date(timeIntervalSinceReferenceDate: .nan))
        var invalidFinish = today
        invalidFinish.finishedAt = Date(timeIntervalSinceReferenceDate: .infinity)
        let analytics = HealthDashboardAnalytics(workouts: [today, active, futureFinish, backwards, invalidStart,
            invalidFinish, boundary, older], unit: .lb, range: .month, now: now, calendar: calendar)

        XCTAssertEqual(analytics.workouts.map(\.id), [boundary.id, today.id])
        XCTAssertEqual(analytics.dailyCounts.first?.date, date(2026, 2, 28, 0))
        XCTAssertEqual(analytics.dailyCounts.last?.date, date(2026, 3, 31, 0))
        XCTAssertEqual(analytics.dailyCounts.count, 32)
        XCTAssertEqual(HealthDashboardRange.threeMonths.startDate(relativeTo: now, calendar: calendar), date(2025, 12, 31, 0))
        XCTAssertEqual(HealthDashboardRange.year.startDate(relativeTo: now, calendar: calendar), date(2025, 3, 31, 0))
    }

    func testHeatmapUsesLocalCalendarDaysAcrossDaylightSavingAndCoversAllHistory() {
        let workouts = [workout(date(2026, 3, 7, 23)), workout(date(2026, 3, 8, 1)), workout(date(2026, 3, 8, 3))]
        let analytics = HealthDashboardAnalytics(workouts: workouts, unit: .lb, range: .all,
                                               now: date(2026, 3, 9), calendar: calendar)
        XCTAssertEqual(analytics.dailyCounts.map(\.count), [1, 2, 0])
        XCTAssertEqual(analytics.dailyCounts[2].date.timeIntervalSince(analytics.dailyCounts[1].date), 23 * 3600)
        XCTAssertEqual(analytics.activeDayCount, 2)
        XCTAssertEqual(analytics.weekdayCounts.map(\.weekday), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(analytics.weekdayCounts.first(where: { $0.weekday == 1 })?.count, 2)
        XCTAssertEqual(analytics.weekdayCounts.first(where: { $0.weekday == 7 })?.count, 1)
        XCTAssertEqual(analytics.weekdayCounts.reduce(0) { $0 + $1.count }, 3)
    }

    func testDurationsCountCompletedSessionsIncludingZeroWithoutInventingEmptyAverages() {
        let analytics = HealthDashboardAnalytics(workouts: [workout(date(2026, 3, 1), duration: 1200),
            workout(date(2026, 3, 2), duration: 2400), workout(date(2026, 3, 3), duration: 0)],
            unit: .lb, range: .all, now: date(2026, 3, 4), calendar: calendar)
        XCTAssertEqual(analytics.totalDuration, 3600)
        XCTAssertEqual(analytics.averageDuration, 1200)
        XCTAssertEqual(analytics.longestDuration, 2400)
        let empty = HealthDashboardAnalytics(workouts: [], unit: .kg, range: .all,
                                             now: date(2026, 3, 4), calendar: calendar)
        XCTAssertNil(empty.averageDuration)
        XCTAssertNil(empty.longestDuration)
        XCTAssertEqual(empty.dailyCounts.map(\.count), [0])
        let invalidNow = HealthDashboardAnalytics(workouts: analytics.workouts, unit: .lb, range: .all,
            now: Date(timeIntervalSinceReferenceDate: .nan), calendar: calendar)
        XCTAssertTrue(invalidNow.workouts.isEmpty)
        XCTAssertTrue(invalidNow.dailyCounts.isEmpty)
    }

    func testProgressionConvertsBeforeComparingAndUsesOnlyValidCompletedSets() throws {
        let exercise = Exercise(name: "Bench press")
        let first = workout(date(2026, 3, 1), exercises: [WorkoutExercise(exercise: exercise, sets: [
            WorkoutSet(weight: 100, reps: 5, isCompleted: true),
            WorkoutSet(weight: 500, reps: 5, isCompleted: false),
            WorkoutSet(weight: 600, reps: 0, isCompleted: true),
            WorkoutSet(weight: .infinity, reps: 5, isCompleted: true)
        ])])
        let last = workout(date(2026, 3, 2), unit: .kg, exercises: [
            WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 50, reps: 5, isCompleted: true)]),
            WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 55, reps: 4, isCompleted: true),
                WorkoutSet(weight: -10, reps: 6, isCompleted: true)])
        ])
        let analytics = HealthDashboardAnalytics(workouts: [last, first], unit: .lb, range: .all,
            now: date(2026, 3, 4), calendar: calendar)
        let progression = try XCTUnwrap(analytics.exercises.first)
        XCTAssertEqual(progression.sessionCount, 2)
        XCTAssertEqual(progression.firstWeight, 100)
        XCTAssertEqual(progression.latestWeight, 55 / 0.45359237, accuracy: 0.000001)
        XCTAssertEqual(progression.maximumWeight, 55 / 0.45359237, accuracy: 0.000001)
        XCTAssertEqual(progression.change, 55 / 0.45359237 - 100, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(progression.changePercent), 21.2542442, accuracy: 0.000001)
        XCTAssertEqual(analytics.personalRecords.first?.date, last.startedAt)
        XCTAssertEqual(analytics.personalRecords.first?.reps, 4)

        let kilograms = HealthDashboardAnalytics(workouts: [first, last], unit: .kg, range: .all,
            now: date(2026, 3, 4), calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(kilograms.exercises.first).firstWeight, 45.359237, accuracy: 0.000001)
        XCTAssertEqual(kilograms.exercises.first?.maximumWeight, 55)
    }

    func testExerciseIdentitySeparatesSameNamesAndZeroBaselineHasNoPercentChange() throws {
        let first = Exercise(name: "Same name")
        let second = Exercise(name: "Same name")
        let sessions = [workout(date(2026, 3, 1), exercises: [
            WorkoutExercise(exercise: first, sets: [WorkoutSet(weight: 0, reps: 10, isCompleted: true)]),
            WorkoutExercise(exercise: second, sets: [WorkoutSet(weight: 70, reps: 5, isCompleted: true)])
        ]), workout(date(2026, 3, 2), exercises: [WorkoutExercise(exercise: first,
            sets: [WorkoutSet(weight: 10, reps: 10, isCompleted: true)])])]
        let analytics = HealthDashboardAnalytics(workouts: sessions, unit: .kg, range: .all,
            now: date(2026, 3, 4), calendar: calendar)
        XCTAssertEqual(analytics.exercises.count, 2)
        let progression = try XCTUnwrap(analytics.exercises.first(where: { $0.id == first.id }))
        XCTAssertNil(progression.changePercent)
        XCTAssertGreaterThan(progression.change, 0)
        XCTAssertEqual(analytics.personalRecords.count, 2)
    }

    func testHealthMetricsPreserveMissingVersusMeasuredZeroAndGroupByTemplateID() throws {
        let templateA = UUID(), templateB = UUID()
        let first = workout(date(2026, 3, 1), templateID: templateA, name: "Same name")
        let second = workout(date(2026, 3, 2), templateID: templateA, name: "Renamed")
        let third = workout(date(2026, 3, 3), templateID: templateB, name: "Same name")
        let custom = workout(date(2026, 3, 4))
        let now = date(2026, 3, 5)
        let snapshots = [first.id: snapshot(first, rates: [100, 120], energies: [0]),
                         second.id: snapshot(second, rates: [130], energies: [30, 40])]
        let activity = HealthDashboardActivity(workouts: [first, second, third, custom], snapshots: snapshots, now: now)
        XCTAssertEqual(activity.totalDuration, 7200)
        XCTAssertEqual(activity.workoutCount, 4)
        XCTAssertEqual(activity.averageHeartRate, 120)
        XCTAssertEqual(activity.activeEnergy, 70)
        XCTAssertEqual(activity.heartRateWorkoutCount, 2)
        XCTAssertEqual(activity.energyWorkoutCount, 2)
        XCTAssertEqual(activity.templates.count, 3)
        let groupA = try XCTUnwrap(activity.templates.first(where: { $0.templateID == templateA }))
        XCTAssertEqual(groupA.name, "Renamed")
        XCTAssertEqual(groupA.workoutCount, 2)
        XCTAssertEqual(groupA.averageHeartRate, 120)
        XCTAssertEqual(groupA.activeEnergy, 70)
        let groupB = try XCTUnwrap(activity.templates.first(where: { $0.templateID == templateB }))
        XCTAssertNil(groupB.averageHeartRate)
        XCTAssertNil(groupB.activeEnergy)
        XCTAssertEqual(groupB.energyWorkoutCount, 0)
        let zero = HealthDashboardActivity(workouts: [first], snapshots: [first.id: snapshots[first.id]!], now: now)
        XCTAssertEqual(zero.activeEnergy, 0)
        XCTAssertEqual(zero.energyWorkoutCount, 1)
        let missing = HealthDashboardActivity(workouts: [first], snapshots: [:], now: now)
        XCTAssertNil(missing.activeEnergy)
        XCTAssertNil(missing.averageHeartRate)
    }

    func testHealthAggregationScopesSamplesAndRejectsWrongWorkoutSnapshot() {
        let session = workout(date(2026, 3, 1))
        let now = date(2026, 3, 2)
        let contaminated = WorkoutHealthSnapshot(workoutID: session.id, workoutName: session.name,
            startedAt: session.startedAt, endedAt: session.finishedAt!, fetchedAt: now, metrics: [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: [
                    WorkoutHealthSample(date: session.startedAt, value: 110),
                    WorkoutHealthSample(date: session.startedAt, value: 0),
                    WorkoutHealthSample(date: session.startedAt, value: .nan),
                    WorkoutHealthSample(date: session.finishedAt!.addingTimeInterval(1), value: 200)
                ]), WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [
                    WorkoutHealthSample(date: session.startedAt, value: 25),
                    WorkoutHealthSample(date: session.startedAt.addingTimeInterval(-1), value: 100),
                    WorkoutHealthSample(date: session.startedAt, value: -1)
                ])])
        let activity = HealthDashboardActivity(workouts: [session], snapshots: [session.id: contaminated], now: now)
        XCTAssertEqual(activity.averageHeartRate, 110)
        XCTAssertEqual(activity.activeEnergy, 25)
        let wrong = snapshot(workout(date(2026, 3, 1)), rates: [150], energies: [100])
        let rejected = HealthDashboardActivity(workouts: [session], snapshots: [session.id: wrong], now: now)
        XCTAssertNil(rejected.averageHeartRate)
        XCTAssertNil(rejected.activeEnergy)
    }

    private func snapshot(_ workout: WorkoutSession, rates: [Double], energies: [Double]) -> WorkoutHealthSnapshot {
        WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: workout.startedAt,
            endedAt: workout.finishedAt!, fetchedAt: workout.finishedAt!, metrics: [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: rates.map { WorkoutHealthSample(date: workout.startedAt, value: $0) }),
                WorkoutHealthMetricSeries(metric: .activeEnergy, samples: energies.map { WorkoutHealthSample(date: workout.startedAt, value: $0) })
            ])
    }
}
