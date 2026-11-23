import Charts
import SwiftUI

struct HealthDashboardActivityView: View {
    let workouts: [WorkoutSession]
    let unit: WeightUnit
    let range: HealthDashboardRange
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var health: HealthDashboardHealthStore
    @State private var setHeartRate: HealthDashboardSetHeartRateStore
    @State private var preferredSetFilter: SetHeartRateFilter?

    init(workouts: [WorkoutSession], unit: WeightUnit = .lb, range: HealthDashboardRange = .all,
         healthDataProvider: (any WorkoutHealthDataProviding)? = nil) {
        self.workouts = workouts
        self.unit = unit
        self.range = range
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
        _setHeartRate = State(initialValue: HealthDashboardSetHeartRateStore(provider: provider))
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
            setHeartRateTrends
        }
        .onAppear {
            health.updateWorkouts(workouts, range: range)
            setHeartRate.updateWorkouts(workouts, range: range)
        }
        .onChange(of: workouts) { _, selection in
            health.updateWorkouts(selection, range: range)
            setHeartRate.updateWorkouts(selection, range: range)
        }
        .onChange(of: range) { _, selection in
            health.updateWorkouts(workouts, range: selection)
            setHeartRate.updateWorkouts(workouts, range: selection)
        }
        .onDisappear {
            health.cancel()
            setHeartRate.cancel()
        }
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
                    health.updateWorkouts(workouts, range: range)
                    health.load()
                } label: {
                    Label(health.hasLoaded ? "Refresh Apple Health" : "Load Apple Health", systemImage: "heart.text.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .liftGlassButton(prominent: true)
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
            if activity.excludedEnergyWorkoutCount > 0 {
                let count = activity.excludedEnergyWorkoutCount
                Label("Calories from \(count) overlapping \(count == 1 ? "workout were" : "workouts were") excluded to avoid counting the same time twice. Partial overlaps may leave some calories out.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("healthCaloriesOverlapWarning")
            }
            ForEach(health.failures) { failure in
                Label("\(failure.workoutName): \(failure.message)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("healthDashboardReadFailure-\(failure.id)")
            }
            Text("Missing readings can mean no source data, limited read access, or Apple Watch sync delays. Apple Health doesn't reveal read permission status. Calories cover available intervals; heart rate averages each workout's session average from Apple Health.")
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

    private var setFilter: SetHeartRateFilter {
        preferredSetFilter ?? (setHeartRate.hasMarkedSetsInEligibleWorkouts ? .markedOnly : .allTimestamped)
    }

    private var setHeartRateTrends: some View {
        HealthDashboardCard(title: "Exercise & Set Heart Rate", subtitle: "Optional Apple Health readings for recorded sets.",
                            systemImage: "heart.circle") {
            Text("Readings stay in memory on this device. LiftLog never saves, backs up, or shares them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if setHeartRate.eligibleWorkoutCount == 0 {
                HealthDashboardInsight(text: "Workouts with recorded set timestamps will appear here once completed.",
                                       systemImage: "clock")
            } else {
                setHeartRateLoadControl

                if setHeartRate.omittedWorkoutCount > 0 {
                    Text("Analyzes the latest \(setHeartRate.selectedWorkoutCount) timestamped workouts in this range.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let picker = Picker("Sets", selection: Binding(
                    get: { setFilter },
                    set: { preferredSetFilter = $0 }
                )) {
                    ForEach(SetHeartRateFilter.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("healthSetHeartRateFilterPicker")

                if dynamicTypeSize.isAccessibilitySize {
                    picker.pickerStyle(.menu)
                } else {
                    picker.pickerStyle(.segmented)
                }

                if setHeartRate.hasLoaded {
                    HealthDashboardSetHeartRateResults(
                        input: .init(workouts: workouts, snapshots: setHeartRate.snapshots, unit: unit, filter: setFilter),
                        hasMarkedSets: setHeartRate.hasMarkedSetsInSelectedWorkouts,
                        hasSuccessfulReads: !setHeartRate.snapshots.isEmpty
                    )
                }

                ForEach(setHeartRate.failures) { failure in
                    Label {
                        Text("\(failure.workoutName): \(failure.message)")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var setHeartRateLoadControl: some View {
        if setHeartRate.isLoading {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                ProgressView(value: Double(setHeartRate.completedCount), total: Double(setHeartRate.selectedWorkoutCount)) {
                    Text("Reading \(setHeartRate.completedCount) of \(setHeartRate.selectedWorkoutCount) workouts")
                        .font(.caption)
                }
                Button("Cancel") { setHeartRate.cancel() }
                    .liftGlassButton()
                    .accessibilityIdentifier("cancelSetHeartRateTrendsButton")
            }
        } else {
            Button {
                setHeartRate.updateWorkouts(workouts, range: range)
                setHeartRate.load()
            } label: {
                Label(setHeartRate.hasLoaded ? "Refresh Set Heart Rate" : "Load Set Heart Rate",
                      systemImage: "heart.text.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .liftGlassButton(prominent: true)
            .tint(.pink)
            .accessibilityIdentifier("loadSetHeartRateTrendsButton")
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

private struct HealthDashboardSetHeartRateResults: View {
    struct Input: Equatable, Sendable {
        let workouts: [WorkoutSession]
        let snapshots: [UUID: WorkoutHealthSnapshot]
        let unit: WeightUnit
        let filter: SetHeartRateFilter

        func trends() -> [ExerciseHeartRateTrend] {
            ExerciseHeartRateTrendAnalytics.trends(workouts: workouts, snapshots: snapshots, unit: unit, filter: filter)
        }
    }

    let input: Input
    let hasMarkedSets: Bool
    let hasSuccessfulReads: Bool

    @State private var result: (input: Input, trends: [ExerciseHeartRateTrend])?
    @State private var selectedExerciseID: UUID?
    @State private var selectedDate: Date?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let result, result.input == input {
                if let exercise = result.trends.first(where: { $0.id == selectedExerciseID }) ?? result.trends.first {
                    exerciseResults(exercise, trends: result.trends)
                    comparison(result.trends)
                } else {
                    HealthDashboardInsight(text: emptyMessage, systemImage: "heart.slash")
                }
            } else {
                ProgressView("Matching readings to sets…")
            }
        }
        .task(id: input) {
            let request = input
            let trends = await withTaskGroup(of: [ExerciseHeartRateTrend].self) { group in
                group.addTask { Task.isCancelled ? [] : request.trends() }
                return await group.next() ?? []
            }
            guard !Task.isCancelled else { return }
            selectedDate = nil
            result = (request, trends)
        }
    }

    private var emptyMessage: String {
        if input.filter == .markedOnly && !hasMarkedSets {
            return "No timestamped sets are marked for heart rate in the selected workouts. Choose All sets to see readings for other sets."
        }
        if !hasSuccessfulReads {
            return "Apple Health readings couldn't be loaded for these workouts. Try refreshing."
        }
        return "No Apple Health heart rate readings matched the selected sets."
    }

    private func exerciseResults(_ exercise: ExerciseHeartRateTrend, trends: [ExerciseHeartRateTrend]) -> some View {
        let point = selectedPoint(in: exercise)
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Exercise", selection: Binding(
                get: { exercise.id },
                set: { selectedExerciseID = $0; selectedDate = nil }
            )) {
                ForEach(trends) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("healthSetHeartRateExercisePicker")

            if let point {
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.workoutName).font(.subheadline.weight(.semibold))
                    Text(point.date, format: .dateTime.year().month(.abbreviated).day())
                    Text("Heaviest set: \(HealthDashboardFormatting.number(point.heaviestWeight)) \(point.unit.rawValue) × \(point.repsAtHeaviest) reps")
                }
                .font(.caption)
                .accessibilityElement(children: .combine)

                let metrics = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
                metrics {
                    HealthDashboardMetric(title: "Peak HR", value: reading(point.peakHeartRate), tint: .pink)
                    HealthDashboardMetric(title: "Avg HR", value: reading(point.averageHeartRate), tint: .orange)
                }
                HealthDashboardMetric(title: "Avg 60s Recovery", value: recoveryReading(point.averageRecoveryDrop60s),
                                      detail: "Change from peak to the reading around 60 seconds after a set",
                                      tint: .primary)
            }

            chart(exercise, selectedPoint: point)
            Text("Tap or drag the chart to inspect a workout.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func comparison(_ trends: [ExerciseHeartRateTrend]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Exercise Heart Rate Comparison")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(trends) { trend in
                VStack(alignment: .leading, spacing: 6) {
                    Text(trend.name).font(.subheadline.weight(.semibold))
                    Text("\(trend.sessionCount) \(trend.sessionCount == 1 ? "session" : "sessions") · \(trend.totalCorrelatedSets) \(trend.totalCorrelatedSets == 1 ? "set" : "sets") with readings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    layout {
                        comparisonMetric("Avg HR", value: reading(trend.overallAverageHeartRate))
                        comparisonMetric("Peak HR", value: reading(trend.overallPeakHeartRate))
                        comparisonMetric("Avg 60s Recovery", value: recoveryReading(trend.overallAverageRecoveryDrop60s))
                    }
                }
                .accessibilityElement(children: .combine)
                if trend.id != trends.last?.id { Divider() }
            }
        }
    }

    private func comparisonMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedPoint(in exercise: ExerciseHeartRateTrend) -> ExerciseHeartRateTrendPoint? {
        guard let selectedDate else { return exercise.points.last }
        return exercise.points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private func chart(_ exercise: ExerciseHeartRateTrend, selectedPoint: ExerciseHeartRateTrendPoint?) -> some View {
        let first = exercise.points.first?.date ?? .now
        let last = exercise.points.last?.date ?? first
        let padding = max(last.timeIntervalSince(first) * 0.04, 43_200)
        return Chart {
            ForEach(exercise.points) { point in
                if let peak = point.peakHeartRate {
                    LineMark(x: .value("Workout date", point.date), y: .value("bpm", peak))
                        .foregroundStyle(by: .value("Metric", "Peak HR"))
                        .accessibilityHidden(true)
                    PointMark(x: .value("Workout date", point.date), y: .value("bpm", peak))
                        .foregroundStyle(by: .value("Metric", "Peak HR"))
                        .symbol(.diamond)
                        .symbolSize(point.id == selectedPoint?.id ? 70 : 30)
                        .accessibilityLabel("Peak HR, \(point.date.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue(reading(peak))
                }
                if let average = point.averageHeartRate {
                    LineMark(x: .value("Workout date", point.date), y: .value("bpm", average))
                        .foregroundStyle(by: .value("Metric", "Avg HR"))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .accessibilityHidden(true)
                    PointMark(x: .value("Workout date", point.date), y: .value("bpm", average))
                        .foregroundStyle(by: .value("Metric", "Avg HR"))
                        .symbol(.circle)
                        .symbolSize(point.id == selectedPoint?.id ? 55 : 24)
                        .accessibilityLabel("Avg HR, \(point.date.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue(reading(average))
                }
            }
            if selectedDate != nil, let selectedPoint {
                RuleMark(x: .value("Selected workout", selectedPoint.date))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(["Peak HR": Color.pink, "Avg HR": Color.orange])
        .chartXScale(domain: first.addingTimeInterval(-padding)...last.addingTimeInterval(padding))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartYAxisLabel("bpm")
        .frame(height: 220)
        .accessibilityIdentifier("healthSetHeartRateTrendChart")
    }

    private func reading(_ value: Double?) -> String {
        value.map { "\(HealthDashboardFormatting.number($0)) bpm" } ?? "Unavailable"
    }

    private func recoveryReading(_ drop: Double?) -> String {
        guard let drop else { return "Unavailable" }
        let change = -drop
        let formatted = change.formatted(.number.precision(.fractionLength(0...1)).sign(strategy: .always(includingZero: false)))
        return "\(formatted) bpm"
    }
}
