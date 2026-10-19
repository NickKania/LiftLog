import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutHistoryEditingTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryEditing-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    private func session(imported: Bool = false) -> WorkoutSession {
        WorkoutSession(name: "Recorded workout", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_003_600), unit: .kg,
            importSourceKey: imported ? "strong:synthetic" : nil,
            exercises: [WorkoutExercise(exercise: ExerciseCatalog.all[0], sets: [
                WorkoutSet(weight: 40, reps: 8, isCompleted: true),
                WorkoutSet(weight: 45, reps: 6, isCompleted: true)
            ])])
    }

    @MainActor
    func testCorrectionRelaunchUndoAndImportDuplicateProtection() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let original = session(imported: true)
        XCTAssertNotNil(store.importWorkouts([original]))
        XCTAssertTrue(store.startWorkout())
        let active = store.activeWorkout
        let templates = store.templates
        var draft = original
        draft.name = "  Corrected workout  "
        draft.startedAt = original.startedAt.addingTimeInterval(-86_400)
        draft.finishedAt = draft.startedAt.addingTimeInterval(2700)
        draft.exercises[0].sets[0].weight = 52.5
        draft.exercises[0].sets[0].reps = 9
        draft.notes = "  Session note  "
        draft.exercises[0].notes = "Exercise note"
        XCTAssertTrue(store.saveHistoryWorkout(draft, replacing: original), store.errorMessage ?? "")
        let corrected = try XCTUnwrap(store.history.first)
        XCTAssertEqual(corrected.exercises[0].sets[1], original.exercises[0].sets[1])
        XCTAssertEqual(corrected.exercises[0].id, original.exercises[0].id)
        XCTAssertEqual(corrected.exercises[0].sets[0].id, original.exercises[0].sets[0].id)
        XCTAssertEqual(corrected.notes, "Session note")
        XCTAssertEqual(corrected.importSourceKey, original.importSourceKey)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertEqual(store.templates, templates)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.history, [corrected])
        XCTAssertEqual(reloaded.historyRecovery, [original])
        XCTAssertEqual(reloaded.importWorkouts([original])?.skippedDuplicateCount, 1)
        XCTAssertTrue(reloaded.undoHistoryCorrection(replacing: corrected))
        XCTAssertEqual(WorkoutStore(fileURL: url).history, [original])
        XCTAssertTrue(reloaded.historyRecovery.isEmpty)
    }

    @MainActor
    func testValidationStalenessDeletionAndRestoreBlocking() async throws {
        let store = WorkoutStore(fileURL: try file())
        let original = session()
        XCTAssertTrue(store.saveHistoryWorkout(original, replacing: nil))
        var invalid = original
        invalid.finishedAt = original.startedAt.addingTimeInterval(-1)
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
        invalid = original
        invalid.exercises[0].sets[0].weight = .infinity
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
        invalid = original
        invalid.notes = String(repeating: "x", count: 10_001)
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
        invalid = original
        invalid.exercises[0].sets[0].isCompleted = false
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
        XCTAssertEqual(store.history, [original])
        XCTAssertTrue(store.historyRecovery.isEmpty)
        store.beginRestore()
        invalid = original
        invalid.name = "Correction"
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
        store.endRestore()
        XCTAssertTrue(store.saveHistoryWorkout(invalid, replacing: original))
        XCTAssertFalse(store.saveHistoryWorkout(original, replacing: original))
        XCTAssertFalse(store.undoHistoryCorrection(replacing: original))
        XCTAssertTrue(store.deleteWorkout(id: original.id))
        XCTAssertTrue(store.historyRecovery.isEmpty)
        XCTAssertFalse(store.saveHistoryWorkout(invalid, replacing: original))
    }

    @MainActor
    func testFailedCorrectionAndUndoPublishNothingAndCanRetry() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let original = session()
        XCTAssertTrue(store.saveHistoryWorkout(original, replacing: nil))
        var draft = original
        draft.name = "Corrected"
        draft.exercises.append(WorkoutExercise(exercise: Exercise(name: "Added correction exercise", category: "Custom"), sets: [WorkoutSet(isCompleted: true)]))
        let db = try SQLiteConnection(url: url)
        try db.execute("CREATE TRIGGER reject_history BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertFalse(store.saveHistoryWorkout(draft, replacing: original))
        XCTAssertEqual(store.history, [original])
        XCTAssertTrue(store.historyRecovery.isEmpty)
        XCTAssertFalse(store.personalExercises.contains { $0.name == "Added correction exercise" })
        XCTAssertEqual(try WorkoutDatabase(url: url).load().history, [original])
        try db.execute("DROP TRIGGER reject_history")
        XCTAssertTrue(store.saveHistoryWorkout(draft, replacing: original))
        XCTAssertTrue(store.personalExercises.contains { $0.name == "Added correction exercise" })
        try db.execute("CREATE TRIGGER reject_history BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertFalse(store.undoHistoryCorrection(replacing: draft))
        XCTAssertEqual(store.history, [draft])
        XCTAssertEqual(store.historyRecovery, [original])
        try db.execute("DROP TRIGGER reject_history")
        XCTAssertTrue(store.undoHistoryCorrection(replacing: draft))
    }

    func testSourceTargetsAndUnitsCannotBeRewrittenAndAddedRowsHaveNoTargets() throws {
        var original = session(imported: true)
        original.exercises[0].sets[0].targetReps = 10
        original.exercises[0].sets[0].targetWeight = 50
        for change in 0..<5 {
            var draft = original
            switch change {
            case 0: draft.unit = .lb
            case 1: draft.importSourceKey = "changed"
            case 2: draft.exercises[0].exercise = ExerciseCatalog.all[1]
            case 3: draft.exercises[0].sets[0].targetWeight = nil
            default: draft.exercises[0].sets[0].targetReps = 9
            }
            XCTAssertThrowsError(try WorkoutHistoryEditing.validated(draft, replacing: original))
        }
        var draft = original
        draft.exercises[0].sets[0].weight = 55
        draft.exercises[0].sets.removeLast()
        draft.exercises[0].sets.append(WorkoutSet(weight: 20, reps: 12, isCompleted: true))
        draft.exercises.append(WorkoutExercise(exercise: ExerciseCatalog.all[1], sets: [WorkoutSet(isCompleted: true)]))
        let saved = try WorkoutHistoryEditing.validated(draft, replacing: original)
        XCTAssertEqual(saved.exercises[0].sets[0].targetWeight, 50)
        XCTAssertNil(saved.exercises[0].sets[1].targetWeight)
        XCTAssertNil(saved.exercises[1].templateExerciseID)
        XCTAssertThrowsError(try WorkoutHistoryEditing.validated(original))
    }

    @MainActor
    func testManualPastWorkoutRegistersCustomOnlyOnSaveAndRejectsDuplicateID() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var manual = session()
        manual.exercises[0].exercise = Exercise(name: "Synthetic custom movement", category: "Custom")
        manual.exercises[0].sets[0].reps = 0
        XCTAssertFalse(store.saveHistoryWorkout(manual, replacing: nil))
        XCTAssertFalse(store.personalExercises.contains { $0.name == "Synthetic custom movement" })
        manual.exercises[0].sets[0].reps = 8
        XCTAssertTrue(store.saveHistoryWorkout(manual, replacing: nil))
        XCTAssertFalse(store.saveHistoryWorkout(manual, replacing: nil))
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.history, [manual])
        XCTAssertTrue(reloaded.personalExercises.contains { $0.id == manual.exercises[0].exercise.id })
        XCTAssertTrue(reloaded.historyRecovery.isEmpty)
    }

    @MainActor
    func testBackupRestoreIncludesNotesAndPreviousRecord() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let original = session()
        XCTAssertTrue(store.saveHistoryWorkout(original, replacing: nil))
        var corrected = original
        corrected.notes = "Session note"
        corrected.exercises[0].notes = "Exercise note"
        XCTAssertTrue(store.saveHistoryWorkout(corrected, replacing: original))
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        let bytes = try Data(contentsOf: backup)
        XCTAssertTrue(store.deleteWorkout(id: original.id))
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.history, [corrected])
        XCTAssertEqual(store.historyRecovery, [original])
        XCTAssertTrue(store.undoHistoryCorrection(replacing: corrected))
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    @MainActor
    func testProgressAndAssistantChartsRecomputeAfterCorrectionUndoAndDeletion() async throws {
        let store = WorkoutStore(fileURL: try file())
        let original = session()
        XCTAssertTrue(store.saveHistoryWorkout(original, replacing: nil))
        let tools = WorkoutAgentTools(store: store)
        func chart() throws -> WorkoutAgentChart {
            let arguments = "{\"metric\":\"max_weight\",\"unit\":\"kg\"}"
            return try XCTUnwrap(tools.execute(name: "graph_workout_history", arguments: arguments).chart)
        }
        func dashboard() -> HealthDashboardAnalytics {
            HealthDashboardAnalytics(workouts: store.history, unit: .kg, range: .all)
        }
        XCTAssertEqual(dashboard().personalRecords.first?.weight, 45)
        var correction = original
        correction.exercises[0].sets[0].weight = 60
        XCTAssertTrue(store.saveHistoryWorkout(correction, replacing: original))
        XCTAssertEqual(dashboard().personalRecords.first?.weight, 60)
        XCTAssertEqual(try chart().points.first?.value, 60)
        XCTAssertTrue(store.undoHistoryCorrection(replacing: correction))
        XCTAssertEqual(dashboard().personalRecords.first?.weight, 45)
        XCTAssertEqual(try chart().points.first?.value, 45)
        XCTAssertTrue(store.deleteWorkout(id: original.id))
        XCTAssertTrue(dashboard().personalRecords.isEmpty)
        XCTAssertTrue(try chart().points.isEmpty)
    }

    func testRemovingSupersetMemberKeepsRemainingIdentitiesAndClearsOrphanGroup() throws {
        var original = session()
        let group = UUID()
        original.exercises[0].supersetID = group
        original.exercises.append(WorkoutExercise(exercise: ExerciseCatalog.all[1], sets: [WorkoutSet(isCompleted: true)], supersetID: group))
        var correction = original
        correction.exercises.removeLast()
        let result = try WorkoutHistoryEditing.validated(correction, replacing: original)
        XCTAssertNil(result.exercises[0].supersetID)
        XCTAssertEqual(result.exercises[0].id, original.exercises[0].id)
        XCTAssertEqual(result.exercises[0].sets, original.exercises[0].sets)
    }

    func testSchemaSevenReadOnlyAndFailedUpgradeRollbackThenRetry() throws {
        let url = try file()
        let database = WorkoutDatabase(url: url)
        let original = session()
        try database.save(WorkoutSnapshot(templates: [], history: [original], activeWorkout: nil, unit: .lb))
        let db = try SQLiteConnection(url: url)
        try db.removeHistoryEditingSchema()
        try db.execute("PRAGMA user_version = 7")
        try db.execute("CREATE TRIGGER reject_upgrade BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        let bytes = try Data(contentsOf: url)
        var loaded = try database.load()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNil(loaded.history[0].notes)
        XCTAssertTrue(loaded.historyRecovery.isEmpty)
        loaded.historyRecovery = [original]
        loaded.history[0].notes = "New note"
        XCTAssertThrowsError(try database.save(loaded))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 7)
        try db.execute("DROP TRIGGER reject_upgrade")
        try database.save(loaded)
        XCTAssertEqual(try database.load().historyRecovery, [original])
        XCTAssertEqual(try database.load().history[0].notes, "New note")
    }

    func testLegacyJSONDefaultsAndInvalidRecoveryAreRejected() throws {
        let original = session()
        let snapshot = WorkoutSnapshot(templates: [], history: [original], activeWorkout: nil, unit: .lb)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "historyRecovery")
        let legacy = try JSONDecoder().decode(WorkoutSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.historyRecovery.isEmpty)
        XCTAssertEqual(legacy.history, [original])
        var invalid = snapshot
        invalid.historyRecovery = [session()]
        XCTAssertThrowsError(try WorkoutStore.validate(invalid))
        invalid.historyRecovery = [original, original]
        XCTAssertThrowsError(try WorkoutStore.validate(invalid))
    }
}
