import Charts
import SwiftUI

struct HealthDashboardActivityView: View {
    let workouts: [WorkoutSession]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var health: HealthDashboardHealthStore

    init(workouts: [WorkoutSession], healthDataProvider: (any WorkoutHealthDataProviding)? = nil) {
        self.workouts = workouts
        let provider: any WorkoutHealthDataProviding
        if let healthDataProvider {
            provider = healthDataProvider
        } else {
            #if DEBUG
            if HealthDashboardUITestFixture.isEnabled {
                provider = HealthDashboardUITestFixture.makeHealthDataProvider()
            } else {
                provider = AppleHealthDataProvider()
            }
            #else
            provider = AppleHealthDataProvider()
            #endif
        }
        _health = State(initialValue: HealthDashboardHealthStore(provider: provider))
    }

    private var analytics: HealthDashboardAnalytics {
        HealthDashboardAnalytics(workouts: workouts, unit: .lb, range: .all)
    }

    private var activity: HealthDashboardActivity { analytics.activity(snapshots: health.snapshots) }
    private var recentDurations: [HealthDashboardDuration] { Array(analytics.durations.suffix(12)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            workoutTime
            healthReadings
            templateActivity
        }
        .onAppear { health.updateWorkouts(workouts) }
        .onChange(of: workouts) { _, selection in health.updateWorkouts(selection) }
        .onDisappear { health.cancel() }
    }

    private var workoutTime: some View {
        HealthDashboardCard(title: "Workout time", subtitle: "Recorded start-to-finish time, including rest.", systemImage: "timer") {
            metricLayout {
                HealthDashboardMetric(title: "Total time", value: HealthDashboardFormatting.duration(activity.totalDuration),
                    detail: "\(activity.workoutCount) workouts", tint: .teal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("healthWorkoutTimeTotal")
                HealthDashboardMetric(title: "Average workout", value: analytics.averageDuration.map(HealthDashboardFormatting.duration) ?? "No data",
                    detail: "Per completed workout", tint: .teal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("healthWorkoutTimeAverage")
            }
            if !recentDurations.isEmpty {
                Chart(recentDurations) { workout in
                    BarMark(x: .value("Workout", workout.workoutID.uuidString), y: .value("Minutes", workout.duration / 60))
                        .foregroundStyle(.teal.gradient)
                        .accessibilityLabel("\(workout.name), \(workout.date.formatted(date: .abbreviated, time: .omitted))")
                        .accessibilityValue(HealthDashboardFormatting.duration(workout.duration))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisTick()
                        AxisValueLabel {
                            if let id = value.as(String.self),
                               let workout = recentDurations.first(where: { $0.workoutID.uuidString == id }) {
                                Text(workout.date, format: .dateTime.month(.abbreviated).day())
                            }
                        }
                    }
                }
                .chartYAxisLabel("Minutes")
                .frame(height: 155)
                .accessibilityIdentifier("healthWorkoutDurationChart")
                Text("Your latest \(recentDurations.count) workouts in this range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let longest = analytics.longestDuration {
                HealthDashboardInsight(text: "Your longest workout in this range was \(HealthDashboardFormatting.duration(longest)).", systemImage: "clock")
            }
        }
    }

    private var healthReadings: some View {
        HealthDashboardCard(title: "Apple Health", subtitle: "Optional readings for these workout time windows.", systemImage: "heart") {
            Text("Load Apple Health to read calories burned and heart rate for the selected workouts. Readings stay on this device in this dashboard; they aren't saved to LiftLog, backed up, or shared with the assistant.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if health.isLoading {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: Double(health.completedCount), total: Double(max(1, health.workoutCount)))
                    HStack {
                        Text("Reading workouts: \(health.completedCount) of \(health.workoutCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { health.cancel() }
                            .accessibilityIdentifier("cancelDashboardHealthButton")
                    }
                }
                .accessibilityIdentifier("healthDashboardReadProgress")
            } else {
                Button {
                    health.updateWorkouts(workouts)
                    health.load()
                } label: {
                    Label(health.hasLoaded ? "Refresh Apple Health" : "Load Apple Health", systemImage: "heart.text.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(workouts.isEmpty)
                .accessibilityIdentifier("loadDashboardHealthButton")
            }

            metricLayout {
                HealthDashboardMetric(title: "Calories burned", value: metricValue(activity.activeEnergy, unit: "kcal"),
                    detail: "Measured intervals in \(activity.energyWorkoutCount) of \(activity.workoutCount) workouts", tint: .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("healthCaloriesBurned")
                HealthDashboardMetric(title: "Average heart rate", value: metricValue(activity.averageHeartRate, unit: "bpm"),
                    detail: "\(activity.heartRateWorkoutCount) of \(activity.workoutCount) workouts", tint: .pink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("healthAverageHeartRate")
            }

            if health.hasLoaded {
                Text(readStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("healthDashboardReadStatus")
            }
            ForEach(health.failures) { failure in
                Label("\(failure.workoutName): \(failure.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("healthDashboardReadFailure-\(failure.id)")
            }
            Text("Missing readings can mean no source data, limited read access, or Apple Watch sync delays. Apple Health doesn't reveal read permission status. Calories cover available intervals; heart rate is the mean of available session averages.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var templateActivity: some View {
        HealthDashboardCard(title: "Activity by template", subtitle: "Compare workout time and available heart rate readings.", systemImage: "list.bullet.rectangle") {
            ForEach(activity.templates) { template in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(template.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(template.workoutCount) workouts").font(.caption).foregroundStyle(.secondary)
                    }
                    metricLayout {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Workout time").font(.caption).foregroundStyle(.secondary)
                            Text(HealthDashboardFormatting.duration(template.totalDuration)).font(.subheadline.weight(.medium))
                            if let average = template.averageDuration {
                                Text("\(HealthDashboardFormatting.duration(average)) per workout").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Average heart rate").font(.caption).foregroundStyle(.secondary)
                            Text(metricValue(template.averageHeartRate, unit: "bpm")).font(.subheadline.weight(.medium))
                            Text("\(template.heartRateWorkoutCount) of \(template.workoutCount) workouts").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("healthDashboardTemplateActivity-\(template.id)")
                if template.id != activity.templates.last?.id { Divider() }
            }
        }
    }

    private func metricValue(_ value: Double?, unit: String) -> String {
        if let value { return "\(HealthDashboardFormatting.number(value)) \(unit)" }
        return health.hasLoaded ? "No data" : health.isLoading ? "Reading…" : "Not loaded"
    }

    private var metricLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
    }

    private var readStatus: String {
        let returned = "\(health.snapshots.count) of \(health.workoutCount) workout reads returned."
        let failures = health.failures.isEmpty ? "" : " \(health.failures.count) failed."
        let empty = health.emptyWorkoutCount == 0 ? "" : " \(health.emptyWorkoutCount) returned no readings."
        return returned + failures + empty
    }
}
