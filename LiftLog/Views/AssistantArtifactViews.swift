import SwiftUI

struct AssistantProposalView: View {
    let proposal: WorkoutAgentProposal
    let isWorking: Bool
    let apply: () -> Void
    let discard: () -> Void
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(proposal.beforeTemplate != nil ? "Suggested template version" : "Suggested workout change", systemImage: "pencil.and.list.clipboard").font(.headline)
            Text(proposal.summary)
            if proposal.beforeTemplate != nil {
                Text(proposal.status == .applied
                     ? "Saved as the default for future workouts. Earlier versions stay available."
                     : "This version becomes the default for future workouts. Earlier versions stay available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                let number = (template.currentVersion?.number ?? 0) + (title == "After" ? 1 : 0)
                Text("Version \(number)\(title == "After" ? (proposal.status == .applied ? " · saved default" : " · proposed default") : " · previous default")")
                    .font(.caption).foregroundStyle(.secondary)
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
                            if let weight = set.targetWeight {
                                Text("Target weight: \(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
