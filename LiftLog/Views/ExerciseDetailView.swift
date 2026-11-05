import SwiftUI

struct ExerciseDetailView: View {
    @Environment(WorkoutStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let exercise: Exercise
    var selectionTitle = "Add Exercise"
    var selectionAccessibilityIdentifier = "exerciseDetailAddButton"
    let onAdd: () -> Void

    private var detail: ExerciseDetail? { ExerciseCatalog.detail(for: exercise.id) }
    private var instructions: [String] { store.exerciseInstructions(for: exercise.id) }
    private var hasPersonalInstructions: Bool { store.hasCustomExerciseInstructions(exercise.id) }
    private var isFavorite: Bool { store.favoriteExerciseIDs.contains(exercise.id) }
    private var source: ExerciseContentSource? {
        guard let detail else { return nil }
        return ExerciseCatalog.attribution.sources.first { $0.id == detail.source.sourceID }
    }

    var body: some View {
        LiftList {
            Section {
                Text(exercise.name)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("exerciseDetailName")
                Button(action: onAdd) {
                    Label(selectionTitle, systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .liftGlassButton(prominent: true)
                .listRowSeparator(.hidden)
                .accessibilityIdentifier(selectionAccessibilityIdentifier)
                Button {
                    store.setExerciseFavorite(exercise.id, isFavorite: !isFavorite)
                } label: {
                    Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.fill" : "star")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityValue(isFavorite ? "Favorite" : "Not a favorite")
                .accessibilityIdentifier("exerciseFavoriteButton")
            } footer: {
                Text("Favorite changes are saved immediately, even if you cancel adding an exercise.")
            }

            Section {
                if instructions.isEmpty {
                    Text("No default steps available")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exerciseInstructionsUnavailable")
                } else {
                    Text(hasPersonalInstructions ? "Your personal steps" : "Default source steps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exerciseInstructionsSource")
                    if detail?.instructions.isEmpty == false {
                        Text(hasPersonalInstructions
                             ? "Personal steps may include imported source guidance, which has not been individually reviewed or professionally validated."
                             : "Imported source guidance. These steps have not been individually reviewed or professionally validated.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("exerciseInstructionsReviewNotice")
                    }
                    ForEach(instructionRows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(row.number).")
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(row.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(row.number). \(row.text)")
                        .accessibilityIdentifier("exerciseInstructionStep-\(row.number)")
                    }
                }
            } header: {
                instructionsHeaderLayout {
                    Text("Instructions")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
                    NavigationLink {
                        ExerciseInstructionsEditor(
                            exercise: exercise,
                            instructions: instructions,
                            hasPersonalInstructions: hasPersonalInstructions
                        )
                    } label: {
                        Text(instructions.isEmpty ? "Add Steps" : "Edit Steps")
                            .textCase(nil)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(instructions.isEmpty ? "addExerciseInstructionsButton" : "editExerciseInstructionsButton")
                }
            }

            Section("Exercise metadata") {
                metadata("Category", value: exercise.category)
                metadata("Equipment", value: detail?.equipment)
                metadata("Primary muscles", value: muscles(detail?.primaryMuscles))
                metadata("Secondary muscles", value: muscles(detail?.secondaryMuscles))
                metadata("Type", value: detail?.type)
                metadata("Level", value: detail?.level)
                metadata("Force", value: detail?.force)
                metadata("Mechanic", value: detail?.mechanic)
                if detail == nil {
                    Text("Source metadata is unavailable for this custom or previously saved exercise.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exerciseMetadataUnavailable")
                }
            }

            if let detail {
                Section("Source & credits") {
                    if let source {
                        Text(source.name).font(.headline)
                        Text(source.credit)
                        metadata("Declared license", value: source.licenseID)
                    }
                    metadata("Source record", value: detail.source.sourceRecordID)
                    Text("Source attribution identifies the original content provider and does not indicate professional validation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exerciseMetadataReviewNotice")
                    NavigationLink {
                        CatalogCreditsView()
                    } label: {
                        Label("Credits & Licenses", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("exerciseDetailCreditsLink")
                }
            }
        }
        .navigationTitle("Exercise Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var instructionsHeaderLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }

    /// Content plus duplicate occurrence gives read-only source rows stable identity without relying on position.
    private var instructionRows: [InstructionRow] {
        var occurrences: [String: Int] = [:]
        return instructions.enumerated().map { index, text in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return InstructionRow(id: .init(text: text, occurrence: occurrence), number: index + 1, text: text)
        }
    }

    private struct InstructionRow: Identifiable {
        struct ID: Hashable {
            let text: String
            let occurrence: Int
        }
        let id: ID
        let number: Int
        let text: String
    }

    private func metadata(_ title: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(displayValue(value))
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("exerciseMetadata-\(title)")
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unknown" }
        return value
    }

    private func muscles(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }
}
