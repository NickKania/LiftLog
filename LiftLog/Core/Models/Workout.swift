import Foundation

struct WorkoutSession: Codable, Equatable, Identifiable {
    var id: UUID
    var templateID: UUID?
    var name: String
    var startedAt: Date
    var finishedAt: Date?
    var unit: WeightUnit
    var exercises: [WorkoutExercise]

    init(id: UUID = UUID(), templateID: UUID? = nil, name: String = "Workout", startedAt: Date = Date(), finishedAt: Date? = nil, unit: WeightUnit = .lb, exercises: [WorkoutExercise] = []) {
        self.id = id
        self.templateID = templateID
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.unit = unit
        self.exercises = exercises
    }
}

struct WorkoutExercise: Codable, Equatable, Identifiable {
    var id: UUID
    var exercise: Exercise
    var sets: [WorkoutSet]

    init(id: UUID = UUID(), exercise: Exercise, sets: [WorkoutSet] = [WorkoutSet()]) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
    }

    /// Numeric edits apply to every set; each set keeps its own completion state.
    mutating func updateSetValues(weight: Double, reps: Int) {
        for index in sets.indices {
            sets[index].weight = weight
            sets[index].reps = reps
        }
    }
}

struct WorkoutSet: Codable, Equatable, Identifiable {
    var id: UUID
    var weight: Double
    var reps: Int
    var targetReps: Int?
    var isCompleted: Bool

    init(id: UUID = UUID(), weight: Double = 0, reps: Int = 8, targetReps: Int? = nil, isCompleted: Bool = false) {
        self.id = id
        self.weight = weight
        self.reps = reps
        self.targetReps = targetReps
        self.isCompleted = isCompleted
    }
}
