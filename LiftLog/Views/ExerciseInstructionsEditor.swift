import SwiftUI

struct ExerciseInstructionsEditor: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var steps: [DraftStep]
    @State private var showingResetConfirmation = false
    @State private var resetDraft = false
    @State private var validationMessage: String?
    let exercise: Exercise
    private let defaultInstructions: [String]
    private let hadPersonalInstructions: Bool

    init(exercise: Exercise, instructions: [String], hasPersonalInstructions: Bool) {
        self.exercise = exercise
        defaultInstructions = ExerciseCatalog.detail(for: exercise.id)?.instructions ?? []
        hadPersonalInstructions = hasPersonalInstructions
        _steps = State(initialValue: (instructions.isEmpty ? [""] : instructions).map { DraftStep(text: $0) })
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section {
                    Text(exercise.name)
                        .font(.headline)
                        .id("exerciseInstructionsEditorTop")
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(validationMessage)
                            .accessibilityIdentifier("exerciseInstructionsValidation")
                    }
                    if !defaultInstructions.isEmpty {
                        Text(hadPersonalInstructions && !resetDraft
                             ? "Personal steps may include imported source guidance, which has not been individually reviewed or professionally validated."
                             : "Imported source guidance. These steps have not been individually reviewed or professionally validated.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("exerciseInstructionsEditorReviewNotice")
                    }
                    if steps.isEmpty {
                        Text("No steps in this draft.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(index + 1)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Describe this step", text: textBinding(for: step.id), axis: .vertical)
                                .lineLimit(3...12)
                                .accessibilityLabel("Step \(index + 1)")
                                .accessibilityIdentifier("exerciseInstructionField-\(index + 1)")
                            HStack(spacing: 16) {
                                Button {
                                    move(step.id, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .disabled(index == 0)
                                .accessibilityLabel("Move step \(index + 1) up")
                                .accessibilityIdentifier("moveExerciseInstructionUp-\(index + 1)")
                                Button {
                                    move(step.id, by: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .disabled(index == steps.count - 1)
                                .accessibilityLabel("Move step \(index + 1) down")
                                .accessibilityIdentifier("moveExerciseInstructionDown-\(index + 1)")
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    steps.removeAll { $0.id == step.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .accessibilityLabel("Remove step \(index + 1)")
                                .accessibilityIdentifier("deleteExerciseInstruction-\(index + 1)")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Add Step", systemImage: "plus.circle") {
                        steps.append(DraftStep(text: ""))
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("addExerciseInstructionButton")
                } header: {
                    Text("Personal instructions")
                } footer: {
                    Text(defaultInstructions.isEmpty
                         ? "Your changes apply to this exercise locally throughout the app. Save to keep your changes, or Cancel to discard them."
                         : "Your changes apply to this exercise locally throughout the app. The original default steps are preserved. Save to keep your changes, or Cancel to discard them.")
                }

                if hadPersonalInstructions || !defaultInstructions.isEmpty {
                    Section {
                        Button(defaultInstructions.isEmpty ? "Remove Personal Steps" : "Reset to Default Steps", systemImage: defaultInstructions.isEmpty ? "trash" : "arrow.counterclockwise", role: .destructive) {
                            hideKeyboard()
                            showingResetConfirmation = true
                        }
                        .accessibilityIdentifier(defaultInstructions.isEmpty ? "removePersonalExerciseInstructionsButton" : "resetExerciseInstructionsButton")
                    } footer: {
                        Text(defaultInstructions.isEmpty
                             ? "No default steps are available. Remove Personal Steps clears this draft. Save to remove your saved steps, or Cancel to keep them."
                             : "Reset replaces this draft with the original defaults. Save to apply the reset.")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Steps")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelExerciseInstructionsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        if validationMessage != nil {
                            scrollProxy.scrollTo("exerciseInstructionsEditorTop", anchor: .top)
                        }
                    }
                    .bold()
                    .accessibilityIdentifier("saveExerciseInstructionsButton")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                }
            }
            .confirmationDialog(defaultInstructions.isEmpty ? "Remove personal steps from this draft?" : "Reset this draft to the default steps?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button(defaultInstructions.isEmpty ? "Remove from Draft" : "Reset Draft", role: .destructive) {
                    steps = defaultInstructions.map { DraftStep(text: $0) }
                    resetDraft = true
                    validationMessage = nil
                }
                .accessibilityIdentifier(defaultInstructions.isEmpty ? "removePersonalExerciseInstructionsConfirmButton" : "resetExerciseInstructionsConfirmButton")
                Button("Cancel", role: .cancel) {}
                    .accessibilityIdentifier("cancelExerciseInstructionsResetButton")
            } message: {
                Text(defaultInstructions.isEmpty
                     ? "There are no default steps to restore. Save will remove your personal steps for this exercise throughout the app. Canceling the editor keeps your saved steps."
                     : "Your saved personal steps stay unchanged until you tap Save.")
            }
            .accessibilityIdentifier("exerciseInstructionsEditor")
            .onChange(of: steps.map(\.text)) { _, _ in validationMessage = nil }
        }
    }

    private func textBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { steps.first { $0.id == id }?.text ?? "" },
            set: { text in
                guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
                steps[index].text = text
            }
        )
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard steps.indices.contains(destination) else { return }
        steps.swapAt(index, destination)
    }

    private func save() {
        hideKeyboard()
        let instructions = steps.map(\.text)
        let saved: Bool
        if resetDraft && instructions == defaultInstructions {
            saved = store.resetExerciseInstructions(for: exercise.id)
        } else {
            do {
                try WorkoutStore.validateInstructionSteps(instructions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            } catch {
                validationMessage = error.localizedDescription
                return
            }
            saved = store.setExerciseInstructions(instructions, for: exercise.id)
        }
        if saved { dismiss() }
    }

    private struct DraftStep: Identifiable {
        let id = UUID()
        var text: String
    }
}
