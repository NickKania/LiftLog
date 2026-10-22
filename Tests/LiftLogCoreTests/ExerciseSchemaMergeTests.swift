import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseSchemaMergeTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseSchemaMerge-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func preparedStore() throws -> WorkoutStore {
        let store = WorkoutStore(fileURL: try file())
        let template = WorkoutTemplate(name: "Merge fixture", exercises: (0..<3).map {
            TemplateExercise(exercise: ExerciseCatalog.all[$0], sets: [TemplateSet(weight: Double(40 + $0), targetReps: 8)])
        })
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.startWorkout(template: template))
        XCTAssertTrue(store.setExerciseFavorite(ExerciseCatalog.all[0].id, isFavorite: true))
        XCTAssertTrue(store.setExerciseInstructions(["Personal fixture cue"], for: ExerciseCatalog.all[0].id))
        return store
    }

    @MainActor
    func testBothPreMergeLineagesLoadReadOnlyAndUpgradeAtomicallyWithoutLosingFeatures() async throws {
        for layout in ["main5", "catalog5", "catalog6", "main6"] {
            let store = try preparedStore()
            let url = try file()
            let original = WorkoutSnapshot(templates: store.templates, history: store.history, activeWorkout: store.activeWorkout,
                unit: store.unit, personalExercises: store.personalExercises, favoriteExerciseIDs: store.favoriteExerciseIDs,
                exerciseInstructionOverrides: [.init(exerciseID: ExerciseCatalog.all[0].id, steps: ["Personal fixture cue"])])
            let database = WorkoutDatabase(url: url)
            try database.save(original)
            do {
                let db = try SQLiteConnection(url: url)
                if layout.hasPrefix("catalog") { try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id") }
                if layout == "main5" { try db.execute("DROP TABLE favorite_exercises") }
                if layout != "catalog6" { try db.execute("DROP TABLE exercise_instruction_overrides") }
                try db.removeHistoryEditingSchema()
                try db.execute("PRAGMA user_version = \(layout.hasSuffix("5") ? 5 : 6)")
                try db.execute("CREATE TRIGGER reject_merge BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT, 'failed merge migration'); END")
            }
            let bytes = try Data(contentsOf: url)
            let loaded = try database.load()
            XCTAssertEqual(try Data(contentsOf: url), bytes, layout)
            XCTAssertEqual(loaded.templates, original.templates, layout)
            var expectedWorkout = original.activeWorkout
            if layout.hasPrefix("catalog"), var workout = expectedWorkout {
                for index in workout.exercises.indices { workout.exercises[index].templateExerciseID = nil }
                expectedWorkout = workout
            }
            XCTAssertEqual(loaded.activeWorkout, expectedWorkout, layout)
            XCTAssertEqual(loaded.history, original.history, layout)
            XCTAssertEqual(loaded.favoriteExerciseIDs, layout == "main5" ? [] : original.favoriteExerciseIDs, layout)
            XCTAssertEqual(loaded.exerciseInstructionOverrides, layout == "catalog6" ? original.exerciseInstructionOverrides : [], layout)
            XCTAssertThrowsError(try database.save(loaded), layout)
            XCTAssertEqual(try Data(contentsOf: url), bytes, "Failed migration must retain the exact old file: \(layout)")
            try SQLiteConnection(url: url).execute("DROP TRIGGER reject_merge")
            try database.save(loaded)
            let saved = try database.load()
            XCTAssertEqual(saved.activeWorkout, loaded.activeWorkout, layout)
            XCTAssertEqual(saved.templates, loaded.templates, layout)
            XCTAssertEqual(saved.favoriteExerciseIDs, loaded.favoriteExerciseIDs, layout)
            XCTAssertEqual(saved.exerciseInstructionOverrides, loaded.exerciseInstructionOverrides, layout)
            XCTAssertEqual(try SQLiteConnection(url: url).rows("PRAGMA user_version").first?.integer("user_version"), 9)
        }
    }

    func testIncompleteCurrentSchemaFailsWithoutReplacingSavedData() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        try database.save(WorkoutSnapshot(templates: [], history: [], activeWorkout: nil, unit: .lb))
        try SQLiteConnection(url: url).execute("DROP TABLE favorite_exercises")
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try database.load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testPreMergeCatalogReplacementCannotGainTemplateProvenanceDuringUpgrade() async throws {
        let store = try preparedStore()
        var workout = try XCTUnwrap(store.activeWorkout)
        let templates = store.templates
        // An old native swap followed by removal of the original same movement
        // can look like a unique template match; it is still workout-only.
        workout.exercises[0] = WorkoutExercise(exercise: ExerciseCatalog.all[1])
        workout.exercises.remove(at: 1)
        let url = try file()
        let database = WorkoutDatabase(url: url)
        try database.save(WorkoutSnapshot(templates: templates, history: [], activeWorkout: workout, unit: .lb))
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.removeHistoryEditingSchema()
            try db.execute("PRAGMA user_version = 6")
        }
        let reloaded = WorkoutStore(fileURL: url)
        let active = try XCTUnwrap(reloaded.activeWorkout)
        XCTAssertTrue(active.exercises.allSatisfy { $0.templateExerciseID == nil })
        XCTAssertTrue(reloaded.reorderActiveWorkout(id: active.id, exerciseIDs: active.exercises.reversed().map(\.id), expectedExerciseIDs: active.exercises.map(\.id)))
        XCTAssertEqual(reloaded.templates, templates)
    }

    @MainActor
    func testReplacementThenReorderKeepsReplacementLocalAndRetainsCatalogPreferences() async throws {
        let store = try preparedStore()
        let before = try XCTUnwrap(store.activeWorkout)
        let template = try XCTUnwrap(store.templates.first { $0.id == before.templateID })
        XCTAssertTrue(store.replaceActiveExercise(in: before.id, expectedEntry: before.exercises[0], with: ExerciseCatalog.all[3].id))
        let replaced = try XCTUnwrap(store.activeWorkout)
        XCTAssertNil(replaced.exercises[0].templateExerciseID)
        XCTAssertNil(replaced.exercises[0].sets[0].targetWeight)
        XCTAssertTrue(store.reorderActiveWorkout(id: replaced.id, exerciseIDs: replaced.exercises.reversed().map(\.id), expectedExerciseIDs: replaced.exercises.map(\.id)))
        let updated = try XCTUnwrap(store.templates.first { $0.id == template.id })
        XCTAssertEqual(updated.exercises.map(\.id), [template.exercises[0].id, template.exercises[2].id, template.exercises[1].id])
        XCTAssertEqual(updated.versions.first, template.versions.first)
        XCTAssertEqual(store.activeWorkout?.exercises.last, replaced.exercises[0])
        XCTAssertEqual(store.favoriteExerciseIDs, [ExerciseCatalog.all[0].id])
        XCTAssertEqual(store.exerciseInstructions(for: ExerciseCatalog.all[0].id), ["Personal fixture cue"])
    }
}
