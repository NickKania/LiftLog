import Foundation

enum ExerciseDiscoveryFilter: Hashable, Identifiable {
    case all, unknown, value(String)

    var id: Self { self }
    var label: String {
        switch self {
        case .all: "All"
        case .unknown: "Unknown"
        case .value(let value): value
        }
    }
}

struct ExerciseDiscoverySection: Identifiable, Equatable {
    enum Kind: String, Identifiable {
        case favorites, recentlyTrained, allExercises

        var id: String { rawValue }
        var label: String {
            switch self {
            case .favorites: "Favorites"
            case .recentlyTrained: "Recently Trained"
            case .allExercises: "All Exercises"
            }
        }
    }

    let kind: Kind
    let exercises: [Exercise]

    var id: Kind { kind }
    var title: String { kind.label }
}

/// Build when the available exercise catalog changes, rather than normalizing every
/// catalog name and metadata field for each search keystroke or view render.
struct ExerciseDiscoveryIndex {
    static let catalog = Self(exercises: ExerciseCatalog.all)

    let equipmentOptions: [ExerciseDiscoveryFilter]
    let muscleOptions: [ExerciseDiscoveryFilter]
    let typeOptions: [ExerciseDiscoveryFilter]
    fileprivate let entries: [Entry]
    fileprivate let exercisesByID: [UUID: Exercise]

    init(exercises: [Exercise], details: [UUID: ExerciseDetail] = ExerciseCatalog.details) {
        var seen = Set<UUID>()
        let uniqueExercises = exercises.filter { seen.insert($0.id).inserted }
        entries = uniqueExercises.map { Entry(exercise: $0, detail: details[$0.id]) }
        exercisesByID = Dictionary(uniqueKeysWithValues: uniqueExercises.map { ($0.id, $0) })
        equipmentOptions = Self.options(entries.compactMap(\.equipmentLabel))
        muscleOptions = Self.options(entries.flatMap(\.muscleLabels))
        typeOptions = Self.options(entries.compactMap(\.typeLabel))
    }

    private static func options(_ values: [String]) -> [ExerciseDiscoveryFilter] {
        var seen = Set<String>()
        let labels = values.filter { seen.insert(normalized($0)).inserted }.sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        return [.all] + labels.map(ExerciseDiscoveryFilter.value) + [.unknown]
    }

    fileprivate struct Entry {
        let exercise: Exercise
        let searchDocument: ExerciseSearchDocument
        let equipmentLabel: String?
        let muscleLabels: [String]
        let typeLabel: String?
        let equipment: String?
        let muscles: Set<String>
        let type: String?

        init(exercise: Exercise, detail: ExerciseDetail?) {
            self.exercise = exercise
            searchDocument = ExerciseSearchDocument(exercise: exercise, detail: detail)
            equipmentLabel = displayValue(detail?.equipment)
            muscleLabels = ((detail?.primaryMuscles ?? []) + (detail?.secondaryMuscles ?? []))
                .compactMap { displayValue($0) }
            typeLabel = displayValue(detail?.type)
            equipment = equipmentLabel.map(normalized)
            muscles = Set(muscleLabels.map(normalized))
            type = typeLabel.map(normalized)
        }
    }
}

/// A projection of available catalog identities. Saved exercise snapshots, templates,
/// and active workout drafts are never modified or used to infer training history.
struct ExerciseDiscoveryQuery {
    var searchText = ""
    var equipment = ExerciseDiscoveryFilter.all
    var muscle = ExerciseDiscoveryFilter.all
    var type = ExerciseDiscoveryFilter.all

    var hasFilters: Bool {
        !normalized(searchText).isEmpty || hasMetadataFilters
    }

    var hasMetadataFilters: Bool {
        equipment != .all || muscle != .all || type != .all
    }

    mutating func clearFilters() {
        searchText = ""
        clearMetadataFilters()
    }

    mutating func clearMetadataFilters() {
        equipment = .all
        muscle = .all
        type = .all
    }

