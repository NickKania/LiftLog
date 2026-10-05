import SwiftUI

struct TemplateEditorView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkoutTemplate
    @State private var pickingExercise = false
    @State private var invalidSets: Set<UUID> = []
    @State private var draftUnit: WeightUnit?
    private let isNew: Bool
    private let planningNextWorkout: Bool
    private let original: WorkoutTemplate?

    init(template: WorkoutTemplate?, planningNextWorkout: Bool = false, unit: WeightUnit? = nil) {
        isNew = template == nil
        self.planningNextWorkout = planningNextWorkout
        original = template
        _draftUnit = State(initialValue: unit)
        _draft = State(initialValue: template ?? WorkoutTemplate(name: "", exercises: []))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Template name") {
                    TextField("e.g. Upper Body", text: $draft.name)
                        .accessibilityIdentifier("templateNameField")
                }
                if let original {
                    Section {
                        LabeledContent("Based on", value: "Version \(original.currentVersion?.number ?? 1)")
                        Text("Save your changes as a new version for your next workout.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let lastWorkout {
                        Section("Last completed workout") {
                            DisclosureGroup {
                                ForEach(lastWorkout.exercises) { exercise in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(exercise.exercise.name).font(.subheadline.bold())
                                        Text(exercise.sets.map { set in
                                            "\(comparisonWeight(set.weight, from: lastWorkout.unit)) \(unit.rawValue) × \(set.reps)"
                                        }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lastWorkout.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    Text("\(lastWorkout.exercises.reduce(0) { $0 + $1.sets.count }) completed sets · View actual results")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("lastTemplateWorkoutComparison")
                        }
                    }
                }
                ForEach(Array(draft.exercises.enumerated()), id: \.element.id) { exerciseIndex, exercise in
                    Section {
                        SetColumnHeader(unit: unit, repsTitle: "TARGET REPS")
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                            SetInputRow(number: setIndex + 1, unit: unit, weight: set.weight, reps: set.targetReps, repsTitle: "Target reps", onChange: { weight, reps in
                                draft.exercises[exerciseIndex].updateSetValues(weight: weight, targetReps: reps)
                            }, onValidity: { valid in
                                if valid { invalidSets.remove(set.id) } else { invalidSets.insert(set.id) }
                            })
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    invalidSets.remove(set.id)
                                    draft.exercises[exerciseIndex].sets.removeAll { $0.id == set.id }
                                }
                            }
                        }
                        Button("Add Set", systemImage: "plus") {
                            let last = draft.exercises[exerciseIndex].sets.last
                            draft.exercises[exerciseIndex].sets.append(TemplateSet(weight: last?.weight ?? 0, targetReps: last?.targetReps ?? 10))
                        }
                    } header: {
                        HStack {
                            Text(exercise.exercise.name)
                            Spacer()
                            Button {
                                exercise.sets.forEach { invalidSets.remove($0.id) }
                                draft.exercises.removeAll { $0.id == exercise.id }
                            } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove \(exercise.exercise.name)")
                        }
                    }
                }
                Section {
                    Button("Add Exercise", systemImage: "plus.circle.fill") { pickingExercise = true }
                        .accessibilityIdentifier("addExerciseButton")
                } footer: {
                    Text("Plan exercises, weights, and target reps. Record actual weights and reps when you train.")
                }
                if original != nil {
                    Section {
                        if changes.isEmpty {
                            Text("Adjust a weight, rep target, or exercise to create your next version.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                                Text(change).font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Changes for version \((original?.currentVersion?.number ?? 1) + 1)")
                    } footer: {
                        Text("This becomes the default for future workouts. Previous versions remain available in Version History.")
                    }
                    .accessibilityIdentifier("templateVersionChangeSummary")
                }
            }
            .workoutErrorAlert(enabled: !pickingExercise)
            .navigationTitle(isNew ? "New Template" : (planningNextWorkout ? "Plan Next Workout" : "Edit Template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Save" : "Save Version") {
                        hideKeyboard()
                        if store.saveTemplate(draft, expectedUnit: unit) { dismiss() }
                    }
                    .bold()
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.exercises.isEmpty || draft.exercises.contains { $0.sets.isEmpty } || !invalidSets.isEmpty || (!isNew && changes.isEmpty))
                    .accessibilityIdentifier("saveTemplateButton")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePickerView { exercise in
                    draft.exercises.append(TemplateExercise(exercise: exercise, sets: [TemplateSet(weight: 0, targetReps: 10)]))
                }
            }
        }
        .onAppear { if draftUnit == nil { draftUnit = store.unit } }
    }

    private var unit: WeightUnit { draftUnit ?? store.unit }

    private var lastWorkout: WorkoutSession? {
        store.history.filter { $0.templateID == original?.id }.max { $0.startedAt < $1.startedAt }
    }

    private func comparisonWeight(_ weight: Double, from recordedUnit: WeightUnit) -> String {
        let converted = recordedUnit == unit ? weight : weight * (unit == .kg ? 0.45359237 : 1 / 0.45359237)
        return converted.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var changes: [String] {
        guard let original else { return [] }
        var result: [String] = []
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name != original.name { result.append("Name: \(original.name) → \(name)") }
        for item in original.exercises where !draft.exercises.contains(where: { $0.id == item.id }) {
            result.append("Remove \(item.exercise.name)")
        }
        for item in draft.exercises {
            guard let previous = original.exercises.first(where: { $0.id == item.id }) else {
                result.append("Add \(item.exercise.name): \(item.sets.count) sets")
                continue
            }
            for (index, set) in item.sets.enumerated() {
                guard let oldSet = previous.sets.first(where: { $0.id == set.id }) else {
                    result.append("\(item.exercise.name), set \(index + 1): add \(prescription(set))")
                    continue
                }
                if set.weight != oldSet.weight || set.targetReps != oldSet.targetReps {
                    result.append("\(item.exercise.name), set \(index + 1): \(prescription(oldSet)) → \(prescription(set))")
                }
            }
            for (index, set) in previous.sets.enumerated() where !item.sets.contains(where: { $0.id == set.id }) {
                result.append("\(item.exercise.name): remove set \(index + 1)")
            }
        }
        return result
    }

    private func prescription(_ set: TemplateSet) -> String {
        "\(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue) × \(set.targetReps)"
    }
}

