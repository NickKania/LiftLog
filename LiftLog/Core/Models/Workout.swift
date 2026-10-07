import Foundation

struct WorkoutSession: Codable, Equatable, Identifiable {
    var id: UUID
    var templateID: UUID?
    var templateVersionID: UUID?
    var templateVersionNumber: Int?
    var name: String
    var startedAt: Date
    var finishedAt: Date?
    var unit: WeightUnit
    var exercises: [WorkoutExercise]
    var restSeconds: Int
    var restTimer: WorkoutRestTimer?
    var importSourceKey: String?

    init(id: UUID = UUID(), templateID: UUID? = nil, templateVersionID: UUID? = nil, templateVersionNumber: Int? = nil, name: String = "Workout", startedAt: Date = Date(), finishedAt: Date? = nil, unit: WeightUnit = .lb, importSourceKey: String? = nil, exercises: [WorkoutExercise] = [], restSeconds: Int = 120, restTimer: WorkoutRestTimer? = nil) {
        self.id = id
        self.templateID = templateID
        self.templateVersionID = templateVersionID
        self.templateVersionNumber = templateVersionNumber
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.unit = unit
        self.exercises = exercises
        self.importSourceKey = importSourceKey
        self.restSeconds = restSeconds
        self.restTimer = restTimer
    }

    private enum CodingKeys: String, CodingKey {
        case id, templateID, templateVersionID, templateVersionNumber, name, startedAt, finishedAt, unit, exercises, importSourceKey, restSeconds, restTimer
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        templateID = try values.decodeIfPresent(UUID.self, forKey: .templateID)
        templateVersionID = try values.decodeIfPresent(UUID.self, forKey: .templateVersionID)
        templateVersionNumber = try values.decodeIfPresent(Int.self, forKey: .templateVersionNumber)
        name = try values.decode(String.self, forKey: .name)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        unit = try values.decode(WeightUnit.self, forKey: .unit)
        exercises = try values.decode([WorkoutExercise].self, forKey: .exercises)
        importSourceKey = try values.decodeIfPresent(String.self, forKey: .importSourceKey)
        restSeconds = try values.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 120
        restTimer = try values.decodeIfPresent(WorkoutRestTimer.self, forKey: .restTimer)
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

    /// Numeric edits apply only to remaining sets, preserving completed results.
    mutating func updateSetValues(weight: Double, reps: Int) {
        for index in sets.indices where !sets[index].isCompleted {
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
    var targetWeight: Double?
    var isCompleted: Bool

    init(id: UUID = UUID(), weight: Double = 0, reps: Int = 8, targetReps: Int? = nil, targetWeight: Double? = nil, isCompleted: Bool = false) {
        self.id = id
        self.weight = weight
        self.reps = reps
        self.targetReps = targetReps
        self.targetWeight = targetWeight
        self.isCompleted = isCompleted
    }
}
