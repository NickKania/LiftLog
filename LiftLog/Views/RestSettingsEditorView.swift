import SwiftUI

/// Owns a transient draft; only Save publishes settings to the template or session.
struct RestSettingsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var useWorkoutDefault: Bool
    @State private var seconds: Int
    let title: String
    let workoutRestSeconds: Int?
    let footer: String
    let onSave: (Int?) -> Bool

    init(title: String, restSeconds: Int?, workoutRestSeconds: Int? = nil, footer: String, onSave: @escaping (Int?) -> Bool) {
        self.title = title
        self.workoutRestSeconds = workoutRestSeconds
        self.footer = footer
        self.onSave = onSave
        _useWorkoutDefault = State(initialValue: restSeconds == nil && workoutRestSeconds != nil)
        _seconds = State(initialValue: restSeconds ?? workoutRestSeconds ?? 120)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(title).font(.headline)
                    if let workoutRestSeconds {
                        Toggle("Use workout default", isOn: $useWorkoutDefault)
                            .accessibilityIdentifier("useWorkoutRestDefault")
                        LabeledContent("Workout default", value: RestTime.description(workoutRestSeconds))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(footer)
                }
                if !useWorkoutDefault {
                    Section {
                        RestDurationStepper(seconds: $seconds, identifier: "exerciseRestStepper")
                    } footer: {
                        Text(workoutRestSeconds == nil ? "Exercises use this default unless they have their own rest time. Adjust in 15-second steps, up to 60 minutes." : "Off disables rest for this exercise. Adjust in 15-second steps, up to 60 minutes.")
                    }
                    Section("Quick durations") {
                        ForEach([0, 30, 60, 120, 180], id: \.self) { duration in
                            Button {
                                seconds = duration
                            } label: {
                                HStack {
                                    Text(RestTime.description(duration))
                                    Spacer()
                                    if duration == seconds {
                                        Image(systemName: "checkmark").accessibilityHidden(true)
                                    }
                                }
                            }
                            .accessibilityAddTraits(duration == seconds ? .isSelected : [])
                            .accessibilityIdentifier("restPreset-\(duration)")
                        }
                    }
                }
            }
            .navigationTitle("Rest Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancelRestSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if onSave(useWorkoutDefault ? nil : seconds) { dismiss() }
                    }
                    .bold()
                    .accessibilityIdentifier("saveRestSettingsButton")
                }
            }
            .workoutErrorAlert()
        }
    }
}

/// Keep the duration and native controls together without squeezing long labels at large text sizes.
struct RestDurationStepper: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var seconds: Int
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                Text("Rest between sets")
            }
            Stepper(value: $seconds, in: 0...3600, step: 15) {
                if dynamicTypeSize.isAccessibilitySize {
                    Text(RestTime.description(seconds)).monospacedDigit()
                        .accessibilityLabel("Rest between sets, \(RestTime.description(seconds))")
                } else {
                    LabeledContent("Rest between sets", value: RestTime.description(seconds))
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }
}

enum RestTime {
    static func description(_ seconds: Int) -> String {
        seconds == 0 ? "Off" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    static func exerciseDescription(_ seconds: Int?, workoutDefault: Int) -> String {
        seconds.map(description) ?? "Workout default (\(description(workoutDefault)))"
    }
}
