import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseInstructionTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseInstructions-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    private func snapshot(overrides: [ExerciseInstructionOverride] = []) -> WorkoutSnapshot {
        WorkoutSnapshot(templates: [], history: [], activeWorkout: nil, unit: .lb, exerciseInstructionOverrides: overrides)
    }

    private func bundledExercise() throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.all.first { !(ExerciseCatalog.detail(for: $0.id)?.instructions.isEmpty ?? true) })
    }

    private func downgrade(_ url: URL, to version: Int) throws {
        let db = try SQLiteConnection(url: url)
        try db.execute("DROP TABLE exercise_instruction_overrides")
        if version < 6 { try db.execute("DROP TABLE favorite_exercises") }
        if version < 5 { try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id") }
        if version < 4 { try db.execute("ALTER TABLE exercise_entries DROP COLUMN superset_id") }
        if version < 3 {
            try db.execute("ALTER TABLE records DROP COLUMN rest_seconds")
            try db.execute("ALTER TABLE records DROP COLUMN rest_timer")
        }
        if version < 2 {
            try db.execute("DROP TABLE template_versions")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_id")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_number")
            try db.execute("ALTER TABLE workout_sets DROP COLUMN target_weight")
        }
        try db.removeHistoryEditingSchema()
        try db.execute("PRAGMA user_version = \(version)")
    }

    @MainActor
    func testDefaultsAreImmediatelyAvailableAndPersonalStepsPersistWithoutChangingSnapshots() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let exercise = try bundledExercise()
        let defaults = try XCTUnwrap(ExerciseCatalog.detail(for: exercise.id)?.instructions)
        XCTAssertEqual(store.exerciseInstructions(for: exercise.id), defaults)
        XCTAssertFalse(store.hasCustomExerciseInstructions(exercise.id))
        let templates = store.templates
        XCTAssertTrue(store.startWorkout(template: try XCTUnwrap(templates.first)))
        let active = store.activeWorkout
        XCTAssertTrue(store.setExerciseInstructions(["  Brace first. \n", "Press, then return. "], for: exercise.id))
        XCTAssertEqual(store.exerciseInstructions(for: exercise.id), ["Brace first.", "Press, then return."])
        XCTAssertTrue(store.hasCustomExerciseInstructions(exercise.id))
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(ExerciseCatalog.detail(for: exercise.id)?.instructions, defaults)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.exerciseInstructionOverrides, store.exerciseInstructionOverrides)
        XCTAssertEqual(reloaded.templates, templates)
        XCTAssertEqual(reloaded.activeWorkout, active)
        XCTAssertTrue(reloaded.setExerciseInstructions(["Press, then return.", "Brace first."], for: exercise.id))
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructions(for: exercise.id), ["Press, then return.", "Brace first."])
        XCTAssertTrue(reloaded.resetExerciseInstructions(for: exercise.id))
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructions(for: exercise.id), defaults)
    }

    @MainActor
    func testCustomExercisesCanSaveStepsWithoutFabricatedDefaults() async throws {
        let url = try file()
        let exercise = Exercise(name: "Fixture Personal Move", category: "Custom")
        var saved = snapshot()
        saved.personalExercises = [exercise]
        try WorkoutDatabase(url: url).save(saved)
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.exerciseInstructions(for: exercise.id).isEmpty)
        XCTAssertTrue(store.setExerciseInstructions(["My personal cue"], for: exercise.id))
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructions(for: exercise.id), ["My personal cue"])
        XCTAssertTrue(store.resetExerciseInstructions(for: exercise.id))
        XCTAssertTrue(store.exerciseInstructions(for: exercise.id).isEmpty)
    }

    @MainActor
    func testIdempotentSavesAndResetsDoNotWriteAndSavingDefaultsRemovesOverride() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let exercise = try bundledExercise()
        let defaults = store.exerciseInstructions(for: exercise.id)
        XCTAssertTrue(store.setExerciseInstructions(["Personal step"], for: exercise.id))
        let before = try Data(contentsOf: url)
        let revision = store.revision
        XCTAssertTrue(store.setExerciseInstructions([" Personal step \n"], for: exercise.id))
        XCTAssertTrue(store.resetExerciseInstructions(for: UUID()))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(store.setExerciseInstructions(defaults, for: exercise.id))
        XCTAssertFalse(store.hasCustomExerciseInstructions(exercise.id))
        XCTAssertTrue(WorkoutStore(fileURL: url).exerciseInstructionOverrides.isEmpty)
        let afterReset = try Data(contentsOf: url)
        let resetRevision = store.revision
        XCTAssertTrue(store.setExerciseInstructions(defaults, for: exercise.id))
        XCTAssertTrue(store.resetExerciseInstructions(for: exercise.id))
        XCTAssertEqual(store.revision, resetRevision)
        XCTAssertEqual(try Data(contentsOf: url), afterReset)
    }

    @MainActor
    func testInvalidEditsDoNotWriteOrPublishAndBoundariesAreAccepted() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try bundledExercise().id
        let before = try Data(contentsOf: url)
        let revision = store.revision
        for steps in [[], ["\n  "], ["Good", ""], Array(repeating: "Step", count: 101), [String(repeating: "x", count: 10_001)]] {
            XCTAssertFalse(store.setExerciseInstructions(steps, for: id))
            XCTAssertNotNil(store.errorMessage)
        }
        XCTAssertFalse(store.setExerciseInstructions(["Step"], for: UUID()))
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.exerciseInstructionOverrides.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(store.setExerciseInstructions(Array(repeating: "Step", count: 100), for: id))
        XCTAssertTrue(store.setExerciseInstructions([String(repeating: "x", count: 10_000)], for: id))
    }

    @MainActor
    func testOrphansSurviveUnrelatedMutationsAndCanBeReset() async throws {
        let url = try file()
        let orphan = UUID()
        let overrides = [ExerciseInstructionOverride(exerciseID: orphan, steps: ["Retained personal cue"])]
        try WorkoutDatabase(url: url).save(snapshot(overrides: overrides))
        let store = WorkoutStore(fileURL: url)
        XCTAssertEqual(store.exerciseInstructions(for: orphan), overrides[0].steps)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertTrue(store.startWorkout())
        XCTAssertTrue(store.discardWorkout())
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructionOverrides, overrides)
        XCTAssertTrue(store.resetExerciseInstructions(for: orphan))
        XCTAssertTrue(WorkoutStore(fileURL: url).exerciseInstructionOverrides.isEmpty)
    }

    @MainActor
    func testFailedSaveAndResetRollBackDatabaseAndPublishedState() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try bundledExercise().id
        XCTAssertTrue(store.setExerciseInstructions(["Existing cue"], for: id))
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_steps BEFORE DELETE ON exercise_instruction_overrides BEGIN SELECT RAISE(ABORT, 'failed instruction save'); END")
        }
        let before = try WorkoutDatabase(url: url).load()
        let revision = store.revision
        XCTAssertFalse(store.setExerciseInstructions(["New cue"], for: id))
        XCTAssertFalse(store.resetExerciseInstructions(for: id))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.exerciseInstructionOverrides, before.exerciseInstructionOverrides)
        let after = try WorkoutDatabase(url: url).load()
        XCTAssertEqual(after.exerciseInstructionOverrides, before.exerciseInstructionOverrides)
        XCTAssertEqual(after.templates, before.templates)
    }

    @MainActor
    func testInstructionMutationsAreBlockedDuringRestore() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try bundledExercise().id
        XCTAssertTrue(store.setExerciseInstructions(["Existing cue"], for: id))
        let before = try Data(contentsOf: url)
        store.beginRestore()
        XCTAssertFalse(store.setExerciseInstructions(["Changed cue"], for: id))
        XCTAssertFalse(store.resetExerciseInstructions(for: id))
        XCTAssertEqual(store.exerciseInstructions(for: id), ["Existing cue"])
        XCTAssertEqual(try Data(contentsOf: url), before)
        store.endRestore()
        XCTAssertTrue(store.resetExerciseInstructions(for: id))
    }

    func testLegacyJSONDefaultsEmptyAndInvalidSnapshotsAreRejected() throws {
        let override = ExerciseInstructionOverride(exerciseID: UUID(), steps: ["Cue"])
        let saved = snapshot(overrides: [override])
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSnapshot.self, from: encoded).exerciseInstructionOverrides, [override])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "exerciseInstructionOverrides")
        let legacy = try JSONDecoder().decode(WorkoutSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.exerciseInstructionOverrides.isEmpty)
        let url = try file()
        let db = WorkoutDatabase(url: url)
        try db.save(saved)
        let before = try Data(contentsOf: url)
        let invalid = [snapshot(overrides: [override, override]), snapshot(overrides: [.init(exerciseID: UUID(), steps: [])]),
                       snapshot(overrides: [.init(exerciseID: UUID(), steps: ["  "])]),
                       snapshot(overrides: [.init(exerciseID: UUID(), steps: Array(repeating: "Cue", count: 101))]),
                       snapshot(overrides: [.init(exerciseID: UUID(), steps: [String(repeating: "x", count: 10_001)])])]
        for value in invalid {
            XCTAssertThrowsError(try WorkoutStore.validate(value))
            XCTAssertThrowsError(try db.save(value))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testV1ThroughV6ReadOnlyBackupsStayUnchangedAndSavesUpgradeToCurrentSchema() throws {
        for version in 1...6 {
            let url = try file()
            let database = WorkoutDatabase(url: url)
            try database.save(snapshot())
            try downgrade(url, to: version)
            let backup = url.deletingLastPathComponent().appendingPathComponent("v\(version)-backup.sqlite")
            try database.backup(to: backup)
            let bytes = try Data(contentsOf: backup)
            let legacy = try WorkoutDatabase(url: backup).load()
            XCTAssertTrue(legacy.exerciseInstructionOverrides.isEmpty)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            var next = legacy
            next.exerciseInstructionOverrides = [.init(exerciseID: UUID(), steps: ["An apostrophe's cue", "Second\nline"])]
            try database.save(next)
            XCTAssertEqual(try database.load().exerciseInstructionOverrides, next.exerciseInstructionOverrides)
            XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 8)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
        }
    }

    func testFailedV7MigrationRollsBackSchemaAndRecordsThenRetries() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        let original = snapshot()
        try database.save(original)
        try downgrade(url, to: 5)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_settings BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT, 'failed upgrade'); END")
        }
        var next = original
        next.unit = .kg
        next.exerciseInstructionOverrides = [.init(exerciseID: UUID(), steps: ["New cue"])]
        XCTAssertThrowsError(try database.save(next))
        XCTAssertEqual(try database.load().unit, original.unit)
        do {
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 5)
            XCTAssertTrue(try db.rows("SELECT name FROM sqlite_master WHERE name = 'exercise_instruction_overrides'").isEmpty)
            try db.execute("DROP TRIGGER reject_settings")
        }
        try database.save(next)
        XCTAssertEqual(try database.load().exerciseInstructionOverrides, next.exerciseInstructionOverrides)
    }

    @MainActor
    func testSQLiteBackupRestoreReplacesOverridesIncludingOrphans() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try bundledExercise().id
        XCTAssertTrue(store.setExerciseInstructions(["Will be replaced"], for: id))
        let overrides = [ExerciseInstructionOverride(exerciseID: id, steps: ["Restored cue"]),
                         ExerciseInstructionOverride(exerciseID: UUID(), steps: ["Orphan cue"])]
        let source = url.deletingLastPathComponent().appendingPathComponent("source.sqlite")
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try WorkoutDatabase(url: source).save(snapshot(overrides: overrides))
        try WorkoutDatabase(url: source).backup(to: backup)
        let bytes = try Data(contentsOf: backup)
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.exerciseInstructionOverrides, overrides)
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructionOverrides, overrides)
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(WorkoutStore(fileURL: url).exerciseInstructionOverrides, overrides)
    }

    func testMalformedPersistedStepsAreRejectedWithoutReplacingData() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        let id = UUID()
        try database.save(snapshot(overrides: [.init(exerciseID: id, steps: ["Cue"])]))
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("UPDATE exercise_instruction_overrides SET steps = ? WHERE exercise_id = ?", [.text("[]"), .text(id.uuidString)])
        }
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try database.load())
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
