import SwiftUI

/// Entry IDs distinguish repeated instances of the same catalog exercise.
struct SupersetEditorEntry: SupersetExercise {
    let id: UUID
    let name: String
    var supersetID: UUID?
}

struct SupersetEditorContext: Identifiable {
    let id: UUID
    let exercises: [SupersetEditorEntry]
    let scope: String

    init<T: SupersetExercise>(anchorID: UUID, exercises: [T], scope: String = "workout", name: (T) -> String) {
        id = anchorID
        self.scope = scope
        self.exercises = exercises.map {
            SupersetEditorEntry(id: $0.id, name: name($0), supersetID: $0.supersetID)
        }
    }
}

struct SupersetStyle {
    let index: Int

    var label: String {
        let letter = index < 26 ? String(UnicodeScalar(65 + index)!) : String(index + 1)
        return "Superset \(letter)"
    }

    var color: Color {
        Color(hue: (0.58 + Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.8)
    }

    static func group<T: SupersetExercise>(for exercise: T, in exercises: [T]) -> SupersetStyle? {
        guard let groupID = exercise.supersetID else { return nil }
        var groups: [UUID] = []
        for item in exercises {
            if let id = item.supersetID, !groups.contains(id) { groups.append(id) }
        }
        guard let index = groups.firstIndex(of: groupID) else { return nil }
        return SupersetStyle(index: index)
    }
}

struct SupersetExerciseHeading: View {
    let name: String
    let entryID: UUID
    let group: SupersetStyle?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.headline).textCase(nil)
            if let group {
                HStack(spacing: 4) {
                    Image(systemName: "link").accessibilityHidden(true)
                    Text(group.label)
                        .accessibilityIdentifier("supersetLabel-\(entryID)")
                }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(group.color)
                    .textCase(nil)
            }
        }
    }
}

struct SupersetRowBackground: View {
    let group: SupersetStyle?
    var completed = false

    var body: some View {
        ZStack(alignment: .leading) {
            LiftTheme.surface
            if completed { Color.green.opacity(0.10) }
            if let group {
                group.color.opacity(0.05)
                Rectangle().fill(group.color).frame(width: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

struct SupersetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let context: SupersetEditorContext
    let onSave: (Set<UUID>) -> Void
    @State private var selectedIDs: Set<UUID>

    init(context: SupersetEditorContext, onSave: @escaping (Set<UUID>) -> Void) {
        self.context = context
        self.onSave = onSave
        let groupID = context.exercises.first { $0.id == context.id }?.supersetID
        var selected: Set<UUID> = [context.id]
        if let groupID {
            selected.formUnion(context.exercises.filter { $0.supersetID == groupID }.map(\.id))
        }
        _selectedIDs = State(initialValue: selected)
    }

    private var editing: Bool {
        context.exercises.first { $0.id == context.id }?.supersetID != nil
    }

    var body: some View {
        NavigationStack {
            LiftList {
                Section {
                    ForEach(Array(context.exercises.enumerated()), id: \.element.id) { index, exercise in
                        Button {
                            guard exercise.id != context.id else { return }
                            if selectedIDs.contains(exercise.id) { selectedIDs.remove(exercise.id) }
                            else { selectedIDs.insert(exercise.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(exercise.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selectedIDs.contains(exercise.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exercise.name).foregroundStyle(.primary)
                                    if exercise.id == context.id {
                                        Text("Starting exercise").font(.caption).foregroundStyle(.secondary)
                                    } else if let group = SupersetStyle.group(for: exercise, in: context.exercises) {
                                        Text(group.label).font(.caption).foregroundStyle(group.color)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(exercise.name), exercise \(index + 1)")
                        .accessibilityValue(exercise.id == context.id ? "Selected, required" : (selectedIDs.contains(exercise.id) ? "Selected" : "Not selected"))
                        .accessibilityHint(exercise.id == context.id ? "The starting exercise stays selected" : "Toggle membership in this superset")
                        .accessibilityIdentifier("supersetExercise-\(exercise.id)")
                    }
                } header: {
                    Text("Exercises in this \(context.scope)")
                } footer: {
                    Text("Select at least two exercises to perform together. Selected exercises move into this superset.\(editing ? " Keep only the starting exercise selected to remove the group." : "")")
                }
                if editing {
                    Section {
                        Button("Remove Superset", systemImage: "link.badge.minus", role: .destructive) {
                            onSave([context.id])
                            dismiss()
                        }
                        .accessibilityIdentifier("removeSupersetButton")
                    } footer: {
                        Text("Exercises and sets stay in your \(context.scope).")
                    }
                }
            }
            .navigationTitle(editing ? "Edit Superset" : "Add to Superset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("cancelSupersetButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(selectedIDs)
                        dismiss()
                    }
                    .bold()
                    .disabled(!editing && selectedIDs.count < 2)
                    .accessibilityIdentifier("saveSupersetButton")
                }
            }
            .accessibilityIdentifier("supersetEditorSheet")
        }
    }
}
