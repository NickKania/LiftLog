import AppIntents
import Foundation

struct WorkoutTemplateEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Workout Template"
    static var defaultQuery = WorkoutTemplateQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WorkoutTemplateQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [WorkoutTemplateEntity] {
        Self.values(AppWorkoutStore.shared).filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [WorkoutTemplateEntity] {
        Self.values(AppWorkoutStore.shared).filter { $0.name.localizedStandardContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [WorkoutTemplateEntity] { Self.values(AppWorkoutStore.shared) }
    @MainActor static func values(_ store: WorkoutStore) -> [WorkoutTemplateEntity] {
        store.templates.map { WorkoutTemplateEntity(id: $0.id, name: $0.name) }
    }
}

struct CatalogExerciseEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Exercise"
    static var defaultQuery = CatalogExerciseQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct CatalogExerciseQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [CatalogExerciseEntity] {
        AppWorkoutStore.shared.exercises.filter { identifiers.contains($0.id) }.map { CatalogExerciseEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func entities(matching string: String) async throws -> [CatalogExerciseEntity] {
        AppWorkoutStore.shared.exercises.filter { $0.name.localizedStandardContains(string) }.map { CatalogExerciseEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func suggestedEntities() async throws -> [CatalogExerciseEntity] {
        AppWorkoutStore.shared.exercises.prefix(20).map { CatalogExerciseEntity(id: $0.id, name: $0.name) }
    }
}

/// Identity includes the session so a saved shortcut cannot target another workout.
struct ActiveExerciseEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Current Workout Exercise"
    static var defaultQuery = ActiveExerciseQuery()
    var workoutID: UUID
    var entryID: UUID
    var name: String
    var position: Int
    var id: String { "\(workoutID)/\(entryID)" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "Exercise \(position)")
    }
}

struct ActiveExerciseQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ActiveExerciseEntity] {
        Self.values(AppWorkoutStore.shared).filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [ActiveExerciseEntity] {
        Self.values(AppWorkoutStore.shared).filter { $0.name.localizedStandardContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [ActiveExerciseEntity] { Self.values(AppWorkoutStore.shared) }
    @MainActor static func values(_ store: WorkoutStore) -> [ActiveExerciseEntity] {
        guard let workout = store.activeWorkout else { return [] }
        return workout.exercises.enumerated().map { index, entry in
            ActiveExerciseEntity(workoutID: workout.id, entryID: entry.id, name: entry.exercise.name, position: index + 1)
        }
    }
}

struct ActiveSetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Incomplete Workout Set"
    static var defaultQuery = ActiveSetQuery()
    var workoutID: UUID
    var entryID: UUID
    var setID: UUID
    var name: String
    var exercisePosition: Int
    var setNumber: Int
    var id: String { "\(workoutID)/\(entryID)/\(setID)" }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name), set \(setNumber)", subtitle: "Exercise \(exercisePosition)")
    }
}

struct ActiveSetQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ActiveSetEntity] {
        Self.values(AppWorkoutStore.shared).filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [ActiveSetEntity] {
        Self.values(AppWorkoutStore.shared).filter { $0.name.localizedStandardContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [ActiveSetEntity] { Self.values(AppWorkoutStore.shared) }
    @MainActor static func values(_ store: WorkoutStore) -> [ActiveSetEntity] {
        guard let workout = store.activeWorkout else { return [] }
        return workout.exercises.enumerated().flatMap { exerciseIndex, entry in
            entry.sets.enumerated().compactMap { setIndex, set in
                guard !set.isCompleted else { return nil }
                return ActiveSetEntity(workoutID: workout.id, entryID: entry.id, setID: set.id,
                                       name: entry.exercise.name, exercisePosition: exerciseIndex + 1, setNumber: setIndex + 1)
            }
        }
    }
}
