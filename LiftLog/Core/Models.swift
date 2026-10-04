import Foundation

enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case lb, kg
    var id: String { rawValue }
}

struct Exercise: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var category: String

    init(id: UUID = UUID(), name: String, category: String = "Other") {
        self.id = id
        self.name = name
        self.category = category
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

struct TemplateExercise: Codable, Equatable, Identifiable {
    var id: UUID
    var exercise: Exercise
    var sets: [TemplateSet]

    init(id: UUID = UUID(), exercise: Exercise, sets: [TemplateSet] = [TemplateSet()]) {
        self.id = id
        self.exercise = exercise
        self.sets = sets
    }
}

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

struct WorkoutSet: Codable, Equatable, Identifiable {
    var id: UUID
    var weight: Double
    var reps: Int
    var isCompleted: Bool

    init(id: UUID = UUID(), weight: Double = 0, reps: Int = 8, isCompleted: Bool = false) {
        self.id = id
        self.weight = weight
        self.reps = reps
        self.isCompleted = isCompleted
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
}

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
