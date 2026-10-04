import SwiftUI
import UniformTypeIdentifiers

/// File selection and review stay local until the user confirms the import.
struct WorkoutImportView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var initialized = false
    @State private var sourceUnit: WeightUnit = .lb
    @State private var timeZoneID = TimeZone.current.identifier
    @State private var csv: String?
    @State private var fileName = ""
    @State private var choosingFile = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: WorkoutImportPreview?
    @State private var selectedIDs: Set<String> = []
    @State private var overrides: [String: Exercise] = [:]
    @State private var matchingSource: String?
    @State private var confirming = false
    @State private var result: WorkoutImportResult?

    private var duplicateIDs: Set<String> {
        Set(store.history.compactMap(\.importSourceKey))
    }
    private var availableIDs: Set<String> {
        Set(preview?.workouts.map(\.id) ?? []).subtracting(duplicateIDs)
    }
    private var selectedSessions: [WorkoutSession] {
        preview?.sessions(selectedIDs: selectedIDs, exerciseOverrides: overrides) ?? []
    }

    private var selectedSetCount: Int {
        selectedSessions.reduce(0) { $0 + $1.exercises.reduce(0) { $0 + $1.sets.count } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result { success(result) }
                else if let preview { review(preview) }
                else { setup }
            }
            .navigationTitle(result != nil ? "Import Complete" : preview == nil ? "Import Workouts" : "Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                        .accessibilityIdentifier("closeWorkoutImportButton")
                }
                if preview != nil && result == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Back") { preview = nil; overrides = [:]; selectedIDs = [] }
                            .disabled(busy)
                            .accessibilityIdentifier("importBackButton")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if result == nil {
                    VStack(spacing: 8) {
                        Button {
                            if preview == nil { preparePreview() } else { confirming = true }
                        } label: {
                            if busy { ProgressView().frame(maxWidth: .infinity) }
                            else {
                                Text(preview == nil ? "Review Workouts" : "Import \(selectedIDs.count) \(selectedIDs.count == 1 ? "Workout" : "Workouts")")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(busy || (preview == nil ? csv == nil : selectedIDs.isEmpty))
                        .accessibilityIdentifier("reviewOrImportButton")
                        Text(preview == nil ? "Confirm the export’s units and time zone before continuing." : "Your history updates only after you confirm.")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding().background(.bar)
                }
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: false) { selection in
                switch selection {
                case .success(let urls): if let url = urls.first { readFile(url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .sheet(isPresented: Binding(get: { matchingSource != nil }, set: { if !$0 { matchingSource = nil } })) {
                if let source = matchingSource {
                    ImportExerciseMatchView(sourceName: source, current: overrides[source] ?? preview?.exerciseMappings.first(where: { $0.sourceName == source })?.matchedExercise) { exercise in
                        overrides[source] = exercise
                        matchingSource = nil
                    }
                }
            }
            .alert("Import selected workouts?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) { }
                Button("Import") { commitImport() }
                    .accessibilityIdentifier("confirmWorkoutImportButton")
            } message: {
                Text("Add \(selectedIDs.count) completed \(selectedIDs.count == 1 ? "workout" : "workouts") with \(selectedSetCount) \(selectedSetCount == 1 ? "set" : "sets") to your history. Existing imports will be skipped.")
            }
            .alert("Unable to import", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "Please try again.") }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                sourceUnit = store.unit
                loadUITestFixtureIfNeeded()
            }
        }
    }

    private var setup: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Bring your training history", systemImage: "square.and.arrow.down")
                        .font(.title3.bold())
                    Text("Import completed workouts from a Strong CSV export. Review exercises, sets, and dates before saving.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                Button { choosingFile = true } label: {
                    Label(csv == nil ? "Choose Strong CSV" : "Choose a Different File", systemImage: "doc.badge.plus")
                }
                .disabled(busy)
                .accessibilityIdentifier("chooseWorkoutCSVButton")
                if csv != nil {
                    Label(fileName, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("selectedImportFile")
                }
            } header: { Text("1 · Choose export") }
            Section {
                Picker("Export weight unit", selection: $sourceUnit) {
                    Text("Pounds (lb)").tag(WeightUnit.lb)
                    Text("Kilograms (kg)").tag(WeightUnit.kg)
                }
                .accessibilityIdentifier("importWeightUnitPicker")
                NavigationLink {
                    ImportTimeZonePicker(selection: $timeZoneID)
                } label: {
                    LabeledContent("Export time zone", value: timeZoneID.replacingOccurrences(of: "_", with: " "))
                }
                .accessibilityIdentifier("importTimeZonePicker")
            } header: { Text("2 · Confirm export settings") }
            footer: {
                Text("Strong’s CSV does not specify a weight unit or time zone. Defaults use your LiftLog unit (\(store.unit.rawValue)) and device time zone. Choose the settings used when these workouts were recorded. Imported weights keep the selected unit.")
            }
        }
        .disabled(busy)
    }

    private func review(_ preview: WorkoutImportPreview) -> some View {
        List {
            Section {
                LabeledContent("File", value: fileName)
                LabeledContent("Weights", value: sourceUnit.rawValue)
                LabeledContent("Time zone", value: timeZoneID.replacingOccurrences(of: "_", with: " "))
                LabeledContent("Ready to import", value: "\(availableIDs.count) workouts")
                if preview.skippedRestRows > 0 {
                    Text("\(preview.skippedRestRows) rest timer rows excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Import summary") }
            if !preview.warnings.isEmpty {
                Section {
                    DisclosureGroup("\(preview.warnings.count) items need attention") {
                        ForEach(preview.warnings) { warning in
                            Text("Record \(warning.row): \(warning.message)")
                                .font(.subheadline)
                        }
                    }
                    .accessibilityIdentifier("importWarnings")
                } footer: { Text("Review skipped or unsupported data before importing. Only supported weight and rep sets will be saved.") }
            }
            Section {
                ForEach(preview.exerciseMappings) { mapping in
                    Button { matchingSource = mapping.sourceName } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mapping.sourceName).foregroundStyle(.primary)
                            if let exercise = overrides[mapping.sourceName] ?? mapping.matchedExercise {
                                Label(exercise.category == "Custom" ? "Custom: \(exercise.name)" : exercise.name, systemImage: exercise.category == "Custom" ? "person.crop.square" : "checkmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Label("Keep original as custom exercise", systemImage: "person.crop.square")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("importMapping-\(mapping.sourceName)")
                }
            } header: { Text("Exercise matching") }
            footer: { Text("Exact catalog matches are selected automatically. Tap any exercise to change its match or keep its original name as a custom exercise.") }
            Section {
                HStack {
                    Button("Select All") { selectedIDs = availableIDs }
                        .accessibilityIdentifier("selectAllImportWorkoutsButton")
                    Spacer()
                    Button("Clear") { selectedIDs = [] }
                        .accessibilityIdentifier("clearImportWorkoutsButton")
                }
                .buttonStyle(.borderless)
                ForEach(preview.workouts) { candidate in
                    candidateRow(candidate)
                }
            } header: { Text("Choose workouts · \(selectedIDs.count) selected") }
            if preview.workouts.isEmpty {
                ContentUnavailableView("No workouts to import", systemImage: "doc.text.magnifyingglass", description: Text("This file contains no supported weight and rep sets. Review the warnings or choose another export."))
            } else if availableIDs.isEmpty {
                Text("All workouts in this export are already in your history.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func candidateRow(_ candidate: WorkoutImportCandidate) -> some View {
        let duplicate = duplicateIDs.contains(candidate.id)
        var workout = candidate.session
        for index in workout.exercises.indices {
            let source = workout.exercises[index].exercise.name
            if let exercise = overrides[source] ?? preview?.exerciseMappings.first(where: { $0.sourceName == source })?.matchedExercise {
                workout.exercises[index].exercise = exercise
            }
        }
        return HStack(spacing: 12) {
            Button {
                if selectedIDs.contains(candidate.id) { selectedIDs.remove(candidate.id) }
                else { selectedIDs.insert(candidate.id) }
            } label: {
                Image(systemName: duplicate ? "checkmark.seal.fill" : selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(duplicate ? Color.secondary : Color.blue)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).disabled(duplicate)
            .accessibilityLabel("\(selectedIDs.contains(candidate.id) ? "Deselect" : "Select") \(workout.name)")
            .accessibilityIdentifier("importSelection-\(candidate.id)")
            NavigationLink {
                WorkoutDetailView(workout: workout)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(workout.name).font(.headline)
                    Text(workout.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(duplicate ? "Already imported" : "\(workout.exercises.count) exercises · \(workout.exercises.reduce(0) { $0 + $1.sets.count }) sets")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            .accessibilityIdentifier("importDetail-\(candidate.id)")
        }
        .accessibilityElement(children: .contain)
    }

    private func success(_ result: WorkoutImportResult) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text("\(result.importedCount) \(result.importedCount == 1 ? "workout" : "workouts") imported").font(.title2.bold())
                .accessibilityIdentifier("importSuccessCount")
            Text("Your training history is ready to explore.").foregroundStyle(.secondary)
            if result.skippedDuplicateCount > 0 {
                Text("\(result.skippedDuplicateCount) existing imports skipped.").font(.subheadline).foregroundStyle(.secondary)
            }
            Button("View History") { dismiss() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .accessibilityIdentifier("viewImportedHistoryButton")
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readFile(_ url: URL) {
        busy = true
        Task {
            do {
                let contents = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 5_000_000 else { throw ImportFileError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 5_000_000 else { throw ImportFileError.tooLarge }
                    guard let text = String(data: data, encoding: .utf8) else { throw ImportFileError.encoding }
                    return text
                }.value
                csv = contents
                fileName = url.lastPathComponent
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func preparePreview() {
        guard let csv, let timeZone = TimeZone(identifier: timeZoneID) else { return }
        busy = true
        let unit = sourceUnit
        let catalog = store.exercises
        Task {
            do {
                let parsed = try await Task.detached(priority: .userInitiated) {
                    try StrongWorkoutImporter.preview(csv: csv, unit: unit, timeZone: timeZone, catalog: catalog)
                }.value
                preview = parsed
                selectedIDs = Set(parsed.workouts.map(\.id)).subtracting(duplicateIDs)
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func commitImport() {
        if let imported = store.importWorkouts(selectedSessions) { result = imported }
        else { error = store.errorMessage ?? "Could not save the imported workouts. Please try again."; store.errorMessage = nil }
    }

    private func loadUITestFixtureIfNeeded() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), args.contains("--import-ui-fixture"), csv == nil else { return }
        fileName = "Sample Strong export.csv"
        csv = """
        Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,RPE
        2024-01-01 10:00:00,Sample Upper,30m,Bench Press,1,50,10,0,0,
        2024-01-01 10:00:00,Sample Upper,30m,Bench Press,Rest Timer,0,0,0,60,
        2024-01-02 10:00:00,Sample Lower,45m,Fixture Squat,1,80,8,0,0,
        """
        #endif
    }
}

private enum ImportFileError: LocalizedError {
    case tooLarge, encoding
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Choose a CSV smaller than 5 MB. Split larger exports into smaller files."
        case .encoding: return "This file is not UTF-8 text. Choose the original CSV export from Strong."
        }
    }
}

private struct ImportTimeZonePicker: View {
    @Binding var selection: String
    @State private var search = ""
    private var identifiers: [String] {
        let zones = Set(TimeZone.knownTimeZoneIdentifiers + [TimeZone.current.identifier, "GMT"]).sorted()
        return zones.filter { search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List(identifiers, id: \.self) { identifier in
            Button {
                selection = identifier
            } label: {
                HStack {
                    Text(identifier.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                    Spacer()
                    if selection == identifier { Image(systemName: "checkmark") }
                }
            }
            .accessibilityIdentifier("importTimeZone-\(identifier)")
        }
        .searchable(text: $search, prompt: "Search city or region")
        .navigationTitle("Export Time Zone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ImportExerciseMatchView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let sourceName: String
    let current: Exercise?
    let onSelect: (Exercise) -> Void
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(sourceName).font(.headline)
                    Button("Keep Original Name as Custom") {
                        onSelect(Exercise(name: sourceName, category: "Custom"))
                    }
                    .accessibilityIdentifier("keepOriginalImportExerciseButton")
                } header: { Text("Imported exercise") }
                Section("Match to catalog") {
                    ForEach(store.exercises.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { exercise in
                        Button { onSelect(exercise) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exercise.name).foregroundStyle(.primary)
                                    Text(exercise.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if current?.id == exercise.id { Image(systemName: "checkmark") }
                            }
                        }
                        .accessibilityIdentifier("importCatalogExercise-\(exercise.name)")
                    }
                }
            }
            .searchable(text: $search, prompt: "Find a matching exercise")
            .navigationTitle("Match Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
