import SwiftUI

struct WorkoutHistoryView: View {
    @Environment(WorkoutStore.self) private var store
    @State private var importing = false

    var body: some View {
        Group {
            if store.history.isEmpty {
                ContentUnavailableView("Build your history", systemImage: "clock.arrow.circlepath", description: Text("Completed workouts will appear here. Start a workout and log your first set."))
            } else {
                List(store.history) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workout.name).font(.headline)
                            if let version = workout.templateVersionNumber {
                                Text("Template version \(version)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Label("\(workout.exercises.count) exercises", systemImage: "dumbbell")
                                Label("\(workout.exercises.reduce(0) { $0 + $1.sets.count }) sets", systemImage: "checkmark.circle")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("historyWorkout-\(workout.name)")
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Workouts", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("importWorkoutsButton")
            }
        }
        .sheet(isPresented: $importing) { WorkoutImportView() }
    }
}

struct WorkoutDetailView: View {
    let workout: WorkoutSession

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Duration", value: duration)
                LabeledContent("Completed sets", value: String(workout.exercises.reduce(0) { $0 + $1.sets.count }))
                if let version = workout.templateVersionNumber {
                    LabeledContent("Template version", value: String(version))
                        .accessibilityIdentifier("historyTemplateVersion")
                }
            }
            ForEach(workout.exercises) { exercise in
                Section(exercise.exercise.name) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        HStack {
                            Text("Set \(index + 1)").foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(set.reps)")
                                    .monospacedDigit()
                                if set.targetWeight != nil || set.targetReps != nil {
                                    Text(plannedPrescription(set))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("historySetPlan-\(index + 1)")
                                }
                            }
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func plannedPrescription(_ set: WorkoutSet) -> String {
        switch (set.targetWeight, set.targetReps) {
        case let (weight?, reps?):
            "Planned: \(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(reps)"
        case let (weight?, nil):
            "Planned weight: \(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue)"
        case let (nil, reps?):
            "Planned reps: \(reps)"
        case (nil, nil):
            ""
        }
    }

    private var duration: String {
        let interval = (workout.finishedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt)
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "Unavailable" }
        let seconds = Int(interval)
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }
}
