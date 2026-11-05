import Foundation

/// Also decodes version-1 JSON files during the one-time migration to SQLite.
struct WorkoutSnapshot: Codable {
    var version = 2
    /// One previous committed record per corrected workout, included in backups.
    var historyRecovery: [WorkoutSession] = []
    var templates: [WorkoutTemplate]
    var history: [WorkoutSession]
    var activeWorkout: WorkoutSession?
    var unit: WeightUnit
    var personalExercises: [Exercise] = []
    var favoriteExerciseIDs: [UUID] = []
    var exerciseInstructionOverrides: [ExerciseInstructionOverride] = []

    init(templates: [WorkoutTemplate], history: [WorkoutSession], activeWorkout: WorkoutSession?, unit: WeightUnit, personalExercises: [Exercise] = [], favoriteExerciseIDs: [UUID] = [], exerciseInstructionOverrides: [ExerciseInstructionOverride] = [], historyRecovery: [WorkoutSession] = []) {
        self.historyRecovery = historyRecovery
        self.templates = templates
        self.history = history
        self.activeWorkout = activeWorkout
        self.unit = unit
        self.personalExercises = personalExercises
        self.favoriteExerciseIDs = favoriteExerciseIDs
        self.exerciseInstructionOverrides = exerciseInstructionOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case historyRecovery, version, templates, history, activeWorkout, unit, personalExercises, favoriteExerciseIDs, exerciseInstructionOverrides
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        historyRecovery = try values.decodeIfPresent([WorkoutSession].self, forKey: .historyRecovery) ?? []
        version = try values.decode(Int.self, forKey: .version)
        templates = try values.decode([WorkoutTemplate].self, forKey: .templates)
        history = try values.decode([WorkoutSession].self, forKey: .history)
        activeWorkout = try values.decodeIfPresent(WorkoutSession.self, forKey: .activeWorkout)
        unit = try values.decode(WeightUnit.self, forKey: .unit)
        personalExercises = try values.decodeIfPresent([Exercise].self, forKey: .personalExercises) ?? []
        favoriteExerciseIDs = try values.decodeIfPresent([UUID].self, forKey: .favoriteExerciseIDs) ?? []
        exerciseInstructionOverrides = try values.decodeIfPresent([ExerciseInstructionOverride].self, forKey: .exerciseInstructionOverrides) ?? []
    }
}
