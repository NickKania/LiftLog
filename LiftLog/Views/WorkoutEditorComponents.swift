import SwiftUI

struct ExercisePickerView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let onSelect: (Exercise) -> Void

    private var matches: [Exercise] {
        store.exercises.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { exercise in
                    Button {
                        onSelect(exercise)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(exercise.name).foregroundStyle(.primary)
                            Text(exercise.category).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("exercise-\(exercise.name)")
                }
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button {
                            onSelect(Exercise(name: search.trimmingCharacters(in: .whitespacesAndNewlines), category: "Custom"))
                            dismiss()
                        } label: { Label("Add “\(search)”", systemImage: "plus.circle") }
                        .accessibilityIdentifier("addCustomExerciseButton")
                    }
                }
            }
            .searchable(text: $search, prompt: "Find or create an exercise")
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Text stays local while a number is incomplete, so typing a decimal never resets the field.
struct SetInputRow: View {
    let number: Int
    let unit: WeightUnit
    let weight: Double
    let reps: Int
    var completed: Bool? = nil
    let onChange: (Double, Int) -> Void
    var onCompletion: (() -> Void)? = nil
    var onValidity: ((Bool) -> Void)? = nil
    @State private var weightText = ""
    @State private var repsText = ""
    @State private var initialized = false

    private var parsedWeight: Double? {
        guard !weightText.isEmpty,
              let value = Double(weightText.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value >= 0 else { return nil }
        return value
    }
    private var parsedReps: Int? {
        guard let value = Int(repsText), value > 0 else { return nil }
        return value
    }
    private var valid: Bool { parsedWeight != nil && parsedReps != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text("\(number)").font(.subheadline.bold()).foregroundStyle(.secondary).frame(width: 26)
                TextField("0", text: $weightText)
                    .keyboardType(.decimalPad)
                    .accessibilityLabel("Weight for set \(number), \(unit.rawValue)")
                    .accessibilityIdentifier("setWeight-\(number)")
                    .frame(maxWidth: .infinity)
                TextField("Reps", text: $repsText)
                    .keyboardType(.numberPad)
                    .accessibilityLabel("Repetitions for set \(number)")
                    .accessibilityIdentifier("setReps-\(number)")
                    .frame(maxWidth: .infinity)
                if let completed {
                    Button {
                        if completed || valid { onCompletion?() }
                    } label: {
                        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(completed ? Color.green : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!completed && !valid)
                    .accessibilityLabel(completed ? "Mark set \(number) incomplete" : "Complete set \(number)")
                    .accessibilityIdentifier("completeSet-\(number)")
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 3)
            if initialized && !valid {
                Text("Enter a weight of 0 or more and at least 1 rep.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear {
            guard !initialized else { return }
            weightText = weight == weight.rounded() && weight < 1e15 ? String(format: "%.0f", weight) : String(weight)
            repsText = String(reps)
            initialized = true
            onValidity?(valid)
        }
        .onChange(of: weightText) { _, _ in commit() }
        .onChange(of: repsText) { _, _ in commit() }
    }

    private func commit() {
        guard initialized else { return }
        onValidity?(valid)
        if let parsedWeight, let parsedReps, parsedWeight != weight || parsedReps != reps {
            onChange(parsedWeight, parsedReps)
        }
    }
}

struct SetColumnHeader: View {
    let unit: WeightUnit
    var completion = false
    var body: some View {
        HStack(spacing: 12) {
            Text("SET").frame(width: 26)
            Text(unit.rawValue.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
            Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
            if completion { Image(systemName: "checkmark").frame(width: 44) }
        }
        .font(.caption2.bold()).foregroundStyle(.secondary)
    }
}

private struct WorkoutErrorAlert: ViewModifier {
    @Environment(WorkoutStore.self) private var store
    let enabled: Bool

    func body(content: Content) -> some View {
        content.alert("Unable to save", isPresented: Binding(
            get: { enabled && store.errorMessage != nil },
            set: { if !$0 && enabled { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Please try again.") }
    }
}

extension View {
    func workoutErrorAlert(enabled: Bool = true) -> some View {
        modifier(WorkoutErrorAlert(enabled: enabled))
    }
}
