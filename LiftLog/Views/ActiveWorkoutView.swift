import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pickingExercise = false
    @State private var confirmingFinish = false
    @State private var confirmingDiscard = false
    @State private var invalidSets: Set<UUID> = []

    var body: some View {
        Group {
            if let workout = store.activeWorkout {
                workoutContent(workout)
            } else {
                ContentUnavailableView("Workout saved", systemImage: "checkmark.circle", description: Text("Find your completed sets in History."))
            }
        }
        .workoutErrorAlert(enabled: !pickingExercise)
        .navigationTitle(store.activeWorkout?.name ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "chevron.down") { hideKeyboard(); dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Minimize workout")
                    .accessibilityIdentifier("minimizeWorkoutButton")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") { hideKeyboard(); confirmingFinish = true }
                    .bold()
                    .disabled(!canFinish)
                    .accessibilityIdentifier("finishWorkoutButton")
            }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { hideKeyboard() } }
        }
        .sheet(isPresented: $pickingExercise) {
            ExercisePickerView { exercise in
                mutate { $0.exercises.append(WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 0, reps: 10)])) }
            }
        }
        .alert("Finish workout?", isPresented: $confirmingFinish) {
            Button("Keep Training", role: .cancel) { }
            Button("Save Workout") {
                if store.finishWorkout() { dismiss() }
            }
            .accessibilityIdentifier("confirmFinishWorkoutButton")
        } message: {
            Text("Only completed sets will be saved to your history. Incomplete sets will be excluded.")
        }
        .confirmationDialog("Discard workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) {
                if store.discardWorkout() { dismiss() }
            }
        } message: { Text("This workout and all of its logged sets will be deleted.") }
    }

    private var canFinish: Bool {
        invalidSets.isEmpty && (store.activeWorkout?.exercises.contains { $0.sets.contains(where: \.isCompleted) } ?? false)
    }

    private func workoutContent(_ workout: WorkoutSession) -> some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("DURATION", systemImage: "timer").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text(workout.startedAt, style: .timer).font(.title2.monospacedDigit().bold())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("COMPLETED SETS").font(.caption2.bold()).foregroundStyle(.secondary)
                        Text("\(workout.exercises.reduce(0) { $0 + $1.sets.filter(\.isCompleted).count }) / \(workout.exercises.reduce(0) { $0 + $1.sets.count })")
                            .font(.title2.monospacedDigit().bold())
                    }
                }
                .padding(.vertical, 8)
            }
            if workout.exercises.isEmpty {
                Section {
                    ContentUnavailableView("Ready when you are", systemImage: "dumbbell", description: Text("Add your first exercise to start logging sets."))
                }
            }
            ForEach(workout.exercises) { exercise in
                Section {
                    SetColumnHeader(unit: workout.unit, completion: true)
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SetInputRow(number: index + 1, unit: workout.unit, weight: set.weight, reps: set.reps, completed: set.isCompleted, onChange: { weight, reps in
                            updateSet(exerciseID: exercise.id, setID: set.id) { $0.weight = weight; $0.reps = reps }
                        }, onCompletion: {
                            updateSet(exerciseID: exercise.id, setID: set.id) { $0.isCompleted.toggle() }
                        }, onValidity: { valid in
                            if valid { invalidSets.remove(set.id) } else { invalidSets.insert(set.id) }
                        })
                        .listRowBackground(set.isCompleted ? Color.green.opacity(0.10) : Color(.secondarySystemGroupedBackground))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                invalidSets.remove(set.id)
                                mutate { session in
                                    guard let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                                    session.exercises[index].sets.removeAll { $0.id == set.id }
                                }
                            }
                        }
                    }
                    Button("Add Set", systemImage: "plus") {
                        mutate { session in
                            guard let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                            let last = session.exercises[index].sets.last
                            session.exercises[index].sets.append(WorkoutSet(weight: last?.weight ?? 0, reps: last?.reps ?? 10))
                        }
                    }
                    .accessibilityIdentifier("addSet-\(exercise.exercise.name)")
                } header: {
                    HStack {
                        Text(exercise.exercise.name)
                        Spacer()
                        Menu {
                            Button("Remove Exercise", systemImage: "trash", role: .destructive) {
                                exercise.sets.forEach { invalidSets.remove($0.id) }
                                mutate { $0.exercises.removeAll { $0.id == exercise.id } }
                            }
                        } label: { Image(systemName: "ellipsis").padding(6) }
                        .accessibilityLabel("Options for \(exercise.exercise.name)")
                    }
                }
            }
            Section {
                Button("Add Exercise", systemImage: "plus.circle.fill") { pickingExercise = true }
                    .accessibilityIdentifier("addExerciseButton")
            } footer: {
                Text("Tap the circle beside a set after you complete it. Your progress saves as you train.")
            }
            Section {
                Button("Discard Workout", role: .destructive) { hideKeyboard(); confirmingDiscard = true }
                    .accessibilityIdentifier("discardWorkoutButton")
            }
        }
    }

    private func mutate(_ change: (inout WorkoutSession) -> Void) {
        guard var workout = store.activeWorkout else { return }
        change(&workout)
        store.updateActiveWorkout(workout)
    }

    private func updateSet(exerciseID: UUID, setID: UUID, change: (inout WorkoutSet) -> Void) {
        mutate { session in
            guard let exerciseIndex = session.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let setIndex = session.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { return }
            change(&session.exercises[exerciseIndex].sets[setIndex])
        }
    }
}