struct TemplateVersionHistoryView: View {
    @Environment(WorkoutStore.self) private var store
    let templateID: UUID
    @Binding var showWorkout: Bool

    private var template: WorkoutTemplate? { store.templates.first { $0.id == templateID } }

    var body: some View {
        List {
            if let template {
                Section {
                    ForEach(template.versions.reversed()) { version in
                        NavigationLink {
                            TemplateVersionDetailView(templateID: templateID, version: version, showWorkout: $showWorkout)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Version \(version.number)").font(.headline)
                                    if version.id == template.currentVersion?.id {
                                        Text("Default").font(.caption.bold()).foregroundStyle(.blue)
                                    }
                                }
                                Text(version.name)
                                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(version.exercises.count) exercises · \(version.exercises.reduce(0) { $0 + $1.sets.count }) sets · \(version.unit.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .accessibilityIdentifier("templateVersion-\(version.number)")
                    }
                } footer: {
                    Text("The newest version is your default. You can start a workout from any saved version.")
                }
            } else {
                ContentUnavailableView("Template unavailable", systemImage: "square.stack")
            }
        }
        .navigationTitle("Version History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TemplateVersionDetailView: View {
    @Environment(WorkoutStore.self) private var store
    let templateID: UUID
    let version: WorkoutTemplateVersion
    @Binding var showWorkout: Bool

    var body: some View {
        List {
            Section {
                LabeledContent("Template", value: version.name)
                LabeledContent("Version", value: String(version.number))
                LabeledContent("Saved", value: version.createdAt.formatted(date: .abbreviated, time: .shortened))
                Button("Start This Version", systemImage: "play.fill") {
                    guard let template = store.templates.first(where: { $0.id == templateID }) else { return }
                    if store.startWorkout(template: template, versionID: version.id) { showWorkout = true }
                }
                .disabled(store.activeWorkout != nil)
                .accessibilityIdentifier("startTemplateVersion-\(version.number)")
            } footer: {
                Text("Starting this version keeps the newest version as your default.")
            }
            ForEach(version.exercises) { exercise in
                Section(exercise.exercise.name) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        LabeledContent("Set \(index + 1)", value: "\(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(version.unit.rawValue) × \(set.targetReps)")
                            .monospacedDigit()
                    }
                }
            }
        }
        .workoutErrorAlert(enabled: !showWorkout)
        .navigationTitle("Version \(version.number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
