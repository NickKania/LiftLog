import Foundation

struct WorkoutTemplate: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var exercises: [TemplateExercise]

    init(id: UUID = UUID(), name: String = "", exercises: [TemplateExercise] = []) {
        self.id = id
        self.name = name
        self.exercises = exercises
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
