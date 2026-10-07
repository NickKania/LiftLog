import Foundation
import XCTest
@testable import LiftLogCore

/// Exercises the local backend's transaction boundaries and lifecycle invariants.
final class WorkoutStoreFlowTests: XCTestCase {
    private struct SavedWorkouts: Codable {
        var version = 1
        var templates: [WorkoutTemplate] = []
        var history: [WorkoutSession] = []
        var activeWorkout: WorkoutSession?
        var unit: WeightUnit = .lb
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiftLogFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    private func template(name: String = "Strength", weight: Double = 100) -> WorkoutTemplate {
        WorkoutTemplate(name: name, exercises: [
            TemplateExercise(exercise: Exercise(name: "Squat"), sets: [TemplateSet(weight: weight, targetReps: 5)])
        ])
    }

    private func completedWorkout() -> WorkoutSession {
        WorkoutSession(name: "Strength", finishedAt: Date(), exercises: [
            WorkoutExercise(exercise: Exercise(name: "Squat"), sets: [WorkoutSet(weight: 100, reps: 5, isCompleted: true)])
        ])
    }

    @MainActor
    func testDeletingHistoryPersistsAndPreservesOtherWorkoutData() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        for name in ["First", "Second"] {
            XCTAssertTrue(store.startWorkout(template: template(name: name)))
            var active = try XCTUnwrap(store.activeWorkout)
            active.exercises[0].sets[0].isCompleted = true
            XCTAssertTrue(store.updateActiveWorkout(active))
            XCTAssertTrue(store.finishWorkout())
        }
        XCTAssertTrue(store.startWorkout(template: template(name: "Active")))
        let active = store.activeWorkout
        let templates = store.templates
        let exercises = store.personalExercises
        let retained = try XCTUnwrap(store.history.last)
        let deleted = try XCTUnwrap(store.history.first)
        let revision = store.revision

        XCTAssertTrue(store.deleteWorkout(id: deleted.id))
        XCTAssertEqual(store.revision, revision + 1)
        XCTAssertEqual(store.history, [retained])
        let restored = WorkoutStore(fileURL: file)
        XCTAssertEqual(restored.history, [retained])
        XCTAssertEqual(restored.activeWorkout, active)
        XCTAssertEqual(restored.templates, templates)
        XCTAssertEqual(restored.personalExercises, exercises)

        // A history deletion cannot discard the active session.
        XCTAssertTrue(restored.deleteWorkout(id: try XCTUnwrap(active).id))
        XCTAssertEqual(restored.activeWorkout, active)
        XCTAssertEqual(restored.history, [retained])
        XCTAssertTrue(restored.deleteWorkout(id: retained.id))
        XCTAssertTrue(WorkoutStore(fileURL: file).history.isEmpty)
    }

