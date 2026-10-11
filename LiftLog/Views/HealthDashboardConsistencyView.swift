import SwiftUI
import Charts

struct HealthDashboardConsistencyView: View {
    let analytics: HealthDashboardAnalytics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            metricLayout { overviewMetrics }

            HealthDashboardCard(title: "Your weekly rhythm", subtitle: "Completed workouts by day of the week", systemImage: "chart.bar.fill") {
                Chart(analytics.weekdayCounts) { day in
                    BarMark(x: .value("Weekday", day.label), y: .value("Workouts", day.count))
                        .cornerRadius(5)
                        .foregroundStyle(.teal.gradient)
                        .accessibilityLabel(dayName(day.weekday))
                        .accessibilityValue("\(day.count) \(day.count == 1 ? "workout" : "workouts")")
                }
                .chartYScale(domain: 0...max((analytics.weekdayCounts.map(\.count).max() ?? 0) + 1, 2))
                .chartXAxis { AxisMarks { AxisValueLabel().font(.caption2) } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        AxisValueLabel {
                            if let count = value.as(Int.self) { Text("\(count)").font(.caption2) }
                        }
                    }
                }
                .frame(height: 190)
                .accessibilityIdentifier("healthWeekdayChart")
                if let busiest = analytics.weekdayCounts.max(by: { $0.count < $1.count }), busiest.count > 0 {
                    HealthDashboardInsight(text: "\(dayName(busiest.weekday)) is your most frequent training day in this range, with \(busiest.count) \(busiest.count == 1 ? "workout" : "workouts").", systemImage: "calendar")
                }
            }

            HealthDashboardCard(title: "Every workout adds up", subtitle: "Each square is a day. More intense green means more workouts.", systemImage: "square.grid.3x3.fill") {
                HealthDashboardHeatmap(days: analytics.dailyCounts)
            }

            HealthDashboardCard(title: "Time spent training", subtitle: "Elapsed time from your recorded workout start and finish", systemImage: "timer") {
                if analytics.durations.isEmpty {
                    HealthDashboardInsight(text: "Workout durations are unavailable for this range. A recorded start and finish are needed.", systemImage: "clock.badge.questionmark")
                } else {
                    metricLayout { durationMetrics }
                    if let longest = analytics.longestDuration {
                        LabeledContent("Longest workout", value: HealthDashboardFormatting.duration(longest))
                            .font(.subheadline)
                    }
                    Text("Duration available for \(analytics.durations.count) of \(analytics.workoutCount) workouts. Includes time between sets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("healthDurationMetrics")
        }
    }

    @ViewBuilder private var overviewMetrics: some View {
        HealthDashboardMetric(title: "Workouts", value: "\(analytics.workoutCount)", detail: "Completed in this range")
            .accessibilityLabel("Workouts")
            .accessibilityValue("\(analytics.workoutCount)")
            .accessibilityIdentifier("healthWorkoutCount")
        HealthDashboardMetric(title: "Active days", value: "\(analytics.activeDayCount)", detail: "Days you showed up", tint: .teal)
    }

    @ViewBuilder private var durationMetrics: some View {
        HealthDashboardMetric(title: "Total time", value: HealthDashboardFormatting.duration(analytics.totalDuration), tint: .teal)
        if let average = analytics.averageDuration {
            HealthDashboardMetric(title: "Average workout", value: HealthDashboardFormatting.duration(average))
        }
    }

    private func dayName(_ weekday: Int) -> String {
        Calendar.current.weekdaySymbols[weekday - 1]
    }

    private var metricLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
}

private struct HealthDashboardHeatmap: View {
    let days: [HealthDashboardDay]
    private let cellSize: CGFloat = 15
    private let spacing: CGFloat = 4
    private var calendar: Calendar { .current }

    private var weeks: [[HealthDashboardDay?]] {
        guard let first = days.first else { return [] }
        let offset = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
        let padded: [HealthDashboardDay?] = Array(repeating: nil, count: offset) + days.map { Optional($0) }
        return stride(from: 0, to: padded.count, by: 7).map { start in
            let week = Array(padded[start..<min(start + 7, padded.count)])
            return week + Array(repeating: nil, count: 7 - week.count)
        }
    }

    private var weekdayLabels: [String] {
        (0..<7).map { calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        let heatmapWeeks = weeks
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: spacing) {
                    Color.clear.frame(height: 20)
                    ForEach(Array(weekdayLabels.enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(height: cellSize)
                    }
                }
                .frame(width: 28, alignment: .leading)
                .accessibilityHidden(true)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: spacing) {
                            ForEach(Array(heatmapWeeks.enumerated()), id: \.offset) { index, week in
                                VStack(spacing: spacing) {
                                    Text(monthLabel(at: index, weeks: heatmapWeeks))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(width: cellSize, height: 20, alignment: .leading)
                                        .accessibilityHidden(true)
                                    ForEach(0..<7, id: \.self) { row in
                                        if let day = week[row] {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(color(for: day.count))
                                                .frame(width: cellSize, height: cellSize)
                                                .accessibilityElement()
                                                .accessibilityLabel(day.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                                                .accessibilityValue("\(day.count) \(day.count == 1 ? "workout" : "workouts")")
                                        } else {
                                            Color.clear.frame(width: cellSize, height: cellSize).accessibilityHidden(true)
                                        }
                                    }
                                }
                            }
                            Color.clear.frame(width: 1).id("heatmapEnd").accessibilityHidden(true)
                        }
                        .padding(.trailing, 24)
                    }
                    .scrollIndicators(.visible)
                    .onAppear { proxy.scrollTo("heatmapEnd", anchor: .trailing) }
                    .onChange(of: days.first?.date) { _, _ in proxy.scrollTo("heatmapEnd", anchor: .trailing) }
                }
            }
            .accessibilityIdentifier("healthWorkoutHeatmap")
            HStack(spacing: 5) {
                Text("Less").padding(.trailing, 3)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3).fill(color(for: level))
                        .frame(width: 12, height: 12)
                }
                Text("More").padding(.leading, 3)
                Spacer(minLength: 0)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heatmap legend: gray means no workouts; more intense green means more workouts, up to four or more in a day")
            if let first = days.first, let last = days.last {
                Text("\(first.date.formatted(date: .abbreviated, time: .omitted)) – \(last.date.formatted(date: .abbreviated, time: .omitted)). Swipe to explore earlier weeks.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func monthLabel(at index: Int, weeks: [[HealthDashboardDay?]]) -> String {
        guard let date = weeks[index].compactMap({ $0 }).first?.date else { return "" }
        if index > 0, let previous = weeks[index - 1].compactMap({ $0 }).first?.date,
           calendar.isDate(date, equalTo: previous, toGranularity: .month) { return "" }
        if calendar.component(.month, from: date) == 1 {
            return date.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
        return date.formatted(.dateTime.month(.abbreviated))
    }

    private func color(for count: Int) -> Color {
        switch count {
        case 0: Color(.tertiarySystemFill)
        case 1: Color.green.opacity(0.3)
        case 2: Color.green.opacity(0.55)
        case 3: Color.green.opacity(0.8)
        default: Color.green
        }
    }
}
