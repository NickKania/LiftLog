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

    /// Applies the same weight and reps to every set, preserving set IDs.
    mutating func updateSetValues(weight: Double, reps: Int) {
        for index in sets.indices {
            sets[index].weight = weight
            sets[index].reps = reps
        }
    }
}

struct TemplateSet: Codable, Equatable, Identifiable {
    var id: UUID
    var weight: Double
    var reps: Int

    init(id: UUID = UUID(), weight: Double = 0, reps: Int = 8) {
        self.id = id
        self.weight = weight
        self.reps = reps
    }
}
