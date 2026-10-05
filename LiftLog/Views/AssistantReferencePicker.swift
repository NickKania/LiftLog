import SwiftUI

struct AssistantReferencePicker: View {
    let references: [AssistantWorkoutReference]
    let isDisabled: Bool
    let onSelect: ([AssistantWorkoutReference]) -> Void
    let onCancel: () -> Void
    @State private var selectedReferences: [AssistantWorkoutReference]
    @State private var query = ""

    private let selectionLimit = 10

    init(
        references: [AssistantWorkoutReference],
        selectedReferences: [AssistantWorkoutReference],
        isDisabled: Bool,
        onSelect: @escaping ([AssistantWorkoutReference]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.references = references
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selectedReferences = State(initialValue: selectedReferences)
    }

    private var matchingReferences: [AssistantWorkoutReference] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return references }
        return references.filter { reference in
            var searchableText = "\(reference.name) \(reference.subtitle)"
            if let date = reference.startedAt {
                searchableText += " \(date.formatted(.dateTime.year().month(.wide).day()))"
                searchableText += " \(date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
            }
            return searchableText.localizedStandardContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search names or dates", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("assistantReferenceSearch")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.accessibilityLabel("Clear search")
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.vertical, 10)

                List {
                    Section {
                        Text("\(selectedReferences.count) of \(selectionLimit) selected")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("assistantReferenceSelectionCount")
                        if selectedReferences.count == selectionLimit {
                            Text("Remove a tag to choose another workout or template.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if references.isEmpty {
                        ContentUnavailableView("No workouts or templates", systemImage: "dumbbell", description: Text("Create a template or log a workout to tag it here."))
                            .accessibilityIdentifier("assistantReferenceEmptyState")
                    } else if matchingReferences.isEmpty {
                        ContentUnavailableView("No matching workouts", systemImage: "magnifyingglass", description: Text("Try another name or date."))
                            .accessibilityIdentifier("assistantReferenceNoResults")
                    } else {
                        referenceSection("Templates", kind: .template)
                        referenceSection("Workouts", kind: .workout)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tag workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("assistantReferencePickerCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onSelect(selectedReferences) }
                        .disabled(isDisabled)
                        .accessibilityIdentifier("assistantReferencePickerDoneButton")
                }
            }
        }
        .accessibilityIdentifier("assistantReferencePicker")
    }

    @ViewBuilder
    private func referenceSection(_ title: String, kind: AssistantWorkoutReference.Kind) -> some View {
        let items = matchingReferences.filter { $0.kind == kind }
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.key) { reference in
                    let isSelected = selectedReferences.contains { $0.key == reference.key }
                    Button {
                        if isSelected {
                            selectedReferences.removeAll { $0.key == reference.key }
                        } else if selectedReferences.count < selectionLimit {
                            selectedReferences.append(reference)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            AssistantReferenceLabel(reference: reference)
                            Spacer(minLength: 8)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled || (!isSelected && selectedReferences.count >= selectionLimit))
                    .accessibilityLabel("\(reference.name), \(reference.subtitle)")
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                    .accessibilityIdentifier("assistantReferenceRow.\(reference.key)")
                }
            }
        }
    }
}

struct AssistantReferenceLabel: View {
    let reference: AssistantWorkoutReference

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: reference.kind == .template ? "square.stack" : "dumbbell")
                .foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: reference.name).font(.subheadline.weight(.medium))
                Text(verbatim: reference.subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
