import SwiftUI
import Charts
import UIKit

struct AssistantChartView: View {
    let chart: WorkoutAgentChart
    @State private var shareImage: UIImage?

    private var valueLabel: String {
        switch chart.metric {
        case .volume: return "Volume (\(chart.unit?.rawValue ?? "") × reps)"
        case .maxWeight: return "Max weight (\(chart.unit?.rawValue ?? ""))"
        case .completedSets: return "Completed sets"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            plot
            if let shareImage {
                let image = Image(uiImage: shareImage)
                ShareLink(item: image, preview: SharePreview(chart.title, image: image)) {
                    Label("Share chart", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("assistantShareChartButton")
            }
        }.assistantCard()
            .task(id: chart.id) {
                let renderer = ImageRenderer(content: plot.padding(24).frame(width: 600).background(.white).environment(\.colorScheme, .light))
                renderer.scale = 2
                shareImage = renderer.uiImage
            }
    }

    private var plot: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chart.title).font(.headline)
            if chart.points.isEmpty {
                ContentUnavailableView("No recorded sets", systemImage: "chart.xyaxis.line", description: Text("Complete and save a workout to chart this metric."))
            } else {
                Text(valueLabel).font(.caption).foregroundStyle(.secondary)
                Chart(chart.points) { point in
                    LineMark(x: .value("Date", point.date), y: .value(valueLabel, point.value))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("Date", point.date), y: .value(valueLabel, point.value))
                        .foregroundStyle(.blue)
                        .accessibilityLabel("\(point.workoutName), \(point.date.formatted(date: .abbreviated, time: .omitted))")
                        .accessibilityValue(point.value.formatted(.number.precision(.fractionLength(0...2))))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                VStack(spacing: 2) {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                    if includesTimeOnAxis { Text(date, format: .dateTime.hour().minute()) }
                                }.font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 220)
                .accessibilityIdentifier("assistantWorkoutChart")
                Text("Source: completed sets in \(chart.points.count) recorded workouts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var includesTimeOnAxis: Bool {
        guard let first = chart.points.first, let last = chart.points.last else { return false }
        return last.date.timeIntervalSince(first.date) < 3 * 24 * 3600
    }
}

struct AssistantProposalView: View {
    let proposal: WorkoutAgentProposal
    let isWorking: Bool
    let apply: () -> Void
    let discard: () -> Void
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Suggested workout change", systemImage: "pencil.and.list.clipboard").font(.headline)
            Text(proposal.summary)
            DisclosureGroup("Before and after", isExpanded: $showDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    snapshot(title: "Before", template: proposal.beforeTemplate, workout: proposal.beforeWorkout)
                    snapshot(title: "After", template: proposal.afterTemplate, workout: proposal.afterWorkout)
                }.padding(.top, 10)
            }
            switch proposal.status {
            case .pending:
                Text("Review the changes above. Your workout data changes only when you tap Apply.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Apply", action: apply).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("assistantApplyProposalButton")
                    Button("Discard", action: discard).buttonStyle(.bordered)
                        .accessibilityIdentifier("assistantDiscardProposalButton")
                }.controlSize(.large).disabled(isWorking)
            case .applied: Label("Applied", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .rejected: Label("Discarded", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .stale:
                Label("Your workout changed since this suggestion. Ask for a new proposal.", systemImage: "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.assistantCard()
    }

    private func snapshot(title: String, template: WorkoutTemplate?, workout: WorkoutSession?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if let template {
                Text(template.name).font(.subheadline.bold())
                ForEach(template.exercises) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.exercise.name).font(.subheadline.weight(.medium))
                        ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                            Text("Set \(index + 1): \(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(proposal.unit.rawValue) × \(set.targetReps) target reps")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let workout {
                Text(workout.name).font(.subheadline.bold())
                ForEach(workout.exercises) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.exercise.name).font(.subheadline.weight(.medium))
                        ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                            Text("Set \(index + 1): \(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(set.reps) reps\(set.isCompleted ? " · completed" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                            if let target = set.targetReps { Text("Target: \(target) reps").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if workout.exercises.isEmpty { Text("No exercises").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("No existing workout or template").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
