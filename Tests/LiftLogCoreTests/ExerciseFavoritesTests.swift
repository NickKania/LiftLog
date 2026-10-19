import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseFavoritesTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseFavorites-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    private func snapshot(favorites: [UUID] = []) -> WorkoutSnapshot {
        let exercise = Exercise(name: "Fixture Press", category: "Custom")
        let template = WorkoutTemplate(name: "Fixture", exercises: [TemplateExercise(exercise: exercise)])
        return WorkoutSnapshot(templates: [template], history: [], activeWorkout: nil, unit: .lb,
                               personalExercises: [exercise], favoriteExerciseIDs: favorites)
    }

    private func downgrade(_ url: URL, to version: Int) throws {
        let db = try SQLiteConnection(url: url)
        try db.execute("DROP TABLE exercise_instruction_overrides")
        try db.execute("DROP TABLE favorite_exercises")
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
    func testFavoritesPersistForBundledAndPersonalExercisesWithoutChangingWorkoutSnapshots() async throws {
        let url = try file()
        let saved = snapshot()
        try WorkoutDatabase(url: url).save(saved)
        let store = WorkoutStore(fileURL: url)
        let bundled = try XCTUnwrap(ExerciseCatalog.all.first)
        let personal = try XCTUnwrap(store.personalExercises.first)
        let templates = store.templates
        XCTAssertTrue(store.setExerciseFavorite(bundled.id, isFavorite: true))
        XCTAssertTrue(store.setExerciseFavorite(personal.id, isFavorite: true))
        XCTAssertEqual(store.favoriteExerciseIDs, [bundled.id, personal.id])
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(store.history, saved.history)
        XCTAssertEqual(store.activeWorkout, saved.activeWorkout)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.favoriteExerciseIDs, store.favoriteExerciseIDs)
        XCTAssertEqual(reloaded.templates, templates)
        XCTAssertEqual(reloaded.personalExercises, saved.personalExercises)
        XCTAssertTrue(reloaded.setExerciseFavorite(bundled.id, isFavorite: false))
        XCTAssertEqual(WorkoutStore(fileURL: url).favoriteExerciseIDs, [personal.id])
    }

    @MainActor
    func testIdempotentFavoritesAndUnavailableIDsDoNotWriteOrAdvanceRevision() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try XCTUnwrap(store.exercises.first?.id)
        XCTAssertTrue(store.setExerciseFavorite(id, isFavorite: true))
        let before = try Data(contentsOf: url)
        let revision = store.revision
        XCTAssertTrue(store.setExerciseFavorite(id, isFavorite: true))
        XCTAssertTrue(store.setExerciseFavorite(UUID(), isFavorite: false))
        XCTAssertFalse(store.setExerciseFavorite(UUID(), isFavorite: true))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.favoriteExerciseIDs, [id])
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testUnrelatedMutationsRetainFavoritesAndOrphanIDsCanBeRemoved() async throws {
        let url = try file()
        let orphan = UUID()
        try WorkoutDatabase(url: url).save(snapshot(favorites: [orphan]))
        let store = WorkoutStore(fileURL: url)
        XCTAssertFalse(store.exercises.contains { $0.id == orphan })
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertTrue(store.startWorkout())
        XCTAssertTrue(store.discardWorkout())
        let template = WorkoutTemplate(name: "Another", exercises: [TemplateExercise(exercise: try XCTUnwrap(store.exercises.first))])
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.deleteTemplate(id: template.id))
        XCTAssertEqual(WorkoutStore(fileURL: url).favoriteExerciseIDs, [orphan])
        XCTAssertFalse(store.setExerciseFavorite(orphan, isFavorite: true))
        XCTAssertTrue(store.setExerciseFavorite(orphan, isFavorite: false))
        XCTAssertTrue(WorkoutStore(fileURL: url).favoriteExerciseIDs.isEmpty)
    }

    @MainActor
    func testFailedFavoriteSaveRollsBackDatabaseAndPublishedState() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let ids = Array(store.exercises.prefix(3).map(\.id))
        XCTAssertTrue(store.setExerciseFavorite(ids[0], isFavorite: true))
        XCTAssertTrue(store.setExerciseFavorite(ids[1], isFavorite: true))
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_favorites BEFORE INSERT ON favorite_exercises BEGIN SELECT RAISE(ABORT, 'failed favorite save'); END")
        }
        let before = try WorkoutDatabase(url: url).load()
        let revision = store.revision
        XCTAssertFalse(store.setExerciseFavorite(ids[2], isFavorite: true))
        XCTAssertFalse(store.setExerciseFavorite(ids[0], isFavorite: false))
        XCTAssertEqual(store.favoriteExerciseIDs, Array(ids.prefix(2)))
        XCTAssertEqual(store.revision, revision)
        XCTAssertNotNil(store.errorMessage)
        let after = try WorkoutDatabase(url: url).load()
        XCTAssertEqual(after.favoriteExerciseIDs, before.favoriteExerciseIDs)
        XCTAssertEqual(after.templates, before.templates)
        XCTAssertEqual(after.unit, before.unit)
    }

    @MainActor
    func testFavoritesAreBlockedDuringRestore() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try XCTUnwrap(store.exercises.first?.id)
        let before = try Data(contentsOf: url)
        store.beginRestore()
        XCTAssertFalse(store.setExerciseFavorite(id, isFavorite: true))
        XCTAssertTrue(store.favoriteExerciseIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
        store.endRestore()
        XCTAssertTrue(store.setExerciseFavorite(id, isFavorite: true))
    }

    func testLegacyJSONDefaultsEmptyAndDuplicateFavoritesAreRejected() throws {
        let saved = snapshot(favorites: [UUID()])
        let encoded = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSnapshot.self, from: encoded).favoriteExerciseIDs, saved.favoriteExerciseIDs)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "favoriteExerciseIDs")
        let legacy = try JSONDecoder().decode(WorkoutSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.favoriteExerciseIDs.isEmpty)
        var duplicate = saved
        duplicate.favoriteExerciseIDs += saved.favoriteExerciseIDs
        XCTAssertThrowsError(try WorkoutStore.validate(duplicate))
        let url = try file()
        let database = WorkoutDatabase(url: url)
        try database.save(saved)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try database.save(duplicate))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testV1ThroughV4ReadOnlyBackupsStayUnchangedAndSaveUpgradesToCurrentSchema() throws {
        for version in 1...4 {
            let url = try file()
            let database = WorkoutDatabase(url: url)
            let saved = snapshot()
            try database.save(saved)
            try downgrade(url, to: version)
            let backup = url.deletingLastPathComponent().appendingPathComponent("v\(version)-backup.sqlite")
            try database.backup(to: backup)
            let bytes = try Data(contentsOf: backup)
            let legacy = try WorkoutDatabase(url: backup).load()
            XCTAssertTrue(legacy.favoriteExerciseIDs.isEmpty)
            XCTAssertEqual(legacy.templates, saved.templates)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
            var next = legacy
            next.favoriteExerciseIDs = [UUID()]
            try database.save(next)
            XCTAssertEqual(try database.load().favoriteExerciseIDs, next.favoriteExerciseIDs)
            XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 8)
            XCTAssertEqual(try Data(contentsOf: backup), bytes)
        }
    }

    func testFailedV5MigrationRollsBackSchemaAndRecordsThenRetries() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        let original = snapshot()
        try database.save(original)
        try downgrade(url, to: 4)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'failed upgrade'); END")
        }
        var next = original
        next.favoriteExerciseIDs = [UUID()]
        next.templates[0].name = "Must roll back"
        XCTAssertThrowsError(try database.save(next))
        XCTAssertEqual(try database.load().templates, original.templates)
        do {
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 4)
            XCTAssertTrue(try db.rows("SELECT name FROM sqlite_master WHERE name = 'favorite_exercises'").isEmpty)
            try db.execute("DROP TRIGGER reject_records")
        }
        try database.save(next)
        XCTAssertEqual(try database.load().favoriteExerciseIDs, next.favoriteExerciseIDs)
    }

    @MainActor
    func testSQLiteBackupAndRestoreReplaceFavoritesIncludingOrphans() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let id = try XCTUnwrap(store.exercises.first?.id)
        let orphan = UUID()
        let source = url.deletingLastPathComponent().appendingPathComponent("source.sqlite")
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        let saved = snapshot(favorites: [id, orphan])
        try WorkoutDatabase(url: source).save(saved)
        try WorkoutDatabase(url: source).backup(to: backup)
        let bytes = try Data(contentsOf: backup)
        XCTAssertEqual(try WorkoutDatabase(url: backup).load().favoriteExerciseIDs, [id, orphan])
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.favoriteExerciseIDs, [id, orphan])
        XCTAssertEqual(WorkoutStore(fileURL: url).favoriteExerciseIDs, [id, orphan])
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(WorkoutStore(fileURL: url).favoriteExerciseIDs, [id, orphan])
    }
}
