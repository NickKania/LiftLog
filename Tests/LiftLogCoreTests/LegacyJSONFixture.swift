import Foundation
@testable import LiftLogCore

@MainActor
func legacyJSON(from store: WorkoutStore) throws -> Data {
    try JSONEncoder().encode(WorkoutSnapshot(templates: store.templates, history: store.history,
        activeWorkout: store.activeWorkout, unit: store.unit, personalExercises: store.personalExercises))
}
