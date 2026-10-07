import SwiftUI
import Charts

/// The same plot is used for interaction and image export.
struct AssistantChartPlot: View {
    enum Style: String { case line, bars }
    let presentation: AssistantChartPresentation
    let style: Style
    let selectedID: UUID?

    private var isHealthChart: Bool { presentation.chart.metric.isHealthMetric }
    private var xLabel: String { isHealthChart ? "Health interval time" : "Workout" }

    private func xPosition(_ index: Int, point: WorkoutAgentChart.Point) -> Double {
        isHealthChart ? point.date.timeIntervalSinceReferenceDate : Double(index)
    }

    private var xDomain: ClosedRange<Double> {
        guard isHealthChart, let first = presentation.points.first, let last = presentation.points.last else {
            return -0.5...(Double(max(presentation.points.count - 1, 0)) + 0.5)
        }
        let start = first.date.timeIntervalSinceReferenceDate
        let end = last.date.timeIntervalSinceReferenceDate
        let padding = max((end - start) * 0.04, 1)
        return (start - padding)...(end + padding)
    }

    private var barHalfWidth: Double {
        guard isHealthChart else { return 0.28 }
        let dates = presentation.points.map { $0.date.timeIntervalSinceReferenceDate }
        let gaps = zip(dates, dates.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        return max((gaps.min() ?? 10) * 0.28, 0.1)
    }

    var body: some View {
        let points = presentation.points
        Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                if style == .line {
                    AreaMark(x: .value(xLabel, xPosition(index, point: point)), yStart: .value("Baseline", 0), yEnd: .value(presentation.valueLabel, point.value))
                        .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.16), .blue.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        .accessibilityHidden(true)
                    LineMark(x: .value(xLabel, xPosition(index, point: point)), y: .value(presentation.valueLabel, point.value))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    PointMark(x: .value(xLabel, xPosition(index, point: point)), y: .value(presentation.valueLabel, point.value))
                        .symbolSize(point.id == selectedID ? 90 : 40)
                        .foregroundStyle(.blue)
                        .accessibilityLabel("\(point.workoutName), \(point.date.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue("\(presentation.formattedValue(point.value)) \(presentation.valueUnit)")
                } else {
                    RectangleMark(xStart: .value(xLabel, xPosition(index, point: point) - barHalfWidth),
                            xEnd: .value(xLabel, xPosition(index, point: point) + barHalfWidth),
                            yStart: .value("Baseline", 0.0),
                            yEnd: .value(presentation.valueLabel, point.value))
                        .cornerRadius(4)
                        .foregroundStyle(.blue.opacity(selectedID == nil || point.id == selectedID ? 1 : 0.35))
                        .accessibilityLabel("\(point.workoutName), \(point.date.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityValue("\(presentation.formattedValue(point.value)) \(presentation.valueUnit)")
                }
                if point.id == selectedID {
                    RuleMark(x: .value(xLabel, xPosition(index, point: point)))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .foregroundStyle(.blue.opacity(0.3))
                        .accessibilityHidden(true)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...max((points.map(\.value).max() ?? 0) * 1.15, 1))
        .chartXAxis {
            AxisMarks(values: presentation.axisIndices.map { xPosition($0, point: points[$0]) }) { value in
                AxisValueLabel {
                    if let position = value.as(Double.self) {
                        let date = isHealthChart ? Date(timeIntervalSinceReferenceDate: position) : points[Int(position)].date
                        VStack(spacing: 3) {
                            if isHealthChart, sameDay || points.count == 1 {
                                Text(date, format: .dateTime.hour().minute())
                            } else {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                            }
                            if isHealthChart, !sameDay, points.count > 1 {
                                Text(date, format: .dateTime.hour().minute())
                            } else if !isHealthChart, sameDay {
                                Text(date, format: .dateTime.hour().minute())
                            } else if spansYears {
                                Text(date, format: .dateTime.year())
                            }
                        }.font(.caption2).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(number, format: .number.notation(.compactName).precision(.fractionLength(0...1)))
                            .font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .frame(height: 210)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier("assistantWorkoutChart")
    }

    private var sameDay: Bool {
        guard let first = presentation.points.first, let last = presentation.points.last,
              presentation.points.count > 1 else { return false }
        return Calendar.current.isDate(first.date, inSameDayAs: last.date)
    }

    private var spansYears: Bool {
        guard let first = presentation.points.first, let last = presentation.points.last else { return false }
        return Calendar.current.component(.year, from: first.date) != Calendar.current.component(.year, from: last.date)
    }
}
