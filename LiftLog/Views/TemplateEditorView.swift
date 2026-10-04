import SwiftUI

struct TemplateEditorView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkoutTemplate
    @State private var pickingExercise = false
    @State private var invalidSets: Set<UUID> = []
    private let isNew: Bool

    init(template: WorkoutTemplate?) {
        isNew = template == nil
        _draft = State(initialValue: template ?? WorkoutTemplate(name: "", exercises: []))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Template name") {
                    TextField("e.g. Upper Body", text: $draft.name)
                        .accessibilityIdentifier("templateNameField")
                }
                ForEach(Array(draft.exercises.enumerated()), id: \.element.id) { exerciseIndex, exercise in
                    Section {
                        SetColumnHeader(unit: store.unit)
                        ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { setIndex, set in
                            SetInputRow(number: setIndex + 1, unit: store.unit, weight: set.weight, reps: set.reps, onChange: { weight, reps in
                                draft.exercises[exerciseIndex].sets[setIndex].weight = weight
                                draft.exercises[exerciseIndex].sets[setIndex].reps = reps
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
                            draft.exercises[exerciseIndex].sets.append(TemplateSet(weight: last?.weight ?? 0, reps: last?.reps ?? 10))
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
                    Text("Use templates to plan exercises and sets. Each workout gets its own copy so you can adjust as you train.")
                }
            }
            .workoutErrorAlert(enabled: !pickingExercise)
            .navigationTitle(isNew ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.saveTemplate(draft) { dismiss() }
                    }
                    .bold()
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.exercises.isEmpty || draft.exercises.contains { $0.sets.isEmpty } || !invalidSets.isEmpty)
                    .accessibilityIdentifier("saveTemplateButton")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePickerView { exercise in
                    draft.exercises.append(TemplateExercise(exercise: exercise, sets: [TemplateSet(weight: 0, reps: 10)]))
                }
            }
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
