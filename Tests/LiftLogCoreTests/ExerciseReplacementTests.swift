import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseReplacementTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ExerciseReplacement-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    private func template() -> WorkoutTemplate {
        let group = UUID()
        return WorkoutTemplate(name: "Synthetic swap plan", exercises: [
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: [TemplateSet(weight: 50, targetReps: 6), TemplateSet(weight: 55, targetReps: 8)], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[1], supersetID: group),
            TemplateExercise(exercise: ExerciseCatalog.all[2])
        ], restSeconds: 75)
    }

    func testTemplateDraftReplacementResetsLoadsAndIdentitiesPreservingPositionRepsAndGroup() throws {
        let original = template()
        let before = original.exercises[0]
        let updated = try ExerciseReplacement.replacing(original, expectedEntry: before, with: ExerciseCatalog.all[3])
        let replaced = updated.exercises[0]
        XCTAssertNotEqual(replaced.id, before.id)
        XCTAssertTrue(Set(replaced.sets.map(\.id)).isDisjoint(with: before.sets.map(\.id)))
        XCTAssertEqual(replaced.exercise, ExerciseCatalog.all[3])
        XCTAssertEqual(replaced.sets.map(\.weight), [0, 0])
        XCTAssertEqual(replaced.sets.map(\.targetReps), [6, 8])
        XCTAssertEqual(replaced.supersetID, before.supersetID)
        XCTAssertEqual(Array(updated.exercises.dropFirst()), Array(original.exercises.dropFirst()))
        XCTAssertEqual(updated.restSeconds, original.restSeconds)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(original.exercises[0], before)
    }

    func testPureHelpersRejectStaleSameIdentityCompletedAndFinishedChanges() throws {
        var plan = template()
        let expected = plan.exercises[0]
        XCTAssertThrowsError(try ExerciseReplacement.replacing(plan, expectedEntry: expected, with: expected.exercise))
        plan.exercises[0].sets[0].targetReps = 10
        XCTAssertThrowsError(try ExerciseReplacement.replacing(plan, expectedEntry: expected, with: ExerciseCatalog.all[3]))
        var session = WorkoutSession(exercises: [WorkoutExercise(exercise: expected.exercise)])
        var entry = session.exercises[0]
        session.exercises[0].sets[0].weight = 5
        XCTAssertThrowsError(try ExerciseReplacement.replacing(session, expectedEntry: entry, with: ExerciseCatalog.all[3]))
        session.exercises[0].sets[0].isCompleted = true
        entry = session.exercises[0]
        XCTAssertThrowsError(try ExerciseReplacement.replacing(session, expectedEntry: entry, with: ExerciseCatalog.all[3]))
        session.exercises[0].sets[0].isCompleted = false
        session.finishedAt = session.startedAt
        entry = session.exercises[0]
        XCTAssertThrowsError(try ExerciseReplacement.replacing(session, expectedEntry: entry, with: ExerciseCatalog.all[3]))
    }

    @MainActor
    func testSavingTemplateSwapCreatesVersionWithoutChangingActiveOrHistoryAndRelaunches() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let original = template()
        XCTAssertTrue(store.saveTemplate(original))
        let saved = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.startWorkout(template: saved))
        var finished = try XCTUnwrap(store.activeWorkout)
        finished.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(finished))
        XCTAssertTrue(store.finishWorkout())
        let history = store.history
        XCTAssertTrue(store.startWorkout(template: saved))
        let active = store.activeWorkout
        let draft = try ExerciseReplacement.replacing(saved, expectedEntry: saved.exercises[0], with: ExerciseCatalog.all[3])
        XCTAssertEqual(store.templates.first { $0.id == saved.id }, saved)
        XCTAssertTrue(store.saveTemplate(draft))
        let updated = try XCTUnwrap(store.templates.first { $0.id == saved.id })
        XCTAssertEqual(updated.versions.count, 2)
        XCTAssertEqual(updated.versions[0], saved.versions[0])
        XCTAssertEqual(updated.versions[1].exercises, draft.exercises)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertEqual(store.history, history)
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertEqual(reloaded.templates.first { $0.id == updated.id }, updated)
        XCTAssertEqual(reloaded.activeWorkout, active)
        XCTAssertEqual(reloaded.history, history)
    }

    @MainActor
    func testActiveSwapClearsTargetsLoadsAndIDsPreservesOtherWorkRestAttributionAndRelaunch() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let plan = template()
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        var before = try XCTUnwrap(store.activeWorkout)
        before.exercises[1].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(before, now: Date(timeIntervalSince1970: 100)))
        before = try XCTUnwrap(store.activeWorkout)
        let templates = store.templates
        let history = store.history
        let expected = before.exercises[0]
        XCTAssertTrue(store.replaceActiveExercise(in: before.id, expectedEntry: expected, with: ExerciseCatalog.all[3].id))
        let after = try XCTUnwrap(store.activeWorkout)
        let replacement = after.exercises[0]
        XCTAssertEqual(replacement.exercise, ExerciseCatalog.all[3])
        XCTAssertNotEqual(replacement.id, expected.id)
        XCTAssertTrue(Set(replacement.sets.map(\.id)).isDisjoint(with: expected.sets.map(\.id)))
        XCTAssertEqual(replacement.sets.map(\.weight), [0, 0])
        XCTAssertEqual(replacement.sets.map(\.reps), [6, 8])
        XCTAssertTrue(replacement.sets.allSatisfy { $0.targetWeight == nil && $0.targetReps == nil && !$0.isCompleted })
        XCTAssertEqual(replacement.supersetID, expected.supersetID)
        var expectedSession = before
        expectedSession.exercises[0] = replacement
        XCTAssertEqual(after, expectedSession)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, after)
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backup)
        XCTAssertEqual(try WorkoutDatabase(url: backup).load().activeWorkout, after)
        XCTAssertTrue(store.discardWorkout())
        try store.restoreDatabase(from: backup)
        XCTAssertEqual(store.activeWorkout, after)
    }

    @MainActor
    func testStoreRejectsStaleSessionEntryMissingCandidateCompletedAndSameIdentityWithoutPublishing() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertTrue(store.startWorkout(template: template()))
        var active = try XCTUnwrap(store.activeWorkout)
        let expected = active.exercises[0]
        let candidate = ExerciseCatalog.all[3].id
        XCTAssertFalse(store.replaceActiveExercise(in: UUID(), expectedEntry: expected, with: candidate))
        XCTAssertFalse(store.replaceActiveExercise(in: active.id, expectedEntry: expected, with: UUID()))
        XCTAssertFalse(store.replaceActiveExercise(in: active.id, expectedEntry: expected, with: expected.exercise.id))
        XCTAssertEqual(store.activeWorkout, active)
        active.exercises[0].sets[0].weight = 99
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertFalse(store.replaceActiveExercise(in: active.id, expectedEntry: expected, with: candidate))
        active = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(active.exercises[0].sets[0].weight, 99)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        active = try XCTUnwrap(store.activeWorkout)
        XCTAssertFalse(store.replaceActiveExercise(in: active.id, expectedEntry: active.exercises[0], with: candidate))
        XCTAssertEqual(store.activeWorkout, active)
    }

    @MainActor
    func testRestoreBlockingAndDatabaseFailureKeepExactStateAndPersistedData() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        XCTAssertTrue(store.startWorkout(template: template()))
        let before = try XCTUnwrap(store.activeWorkout)
        let revision = store.revision
        let persisted = try WorkoutDatabase(url: url).load()
        store.beginRestore()
        XCTAssertFalse(store.replaceActiveExercise(in: before.id, expectedEntry: before.exercises[0], with: ExerciseCatalog.all[3].id))
        XCTAssertEqual(store.activeWorkout, before)
        XCTAssertEqual(store.revision, revision)
        store.endRestore()
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("CREATE TRIGGER reject_swap BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END")
        }
        XCTAssertFalse(store.replaceActiveExercise(in: before.id, expectedEntry: before.exercises[0], with: ExerciseCatalog.all[3].id))
        XCTAssertEqual(store.activeWorkout, before)
        XCTAssertEqual(store.revision, revision)
        let afterFailure = try WorkoutDatabase(url: url).load()
        XCTAssertEqual(afterFailure.activeWorkout, persisted.activeWorkout)
        XCTAssertEqual(afterFailure.templates, persisted.templates)
        XCTAssertEqual(afterFailure.history, persisted.history)
        XCTAssertEqual(afterFailure.personalExercises, persisted.personalExercises)
        XCTAssertNotNil(store.errorMessage)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("DROP TRIGGER reject_swap")
        }
        XCTAssertTrue(store.replaceActiveExercise(in: before.id, expectedEntry: before.exercises[0], with: ExerciseCatalog.all[3].id))
    }

    @MainActor
    func testGenericReplacementCannotCarryOriginalTargetsOntoDifferentMovement() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertTrue(store.startWorkout(template: template()))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].exercise = ExerciseCatalog.all[3]
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertTrue(try XCTUnwrap(store.activeWorkout).exercises[0].sets.allSatisfy { $0.targetReps == nil && $0.targetWeight == nil })
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        let before = store.activeWorkout
        workout = try XCTUnwrap(before)
        workout.exercises[0].exercise = ExerciseCatalog.all[4]
        XCTAssertFalse(store.updateActiveWorkout(workout))
        XCTAssertEqual(store.activeWorkout, before)
    }
}
