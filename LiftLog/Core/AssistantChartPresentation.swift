import Foundation

/// Presentation works on an immutable chart snapshot, never recalculating workout data.
struct AssistantChartPresentation {
    enum Range: Int, CaseIterable {
        case all = 0, month = 30, quarter = 90

        var label: String {
            switch self {
            case .all: return "All"
            case .month: return "30 days"
            case .quarter: return "90 days"
            }
        }
    }

    let chart: WorkoutAgentChart
    let range: Range
    let points: [WorkoutAgentChart.Point]

    init(chart: WorkoutAgentChart, range: Range = .all) {
        self.chart = chart
        self.range = range
        let sorted = chart.points.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
        }.map(\.element)
        guard range != .all, let latest = sorted.last?.date,
              let start = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: latest) else {
            points = sorted
            return
        }
        points = sorted.filter { $0.date >= start }
    }

    var axisIndices: [Int] {
        guard !points.isEmpty else { return [] }
        if points.count <= 3 { return Array(points.indices) }
        return [0, (points.count - 1) / 2, points.count - 1]
    }

    func nearestPoint(to position: Double) -> WorkoutAgentChart.Point? {
        guard position.isFinite, !points.isEmpty else { return nil }
        let clamped = min(max(position.rounded(), 0), Double(points.count - 1))
        return points[Int(clamped)]
    }

    var valueLabel: String {
        switch chart.metric {
        case .volume: return "Volume (\(chart.unit?.rawValue ?? "") × reps)"
        case .maxWeight: return "Max weight (\(chart.unit?.rawValue ?? ""))"
        case .completedSets: return "Completed sets"
        case .heartRate, .activeEnergy, .steps:
            return "\(chart.metric.label) (\(chart.valueUnitLabel))"
        }
    }

    var valueUnit: String {
        switch chart.metric {
        case .volume: return "\(chart.unit?.rawValue ?? "") × reps"
        case .maxWeight: return chart.unit?.rawValue ?? ""
        case .completedSets: return "sets"
        case .heartRate, .activeEnergy, .steps: return chart.valueUnitLabel
        }
    }

    func formattedValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
