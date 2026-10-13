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
        XCTAssertEqual(analytics.dailyActivity.first?.date, date(2026, 2, 28, 0))
        XCTAssertEqual(analytics.dailyActivity.last?.date, date(2026, 3, 31, 0))
        XCTAssertEqual(analytics.dailyActivity.count, 32)
        XCTAssertEqual(HealthDashboardRange.threeMonths.startDate(relativeTo: now, calendar: calendar), date(2025, 12, 31, 0))
        XCTAssertEqual(HealthDashboardRange.year.startDate(relativeTo: now, calendar: calendar), date(2025, 3, 31, 0))
    }

    func testHeatmapUsesLocalCalendarDaysAcrossDaylightSavingAndCoversAllHistory() {
        let workouts = [workout(date(2026, 3, 7, 23)), workout(date(2026, 3, 8, 1)), workout(date(2026, 3, 8, 3))]
        let analytics = HealthDashboardAnalytics(workouts: workouts, unit: .lb, range: .all,
                                               now: date(2026, 3, 9), calendar: calendar)
        XCTAssertEqual(analytics.dailyActivity.map(\.count), [1, 2, 0])
        XCTAssertEqual(analytics.dailyActivity.map(\.totalDuration), [1800, 3600, 0])
        XCTAssertEqual(analytics.dailyActivity[2].date.timeIntervalSince(analytics.dailyActivity[1].date), 23 * 3600)
        XCTAssertEqual(analytics.activeDayCount, 2)
        XCTAssertEqual(analytics.weekdayCounts.map(\.weekday), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(analytics.weekdayCounts.first(where: { $0.weekday == 1 })?.count, 2)
        XCTAssertEqual(analytics.weekdayCounts.first(where: { $0.weekday == 7 })?.count, 1)
        XCTAssertEqual(analytics.weekdayCounts.reduce(0) { $0 + $1.count }, 3)
    }

    func testHeatmapSumsDailyTrainingTimeAndCapsIntensityAtOneHour() {
        let sessions = [
            workout(date(2026, 3, 1, 9), duration: 600),
            workout(date(2026, 3, 1, 18), duration: 300),
            workout(date(2026, 3, 2), duration: 1800),
            workout(date(2026, 3, 3), duration: 2700),
            workout(date(2026, 3, 4), duration: 3600),
            workout(date(2026, 3, 5), duration: 5400),
            workout(date(2026, 3, 6), duration: 0),
            workout(date(2026, 3, 6), duration: -60),
            WorkoutSession(startedAt: date(2026, 3, 6))
        ]
        let analytics = HealthDashboardAnalytics(workouts: sessions, unit: .lb, range: .all,
            now: date(2026, 3, 7), calendar: calendar)

        XCTAssertEqual(analytics.dailyActivity.map(\.count), [2, 1, 1, 1, 1, 1, 0])
        XCTAssertEqual(analytics.dailyActivity.map(\.totalDuration), [900, 1800, 2700, 3600, 5400, 0, 0])
        XCTAssertEqual(analytics.dailyActivity.map(\.heatmapIntensity), [0.25, 0.5, 0.75, 1, 1, 0, 0])
        XCTAssertEqual(analytics.dailyActivity.reduce(0) { $0 + $1.totalDuration }, analytics.totalDuration)
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
        XCTAssertEqual(empty.dailyActivity.map(\.count), [0])
        let invalidNow = HealthDashboardAnalytics(workouts: analytics.workouts, unit: .lb, range: .all,
            now: Date(timeIntervalSinceReferenceDate: .nan), calendar: calendar)
        XCTAssertTrue(invalidNow.workouts.isEmpty)
        XCTAssertTrue(invalidNow.dailyActivity.isEmpty)
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
        XCTAssertEqual(HealthDashboardAnalytics.personalRecords(for: analytics.exercises), analytics.personalRecords)

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

    func testIdenticalEnergyWindowsCountOnlyStableFirstReadingWithoutChangingHeartRateOrTime() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var first = workout(date(2026, 3, 1))
        var duplicate = workout(first.startedAt)
        first.id = firstID
        duplicate.id = secondID
        let readings = [first.id: snapshot(first, rates: [100], energies: [50]),
                        duplicate.id: snapshot(duplicate, rates: [140], energies: [90])]
        let activity = HealthDashboardActivity(workouts: [duplicate, first], snapshots: readings, now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 50)
        XCTAssertEqual(activity.energyWorkoutCount, 1)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 1)
        XCTAssertEqual(activity, HealthDashboardActivity(workouts: [first, duplicate], snapshots: readings, now: date(2026, 3, 2)))
        XCTAssertEqual(activity.workoutCount, 2)
        XCTAssertEqual(activity.totalDuration, 3600)
        XCTAssertEqual(activity.averageHeartRate, 120)
        XCTAssertEqual(activity.heartRateWorkoutCount, 2)
    }

    func testPartiallyOverlappingEnergyWindowsExcludeWholeLaterReadingEvenWithDistinctSampleDates() {
        let first = workout(date(2026, 3, 1, 12), duration: 3600)
        let overlapping = workout(date(2026, 3, 1, 12, 30), duration: 3600)
        // Samples are interval totals with a representative date. Their timestamps
        // cannot reveal which fraction of a reading overlaps the other workout.
        let laterReading = WorkoutHealthSnapshot(workoutID: overlapping.id, workoutName: overlapping.name,
            startedAt: overlapping.startedAt, endedAt: overlapping.finishedAt!, fetchedAt: overlapping.finishedAt!,
            metrics: [WorkoutHealthMetricSeries(metric: .activeEnergy,
                samples: [WorkoutHealthSample(date: overlapping.finishedAt!, value: 70)])])
        let activity = HealthDashboardActivity(workouts: [first, overlapping], snapshots: [
            first.id: snapshot(first, rates: [], energies: [40]), overlapping.id: laterReading
        ], now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 40)
        XCTAssertEqual(activity.energyWorkoutCount, 1)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 1)
    }

    func testTouchingEnergyWindowsBothCountAndRejectedOverlapDoesNotBlockLaterReading() {
        let first = workout(date(2026, 3, 1, 12), duration: 1800)
        let overlapping = workout(date(2026, 3, 1, 12, 15), duration: 7200)
        let touching = workout(date(2026, 3, 1, 12, 30), duration: 1800)
        let activity = HealthDashboardActivity(workouts: [overlapping, touching, first], snapshots: [
            first.id: snapshot(first, rates: [], energies: [40]),
            overlapping.id: snapshot(overlapping, rates: [], energies: [150]),
            touching.id: snapshot(touching, rates: [], energies: [60])
        ], now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 100)
        XCTAssertEqual(activity.energyWorkoutCount, 2)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 1)
    }

    func testCrossTemplateOverlapUsesSameGlobalSelectionForTotalsAndTemplateCoverage() throws {
        let templateA = UUID(), templateB = UUID()
        let first = workout(date(2026, 3, 1, 12), duration: 3600, templateID: templateA)
        let overlapping = workout(date(2026, 3, 1, 12, 30), duration: 3600, templateID: templateB)
        let later = workout(date(2026, 3, 1, 14), duration: 1800, templateID: templateB)
        let activity = HealthDashboardActivity(workouts: [overlapping, first, later], snapshots: [
            first.id: snapshot(first, rates: [100], energies: [40]),
            overlapping.id: snapshot(overlapping, rates: [120], energies: [70]),
            later.id: snapshot(later, rates: [140], energies: [20])
        ], now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 60)
        XCTAssertEqual(activity.energyWorkoutCount, 2)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 1)
        XCTAssertEqual(activity.templates.compactMap(\.activeEnergy).reduce(0, +), activity.activeEnergy)
        let groupA = try XCTUnwrap(activity.templates.first(where: { $0.templateID == templateA }))
        let groupB = try XCTUnwrap(activity.templates.first(where: { $0.templateID == templateB }))
        XCTAssertEqual(groupA.activeEnergy, 40)
        XCTAssertEqual(groupA.energyWorkoutCount, 1)
        XCTAssertEqual(groupA.excludedEnergyWorkoutCount, 0)
        XCTAssertEqual(groupB.activeEnergy, 20)
        XCTAssertEqual(groupB.energyWorkoutCount, 1)
        XCTAssertEqual(groupB.excludedEnergyWorkoutCount, 1)
        XCTAssertEqual(groupB.averageHeartRate, 130)
        XCTAssertEqual(groupB.heartRateWorkoutCount, 2)
    }

    func testEarlierMissingOrInvalidEnergyDoesNotExcludeOverlappingValidReading() {
        let first = workout(date(2026, 3, 1, 12), duration: 7200)
        let invalid = workout(date(2026, 3, 1, 12, 15), duration: 3600)
        let valid = workout(date(2026, 3, 1, 12, 30), duration: 1800)
        let activity = HealthDashboardActivity(workouts: [first, invalid, valid], snapshots: [
            first.id: snapshot(first, rates: [100], energies: []),
            invalid.id: snapshot(invalid, rates: [], energies: [.nan, -1]),
            valid.id: snapshot(valid, rates: [140], energies: [35])
        ], now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 35)
        XCTAssertEqual(activity.energyWorkoutCount, 1)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 0)
        XCTAssertEqual(activity.averageHeartRate, 120)
    }

    func testEnergySelectionUsesScopedSnapshotEndAndIsIndependentOfInputOrdering() {
        let first = workout(date(2026, 3, 1, 12), duration: 7200)
        let later = workout(date(2026, 3, 1, 12, 30), duration: 1800)
        let partial = WorkoutHealthSnapshot(workoutID: first.id, workoutName: first.name, startedAt: first.startedAt,
            endedAt: later.startedAt, fetchedAt: first.finishedAt!, metrics: [
                WorkoutHealthMetricSeries(metric: .activeEnergy,
                    samples: [WorkoutHealthSample(date: first.startedAt, value: 25)])
            ])
        let readings = [first.id: partial, later.id: snapshot(later, rates: [], energies: [45])]
        let forward = HealthDashboardActivity(workouts: [first, later], snapshots: readings, now: date(2026, 3, 2))
        let reverse = HealthDashboardActivity(workouts: [later, first], snapshots: readings, now: date(2026, 3, 2))
        XCTAssertEqual(forward.activeEnergy, 70)
        XCTAssertEqual(forward.energyWorkoutCount, 2)
        XCTAssertEqual(forward.excludedEnergyWorkoutCount, 0)
        XCTAssertEqual(forward, reverse)
    }

    func testMeasuredZeroEnergyStillReservesWindowAndExcludedTemplateRemainsUnmeasured() throws {
        let first = workout(date(2026, 3, 1, 12), duration: 3600, templateID: UUID())
        let overlapping = workout(date(2026, 3, 1, 12, 30), duration: 1800, templateID: UUID())
        let activity = HealthDashboardActivity(workouts: [first, overlapping], snapshots: [
            first.id: snapshot(first, rates: [], energies: [0]),
            overlapping.id: snapshot(overlapping, rates: [], energies: [70])
        ], now: date(2026, 3, 2))
        XCTAssertEqual(activity.activeEnergy, 0)
        XCTAssertEqual(activity.energyWorkoutCount, 1)
        XCTAssertEqual(activity.excludedEnergyWorkoutCount, 1)
        let omitted = try XCTUnwrap(activity.templates.first(where: { $0.templateID == overlapping.templateID }))
        XCTAssertNil(omitted.activeEnergy)
        XCTAssertEqual(omitted.energyWorkoutCount, 0)
        XCTAssertEqual(omitted.excludedEnergyWorkoutCount, 1)
    }

    private func snapshot(_ workout: WorkoutSession, rates: [Double], energies: [Double]) -> WorkoutHealthSnapshot {
        WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: workout.startedAt,
            endedAt: workout.finishedAt!, fetchedAt: workout.finishedAt!, metrics: [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: rates.map { WorkoutHealthSample(date: workout.startedAt, value: $0) }),
                WorkoutHealthMetricSeries(metric: .activeEnergy, samples: energies.map { WorkoutHealthSample(date: workout.startedAt, value: $0) })
            ])
    }
}
