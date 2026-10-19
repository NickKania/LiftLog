import SwiftUI

/// Choosing a candidate only opens a review. The owning editor commits the explicit replacement.
struct ExerciseSwapView: View {
    enum Scope {
        case template, workout

        var consequence: String {
            switch self {
            case .template:
                "This updates your draft. Save or Save Version in the template editor keeps the replacement. Previous versions and workouts stay unchanged."
            case .workout:
                "This changes only this workout. Original weight and rep targets are cleared. Your template and workout history stay unchanged."
            }
        }
    }

    @Environment(WorkoutStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ExerciseDiscoveryQuery()
    @State private var index = ExerciseDiscoveryIndex(exercises: [])
    @State private var alternatives: [ExerciseAlternative] = []
    @State private var browsingAll = false
    let originalExercise: Exercise
    let scope: Scope
    let onReplace: (Exercise) -> Bool

    private var isSearching: Bool {
        !query.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Replacing", value: originalExercise.name)
                }

                if isSearching || browsingAll {
                    let matches = query.searchMatches(in: index)
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: query.searchText)
                    } else {
                        Section(isSearching ? "Search Results" : "All Exercises") {
                            ForEach(matches) { match in
                                candidateRow(match.exercise, reason: match.displayReason)
                            }
                        }
                    }
                } else {
                    Section {
                        if alternatives.isEmpty {
                            Text("No similar movements found from available metadata. Search or browse all exercises to choose a replacement.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("exerciseSwapNoSuggestions")
                        }
                        ForEach(alternatives) { alternative in
                            candidateRow(alternative.exercise, reason: alternative.reasons.joined(separator: " · "))
                        }
                    } header: {
                        Text("Similar Movements")
                            .accessibilityIdentifier("exerciseSwapSimilarHeading")
                    } footer: {
                        Text("Suggestions share recorded movement metadata. Choose a suitable load for the new exercise.")
                    }
                    Section {
                        Button("Browse All Exercises", systemImage: "list.bullet") {
                            browsingAll = true
                        }
                        .accessibilityIdentifier("exerciseSwapBrowseAllButton")
                    }
                }
            }
            .accessibilityIdentifier("exerciseSwapList")
            .scrollDismissesKeyboard(.interactively)
            .searchable(text: $query.searchText, prompt: "Find a replacement")
            .navigationTitle("Replace Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("exerciseSwapCancelButton")
                }
            }
        }
        .workoutErrorAlert()
        .onAppear { refreshCandidates() }
        .onChange(of: store.exercises) { _, _ in refreshCandidates() }
    }

    private func candidateRow(_ exercise: Exercise, reason: String?) -> some View {
        NavigationLink {
            ExerciseSwapReviewView(originalExercise: originalExercise, replacement: exercise, scope: scope, onCancel: { dismiss() }) {
                if onReplace(exercise) { dismiss() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name).foregroundStyle(.primary)
                Text(exercise.category).font(.caption).foregroundStyle(.secondary)
                if let reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 3)
        }
        .accessibilityLabel("Review replacement with \(exercise.name)")
        .accessibilityHint(reason ?? exercise.category)
        .accessibilityIdentifier("exerciseSwapCandidate-\(exercise.id)")
    }

    private func refreshCandidates() {
        index = ExerciseDiscoveryIndex(exercises: store.exercises.filter { $0.id != originalExercise.id })
        alternatives = ExerciseAlternatives(exercises: store.exercises).alternatives(for: originalExercise)
    }
}

private struct ExerciseSwapReviewView: View {
    let originalExercise: Exercise
    let replacement: Exercise
    let scope: ExerciseSwapView.Scope
    let onCancel: () -> Void
    let onReplace: () -> Void

    var body: some View {
        List {
            Section("Replacement") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(originalExercise.name)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("exerciseSwapOriginalName")
                    Image(systemName: "arrow.down")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(replacement.name)
                        .font(.headline)
                        .accessibilityIdentifier("exerciseSwapReplacementName")
                }
                .padding(.vertical, 4)
                NavigationLink {
                    ExerciseSwapDetailView(exercise: replacement)
                } label: {
                    Label("Instructions & Details", systemImage: "info.circle")
                }
                .accessibilityIdentifier("exerciseSwapDetailsButton")
            }
            Section("What changes") {
                Label("All replacement weights start at 0. Choose a suitable load before training.", systemImage: "scalemass")
                Label("Set count, reps, exercise order, and superset membership are kept.", systemImage: "list.number")
                Text(scope.consequence)
                    .accessibilityIdentifier("exerciseSwapScopeConsequence")
            }
            Section {
                Button(action: onReplace) {
                    Text("Replace Exercise")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("exerciseSwapConfirmButton")
            }
        }
        .accessibilityIdentifier("exerciseSwapReviewList")
        .navigationTitle("Review Replacement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
                    .accessibilityIdentifier("exerciseSwapCancelButton")
            }
        }
    }
}

private struct ExerciseSwapDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: Exercise

    var body: some View {
        ExerciseDetailView(
            exercise: exercise,
            selectionTitle: "Back to Replacement Review",
            selectionAccessibilityIdentifier: "exerciseSwapReturnToReviewButton"
        ) { dismiss() }
    }
}
