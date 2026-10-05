import Foundation

/// Also decodes version-1 JSON files during the one-time migration to SQLite.
struct WorkoutSnapshot: Codable {
    var version = 2
    var templates: [WorkoutTemplate]
    var history: [WorkoutSession]
    var activeWorkout: WorkoutSession?
    var unit: WeightUnit
    var personalExercises: [Exercise] = []

    init(templates: [WorkoutTemplate], history: [WorkoutSession], activeWorkout: WorkoutSession?, unit: WeightUnit, personalExercises: [Exercise] = []) {
        self.templates = templates
        self.history = history
        self.activeWorkout = activeWorkout
        self.unit = unit
        self.personalExercises = personalExercises
    }

    private enum CodingKeys: String, CodingKey {
        case version, templates, history, activeWorkout, unit, personalExercises
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        templates = try values.decode([WorkoutTemplate].self, forKey: .templates)
        history = try values.decode([WorkoutSession].self, forKey: .history)
        activeWorkout = try values.decodeIfPresent(WorkoutSession.self, forKey: .activeWorkout)
        unit = try values.decode(WeightUnit.self, forKey: .unit)
        personalExercises = try values.decodeIfPresent([Exercise].self, forKey: .personalExercises) ?? []
    }
}
