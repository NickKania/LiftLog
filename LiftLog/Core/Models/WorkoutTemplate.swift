import Foundation

struct WorkoutTemplate: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var exercises: [TemplateExercise]
    var versions: [WorkoutTemplateVersion]
    var currentVersion: WorkoutTemplateVersion? { versions.last }

    init(id: UUID = UUID(), name: String = "", exercises: [TemplateExercise] = [], versions: [WorkoutTemplateVersion] = []) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.versions = versions
    }

    private enum CodingKeys: String, CodingKey { case id, name, exercises, versions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        exercises = try values.decode([TemplateExercise].self, forKey: .exercises)
        versions = try values.decodeIfPresent([WorkoutTemplateVersion].self, forKey: .versions) ?? []
    }
}

/// A saved prescription. Its loads always retain the unit used when it was saved.
struct WorkoutTemplateVersion: Codable, Equatable, Identifiable {
    let id: UUID
    let number: Int
    let createdAt: Date
    let name: String
    let exercises: [TemplateExercise]
    let unit: WeightUnit

    init(id: UUID = UUID(), number: Int, createdAt: Date = Date(), name: String, exercises: [TemplateExercise], unit: WeightUnit) {
        self.id = id
        self.number = number
        self.createdAt = createdAt
        self.name = name
        self.exercises = exercises
        self.unit = unit
    }

    func exercises(in unit: WeightUnit) -> [TemplateExercise] {
        guard unit != self.unit else { return exercises }
        let factor = unit == .kg ? 0.45359237 : 1 / 0.45359237
        return exercises.map { exercise in
            var converted = exercise
            for index in converted.sets.indices { converted.sets[index].weight *= factor }
            return converted
        }
    }
}

struct TemplateExercise: Codable, Equatable, Identifiable {
    var id: UUID
    var exercise: Exercise
    var sets: [TemplateSet]

    init(id: UUID = UUID(), exercise: Exercise, sets: [TemplateSet] = [TemplateSet()]) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
    }

    /// Applies the same weight and target reps to every set, preserving set IDs.
    mutating func updateSetValues(weight: Double, targetReps: Int) {
        for index in sets.indices {
            sets[index].weight = weight
            sets[index].targetReps = targetReps
        }
    }
}

struct TemplateSet: Codable, Equatable, Identifiable {
    var id: UUID
    var weight: Double
    var targetReps: Int

    init(id: UUID = UUID(), weight: Double = 0, targetReps: Int = 8) {
        self.id = id
        self.weight = weight
        self.targetReps = targetReps
    }

    // Older saved templates called the planned count "reps".
    private enum CodingKeys: String, CodingKey {
        case id, weight, targetReps, reps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        weight = try values.decode(Double.self, forKey: .weight)
        targetReps = try values.decodeIfPresent(Int.self, forKey: .targetReps)
            ?? values.decode(Int.self, forKey: .reps)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(weight, forKey: .weight)
        try values.encode(targetReps, forKey: .targetReps)
    }
}