    @MainActor
    func testFailedHistoryDeletionKeepsSessionAndCanRetry() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        let history = store.history
        let id = try XCTUnwrap(history.first).id
        let revision = store.revision
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: file.appendingPathComponent("sentinel"))

        XCTAssertFalse(store.deleteWorkout(id: id))
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(store.revision, revision)
        XCTAssertNotNil(store.errorMessage)

        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        XCTAssertEqual(WorkoutStore(fileURL: file).history, history)
        XCTAssertTrue(store.deleteWorkout(id: id))
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(WorkoutStore(fileURL: file).history.isEmpty)
    }

    @MainActor
    func testWhitespaceIsTrimmedForSavedTemplatesAndStartedSessions() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let draft = template(name: " \n Morning Strength \t")
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == draft.id }?.name, "Morning Strength")
        XCTAssertTrue(store.startWorkout(template: draft))
        XCTAssertEqual(store.activeWorkout?.name, "Morning Strength")
        let restored = WorkoutStore(fileURL: file)
        XCTAssertEqual(restored.activeWorkout, store.activeWorkout)
        XCTAssertEqual(restored.templates, store.templates)
    }

    @MainActor
    func testInvalidTemplateCannotStartOrChangePersistedData() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let saved = try Data(contentsOf: file)
        let templates = store.templates
        var invalid = template()
        invalid.exercises[0].exercise.name = " \n "
        XCTAssertFalse(store.startWorkout(template: invalid))
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.startWorkout())
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testDeletingSourceTemplateKeepsResumableWorkoutAndItsHistory() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let planned = template()
        XCTAssertTrue(store.saveTemplate(planned))
        XCTAssertTrue(store.startWorkout(template: planned))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.deleteTemplate(id: planned.id))
        XCTAssertEqual(store.activeWorkout, active)

        let restored = WorkoutStore(fileURL: file)
        XCTAssertFalse(restored.templates.contains { $0.id == planned.id })
        XCTAssertEqual(restored.activeWorkout, active)
        XCTAssertTrue(restored.finishWorkout())
        XCTAssertEqual(restored.history.first?.templateID, planned.id)
        XCTAssertEqual(restored.history.first?.exercises, active.exercises)
        XCTAssertEqual(WorkoutStore(fileURL: file).history, restored.history)
    }

    @MainActor
    func testFinishedSessionDraftCannotUpdateTheNextWorkout() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        var oldDraft = try XCTUnwrap(store.activeWorkout)
        oldDraft.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(oldDraft))
        XCTAssertTrue(store.finishWorkout())
        let firstHistory = store.history
        XCTAssertFalse(store.updateActiveWorkout(oldDraft))
        XCTAssertTrue(store.startWorkout())
        let nextWorkout = store.activeWorkout
        let saved = try Data(contentsOf: file)
        oldDraft.name = "Stale edit"
        XCTAssertFalse(store.updateActiveWorkout(oldDraft))
        XCTAssertEqual(store.activeWorkout, nextWorkout)
        XCTAssertEqual(store.history, firstHistory)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    @MainActor
    func testDiscardedSessionDraftCannotResurrectAWorkout() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        let stale = try XCTUnwrap(store.activeWorkout)
        XCTAssertTrue(store.discardWorkout())
        let saved = try Data(contentsOf: file)
        XCTAssertFalse(store.updateActiveWorkout(stale))
        XCTAssertFalse(store.finishWorkout())
        XCTAssertNil(store.activeWorkout)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertTrue(store.discardWorkout())
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testSuccessiveFinishesPersistNewestFirstWithoutDuplicatingHistory() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var ids: [UUID] = []
        for name in ["First", "Second", "Third"] {
            XCTAssertTrue(store.startWorkout(template: template(name: name)))
            var active = try XCTUnwrap(store.activeWorkout)
            active.exercises[0].sets[0].isCompleted = true
            ids.append(active.id)
            XCTAssertTrue(store.updateActiveWorkout(active))
            XCTAssertTrue(store.finishWorkout())
        }
        XCTAssertEqual(store.history.map(\.id), Array(ids.reversed()))
        XCTAssertEqual(store.history.map(\.name), ["Third", "Second", "First"])
        let saved = try Data(contentsOf: file)
        XCTAssertFalse(store.finishWorkout())
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertEqual(WorkoutStore(fileURL: file).history, store.history)
    }

    @MainActor
    func testInvalidSessionNamesAndDuplicateExercisesLeaveDiskAndMemoryUnchanged() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        let active = try XCTUnwrap(store.activeWorkout)
        let saved = try Data(contentsOf: file)
        var invalidName = active
        invalidName.name = "\n\t"
        var invalidExercise = active
        invalidExercise.exercises[0].exercise.name = " "
        var duplicates = active
        duplicates.exercises.append(duplicates.exercises[0])
        for invalid in [invalidName, invalidExercise, duplicates] {
            XCTAssertFalse(store.updateActiveWorkout(invalid))
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.activeWorkout, active)
            XCTAssertEqual(try Data(contentsOf: file), saved)
        }
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testConversionOverflowFailsAtomicallyAndPreservesUnit() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.setUnit(.kg))
        let heavy = template(weight: .greatestFiniteMagnitude)
        XCTAssertTrue(store.saveTemplate(heavy))
        let templates = store.templates
        let saved = try Data(contentsOf: file)
        XCTAssertFalse(store.setUnit(.lb))
        XCTAssertEqual(store.unit, .kg)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(try Data(contentsOf: file), saved)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.deleteTemplate(id: heavy.id))
        XCTAssertTrue(store.setUnit(.lb))
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testInitialWriteFailureCanRecoverAndPersistStarterTemplates() async throws {
        let file = try temporaryFile()
        let parent = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: parent)
        try Data("blocking parent".utf8).write(to: parent)
        let store = WorkoutStore(fileURL: file)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.templates.isEmpty)
        XCTAssertFalse(store.startWorkout())
        XCTAssertNil(store.activeWorkout)
        try FileManager.default.removeItem(at: parent)
        XCTAssertTrue(store.startWorkout())
        XCTAssertNil(store.errorMessage)
        let restored = WorkoutStore(fileURL: file)
        XCTAssertEqual(restored.templates, store.templates)
        XCTAssertEqual(restored.activeWorkout, store.activeWorkout)
    }

    @MainActor
    func testSemanticallyInvalidSnapshotsArePreservedAndAllWritesBlocked() async throws {
        let completed = completedWorkout()
        let planned = template()
        var unfinishedHistory = completed
        unfinishedHistory.finishedAt = nil
        var emptyHistory = completed
        emptyHistory.exercises = []
        var emptySets = completed
        emptySets.exercises[0].sets = []
        var incompleteSets = completed
        incompleteSets.exercises[0].sets[0].isCompleted = false
        var activeAlsoInHistory = completed
        activeAlsoInHistory.finishedAt = nil
        var duplicateItems = completed
        duplicateItems.exercises.append(duplicateItems.exercises[0])
        let cases: [(String, SavedWorkouts)] = [
            ("duplicate templates", SavedWorkouts(templates: [planned, planned])),
            ("duplicate history", SavedWorkouts(history: [completed, completed])),
            ("unfinished history", SavedWorkouts(history: [unfinishedHistory])),
            ("empty history", SavedWorkouts(history: [emptyHistory])),
            ("empty history sets", SavedWorkouts(history: [emptySets])),
            ("incomplete history sets", SavedWorkouts(history: [incompleteSets])),
            ("finished active workout", SavedWorkouts(activeWorkout: completed)),
            ("active workout in history", SavedWorkouts(history: [completed], activeWorkout: activeAlsoInHistory)),
            ("duplicate history exercises", SavedWorkouts(history: [duplicateItems]))
        ]
        for (name, snapshot) in cases {
            let file = try temporaryFile()
            let original = try JSONEncoder().encode(snapshot)
            let legacy = file.deletingPathExtension().appendingPathExtension("json")
            try original.write(to: legacy)
            let store = WorkoutStore(fileURL: file)
            XCTAssertNotNil(store.errorMessage, name)
            XCTAssertTrue(store.templates.isEmpty, name)
            XCTAssertTrue(store.history.isEmpty, name)
            XCTAssertNil(store.activeWorkout, name)
            XCTAssertFalse(store.saveTemplate(planned), name)
            XCTAssertFalse(store.deleteTemplate(id: planned.id), name)
            XCTAssertFalse(store.startWorkout(), name)
            XCTAssertFalse(store.discardWorkout(), name)
            XCTAssertFalse(store.setUnit(.kg), name)
            XCTAssertEqual(try Data(contentsOf: legacy), original, name)
        }
    }
}
