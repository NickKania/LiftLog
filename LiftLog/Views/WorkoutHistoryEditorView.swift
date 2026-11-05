import SwiftUI

struct WorkoutHistoryEditorView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Keep the captured base stable when the presenting store/view refreshes.
    @State private var original: WorkoutSession?
    @State private var draft: WorkoutSession
    @State private var pickingExercise = false
    @State private var reviewing = false
    @State private var invalidSets: Set<UUID> = []

    init(workout: WorkoutSession?, unit: WeightUnit) {
        _original = State(initialValue: workout)
        let now = Date()
        _draft = State(initialValue: workout ?? WorkoutSession(name: "", startedAt: now.addingTimeInterval(-3600), finishedAt: now, unit: unit))
    }

    private var validationMessage: String? {
        do { _ = try WorkoutHistoryEditing.validated(draft, replacing: original); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            LiftList {
                Section("Workout") {
                    TextField("Name", text: $draft.name, axis: .vertical)
                        .accessibilityLabel("Workout name")
                        .lineLimit(1...3)
                        .accessibilityIdentifier("historyEditorNameField")
                    DatePicker("Started", selection: $draft.startedAt)
                        .accessibilityIdentifier("historyEditorStartDate")
                    DatePicker("Finished", selection: Binding(get: { draft.finishedAt ?? draft.startedAt }, set: { draft.finishedAt = $0 }))
                        .accessibilityIdentifier("historyEditorFinishDate")
                    if original == nil {
                        Picker("Recorded unit", selection: $draft.unit) {
                            ForEach(WeightUnit.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .accessibilityIdentifier("historyEditorUnitPicker")
                    } else {
                        LabeledContent("Recorded unit", value: draft.unit.rawValue)
                    }
                }
                Section("Workout notes") {
                    TextField("Optional notes", text: notesBinding($draft.notes), axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("historyEditorNotesField")
                }
                ForEach(draft.exercises) { exercise in
                    exerciseSection(exercise)
                }
                Section {
                    Button("Add Exercise", systemImage: "plus.circle.fill") {
                        hideKeyboard()
                        pickingExercise = true
                    }
                        .accessibilityIdentifier("addHistoryExerciseButton")
                } footer: {
                    Text("Enter only completed sets. Each row is independent. Added sets have no planned targets.")
                }
                if let validationMessage {
                    Section {
                        Text(validationMessage).foregroundStyle(.red)
                            .accessibilityIdentifier("historyEditorValidation")
                    }
                }
            }
            .accessibilityIdentifier("historyWorkoutEditor")
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(original == nil ? (dynamicTypeSize.isAccessibilitySize ? "Past" : "Past Workout") : (dynamicTypeSize.isAccessibilitySize ? "Correct" : "Correct Workout"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelHistoryEditorButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        hideKeyboard()
                        reviewing = true
                    }
                    .bold()
                    .disabled(validationMessage != nil || !invalidSets.isEmpty || draft == original)
                    .accessibilityIdentifier("reviewHistoryWorkoutButton")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
            }
            .sheet(isPresented: $pickingExercise) {
                ExercisePickerView { exercise in
                    draft.exercises.append(WorkoutExercise(exercise: exercise, sets: [WorkoutSet(isCompleted: true)]))
                }
            }
            .navigationDestination(isPresented: $reviewing) {
                WorkoutRecordView(workout: draft, title: dynamicTypeSize.isAccessibilitySize ? "Review" : "Review Workout")
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 10) {
                            Text(dynamicTypeSize.isAccessibilitySize ? (original == nil ? "Save to history." : "Undo stays available.") : (original == nil ? "Save this completed workout to history." : "Undo Last Correction will remain available after relaunch."))
                                .accessibilityLabel(original == nil ? "Save this completed workout to history." : "Undo Last Correction will remain available after relaunch.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                if store.saveHistoryWorkout(draft, replacing: original) { dismiss() }
                            } label: {
                                Text(dynamicTypeSize.isAccessibilitySize ? "Save" : (original == nil ? "Save Past Workout" : "Save Correction"))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .liftGlassButton(prominent: true)
                            .accessibilityLabel(original == nil ? "Save Past Workout" : "Save Correction")
                            .accessibilityIdentifier("saveHistoryWorkoutButton")
                        }
                        .liftActionDock()
                    }
                    .workoutErrorAlert()
            }
        }
    }

    private func exerciseSection(_ exercise: WorkoutExercise) -> some View {
        Section {
            SetColumnHeader(unit: draft.unit)
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                SetInputRow(number: index + 1, unit: draft.unit, weight: set.weight, reps: set.reps,
                    targetReps: set.targetReps, targetWeight: set.targetWeight, onChange: { weight, reps in
                        updateExercise(exercise.id) { entry in
                            guard let row = entry.sets.firstIndex(where: { $0.id == set.id }) else { return }
                            entry.sets[row].weight = weight
                            entry.sets[row].reps = reps
                        }
                    }, onValidity: { valid in
                        if valid { invalidSets.remove(set.id) } else { invalidSets.insert(set.id) }
                    })
                    .swipeActions {
                        Button("Delete Set", role: .destructive) {
                            invalidSets.remove(set.id)
                            updateExercise(exercise.id) { $0.sets.removeAll { $0.id == set.id } }
                        }
                    }
            }
            Button("Add Set", systemImage: "plus") {
                updateExercise(exercise.id) { entry in
                    let last = entry.sets.last
                    entry.sets.append(WorkoutSet(weight: last?.weight ?? 0, reps: last?.reps ?? 8, isCompleted: true))
                }
            }
            .accessibilityIdentifier("addHistorySet-\(exercise.id)")
            TextField("Exercise notes", text: Binding(
                get: { exercise.notes ?? "" },
                set: { value in updateExercise(exercise.id) { $0.notes = value } }
            ), axis: .vertical)
            .lineLimit(2...6)
            .accessibilityIdentifier("historyEditorExerciseNotes-\(exercise.id)")
        } header: {
            HStack {
                Text(exercise.exercise.name)
                Spacer()
                Button {
                    exercise.sets.forEach { invalidSets.remove($0.id) }
                    draft.exercises.removeAll { $0.id == exercise.id }
                } label: {
                    Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Remove \(exercise.exercise.name)")
                .accessibilityIdentifier("removeHistoryExercise-\(exercise.id)")
            }
        }
    }

    private func notesBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0 })
    }

    private func updateExercise(_ id: UUID, change: (inout WorkoutExercise) -> Void) {
        guard let index = draft.exercises.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.exercises[index])
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
