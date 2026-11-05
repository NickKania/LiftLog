import SwiftUI
import Charts

struct HealthDashboardWeightView: View {
    let analytics: HealthDashboardAnalytics
    let unit: WeightUnit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedExerciseID: UUID?
    @State private var selectedDate: Date?

    private func nearestPoint(in exercise: HealthDashboardExercise?) -> HealthDashboardWeightPoint? {
        guard let exercise else { return nil }
        guard let selectedDate else { return exercise.points.last }
        return exercise.points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let exercises = analytics.exercises
        let exercise = exercises.first { $0.id == selectedExerciseID } ?? exercises.first
        let selectedPoint = nearestPoint(in: exercise)
        let records = HealthDashboardAnalytics.personalRecords(for: exercises)
        let exerciseIDs = exercises.map(\.id)
        let workoutIDs = analytics.workouts.map(\.id)

        VStack(spacing: 20) {
            if let exercise {
                HealthDashboardCard(title: "Lifting progress", subtitle: "Your heaviest completed set in each workout", systemImage: "dumbbell.fill") {
                    Picker("Exercise", selection: Binding<UUID?>(
                        get: { exercise.id },
                        set: { selectedExerciseID = $0; selectedDate = nil }
                    )) {
                        ForEach(exercises) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("healthWeightExercisePicker")

                    if let point = selectedPoint {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(HealthDashboardFormatting.number(point.weight))
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Selected lifting weight")
                                .accessibilityValue("\(HealthDashboardFormatting.number(point.weight)) \(unit.rawValue)")
                                .accessibilityIdentifier("healthWeightSelectedValue")
                            Text(unit.rawValue).font(.headline).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(point.reps) reps · \(point.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline.weight(.medium))
                            Text(selectedDate == nil ? "Latest recorded workout" : "Selected workout")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    progressionChart(exercise, selectedPoint: selectedPoint)
                    Text("Tap or drag the chart to inspect a workout. Loads are shown in \(unit.rawValue), converted from each workout’s recorded unit.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HealthDashboardInsight(text: progressInsight(exercise), systemImage: "arrow.up.right")
                }

                metricLayout { exerciseMetrics(exercise) }
            } else {
                HealthDashboardCard(title: "Lifting progress", systemImage: "dumbbell.fill") {
                    ContentUnavailableView("No recorded lifting weights", systemImage: "chart.xyaxis.line", description: Text("Complete a set with a recorded weight and reps to follow an exercise’s progress."))
                }
            }

            if !records.isEmpty {
                HealthDashboardCard(title: "Max weights by exercise", subtitle: "Heaviest completed sets within this date range", systemImage: "trophy.fill") {
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.name).font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(record.reps) reps · \(record.date.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Text("\(HealthDashboardFormatting.number(record.weight)) \(unit.rawValue)")
                                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(.blue)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .combine)
                            if index < records.count - 1 { Divider() }
                        }
                    }
                }
                .accessibilityIdentifier("healthExerciseRecords")
            }
        }
        .onChange(of: exerciseIDs) { _, ids in
            if let selectedExerciseID, !ids.contains(selectedExerciseID) {
                self.selectedExerciseID = nil
            }
            selectedDate = nil
        }
        .onChange(of: workoutIDs) { _, _ in selectedDate = nil }
    }

    private func progressionChart(_ exercise: HealthDashboardExercise,
                                  selectedPoint: HealthDashboardWeightPoint?) -> some View {
        Chart {
            ForEach(exercise.points) { point in
                if exercise.points.count > 1 {
                    LineMark(x: .value("Workout date", point.date), y: .value("Weight", point.weight))
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .accessibilityHidden(true)
                }
                PointMark(x: .value("Workout date", point.date), y: .value("Weight", point.weight))
                    .foregroundStyle(.blue)
                    .symbolSize(point.id == selectedPoint?.id ? 75 : 32)
                    .accessibilityLabel("\(exercise.name), \(point.date.formatted(date: .abbreviated, time: .shortened))")
                    .accessibilityValue("\(HealthDashboardFormatting.number(point.weight)) \(unit.rawValue), \(point.reps) reps")
            }
            if selectedDate != nil, let point = selectedPoint {
                RuleMark(x: .value("Selected workout", point.date))
                    .foregroundStyle(.blue.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: dateDomain(exercise))
        .chartYScale(domain: weightDomain(exercise))
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let weight = value.as(Double.self) {
                        Text(HealthDashboardFormatting.number(weight)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .frame(height: 220)
        .accessibilityIdentifier("healthWeightChart")
    }

    @ViewBuilder private func exerciseMetrics(_ exercise: HealthDashboardExercise) -> some View {
        HealthDashboardMetric(title: "Max in this range", value: "\(HealthDashboardFormatting.number(exercise.maximumWeight)) \(unit.rawValue)", tint: .teal)
        HealthDashboardMetric(title: "Recorded workouts", value: "\(exercise.sessionCount)", detail: exercise.name)
    }

    private func progressInsight(_ exercise: HealthDashboardExercise) -> String {
        guard exercise.sessionCount > 1 else {
            return "One recorded workout is your starting point. Add another session to compare lifting weights over time."
        }
        let change = HealthDashboardFormatting.number(abs(exercise.change))
        let direction = exercise.change > 0 ? "higher" : "lower"
        if abs(exercise.change) < 0.0001 {
            return "Your latest top set matches your first at \(HealthDashboardFormatting.number(exercise.latestWeight)) \(unit.rawValue) across \(exercise.sessionCount) workouts in this range. Compare reps alongside weight."
        }
        let percentage = exercise.changePercent.map { " (\(HealthDashboardFormatting.number(abs($0)))%)" } ?? ""
        return "Your latest top set is \(change) \(unit.rawValue)\(percentage) \(direction) than your first in this range. These are recorded loads; reps can vary between workouts."
    }

    private func dateDomain(_ exercise: HealthDashboardExercise) -> ClosedRange<Date> {
        let first = exercise.points.first?.date ?? Date()
        let last = exercise.points.last?.date ?? first
        let padding = max(last.timeIntervalSince(first) * 0.04, 43_200)
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    private func weightDomain(_ exercise: HealthDashboardExercise) -> ClosedRange<Double> {
        let lower = exercise.points.map(\.weight).min() ?? 0
        let upper = exercise.points.map(\.weight).max() ?? 0
        let padding = max((upper - lower) * 0.25, max(upper * 0.08, 1))
        return max(0, lower - padding)...(upper + padding)
    }

    private var metricLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
}