    func results(
        in index: ExerciseDiscoveryIndex,
        favoriteExerciseIDs: [UUID] = [],
        history: [WorkoutSession] = [],
        recentLimit: Int = 8
    ) -> [ExerciseDiscoverySection] {
        results(searchMatches: searchMatches(in: index), in: index,
                favoriteExerciseIDs: favoriteExerciseIDs, history: history, recentLimit: recentLimit)
    }

    /// Ranked matches include presentation context without changing exercise identity.
    /// Resolve text globally before filters so a hidden exact match cannot produce
    /// unrelated spelling suggestions in a different equipment or muscle filter.
    func searchMatches(in index: ExerciseDiscoveryIndex) -> [ExerciseSearchMatch] {
        let textMatches = ExerciseSearchEngine.matches(searchText, documents: index.entries.map(\.searchDocument))
        let equipment = normalizedFilter(equipment)
        let muscle = normalizedFilter(muscle)
        let type = normalizedFilter(type)
        let allowedIDs = Set(index.entries.filter { entry in
            matchesFilter(equipment, values: entry.equipment.map { [$0] } ?? []) &&
                matchesFilter(muscle, values: entry.muscles) &&
                matchesFilter(type, values: entry.type.map { [$0] } ?? [])
        }.map { $0.exercise.id })
        return textMatches.filter { allowedIDs.contains($0.exercise.id) }
    }

    /// Reuses matches already computed for inline search reasons in the picker.
    func results(
        searchMatches: [ExerciseSearchMatch],
        in index: ExerciseDiscoveryIndex,
        favoriteExerciseIDs: [UUID] = [],
        history: [WorkoutSession] = [],
        recentLimit: Int = 8
    ) -> [ExerciseDiscoverySection] {
        let matches = searchMatches.map(\.exercise)
        let matchingIDs = Set(matches.map(\.id))
        var seenFavorites = Set<UUID>()
        let favorites = favoriteExerciseIDs
            .filter { matchingIDs.contains($0) && seenFavorites.insert($0).inserted }
            .compactMap { index.exercisesByID[$0] }
        let favoriteIDs = Set(favorites.map(\.id))
        let recent = Self.recentExerciseIDs(in: history, availableIDs: Set(index.exercisesByID.keys), limit: recentLimit)
            .filter { matchingIDs.contains($0) && !favoriteIDs.contains($0) }
            .compactMap { index.exercisesByID[$0] }
        let featuredIDs = Set(favorites.map(\.id) + recent.map(\.id))
        let all = matches.filter { !featuredIDs.contains($0.id) }
        return [
            ExerciseDiscoverySection(kind: .favorites, exercises: favorites),
            ExerciseDiscoverySection(kind: .recentlyTrained, exercises: recent),
            ExerciseDiscoverySection(kind: .allExercises, exercises: all)
        ].filter { !$0.exercises.isEmpty }
    }

    /// Latest finish time first, with stable session-ID ties and original
    /// exercise order within a session. Recompute from history after deletion or reload.
    static func recentExerciseIDs(in history: [WorkoutSession], availableIDs: Set<UUID>, limit: Int = 8) -> [UUID] {
        guard limit > 0 else { return [] }
        let completed = history.compactMap { workout in
            workout.finishedAt.map { (workout: workout, finishedAt: $0) }
        }.sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
            return $0.workout.id.uuidString < $1.workout.id.uuidString
        }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for completedWorkout in completed {
            for item in completedWorkout.workout.exercises {
                let id = item.exercise.id
                guard item.sets.contains(where: \.isCompleted), availableIDs.contains(id), seen.insert(id).inserted else { continue }
                result.append(id)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

private func normalized(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func displayValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let display = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return display.isEmpty ? nil : display
}

private func normalizedFilter(_ filter: ExerciseDiscoveryFilter) -> ExerciseDiscoveryFilter {
    if case .value(let value) = filter { return .value(normalized(value)) }
    return filter
}

private func matchesFilter<C: Collection>(_ filter: ExerciseDiscoveryFilter, values: C) -> Bool where C.Element == String {
    switch filter {
    case .all: true
    case .unknown: values.isEmpty
    case .value(let value): values.contains(value)
    }
}
