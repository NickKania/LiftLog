import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(RestTimerAlerts.self) private var restAlerts
    @Environment(\.dismiss) private var dismiss
    @State private var reorderWorkout: WorkoutSession?
    @State private var pickingExercise = false
    @State private var supersetEditor: SupersetEditorContext?
    @State private var swapContext: WorkoutExerciseSwapContext?
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
        .workoutErrorAlert(enabled: !pickingExercise && supersetEditor == nil && swapContext == nil && reorderWorkout == nil)
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
        .sheet(item: $reorderWorkout) { workout in
            WorkoutExerciseOrderView(workout: workout)
        }
        .sheet(isPresented: $pickingExercise) {
            ExercisePickerView { exercise in
                mutate { $0.exercises.append(WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 0, reps: 10)])) }
            }
        }
        .sheet(item: $supersetEditor) { context in
            SupersetEditorView(context: context) { selectedIDs in
                mutate { session in
                    SupersetGrouping.update(&session.exercises, anchorID: context.id, selectedIDs: selectedIDs)
                }
            }
        }
        .sheet(item: $swapContext) { context in
            ExerciseSwapView(originalExercise: context.entry.exercise, scope: .workout) { replacement in
                guard store.replaceActiveExercise(in: context.sessionID, expectedEntry: context.entry, with: replacement.id) else { return false }
                context.entry.sets.forEach { invalidSets.remove($0.id) }
                return true
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
                if let version = workout.templateVersionNumber {
                    Label("Template version \(version)", systemImage: "square.stack")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("activeWorkoutTemplateVersion")
                }
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
            if workout.restTimer == nil {
                Section {
                    LabeledContent("Rest between sets", value: workout.restSeconds == 0 ? "Off" : "\(workout.restSeconds / 60):\(String(format: "%02d", workout.restSeconds % 60))")
                        .foregroundStyle(.secondary)
                } footer: {
                    if restAlerts.backgroundSoundUnavailable && workout.restSeconds > 0 {
                        restNotificationHint
                    }
                }
            }
            if workout.exercises.isEmpty {
                Section {
                    ContentUnavailableView("Ready when you are", systemImage: "dumbbell", description: Text("Add your first exercise to start logging sets."))
                }
            }
            if workout.exercises.count > 1 {
                Section {
                    Button("Reorder Exercises", systemImage: "arrow.up.arrow.down") {
                        hideKeyboard()
                        reorderWorkout = workout
                    }
                    .accessibilityIdentifier("reorderExercisesButton")
                }
            }
            ForEach(workout.exercises) { exercise in
                let group = SupersetStyle.group(for: exercise, in: workout.exercises)
                Section {
                    SetColumnHeader(unit: workout.unit, completion: true)
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SetInputRow(number: index + 1, unit: workout.unit, weight: set.weight, reps: set.reps, targetReps: set.targetReps, targetWeight: set.targetWeight, completed: set.isCompleted, onChange: { weight, reps in
                            mutate { session in
                                guard let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                                session.exercises[index].updateSetValues(weight: weight, reps: reps)
                            }
                        }, onCompletion: {
                            updateSet(exerciseID: exercise.id, setID: set.id) { $0.isCompleted.toggle() }
                        }, onValidity: { valid in
                            if valid { invalidSets.remove(set.id) } else { invalidSets.insert(set.id) }
                        })
                        .listRowBackground(SupersetRowBackground(group: group, completed: set.isCompleted))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                invalidSets.remove(set.id)
                                mutate { session in
                                    guard let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                                    session.exercises[index].sets.removeAll { $0.id == set.id }
                                }
                            }
                        }
                        if let timer = workout.restTimer, timer.completedSetID == set.id {
                            inlineRestTimer(timer, duration: workout.restSeconds)
                                .listRowSeparator(.hidden)
                        }
                    }
                    Button("Add Set", systemImage: "plus") {
                        mutate { session in
                            guard let index = session.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                            let last = session.exercises[index].sets.last
                            session.exercises[index].sets.append(WorkoutSet(weight: last?.weight ?? 0, reps: last?.reps ?? 10, targetReps: last?.targetReps, targetWeight: last?.targetWeight))
                        }
                    }
                    .accessibilityIdentifier("addSet-\(exercise.exercise.name)")
                } header: {
                    HStack {
                        SupersetExerciseHeading(name: exercise.exercise.name, entryID: exercise.id, group: group)
                        Spacer()
                        Menu {
                            Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath") {
                                hideKeyboard()
                                swapContext = WorkoutExerciseSwapContext(sessionID: workout.id, entry: exercise)
                            }
                            .disabled(exercise.sets.contains(where: \.isCompleted))
                            .accessibilityHint(exercise.sets.contains(where: \.isCompleted) ? "Completed sets must be kept. Only exercises with no completed sets can be replaced." : "Review a replacement for this workout only")
                            .accessibilityIdentifier("replaceExerciseButton")
                            Button(exercise.supersetID == nil ? "Add to Superset" : "Edit Superset", systemImage: "link") {
                                hideKeyboard()
                                supersetEditor = SupersetEditorContext(anchorID: exercise.id, exercises: workout.exercises, name: { $0.exercise.name })
                            }
                            .accessibilityIdentifier(exercise.supersetID == nil ? "addSupersetButton" : "editSupersetButton")
                            Divider()
                            Button("Remove Exercise", systemImage: "trash", role: .destructive) {
                                exercise.sets.forEach { invalidSets.remove($0.id) }
                                mutate { session in
                                    session.exercises.removeAll { $0.id == exercise.id }
                                    SupersetGrouping.normalize(&session.exercises)
                                }
                            }
                        } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Options for \(exercise.exercise.name)")
                        .accessibilityIdentifier("workoutExerciseMenu-\(exercise.id)")
                    }
                }
                .listRowBackground(SupersetRowBackground(group: group))
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
        .accessibilityIdentifier("activeWorkoutEditor")
    }

    private var restNotificationHint: some View {
        Text("Rest tones play while the app is open. Enable notification sounds in Settings for alerts when the app is in the background.")
    }

    private func inlineRestTimer(_ timer: WorkoutRestTimer, duration: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = timer.remainingSeconds(at: context.date)
            let fraction = min(1, max(0, timer.endsAt.timeIntervalSince(context.date) / Double(max(1, duration))))
            let title = seconds > 0 ? "\(seconds / 60):\(String(format: "%02d", seconds % 60))" : "Rest complete"

            VStack(spacing: 8) {
                Text(title)
                    .font(.headline.monospacedDigit())
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Color.orange.opacity(0.15)
                                Color.orange.frame(width: geometry.size.width * fraction)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .overlay {
                        // Keep the centered time legible on both the orange fill and the empty track.
                        Text(title)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.black)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .mask {
                                GeometryReader { geometry in
                                    Rectangle().frame(width: geometry.size.width * fraction)
                                }
                            }
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(title)
                    .accessibilityIdentifier("restCountdown")
                    .accessibilityHint(seconds > 0 ? "Time remaining before your next set" : "Ready for your next set")

                HStack(alignment: .firstTextBaseline) {
                    Label(seconds > 0 ? "Rest" : "Ready for your next set", systemImage: seconds > 0 ? "timer" : "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(seconds > 0 ? "Skip" : "Dismiss") { store.skipRest() }
                        .font(.subheadline)
                        .accessibilityIdentifier("skipRestButton")
                }

                if restAlerts.backgroundSoundUnavailable {
                    restNotificationHint
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
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

private struct WorkoutExerciseSwapContext: Identifiable {
    let sessionID: UUID
    let entry: WorkoutExercise
    var id: UUID { entry.id }
}

/// Keeps ordering as a draft; cancelling never writes to the workout or its template.
private struct WorkoutExerciseOrderView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let workout: WorkoutSession
    @State private var exercises: [WorkoutExercise]

    init(workout: WorkoutSession) {
        self.workout = workout
        _exercises = State(initialValue: workout.exercises)
    }

    private var linkedExerciseIDs: Set<UUID> {
        store.templateLinkedExerciseIDs(in: workout)
    }

    private var templateOrderMessage: String {
        if linkedExerciseIDs.count < 2 {
            return "This order saves to this workout only. Fewer than two exercises are linked to the current template, so its order will stay the same."
        }
        if linkedExerciseIDs.count < exercises.count {
            return "Only exercises marked Template linked can update your template’s order. Exercises marked Workout only stay local. Logged sets and template targets stay the same."
        }
        return "Saving also updates your template’s exercise order for future workouts. Logged sets and template targets stay the same."
    }

    private func setSummary(_ exercise: WorkoutExercise) -> String {
        guard !exercise.sets.isEmpty else { return "No sets" }
        let hasTargets = exercise.sets.allSatisfy { $0.targetWeight != nil && $0.targetReps != nil }
        let values = exercise.sets.map { set in
            let weight = hasTargets ? (set.targetWeight ?? set.weight) : set.weight
            let reps = hasTargets ? (set.targetReps ?? set.reps) : set.reps
            return "\(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(reps.formatted()) reps"
        }
        let description = Set(values).count == 1 ? (values.first ?? "") : values.joined(separator: "; ")
        return "\(hasTargets ? "Targets" : "Current sets"): \(description)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(exercises) { exercise in
                        let number = (workout.exercises.firstIndex { $0.id == exercise.id } ?? 0) + 1
                        let group = SupersetStyle.group(for: exercise, in: workout.exercises)
                        let linked = linkedExerciseIDs.contains(exercise.id)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(exercise.exercise.name).font(.body.weight(.semibold))
                            Text("Entry \(number) · \(exercise.sets.count) \(exercise.sets.count == 1 ? "set" : "sets")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(setSummary(exercise)).font(.subheadline).foregroundStyle(.secondary)
                            if let group {
                                Label(group.label, systemImage: "link")
                                    .font(.caption.weight(.semibold)).foregroundStyle(group.color)
                            } else {
                                Text("No superset").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(linked ? "Template linked" : "Workout only")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(exercise.exercise.name), entry \(number)")
                        .accessibilityValue("\(exercise.sets.count) sets. \(setSummary(exercise)). \(group?.label ?? "No superset"). \(linked ? "Template linked" : "Workout only")")
                        .accessibilityIdentifier("reorderExercise-\(exercise.id)")
                    }
                    .onMove { offsets, destination in
                        exercises.move(fromOffsets: offsets, toOffset: destination)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Drag handles to reorder. Entry numbers stay with their original exercises.")
                        Text(templateOrderMessage)
                            .accessibilityIdentifier("exerciseOrderTemplateMessage")
                        Text("Superset labels show which exercises belong together. Moving an individual exercise keeps its superset membership.")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Reorder" : "Reorder Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelExerciseOrderButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.reorderActiveWorkout(id: workout.id, exerciseIDs: exercises.map(\.id), expectedExerciseIDs: workout.exercises.map(\.id)) {
                            dismiss()
                        }
                    }
                    .disabled(exercises.map(\.id) == workout.exercises.map(\.id))
                    .accessibilityIdentifier("saveExerciseOrderButton")
                }
            }
            .workoutErrorAlert()
        }
    }
}
