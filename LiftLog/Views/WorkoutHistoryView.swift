import SwiftUI

struct WorkoutHistoryView: View {
    @Environment(WorkoutStore.self) private var store
    @State private var importing = false
    @State private var deletingWorkout: WorkoutSession?
    @State private var renamingWorkoutID: UUID?
    @State private var editedName = ""
    @State private var query = WorkoutHistoryQuery()

    private var templateOptions: [WorkoutHistoryTemplateOption] {
        WorkoutHistoryTemplateOption.options(in: store.history)
    }

    var body: some View {
        let workouts = query.results(in: store.history)
        Group {
            if store.history.isEmpty {
                ContentUnavailableView("Build your history", systemImage: "clock.arrow.circlepath", description: Text("Completed workouts will appear here. Start a workout and log your first set."))
            } else {
                List {
                    Section {
                        if workouts.isEmpty {
                            ContentUnavailableView {
                                Label("No matching workouts", systemImage: "line.3.horizontal.decrease.circle")
                            } description: {
                                Text("Try another search, date range, or template.")
                            } actions: {
                                Button("Clear filters") { query.clearFilters() }
                                    .accessibilityIdentifier("clearHistoryFiltersButton")
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(workouts) { workout in
                            workoutRow(workout)
                        }
                    } header: {
                        Text("\(workouts.count) of \(store.history.count) workouts")
                            .font(.caption)
                            .fontWeight(.regular)
                            .textCase(nil)
                            .accessibilityIdentifier("historyResultCount")
                    }
                }
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Workout or exercise")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("Date range", systemImage: "calendar") {
                        Picker("Date range", selection: $query.dateRange) {
                            ForEach(WorkoutHistoryDateRange.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    Menu("Template", systemImage: "square.stack") {
                        Picker("Template", selection: $query.template) {
                            Text("All templates").tag(WorkoutHistoryTemplateFilter.all)
                            Text("Other workouts").tag(WorkoutHistoryTemplateFilter.other)
                            ForEach(templateOptions) { option in
                                Text(option.name).tag(WorkoutHistoryTemplateFilter.template(option.id))
                            }
                        }
                    }
                    if query.hasFilters {
                        Divider()
                        Button("Clear filters") { query.clearFilters() }
                    }
                } label: {
                    Label("Filter", systemImage: query.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Filter history")
                .accessibilityIdentifier("historyFilterMenu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort workouts", selection: $query.sort) {
                        ForEach(WorkoutHistorySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort history, \(query.sort.label)")
                .accessibilityIdentifier("historySortMenu")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import Workouts", systemImage: "square.and.arrow.down") { importing = true }
                    .accessibilityIdentifier("importWorkoutsButton")
            }
        }
        .sheet(isPresented: $importing) { WorkoutImportView() }
        .onChange(of: store.history) { _, history in
            if case .template(let id) = query.template, !history.contains(where: { $0.templateID == id }) {
                query.template = .all
            }
        }
        .alert("Rename workout", isPresented: Binding(
            get: { renamingWorkoutID != nil },
            set: { if !$0 { renamingWorkoutID = nil } }
        )) {
            TextField("Workout name", text: $editedName)
                .accessibilityIdentifier("historyWorkoutNameField")
            Button("Save") {
                if let id = renamingWorkoutID { store.renameWorkout(id: id, name: editedName) }
                renamingWorkoutID = nil
            }
            .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("saveHistoryWorkoutNameButton")
            Button("Cancel", role: .cancel) { renamingWorkoutID = nil }
        }
        .alert("Delete workout?", isPresented: Binding(
            get: { deletingWorkout != nil },
            set: { if !$0 { deletingWorkout = nil } }
        )) {
            Button("Delete Workout", role: .destructive) {
                if let workout = deletingWorkout { store.deleteWorkout(id: workout.id) }
                deletingWorkout = nil
            }
            .accessibilityIdentifier("confirmDeleteHistoryWorkoutButton")
            Button("Cancel", role: .cancel) { deletingWorkout = nil }
        } message: {
            if let workout = deletingWorkout {
                Text("Delete \(workout.name) from \(workout.startedAt.formatted(date: .abbreviated, time: .shortened))? This cannot be undone.")
            }
        }
        .workoutErrorAlert(enabled: !importing && deletingWorkout == nil && renamingWorkoutID == nil)
    }

    private func workoutRow(_ workout: WorkoutSession) -> some View {
        NavigationLink {
            WorkoutDetailView(workout: workout)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(workout.name)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let version = workout.templateVersionNumber {
                        Text("v\(version)")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .fixedSize()
                            .accessibilityLabel("Template version \(version)")
                    }
                }
                Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label("\(workout.exercises.count) exercises", systemImage: "dumbbell")
                    Label("\(workout.exercises.reduce(0) { $0 + $1.sets.count }) sets", systemImage: "checkmark.circle")
                    Label(duration(for: workout), systemImage: "clock")
                }
                .labelStyle(HistoryStatLabelStyle())
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .accessibilityIdentifier("historyWorkout-\(workout.name)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deletingWorkout = workout
            }
            .tint(.red)
            .accessibilityIdentifier("deleteHistoryWorkout-\(workout.id)")
            Button("Rename", systemImage: "pencil") {
                editedName = workout.name
                renamingWorkoutID = workout.id
            }
            .tint(.blue)
            .accessibilityIdentifier("renameHistoryWorkout-\(workout.id)")
        }
    }

    private func duration(for workout: WorkoutSession) -> String {
        guard let finish = workout.finishedAt else { return "Unavailable" }
        return HealthDashboardFormatting.duration(finish.timeIntervalSince(workout.startedAt))
    }
}

private struct HistoryStatLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

struct WorkoutDetailView: View {
    let workout: WorkoutSession

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Duration", value: duration)
                LabeledContent("Completed sets", value: String(workout.exercises.reduce(0) { $0 + $1.sets.count }))
                if let version = workout.templateVersionNumber {
                    LabeledContent("Template version", value: String(version))
                        .accessibilityIdentifier("historyTemplateVersion")
                }
            }
            ForEach(workout.exercises) { exercise in
                Section(exercise.exercise.name) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        HStack {
                            Text("Set \(index + 1)").foregroundStyle(.secondary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(set.weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(set.reps)")
                                    .monospacedDigit()
                                if set.targetWeight != nil || set.targetReps != nil {
                                    Text(plannedPrescription(set))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("historySetPlan-\(index + 1)")
                                }
                            }
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func plannedPrescription(_ set: WorkoutSet) -> String {
        switch (set.targetWeight, set.targetReps) {
        case let (weight?, reps?):
            "Planned: \(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue) × \(reps)"
        case let (weight?, nil):
            "Planned weight: \(weight.formatted(.number.precision(.fractionLength(0...2)))) \(workout.unit.rawValue)"
        case let (nil, reps?):
            "Planned reps: \(reps)"
        case (nil, nil):
            ""
        }
    }

    private var duration: String {
        let interval = (workout.finishedAt ?? workout.startedAt).timeIntervalSince(workout.startedAt)
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "Unavailable" }
        let seconds = Int(interval)
        return seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min \(seconds % 60) sec"
    }
}
