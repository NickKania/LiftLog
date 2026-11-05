import Foundation

struct ExerciseAlternative: Identifiable, Equatable {
    let exercise: Exercise
    /// Only similarities recorded in the bundled metadata, never an equivalence claim.
    let reasons: [String]

    var id: UUID { exercise.id }
}

/// Conservative offline suggestions. Names and display categories do not establish
/// movement similarity, and absent metadata never supplies a positive match.
struct ExerciseAlternatives {
    private let exercises: [Exercise]
    private let details: [UUID: ExerciseDetail]

    init(exercises: [Exercise], details: [UUID: ExerciseDetail] = ExerciseCatalog.details) {
        var seen = Set<UUID>()
        self.exercises = exercises.filter { seen.insert($0.id).inserted }
        self.details = details
    }

    func alternatives(for exercise: Exercise, limit: Int = 12) -> [ExerciseAlternative] {
        guard limit > 0, let source = details[exercise.id],
              let type = Self.known(source.type), !Self.muscles(source).isEmpty else { return [] }
        let primary = Self.muscles(source)
        let matches: [(alternative: ExerciseAlternative, score: Int)] = exercises.compactMap { candidate in
            guard candidate.id != exercise.id, let detail = details[candidate.id],
                  Self.known(detail.type) == type else { return nil }
            let sharedMuscles = primary.intersection(Self.muscles(detail))
            guard !sharedMuscles.isEmpty,
                  Self.compatible(source.force, detail.force),
                  Self.compatible(source.mechanic, detail.mechanic) else { return nil }
            // At least one recorded movement descriptor must match. Missing force
            // and mechanic together cannot establish a similar movement.
            let force = Self.shared(source.force, detail.force)
            let mechanic = Self.shared(source.mechanic, detail.mechanic)
            guard force != nil || mechanic != nil else { return nil }
            let labels = source.primaryMuscles.filter { Self.known($0).map(sharedMuscles.contains) ?? false }
            var reasons = ["Primary muscles: \(Self.uniqueLabels(labels).joined(separator: ", "))", "Type: \(Self.display(source.type))"]
            var score = sharedMuscles.count * 10
            if let force { reasons.append("Force: \(force)"); score += 2 }
            if let mechanic { reasons.append("Mechanic: \(mechanic)"); score += 2 }
            if let equipment = Self.shared(source.equipment, detail.equipment) {
                reasons.append("Equipment: \(equipment)")
                score += 5
            }
            if primary == Self.muscles(detail) { score += 10 }
            return (ExerciseAlternative(exercise: candidate, reasons: reasons), score)
        }
        return matches.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let left = Self.known($0.alternative.exercise.name) ?? ""
            let right = Self.known($1.alternative.exercise.name) ?? ""
            if left != right { return left < right }
            return $0.alternative.id.uuidString < $1.alternative.id.uuidString
        }.prefix(limit).map(\.alternative)
    }

    private static func muscles(_ detail: ExerciseDetail) -> Set<String> {
        Set(detail.primaryMuscles.compactMap { known($0) })
    }

    private static func known(_ value: String?) -> String? {
        let normalized = display(value).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty ? nil : normalized
    }

    private static func display(_ value: String?) -> String {
        (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func compatible(_ first: String?, _ second: String?) -> Bool {
        guard let first = known(first), let second = known(second) else { return true }
        return first == second
    }

    private static func shared(_ first: String?, _ second: String?) -> String? {
        guard let normalized = known(first), normalized == known(second) else { return nil }
        return display(first)
    }

    private static func uniqueLabels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert(known($0) ?? "").inserted }.map { display($0) }
    }
}
