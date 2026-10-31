import SwiftUI

struct ExercisePickerView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ExerciseDiscoveryQuery()
    @State private var index = ExerciseDiscoveryIndex.catalog
    @State private var showingFilters = false
    @State private var showingDetail = false
    @State private var detailExercise: Exercise?
    let onSelect: (Exercise) -> Void

    private var canCreateExercise: Bool {
        let name = Exercise.normalizedName(query.searchText)
        return !name.isEmpty && !store.exercises.contains { Exercise.normalizedName($0.name) == name }
    }

    var body: some View {
        let matches = query.searchMatches(in: index)
        let sections = query.results(searchMatches: matches, in: index, favoriteExerciseIDs: store.favoriteExerciseIDs, history: store.history)
        let reasons = Dictionary(uniqueKeysWithValues: matches.compactMap { match in
            match.displayReason.map { (match.exercise.id, $0) }
        })
        let hasPossibleMatches = matches.first?.kind == .approximate
        NavigationStack {
            LiftList {
                if #unavailable(iOS 17.1) {
                    Section { filterButton }
                }
                if query.hasMetadataFilters {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(filterSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("exerciseActiveFilters")
                            Button("Clear filters") { query.clearMetadataFilters() }
                                .accessibilityIdentifier("clearExerciseFiltersButton")
                        }
                    }
                }
                if sections.isEmpty {
                    if canCreateExercise { customExerciseSection }
                    Section {
                        ContentUnavailableView {
                            Label("No matching exercises", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try a different search or clear your filters.")
                        } actions: {
                            Button("Clear search and filters") {
                                query.searchText = ""
                                query.clearFilters()
                            }
                            .accessibilityIdentifier("clearExerciseSearchAndFiltersButton")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                if hasPossibleMatches {
                    Section {
                        Text("No direct matches. These exercises have similar spelling.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("exercisePossibleMatchesNotice")
                    } header: {
                        Text("Possible Matches")
                            .accessibilityIdentifier("exerciseSection-possibleMatches")
                    }
                }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.exercises) { exercise in
                            exerciseRow(exercise, reason: reasons[exercise.id])
                        }
                    } header: {
                        Text(section.title)
                            .accessibilityIdentifier("exerciseSection-\(section.kind.rawValue)")
                    }
                }
                if !sections.isEmpty && canCreateExercise { customExerciseSection }
            }
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query.searchText, prompt: "Find or create an exercise")
            .modifier(ExerciseSearchToolbarBehavior())
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("exercisePickerCancelButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if #available(iOS 17.1, *) {
                        filterButton
                    }
                }
            }
            .navigationDestination(isPresented: $showingDetail) {
                if let exercise = detailExercise {
                    ExerciseDetailView(exercise: exercise) { select(exercise) }
                }
            }
            .sheet(isPresented: $showingFilters) {
                ExerciseFilterView(query: $query, index: index)
            }
        }
        .workoutErrorAlert()
        .onAppear { index = ExerciseDiscoveryIndex(exercises: store.exercises) }
        .onChange(of: store.exercises) { _, exercises in
            index = ExerciseDiscoveryIndex(exercises: exercises)
        }
    }

    private var filterButton: some View {
        Button {
            hideKeyboard()
            showingFilters = true
        } label: {
            Label("Filters", systemImage: query.hasMetadataFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(query.hasMetadataFilters ? "Exercise filters, active" : "Exercise filters")
        .accessibilityIdentifier("exerciseFilterButton")
    }

    private var filterSummary: String {
        var parts: [String] = []
        if query.equipment != .all { parts.append("Equipment: \(query.equipment.label)") }
        if query.muscle != .all { parts.append("Muscle: \(query.muscle.label)") }
        if query.type != .all { parts.append("Type: \(query.type.label)") }
        return parts.joined(separator: " · ")
    }

    private var customExerciseSection: some View {
        Section {
            Button {
                select(Exercise(name: query.searchText.trimmingCharacters(in: .whitespacesAndNewlines), category: "Custom"))
            } label: {
                Label("Add “\(query.searchText)”", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("addCustomExerciseButton")
        } footer: {
            Text("Custom exercises are saved when you save the template or workout.")
        }
    }

    private func exerciseRow(_ exercise: Exercise, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    select(exercise)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exercise.name).foregroundStyle(.primary)
                        Text(exercise.category).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(exercise.name)")
                .accessibilityIdentifier("exercise-\(exercise.name)")

                Button {
                    hideKeyboard()
                    detailExercise = exercise
                    showingDetail = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details for \(exercise.name)")
                .accessibilityHint("View exercise metadata and favorite options without adding it")
                .accessibilityIdentifier("exerciseInfo-\(exercise.name)")
            }
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("exerciseSearchReason-\(exercise.id.uuidString)")
            }
        }
    }

    private func select(_ exercise: Exercise) {
        onSelect(exercise)
        dismiss()
    }
}

private struct ExerciseSearchToolbarBehavior: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.1, *) {
            content.searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            content
        }
    }
}

private struct ExerciseFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var query: ExerciseDiscoveryQuery
    let index: ExerciseDiscoveryIndex

    var body: some View {
        NavigationStack {
            LiftForm {
                Section {
                    filterPicker("Equipment", selection: $query.equipment, options: index.equipmentOptions)
                        .accessibilityIdentifier("exerciseEquipmentFilter")
                    filterPicker("Muscle", selection: $query.muscle, options: index.muscleOptions)
                        .accessibilityIdentifier("exerciseMuscleFilter")
                    filterPicker("Type", selection: $query.type, options: index.typeOptions)
                        .accessibilityIdentifier("exerciseTypeFilter")
                } footer: {
                    Text("Filters work together. Muscle includes primary and secondary muscles. Unknown includes exercises without that source metadata.")
                }
                Section {
                    Button("Clear filters") { query.clearMetadataFilters() }
                        .disabled(!query.hasMetadataFilters)
                        .accessibilityIdentifier("clearExerciseFiltersButton")
                }
            }
            .navigationTitle("Exercise Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("exerciseFiltersDoneButton")
                }
            }
        }
    }

    private func filterPicker(_ title: String, selection: Binding<ExerciseDiscoveryFilter>, options: [ExerciseDiscoveryFilter]) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.navigationLink)
    }
}
