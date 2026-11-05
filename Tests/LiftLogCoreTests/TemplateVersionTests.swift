import Foundation
import XCTest
@testable import LiftLogCore

final class TemplateVersionTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateVersions-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    private func template() -> WorkoutTemplate {
        WorkoutTemplate(name: "Bench Day", exercises: [TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 135, targetReps: 8), TemplateSet(weight: 135, targetReps: 8)])])
    }

    @MainActor
    func testHistoryOrderOnlyRevisionPreservesNonuniformSetsAndEarlierVersion() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var initial = template()
        initial.exercises[0].sets[1].weight = 125
        initial.exercises[0].sets[1].targetReps = 10
        initial.exercises.append(TemplateExercise(exercise: ExerciseCatalog.all[1], sets: [TemplateSet(weight: 90, targetReps: 5)]))
        XCTAssertTrue(store.saveTemplate(initial))
        let original = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertTrue(store.startWorkout(template: original))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises.reverse()
        for index in workout.exercises.indices {
            for setIndex in workout.exercises[index].sets.indices {
                workout.exercises[index].sets[setIndex].isCompleted = true
            }
        }
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertTrue(store.finishWorkout())
        let history = try XCTUnwrap(store.history.first)
        let revision = WorkoutTemplate.draft(from: history, replacing: original, unit: store.unit)
        XCTAssertEqual(revision.exercises, Array(original.exercises.reversed()))
        XCTAssertFalse(WorkoutStore.samePrescription(revision.exercises, original.exercises))
        XCTAssertTrue(store.saveTemplate(revision))
        let saved = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertEqual(saved.versions.count, 2)
        XCTAssertEqual(saved.versions.first, original.currentVersion)
        XCTAssertEqual(saved.exercises[1].sets.map(\.weight), [135, 125])
        XCTAssertEqual(saved.exercises[1].sets.map(\.targetReps), [8, 10])
        XCTAssertTrue(store.saveTemplate(.draft(from: history, replacing: saved, unit: store.unit)))
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.templates.first { $0.id == original.id }?.versions.count, 2)
        XCTAssertEqual(reloaded.history, [history])
    }

    @MainActor
    func testHistoryDraftCopiesActualCompletedWorkAndSavesIndependentVersions() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        let original = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertTrue(store.startWorkout(template: original))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].weight = 150
        active.exercises[0].sets[0].reps = 6
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        let history = try XCTUnwrap(store.history.first)
        let newDraft = WorkoutTemplate.draft(from: history, unit: .kg)
        XCTAssertNotEqual(newDraft.id, original.id)
        XCTAssertNotEqual(newDraft.exercises[0].id, history.exercises[0].id)
        XCTAssertTrue(newDraft.versions.isEmpty)
        XCTAssertEqual(newDraft.exercises[0].sets.count, 1)
        XCTAssertEqual(newDraft.exercises[0].sets[0].weight, 150 * 0.45359237, accuracy: 0.00001)
        XCTAssertEqual(newDraft.exercises[0].sets[0].targetReps, 6)
        let revision = WorkoutTemplate.draft(from: history, replacing: original, unit: store.unit)
        XCTAssertEqual(revision.exercises[0].id, original.exercises[0].id)
        XCTAssertEqual(revision.exercises[0].sets[0].id, original.exercises[0].sets[0].id)
        XCTAssertTrue(store.saveTemplate(revision, expectedUnit: store.unit))
        XCTAssertEqual(store.templates.first { $0.id == original.id }?.versions.count, 2)
        XCTAssertEqual(store.templates.first { $0.id == original.id }?.versions.first, original.versions.first)
        let independent = WorkoutTemplate.draft(from: history, unit: store.unit)
        XCTAssertTrue(store.saveTemplate(independent, expectedUnit: store.unit))
        XCTAssertEqual(store.history, [history])
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.history, [history])
        XCTAssertEqual(reloaded.templates.first { $0.id == independent.id }?.currentVersion?.number, 1)
        // A captured revision cannot replace a newer default, or resurrect a deleted target.
        XCTAssertFalse(store.saveTemplate(revision, expectedUnit: store.unit))
        XCTAssertTrue(store.deleteTemplate(id: original.id))
        XCTAssertFalse(store.saveTemplate(revision, expectedUnit: store.unit))
    }

    func testHistoryDraftPreservesRestGroupsAndRepeatedMovementsWithoutCopyingNotes() {
        let group = UUID()
        let movement = ExerciseCatalog.all[0]
        let workout = WorkoutSession(finishedAt: Date(), unit: .lb, exercises: [
            WorkoutExercise(exercise: movement, sets: [WorkoutSet(weight: 10, reps: 8, isCompleted: true)], supersetID: group, notes: "Private note", restSeconds: 0),
            WorkoutExercise(exercise: movement, sets: [WorkoutSet(weight: 20, reps: 5, isCompleted: true)], supersetID: group, restSeconds: 30),
            WorkoutExercise(exercise: movement, sets: [WorkoutSet(isCompleted: false)], supersetID: UUID())
        ], restSeconds: 90, notes: "Workout note", summary: "Coaching")
        let draft = WorkoutTemplate.draft(from: workout, unit: .lb)
        XCTAssertEqual(draft.exercises.count, 2)
        XCTAssertNotEqual(draft.exercises[0].id, draft.exercises[1].id)
        XCTAssertEqual(draft.exercises.map(\.supersetID), [group, group])
        XCTAssertEqual(draft.exercises.map(\.restSeconds), [0, 30])
        XCTAssertEqual(draft.restSeconds, 90)
        XCTAssertEqual(draft.exercises.map { $0.sets[0].weight }, [10, 20])
    }

    @MainActor
    func testRevisionsAreImmutablePersistedAndOnlyRealChangesCreateOne() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        var draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let first = try XCTUnwrap(draft.currentVersion)
        XCTAssertEqual(first.number, 1)
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions, [first])
        // Recreating local rows with identical prescriptions does not manufacture a revision.
        draft.exercises[0].id = UUID()
        draft.exercises[0].sets[0].id = UUID()
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions, [first])
        draft.exercises[0].updateSetValues(weight: 140, targetReps: 9)
        XCTAssertTrue(store.saveTemplate(draft))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.versions.count, 2)
        XCTAssertEqual(saved.versions[0], first)
        XCTAssertEqual(saved.currentVersion?.number, 2)
        XCTAssertEqual(saved.currentVersion?.exercises[0].sets[0].weight, 140)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates.first { $0.id == initial.id }, saved)
    }

    @MainActor
    func testRenameKeepsVersionsAndRecordedWorkoutsAndPersists() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        var draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let versions = draft.versions
        XCTAssertTrue(store.startWorkout(template: draft))
        let active = store.activeWorkout
        draft.name = "  Upper Body  "
        XCTAssertTrue(store.saveTemplate(draft))
        let renamed = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(renamed.name, "Upper Body")
        XCTAssertEqual(renamed.versions, versions)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates.first { $0.id == initial.id }, renamed)
        var completed = try XCTUnwrap(store.activeWorkout)
        completed.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(completed))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history.first?.name, initial.name)
        XCTAssertTrue(store.startWorkout(template: renamed))
        XCTAssertEqual(store.activeWorkout?.name, "Upper Body")
        XCTAssertEqual(store.activeWorkout?.templateVersionID, versions.last?.id)
        draft = renamed
        draft.exercises[0].sets[0].targetReps += 1
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions.count, 2)
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.currentVersion?.name, "Upper Body")
    }

    @MainActor
    func testStaleAndDeletedDraftsCannotReplacePlansAndArchivesCannotBeForged() async throws {
        let store = WorkoutStore(fileURL: try file())
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        let stale = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        var draft = stale
        let genuine = try XCTUnwrap(draft.currentVersion)
        draft.versions = [WorkoutTemplateVersion(id: genuine.id, number: 123, name: "Forged", exercises: genuine.exercises, unit: .kg)]
        draft.exercises[0].sets[0].targetReps = 9
        XCTAssertTrue(store.saveTemplate(draft))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.versions[0], genuine)
        XCTAssertFalse(store.saveTemplate(stale))
        XCTAssertFalse(store.saveTemplate(initial))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }, saved)
        XCTAssertTrue(store.deleteTemplate(id: initial.id))
        XCTAssertFalse(store.saveTemplate(saved))
        XCTAssertFalse(store.templates.contains { $0.id == initial.id })
    }

    @MainActor
    func testStartingOldAndCurrentVersionsRecordsExactTargetsAndKeepsLoggedChangesSeparate() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        var draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let first = try XCTUnwrap(draft.currentVersion)
        draft.exercises[0].updateSetValues(weight: 140, targetReps: 9)
        XCTAssertTrue(store.saveTemplate(draft))
        let current = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertTrue(store.startWorkout(template: current, versionID: first.id))
        var active = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(active.templateVersionID, first.id)
        XCTAssertEqual(active.templateVersionNumber, 1)
        XCTAssertEqual(active.exercises[0].sets[0].targetWeight, 135)
        XCTAssertEqual(active.exercises[0].sets[0].targetReps, 8)
        active.templateVersionID = current.currentVersion?.id
        active.templateVersionNumber = 2
        active.exercises[0].sets[0].weight = 130
        active.exercises[0].sets[0].reps = 7
        active.exercises[0].sets[0].targetWeight = 130
        active.exercises[0].sets[0].targetReps = 7
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        let history = try XCTUnwrap(WorkoutStore(fileURL: url).history.first)
        XCTAssertEqual(history.templateVersionID, first.id)
        XCTAssertEqual(history.exercises[0].sets[0].weight, 130)
        XCTAssertEqual(history.exercises[0].sets[0].reps, 7)
        XCTAssertEqual(history.exercises[0].sets[0].targetWeight, 135)
        XCTAssertEqual(history.exercises[0].sets[0].targetReps, 8)
        // Passing an old draft without an explicit version starts the saved current default.
        XCTAssertTrue(store.startWorkout(template: draft))
        XCTAssertEqual(store.activeWorkout?.templateVersionNumber, 2)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0].targetWeight, 140)
    }

    @MainActor
    func testUnitsConvertCurrentPlanWithoutRewritingSavedVersions() async throws {
        let store = WorkoutStore(fileURL: try file())
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        let oldDraft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let first = try XCTUnwrap(oldDraft.currentVersion)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertFalse(store.saveTemplate(oldDraft, expectedUnit: .lb))
        var converted = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(converted.versions, [first])
        XCTAssertEqual(converted.exercises[0].sets[0].weight, 135 * 0.45359237, accuracy: 1e-9)
        XCTAssertTrue(store.saveTemplate(converted, expectedUnit: .kg))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions.count, 1)
        converted.exercises[0].updateSetValues(weight: 65, targetReps: 8)
        XCTAssertTrue(store.saveTemplate(converted, expectedUnit: .kg))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.versions[0], first)
        XCTAssertEqual(saved.versions[1].unit, .kg)
        XCTAssertTrue(store.startWorkout(template: saved, versionID: first.id))
        XCTAssertEqual(try XCTUnwrap(store.activeWorkout?.exercises[0].sets[0].targetWeight), 135 * 0.45359237, accuracy: 1e-9)
        XCTAssertEqual(store.activeWorkout?.unit, .kg)
        XCTAssertTrue(store.setUnit(.lb))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions, saved.versions)
    }

    @MainActor
    func testInvalidVersionSelectionAndFailedSavePublishNothing() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = template()
        XCTAssertTrue(store.saveTemplate(initial))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertFalse(store.startWorkout(template: saved, versionID: UUID()))
        XCTAssertFalse(store.startWorkout(versionID: UUID()))
        XCTAssertNil(store.activeWorkout)
        var draft = saved
        draft.exercises[0].sets[0].weight = 145
        let revision = store.revision
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertFalse(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }, saved)
        XCTAssertEqual(store.revision, revision)
    }

    @MainActor
    func testV1DatabaseAndBackupMigrationNeverInferHistoricalTargetsOrVersionReferences() async throws {
        let url = try file()
        let initial = template()
        let history = WorkoutSession(templateID: initial.id, name: initial.name, startedAt: Date(timeIntervalSinceReferenceDate: 100), finishedAt: Date(timeIntervalSinceReferenceDate: 200), exercises: [WorkoutExercise(exercise: initial.exercises[0].exercise, sets: [WorkoutSet(weight: 125, reps: 7, isCompleted: true)])])
        let snapshot = WorkoutSnapshot(templates: [initial], history: [history], activeWorkout: nil, unit: .lb)
        try WorkoutDatabase(url: url).save(snapshot)
        // Produce the actual previous relational schema without version-related columns.
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("DROP TABLE template_versions")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_id")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_number")
            try db.execute("ALTER TABLE workout_sets DROP COLUMN target_weight")
            try db.execute("ALTER TABLE records DROP COLUMN rest_seconds")
            try db.execute("ALTER TABLE records DROP COLUMN rest_timer")
            try db.execute("DROP TABLE exercise_instruction_overrides")
            try db.execute("DROP TABLE favorite_exercises")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN superset_id")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.removeHistoryEditingSchema()
            try db.execute("PRAGMA user_version = 1")
        }
        let backup = url.deletingLastPathComponent().appendingPathComponent("v1-backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        let oldBytes = try Data(contentsOf: backup)
        XCTAssertEqual(try WorkoutDatabase(url: backup).load().templates[0].versions, [])
        XCTAssertEqual(try Data(contentsOf: backup), oldBytes)
        let store = WorkoutStore(fileURL: url)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.templates[0].currentVersion?.number, 1)
        XCTAssertEqual(store.history, [history])
        XCTAssertNil(store.history[0].templateVersionID)
        XCTAssertNil(store.history[0].exercises[0].sets[0].targetWeight)
        XCTAssertNil(store.history[0].exercises[0].sets[0].targetReps)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.templates, store.templates)
        XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 10)
        let revisionBeforeRestore = store.revision
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.revision, revisionBeforeRestore + 1)
        XCTAssertEqual(store.history, [history])
        XCTAssertEqual(store.templates[0].versions.count, 1)
        XCTAssertEqual(try Data(contentsOf: backup), oldBytes)
    }

    @MainActor
    func testLegacyJSONDecodesMissingVersionAndWeightFieldsWithoutInventingHistory() async throws {
        let url = try file()
        let initial = template()
        let history = WorkoutSession(templateID: initial.id, name: "Old Bench", startedAt: Date(timeIntervalSinceReferenceDate: 100), finishedAt: Date(timeIntervalSinceReferenceDate: 200), exercises: [WorkoutExercise(exercise: initial.exercises[0].exercise, sets: [WorkoutSet(weight: 125, reps: 7, isCompleted: true)])])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(WorkoutSnapshot(templates: [initial], history: [history], activeWorkout: nil, unit: .lb))) as? [String: Any])
        json["version"] = 1
        var templates = try XCTUnwrap(json["templates"] as? [[String: Any]])
        templates[0].removeValue(forKey: "versions")
        json["templates"] = templates
        let legacy = url.deletingPathExtension().appendingPathExtension("json")
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: legacy)
        let store = WorkoutStore(fileURL: url)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.templates[0].currentVersion?.exercises, initial.exercises)
        XCTAssertEqual(store.history, [history])
        XCTAssertEqual(try Data(contentsOf: legacy), original)
    }

    func testFailedV2MigrationRollsBackSchemaAndOriginalRecords() throws {
        let url = try file()
        let initial = template()
        let original = WorkoutSnapshot(templates: [initial], history: [], activeWorkout: nil, unit: .lb)
        let database = WorkoutDatabase(url: url)
        try database.save(original)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("DROP TABLE template_versions")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_id")
            try db.execute("ALTER TABLE records DROP COLUMN template_version_number")
            try db.execute("ALTER TABLE workout_sets DROP COLUMN target_weight")
            try db.execute("ALTER TABLE records DROP COLUMN rest_seconds")
            try db.execute("ALTER TABLE records DROP COLUMN rest_timer")
            try db.execute("DROP TABLE exercise_instruction_overrides")
            try db.execute("DROP TABLE favorite_exercises")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN superset_id")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.removeHistoryEditingSchema()
            try db.execute("PRAGMA user_version = 1")
            // Force failure after the transactional schema upgrade has run.
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'simulated interrupted upgrade'); END")
        }
        var upgraded = original
        upgraded.templates[0].versions = [WorkoutTemplateVersion(number: 1, name: initial.name, exercises: initial.exercises, unit: .lb)]
        XCTAssertThrowsError(try database.save(upgraded))
        XCTAssertEqual(try database.load().templates, original.templates)
        let db = try SQLiteConnection(url: url, readOnly: true)
        XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 1)
        XCTAssertFalse(try db.rows("PRAGMA table_info(records)").contains { try $0.text("name") == "template_version_id" })
        XCTAssertTrue(try db.rows("SELECT name FROM sqlite_master WHERE name = 'template_versions'").isEmpty)
    }
}
