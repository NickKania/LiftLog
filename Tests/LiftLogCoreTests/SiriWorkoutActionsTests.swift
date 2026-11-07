import Foundation
import XCTest
@testable import LiftLogCore

final class SiriWorkoutActionsTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiriTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func seeded(_ url: URL) throws -> (WorkoutStore, WorkoutSession) {
        let store = WorkoutStore(fileURL: url)
        _ = try SiriWorkoutActions.start(store: store, templateID: store.templates[0].id)
        return (store, try XCTUnwrap(store.activeWorkout))
    }

    @MainActor
    func testStartUsesLatestSavedTemplateAndPersistsIndependentSnapshot() throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        var template = store.templates[0]
        let selectedID = template.id
        template.name = "Latest name"
        template.exercises[0].sets[0].targetReps = 12
        XCTAssertTrue(store.saveTemplate(template))
        let templates = store.templates
        XCTAssertEqual(try SiriWorkoutActions.start(store: store, templateID: selectedID), "Started Latest name.")
        let workout = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(workout.templateVersionID, store.templates[0].currentVersion?.id)
        XCTAssertEqual(workout.exercises[0].sets[0].targetReps, 12)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, workout)
        XCTAssertEqual(store.templates, templates)
        XCTAssertThrowsError(try SiriWorkoutActions.start(store: store, templateID: nil))
        XCTAssertEqual(store.activeWorkout, workout)
    }

    @MainActor
    func testMissingTemplateDoesNotFallBackToEmptyWorkout() throws {
        let store = WorkoutStore(fileURL: try file())
        let revision = store.revision
        XCTAssertThrowsError(try SiriWorkoutActions.start(store: store, templateID: UUID()))
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.revision, revision)
        _ = try SiriWorkoutActions.start(store: store, templateID: nil)
        XCTAssertEqual(store.activeWorkout?.exercises, [])
    }

    @MainActor
    func testAddAllowsDuplicateMovementsWithDistinctEntriesAndNativeDefaults() throws {
        let url = try file()
        let (store, original) = try seeded(url)
        let templates = store.templates
        let movement = original.exercises[0].exercise
        for _ in 0..<2 {
            _ = try SiriWorkoutActions.add(store: store, exerciseID: movement.id, expectedWorkoutID: original.id)
        }
        let workout = try XCTUnwrap(store.activeWorkout)
        let added = Array(workout.exercises.suffix(2))
        XCTAssertEqual(added.map(\.exercise), [movement, movement])
        XCTAssertNotEqual(added[0].id, added[1].id)
        XCTAssertNotEqual(added[0].sets[0].id, added[1].sets[0].id)
        XCTAssertEqual(added[0].sets[0].weight, 0)
        XCTAssertEqual(added[0].sets[0].reps, 10)
        XCTAssertNil(added[0].sets[0].targetReps)
        XCTAssertNil(added[0].templateExerciseID)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, workout)
    }

    @MainActor
    func testCompletionPreservesValuesTargetsAndOtherSetsAndRejectsReplay() throws {
        let url = try file()
        let (store, initial) = try seeded(url)
        var edited = initial
        edited.exercises[0].sets[0].weight = 83
        edited.exercises[0].sets[0].reps = 5
        XCTAssertTrue(store.updateActiveWorkout(edited))
        XCTAssertTrue(store.updateRestSettings(workoutID: initial.id, exerciseID: initial.exercises[0].id, restSeconds: 45))
        let before = try XCTUnwrap(store.activeWorkout)
        let entry = before.exercises[0]
        _ = try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: before.id)
        let after = try XCTUnwrap(store.activeWorkout)
        var expected = entry
        expected.sets[0].isCompleted = true
        XCTAssertEqual(after.exercises[0], expected)
        XCTAssertEqual(Array(after.exercises.dropFirst()), Array(before.exercises.dropFirst()))
        XCTAssertEqual(after.restTimer?.durationSeconds, 45)
        XCTAssertEqual(after.restTimer?.completedSetID, entry.sets[0].id)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, after)
        let revision = store.revision
        XCTAssertThrowsError(try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: before.id))
        XCTAssertEqual(store.activeWorkout, after)
        XCTAssertEqual(store.revision, revision)
        _ = try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[1].id, expectedWorkoutID: before.id)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[0], expected.sets[0])
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[1].targetWeight, entry.sets[1].targetWeight)
        XCTAssertEqual(store.activeWorkout?.exercises[0].sets[1].targetReps, entry.sets[1].targetReps)
    }

    @MainActor
    func testRestOffAndLastSetDoNotStartCountdown() throws {
        let store = WorkoutStore(fileURL: try file())
        _ = try SiriWorkoutActions.start(store: store, templateID: nil)
        let id = try XCTUnwrap(store.activeWorkout?.id)
        _ = try SiriWorkoutActions.add(store: store, exerciseID: store.exercises[0].id, expectedWorkoutID: id)
        _ = try SiriWorkoutActions.add(store: store, exerciseID: store.exercises[1].id, expectedWorkoutID: id)
        _ = try SiriWorkoutActions.add(store: store, exerciseID: store.exercises[2].id, expectedWorkoutID: id)
        let entries = try XCTUnwrap(store.activeWorkout?.exercises)
        XCTAssertTrue(store.updateRestSettings(workoutID: id, exerciseID: entries[1].id, restSeconds: 0))
        _ = try SiriWorkoutActions.complete(store: store, entryID: entries[0].id, setID: entries[0].sets[0].id, expectedWorkoutID: id)
        XCTAssertNotNil(store.activeWorkout?.restTimer)
        _ = try SiriWorkoutActions.complete(store: store, entryID: entries[1].id, setID: entries[1].sets[0].id, expectedWorkoutID: id)
        XCTAssertNil(store.activeWorkout?.restTimer)
        _ = try SiriWorkoutActions.complete(store: store, entryID: entries[2].id, setID: entries[2].sets[0].id, expectedWorkoutID: id)
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testRemoveUsesEntryIdentityAndProtectsCompletedRecords() throws {
        let url = try file()
        let (store, original) = try seeded(url)
        let entry = original.exercises[0]
        _ = try SiriWorkoutActions.add(store: store, exerciseID: entry.exercise.id, expectedWorkoutID: original.id)
        let duplicate = try XCTUnwrap(store.activeWorkout?.exercises.last)
        _ = try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: original.id)
        let completed = store.activeWorkout
        XCTAssertThrowsError(try SiriWorkoutActions.remove(store: store, entryID: entry.id, expectedWorkoutID: original.id))
        XCTAssertEqual(store.activeWorkout, completed)
        _ = try SiriWorkoutActions.remove(store: store, entryID: duplicate.id, expectedWorkoutID: original.id)
        XCTAssertTrue(store.activeWorkout?.exercises.contains(where: { $0.id == entry.id }) == true)
        XCTAssertFalse(store.activeWorkout?.exercises.contains(where: { $0.id == duplicate.id }) == true)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
    }

    @MainActor
    func testFinishRejectsEmptyThenPersistsOnlyCompletedSets() throws {
        let url = try file()
        let (store, original) = try seeded(url)
        let templates = store.templates
        XCTAssertThrowsError(try SiriWorkoutActions.finish(store: store, expectedWorkoutID: original.id))
        XCTAssertEqual(store.activeWorkout, original)
        let entry = original.exercises[0]
        _ = try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: original.id)
        let completed = try XCTUnwrap(store.activeWorkout?.exercises[0].sets[0])
        _ = try SiriWorkoutActions.finish(store: store, expectedWorkoutID: original.id)
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.history[0].exercises.count, 1)
        XCTAssertEqual(store.history[0].exercises[0].sets, [completed])
        XCTAssertNil(store.history[0].restTimer)
        XCTAssertNotNil(store.history[0].finishedAt)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(WorkoutStore(fileURL: url).history, store.history)
        XCTAssertThrowsError(try SiriWorkoutActions.finish(store: store, expectedWorkoutID: original.id))
    }

    @MainActor
    func testStaleAndCrossEntryIDsCannotMutateLiveWorkout() throws {
        let (store, workout) = try seeded(file())
        let entry = workout.exercises[0]
        let revision = store.revision
        XCTAssertThrowsError(try SiriWorkoutActions.add(store: store, exerciseID: entry.exercise.id, expectedWorkoutID: UUID()))
        XCTAssertThrowsError(try SiriWorkoutActions.remove(store: store, entryID: entry.id, expectedWorkoutID: UUID()))
        XCTAssertThrowsError(try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: UUID()))
        XCTAssertThrowsError(try SiriWorkoutActions.finish(store: store, expectedWorkoutID: UUID()))
        XCTAssertThrowsError(try SiriWorkoutActions.add(store: store, exerciseID: UUID(), expectedWorkoutID: workout.id))
        XCTAssertThrowsError(try SiriWorkoutActions.remove(store: store, entryID: UUID(), expectedWorkoutID: workout.id))
        XCTAssertThrowsError(try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: workout.exercises[1].sets[0].id, expectedWorkoutID: workout.id))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.discardWorkout())
        _ = try SiriWorkoutActions.start(store: store, templateID: nil)
        let replacement = store.activeWorkout
        XCTAssertThrowsError(try SiriWorkoutActions.finish(store: store, expectedWorkoutID: workout.id))
        XCTAssertEqual(store.activeWorkout, replacement)
    }

    @MainActor
    func testFailedWritesRollBackEveryActionWithoutSpokenSuccess() throws {
        let url = try file()
        let (store, original) = try seeded(url)
        let entry = original.exercises[0]
        _ = try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[0].id, expectedWorkoutID: original.id)
        let before = store.activeWorkout
        let revision = store.revision
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SiriWorkoutActions.add(store: store, exerciseID: entry.exercise.id, expectedWorkoutID: original.id))
        XCTAssertThrowsError(try SiriWorkoutActions.remove(store: store, entryID: original.exercises[1].id, expectedWorkoutID: original.id))
        XCTAssertThrowsError(try SiriWorkoutActions.complete(store: store, entryID: entry.id, setID: entry.sets[1].id, expectedWorkoutID: original.id))
        XCTAssertThrowsError(try SiriWorkoutActions.finish(store: store, expectedWorkoutID: original.id)) { error in
            XCTAssertFalse(error.localizedDescription.contains(url.path))
        }
        XCTAssertEqual(store.activeWorkout, before)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertEqual(store.revision, revision)

        let emptyURL = try file()
        let empty = WorkoutStore(fileURL: emptyURL)
        try FileManager.default.removeItem(at: emptyURL)
        try FileManager.default.createDirectory(at: emptyURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SiriWorkoutActions.start(store: empty, templateID: nil))
        XCTAssertNil(empty.activeWorkout)
    }
}
