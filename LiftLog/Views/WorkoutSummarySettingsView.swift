import SwiftUI

/// User-level preferences for workout summaries. The editor is a draft so Cancel
/// never changes the prompt or automatic-summary preference.
struct WorkoutSummarySettingsView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var promptEditorHeight = 220.0

    @State private var draftPrompt = ""
    @State private var draftAutomatic = false
    @State private var loaded = false
    @State private var validationMessage: String?

    private var promptIsValid: Bool {
        let count = draftPrompt.count
        return count <= WorkoutSummaryPrompt.maximumLength
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftPrompt)
                    .frame(height: min(promptEditorHeight, 360))
                    .accessibilityLabel("Workout summary prompt")
                    .accessibilityIdentifier("workoutSummaryPromptEditor")
                Text("\(draftPrompt.count.formatted()) of \(WorkoutSummaryPrompt.maximumLength.formatted()) characters")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(promptIsValid ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workoutSummaryPromptCharacterCount")
                if draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("A blank prompt restores the built-in default instructions.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workoutSummaryBlankPromptNotice")
                } else if !promptIsValid {
                    Text("This prompt is too long. Remove characters before saving.")
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workoutSummaryOverlengthNotice")
                }
                Button("Reset to default") {
                    draftPrompt = WorkoutSummaryPrompt.defaultPrompt
                    validationMessage = nil
                }
                .accessibilityIdentifier("workoutSummaryResetPromptButton")
            } header: {
                Text("Custom prompt")
            } footer: {
                Text("The app always adds privacy and safety instructions. Workout names and notes are treated as data, not instructions.")
            }

            Section {
                Toggle("Automatic workout insights", isOn: $draftAutomatic)
                    .accessibilityIdentifier("workoutSummaryAutomaticToggle")
                Text("When enabled, finishing a workout generates insights using the selected assistant provider, the completed workout and up to eight comparable previous sessions. Apple Intelligence processes the data on this iPhone; ChatGPT sends it to OpenAI using your eligible plan and default model. Apple Health is never included automatically. An unavailable provider never falls back to another provider.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workoutSummaryAutomaticDisclosure")
            } header: {
                Text("After finishing")
            }

            if let validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("workoutSummarySettingsValidation")
                }
            }
        }
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? "Summaries" : "Workout Summaries")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("workoutSummarySettingsCancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!loaded || !promptIsValid)
                    .accessibilityIdentifier("workoutSummarySettingsSave")
            }
        }
        .task {
            guard !loaded else { return }
            draftPrompt = store.workoutSummaryPrompt
            draftAutomatic = store.automaticWorkoutSummaries
            loaded = true
        }
    }

    private func save() {
        guard loaded else { return }
        let normalized = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= WorkoutSummaryPrompt.maximumLength else {
            validationMessage = "Keep your custom prompt to \(WorkoutSummaryPrompt.maximumLength) characters or fewer."
            return
        }
        guard store.setWorkoutSummaryPrompt(normalized) else {
            validationMessage = "The prompt could not be saved. Try a shorter prompt."
            return
        }
        _ = store.setAutomaticWorkoutSummaries(draftAutomatic)
        dismiss()
    }
}
