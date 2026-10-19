import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseOrderTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseOrder-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    private func plan() -> WorkoutTemplate {
        let group = UUID()
        return WorkoutTemplate(name: "Strength", exercises: [
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 100, targetReps: 5)], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[1], sets: [TemplateSet(weight: 150, targetReps: 6)], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 80, targetReps: 10)])
        ])
    }

    @MainActor
    private func reorder(_ workout: WorkoutSession, in store: WorkoutStore) -> Bool {
        store.reorderActiveWorkout(id: workout.id, exerciseIDs: workout.exercises.reversed().map(\.id), expectedExerciseIDs: workout.exercises.map(\.id))
    }

    @MainActor
    func testReorderPreservesDuplicateEntriesLoggedValuesTargetsGroupsTimerAndHistory() async throws {
        let url = try file()
        let persisted = WorkoutStore(fileURL: url)
        let initial = plan()
        XCTAssertTrue(persisted.saveTemplate(initial))
        let template = try XCTUnwrap(persisted.templates.first { $0.id == initial.id })
        XCTAssertTrue(persisted.startWorkout(template: template))
        var workout = try XCTUnwrap(persisted.activeWorkout)
        workout.exercises[0].sets[0].weight = 95
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(persisted.updateActiveWorkout(workout))
        workout = try XCTUnwrap(persisted.activeWorkout)
        XCTAssertNotNil(workout.restTimer)
        let originalVersion = template.currentVersion
        let history = persisted.history
        XCTAssertTrue(reorder(workout, in: persisted))
        var expected = workout
        expected.exercises.reverse()
        XCTAssertEqual(persisted.activeWorkout, expected)
        let saved = try XCTUnwrap(persisted.templates.first { $0.id == template.id })
        XCTAssertEqual(saved.exercises, template.exercises.reversed())
        XCTAssertEqual(saved.versions.first, originalVersion)
        XCTAssertEqual(saved.currentVersion?.exercises, saved.exercises)
        XCTAssertEqual(saved.versions.count, 2)
        XCTAssertEqual(persisted.history, history)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.activeWorkout, expected)
        XCTAssertEqual(reloaded.templates, persisted.templates)
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        XCTAssertEqual(try WorkoutDatabase(url: backup).load().activeWorkout, expected)
        XCTAssertTrue(reloaded.discardWorkout())
        XCTAssertTrue(reloaded.startWorkout(template: saved))
        XCTAssertEqual(reloaded.activeWorkout?.exercises.map(\.templateExerciseID), saved.exercises.map { Optional($0.id) })
        XCTAssertEqual(reloaded.activeWorkout?.exercises.first?.sets.first?.weight, 80)
    }

    @MainActor
    func testLatestTemplateTargetsUnitsAndTemplateOnlyEntriesSurviveArchivedSessionReorder() async throws {
        let store = WorkoutStore(fileURL: try file()), initial = plan()
        XCTAssertTrue(store.saveTemplate(initial))
        var draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let original = try XCTUnwrap(draft.currentVersion)
        draft.name = "Updated"
        draft.exercises[0].sets[0].weight = 200
        draft.exercises.insert(TemplateExercise(exercise: ExerciseCatalog.all[2]), at: 1)
        draft.restSeconds = 60
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertTrue(store.startWorkout(template: draft, versionID: original.id))
        let workout = try XCTUnwrap(store.activeWorkout)
        XCTAssertTrue(store.setUnit(.kg))
        let latest = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertTrue(reorder(workout, in: store))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.exercises.map(\.id), [latest.exercises[3].id, latest.exercises[1].id, latest.exercises[2].id, latest.exercises[0].id])
        XCTAssertEqual(saved.exercises.last?.sets, latest.exercises.first?.sets)
        XCTAssertEqual(saved.name, latest.name)
        XCTAssertEqual(saved.restSeconds, latest.restSeconds)
        XCTAssertEqual(saved.currentVersion?.unit, .kg)
        XCTAssertEqual(saved.versions.dropLast(), latest.versions[...])
        XCTAssertEqual(store.activeWorkout?.templateVersionID, original.id)
        XCTAssertEqual(store.activeWorkout?.unit, .lb)
    }

    @MainActor
    func testSessionAdditionsAndRemovalsOnlyChangeOrderOfSurvivingTemplateEntries() async throws {
        let store = WorkoutStore(fileURL: try file()), initial = plan()
        XCTAssertTrue(store.saveTemplate(initial))
        let template = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertTrue(store.startWorkout(template: template))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises.remove(at: 1)
        let added = WorkoutExercise(exercise: initial.exercises[1].exercise)
        workout.exercises.append(added)
        XCTAssertTrue(store.updateActiveWorkout(workout))
        workout = try XCTUnwrap(store.activeWorkout)
        XCTAssertTrue(reorder(workout, in: store))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.exercises.map(\.id), [template.exercises[2].id, template.exercises[1].id, template.exercises[0].id])
        XCTAssertEqual(store.activeWorkout?.exercises.first, added)
    }

    @MainActor
    func testNoOpInvalidStaleDeletedAndUnlinkedSessions() async throws {
        let store = WorkoutStore(fileURL: try file()), initial = plan()
        XCTAssertTrue(store.saveTemplate(initial))
        XCTAssertTrue(store.startWorkout(template: initial))
        let workout = try XCTUnwrap(store.activeWorkout), revision = store.revision
        XCTAssertTrue(store.reorderActiveWorkout(id: workout.id, exerciseIDs: workout.exercises.map(\.id), expectedExerciseIDs: workout.exercises.map(\.id)))
        XCTAssertEqual(store.revision, revision)
        XCTAssertFalse(store.reorderActiveWorkout(id: workout.id, exerciseIDs: [workout.exercises[0].id, workout.exercises[0].id, workout.exercises[1].id], expectedExerciseIDs: workout.exercises.map(\.id)))
        XCTAssertFalse(store.reorderActiveWorkout(id: UUID(), exerciseIDs: workout.exercises.map(\.id), expectedExerciseIDs: workout.exercises.map(\.id)))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertTrue(reorder(workout, in: store))
        XCTAssertFalse(reorder(workout, in: store), "A stale sheet must not replace a newer order")
        XCTAssertTrue(store.deleteTemplate(id: initial.id))
        XCTAssertTrue(reorder(try XCTUnwrap(store.activeWorkout), in: store))
        XCTAssertFalse(store.templates.contains { $0.id == initial.id })
        XCTAssertTrue(store.discardWorkout())
        XCTAssertTrue(store.startWorkout())
        var unlinked = try XCTUnwrap(store.activeWorkout)
        unlinked.exercises = [WorkoutExercise(exercise: ExerciseCatalog.all[0]), WorkoutExercise(exercise: ExerciseCatalog.all[1])]
        XCTAssertTrue(store.updateActiveWorkout(unlinked))
        XCTAssertTrue(reorder(try XCTUnwrap(store.activeWorkout), in: store))
        XCTAssertNil(store.activeWorkout?.templateID)
    }

    @MainActor
    func testOrderDraftUsesLatestLoggedValuesAndLocalMoveDoesNotCreateTemplateVersion() async throws {
        let store = WorkoutStore(fileURL: try file()), initial = plan()
        XCTAssertTrue(store.saveTemplate(initial))
        XCTAssertTrue(store.startWorkout(template: initial))
        var workout = try XCTUnwrap(store.activeWorkout)
        let added = WorkoutExercise(exercise: ExerciseCatalog.all[2])
        workout.exercises.append(added)
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let draft = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].weight = 123
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let latest = try XCTUnwrap(store.activeWorkout)
        let versions = store.templates.first { $0.id == initial.id }?.versions
        let order = [added.id] + draft.exercises.dropLast().map(\.id)
        XCTAssertTrue(store.reorderActiveWorkout(id: draft.id, exerciseIDs: order, expectedExerciseIDs: draft.exercises.map(\.id)))
        XCTAssertEqual(store.activeWorkout?.exercises[1], latest.exercises[0])
        XCTAssertEqual(store.activeWorkout?.restTimer, latest.restTimer)
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions, versions)
    }

    @MainActor
    func testSaveFailureRollsBackWorkoutAndTemplateTogether() async throws {
        let url = try file(), initial = plan()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveTemplate(initial))
        XCTAssertTrue(store.startWorkout(template: initial))
        let workout = try XCTUnwrap(store.activeWorkout), templates = store.templates
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'failed reorder'); END")
        }
        XCTAssertFalse(reorder(workout, in: store))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(try WorkoutDatabase(url: url).load().activeWorkout, workout)
        XCTAssertEqual(try WorkoutDatabase(url: url).load().templates, templates)
        do { try SQLiteConnection(url: url).execute("DROP TRIGGER reject_records") }
        XCTAssertTrue(reorder(workout, in: store))
    }

    @MainActor
    func testV4MigrationReadOnlyBackupAndRollbackAndLegacyJSON() async throws {
        let url = try file(), initial = plan()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveTemplate(initial))
        XCTAssertTrue(store.startWorkout(template: initial))
        let original = try XCTUnwrap(store.activeWorkout)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.removeHistoryEditingSchema()
            try db.execute("PRAGMA user_version = 4")
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'failed migration'); END")
        }
        let bytes = try Data(contentsOf: url)
        let database = WorkoutDatabase(url: url), loaded = try WorkoutDatabase(url: url).load()
        let legacy = try XCTUnwrap(loaded.activeWorkout)
        XCTAssertNil(legacy.exercises[0].templateExerciseID, "Ambiguous legacy duplicates must not be guessed")
        XCTAssertEqual(legacy.exercises[1].templateExerciseID, initial.exercises[1].id)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try database.save(loaded))
        do {
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 4)
            XCTAssertFalse(try db.rows("PRAGMA table_info(exercise_entries)").contains { try $0.text("name") == "template_exercise_id" })
            try db.execute("DROP TRIGGER reject_records")
        }
        try database.save(loaded)
        XCTAssertEqual(try database.load().activeWorkout, legacy)
        let legacyData = try JSONEncoder().encode(WorkoutExercise(exercise: ExerciseCatalog.all[0]))
        XCTAssertNil(try JSONDecoder().decode(WorkoutExercise.self, from: legacyData).templateExerciseID)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutSession.self, from: JSONEncoder().encode(original)), original)
    }
    @MainActor
    func testLegacyJSONWithoutVersionLinksUniqueEntriesAndUpdatesTemplateAfterRelaunch() async throws {
        let url = try file()
        let entries = (0..<3).map { TemplateExercise(exercise: ExerciseCatalog.all[$0]) }
        let template = WorkoutTemplate(name: "Legacy plan", exercises: entries)
        let active = WorkoutSession(templateID: template.id, exercises: entries.map { WorkoutExercise(exercise: $0.exercise) })
        let snapshot = WorkoutSnapshot(templates: [template], history: [], activeWorkout: active, unit: .lb)
        let legacyURL = url.deletingPathExtension().appendingPathExtension("json")
        let bytes = try JSONEncoder().encode(snapshot)
        try bytes.write(to: legacyURL)
        let migrated = WorkoutStore(fileURL: url)
        XCTAssertNil(migrated.errorMessage)
        XCTAssertEqual(migrated.activeWorkout?.exercises.map(\.templateExerciseID), entries.map { Optional($0.id) })
        XCTAssertNil(migrated.activeWorkout?.templateVersionID)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertTrue(reorder(try XCTUnwrap(reloaded.activeWorkout), in: reloaded))
        XCTAssertEqual(reloaded.templates.first?.exercises.map(\.id), entries.reversed().map(\.id))
        XCTAssertEqual(try Data(contentsOf: legacyURL), bytes)
    }

    @MainActor
    func testV1ReadOnlyLoadAndRestoreLinksUniqueEntriesWithoutInventingVersionOrTargets() async throws {
        let url = try file()
        let entries = (0..<3).map { TemplateExercise(exercise: ExerciseCatalog.all[$0]) }
        let template = WorkoutTemplate(name: "Legacy plan", exercises: entries)
        let active = WorkoutSession(templateID: template.id, exercises: entries.map { WorkoutExercise(exercise: $0.exercise) })
        let snapshot = WorkoutSnapshot(templates: [template], history: [], activeWorkout: active, unit: .lb)
        try WorkoutDatabase(url: url).save(snapshot)
        do {
            let db = try SQLiteConnection(url: url)
            try db.removeHistoryEditingSchema()
            for statement in ["DROP TABLE template_versions", "ALTER TABLE records DROP COLUMN template_version_id",
                "ALTER TABLE records DROP COLUMN template_version_number", "ALTER TABLE workout_sets DROP COLUMN target_weight",
                "ALTER TABLE records DROP COLUMN rest_seconds", "ALTER TABLE records DROP COLUMN rest_timer",
                "ALTER TABLE exercise_entries DROP COLUMN superset_id", "ALTER TABLE exercise_entries DROP COLUMN template_exercise_id",
                "PRAGMA user_version = 1"] { try db.execute(statement) }
        }
        let bytes = try Data(contentsOf: url)
        let loaded = try WorkoutDatabase(url: url).load()
        XCTAssertEqual(loaded.activeWorkout?.exercises.map(\.templateExerciseID), entries.map { Optional($0.id) })
        XCTAssertNil(loaded.activeWorkout?.templateVersionID)
        XCTAssertNil(loaded.activeWorkout?.exercises[0].sets[0].targetWeight)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let restored = WorkoutStore(fileURL: try file())
        try restored.restoreDatabase(from: url)
        XCTAssertTrue(reorder(try XCTUnwrap(restored.activeWorkout), in: restored))
        XCTAssertEqual(restored.templates.first?.exercises.map(\.id), entries.reversed().map(\.id))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testStaleMovementLinksAreExcludedAndOnlyEligibleEntriesAffectTemplateOrder() async throws {
        let url = try file(), initial = plan()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.saveTemplate(initial))
        XCTAssertTrue(store.startWorkout(template: initial))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].exercise = ExerciseCatalog.all[2]
        // Reproduce an older app's persisted invalid link without passing the fixed update API.
        try WorkoutDatabase(url: url).save(WorkoutSnapshot(templates: store.templates, history: [], activeWorkout: active, unit: .lb))
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.templateLinkedExerciseIDs(in: active), Set(active.exercises.dropFirst().map(\.id)))
        let order = active.exercises.dropFirst().map(\.id) + [active.exercises[0].id]
        XCTAssertTrue(reloaded.reorderActiveWorkout(id: active.id, exerciseIDs: order, expectedExerciseIDs: active.exercises.map(\.id)))
        XCTAssertEqual(reloaded.templates, store.templates)
        XCTAssertTrue(reloaded.deleteTemplate(id: initial.id))
        XCTAssertTrue(reloaded.templateLinkedExerciseIDs(in: active).isEmpty)
    }

    func testPreVersionBackfillSkipsAmbiguousDuplicatesAndMissingTemplates() {
        let template = plan()
        let active = WorkoutSession(templateID: template.id, exercises: template.exercises.map { WorkoutExercise(exercise: $0.exercise) })
        let snapshot = WorkoutSnapshot(templates: [template], history: [], activeWorkout: active, unit: .lb)
        let inferred = WorkoutStore.backfillingExerciseReferences(snapshot)
        XCTAssertNil(inferred.activeWorkout?.exercises[0].templateExerciseID)
        XCTAssertEqual(inferred.activeWorkout?.exercises[1].templateExerciseID, template.exercises[1].id)
        XCTAssertNil(inferred.activeWorkout?.exercises[2].templateExerciseID)
        XCTAssertNil(inferred.activeWorkout?.templateVersionID)
        XCTAssertNil(inferred.activeWorkout?.templateVersionNumber)
        XCTAssertNil(inferred.activeWorkout?.exercises[1].sets[0].targetReps)
        var missing = snapshot
        missing.templates = []
        XCTAssertEqual(WorkoutStore.backfillingExerciseReferences(missing).activeWorkout, active)
    }

}
