import Foundation
import XCTest
@testable import LiftLogCore

final class WatchWorkoutActionTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatchTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func start(_ store: WorkoutStore, restSeconds: Int = 75, exerciseRestSeconds: Int? = nil) throws -> WorkoutSession {
        let group = UUID()
        let template = WorkoutTemplate(name: "Watch routine", exercises: [
            TemplateExercise(exercise: ExerciseCatalog.all[0], sets: (0..<3).map { _ in
                TemplateSet(weight: 50, targetReps: 8)
            }, supersetID: group, restSeconds: exerciseRestSeconds),
            TemplateExercise(exercise: ExerciseCatalog.all[1], sets: [TemplateSet(weight: 20, targetReps: 10)], supersetID: group)
        ], restSeconds: restSeconds)
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.applyWatchAction(.startTemplate(id: template.id)))
        return try XCTUnwrap(store.activeWorkout)
    }

    @MainActor
    func testWatchCompletionPreservesExerciseRestOverridesAndTimerIdentity() async throws {
        for (sessionDuration, override) in [(120, 45 as Int?), (120, 0), (120, nil), (0, 45)] {
            let url = try file()
            let store = WorkoutStore(fileURL: url)
            let workout = try start(store, restSeconds: sessionDuration, exerciseRestSeconds: override)
            let completedAt = Date(timeIntervalSinceReferenceDate: 1000)
            let deliveredAt = completedAt.addingTimeInterval(7200)
            let timerID = UUID()
            let action = WatchAction.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8,
                                                 completedAt: completedAt, restTimerID: timerID)
            let mirror = store.watchWorkoutState.applyingOptimistically(action)
            XCTAssertEqual(mirror.active?.exercises[0].restSeconds, override)
            XCTAssertTrue(store.applyWatchAction(action, now: deliveredAt))
            XCTAssertEqual(mirror.active, store.watchWorkoutState.active)
            let duration = override ?? sessionDuration
            if duration == 0 {
                XCTAssertNil(store.activeWorkout?.restTimer)
                XCTAssertNil(mirror.active?.restDurationSeconds)
            } else {
                XCTAssertEqual(store.activeWorkout?.restTimer?.id, timerID)
                XCTAssertEqual(store.activeWorkout?.restTimer?.durationSeconds, duration)
                XCTAssertEqual(mirror.active?.restDurationSeconds, duration)
                XCTAssertEqual(mirror.active?.restEndsAt, completedAt.addingTimeInterval(TimeInterval(duration)))
            }
            XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
        }
    }

    @MainActor
    func testOverrideExtensionsMatchOfflineMirrorAfterSettingsChangeAndRelaunch() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store, restSeconds: 120, exerciseRestSeconds: 45)
        let completedAt = Date(timeIntervalSinceReferenceDate: 1000)
        let timerID = UUID()
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8,
                                                         completedAt: completedAt, restTimerID: timerID), now: completedAt))
        // Future completions use new settings; this timer still has its captured 45 seconds.
        XCTAssertTrue(store.updateRestSettings(workoutID: workout.id, exerciseID: workout.exercises[0].id, restSeconds: 0))
        XCTAssertEqual(store.watchWorkoutState.active?.restDurationSeconds, 45)
        var mirror = store.watchWorkoutState
        for (requestedAt, seconds, expectedDuration, expectedRemaining) in [
            (completedAt.addingTimeInterval(10), 30, 75, 65),
            (completedAt.addingTimeInterval(75), 30, 30, 30),
            (completedAt.addingTimeInterval(76), Int.max, 3600, 3600)
        ] {
            let previousID = try XCTUnwrap(mirror.active?.restTimerID)
            let expired = try XCTUnwrap(mirror.active?.restEndsAt) <= requestedAt
            let newID = UUID()
            let action = try XCTUnwrap(mirror.restExtensionAction(by: seconds, at: requestedAt, newTimerID: newID))
            mirror = mirror.applyingOptimistically(action)
            XCTAssertTrue(store.applyWatchAction(action, now: completedAt.addingTimeInterval(7200)))
            let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
            XCTAssertEqual(timer.id, expired ? newID : previousID)
            XCTAssertEqual(timer.durationSeconds, expectedDuration)
            XCTAssertEqual(timer.endsAt, requestedAt.addingTimeInterval(TimeInterval(expectedRemaining)))
            XCTAssertEqual(mirror.active, store.watchWorkoutState.active)
            XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
        }
        let skip = WatchAction.skipRest(workoutID: workout.id, restTimerID: try XCTUnwrap(mirror.active?.restTimerID))
        XCTAssertTrue(store.applyWatchAction(skip))
        XCTAssertEqual(mirror.applyingOptimistically(skip).active, store.watchWorkoutState.active)
        XCTAssertNil(store.watchWorkoutState.active?.restDurationSeconds)
    }

    @MainActor
    func testStartTemplateCopiesPrescriptionAndRejectsUnknownOrAlreadyActiveStart() async throws {
        let store = WorkoutStore(fileURL: try file())
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: UUID())))
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.errorMessage)
        let workout = try start(store)
        let template = try XCTUnwrap(store.templates.first { $0.id == workout.templateID })
        XCTAssertEqual(workout.name, template.name)
        XCTAssertEqual(workout.templateVersionID, template.currentVersion?.id)
        XCTAssertEqual(workout.restSeconds, 75)
        XCTAssertEqual(workout.exercises[0].sets[0].targetWeight, 50)
        XCTAssertEqual(workout.exercises[0].sets[0].targetReps, 8)
        XCTAssertNotEqual(workout.exercises[0].sets[0].id, template.exercises[0].sets[0].id)
        let activeRevision = store.revision
        XCTAssertFalse(store.applyWatchAction(.startEmpty))
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: template.id)))
        XCTAssertFalse(store.applyWatchAction(.startTemplate(id: UUID())))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.revision, activeRevision)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStartEmptyAndFinishRequiresCompletedWork() async throws {
        let store = WorkoutStore(fileURL: try file())
        XCTAssertTrue(store.applyWatchAction(.startEmpty))
        let empty = try XCTUnwrap(store.activeWorkout)
        XCTAssertTrue(empty.exercises.isEmpty)
        XCTAssertFalse(store.applyWatchAction(.finish(workoutID: empty.id)))
        XCTAssertEqual(store.activeWorkout, empty)
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor
    func testCompletePropagatesLikePhonePreservingCompletedSetsTargetsAndOtherEntries() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let sets = workout.exercises[0].sets
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 55, reps: 7, completedAt: Date(), restTimerID: UUID())))
        let firstCompleted = try XCTUnwrap(store.activeWorkout?.exercises[0].sets[0])
        // Complete out of order: phone numeric edits affect earlier incomplete sets too.
        let before = Date()
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[2].id, weight: 60, reps: 6, completedAt: Date(), restTimerID: UUID())))
        let updated = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(updated.exercises[0].sets[0], firstCompleted)
        XCTAssertEqual(updated.exercises[0].sets[1].weight, 60)
        XCTAssertEqual(updated.exercises[0].sets[1].reps, 6)
        XCTAssertFalse(updated.exercises[0].sets[1].isCompleted)
        XCTAssertEqual(updated.exercises[0].sets[2].weight, 60)
        XCTAssertTrue(updated.exercises[0].sets[2].isCompleted)
        XCTAssertEqual(updated.exercises[0].sets.map(\.targetWeight), [50, 50, 50])
        XCTAssertEqual(updated.exercises[0].sets.map(\.targetReps), [8, 8, 8])
        XCTAssertEqual(updated.exercises[1], workout.exercises[1])
        let timer = try XCTUnwrap(updated.restTimer)
        XCTAssertEqual(timer.completedSetID, sets[2].id)
        XCTAssertGreaterThanOrEqual(timer.endsAt, before.addingTimeInterval(75))
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, updated)
    }

    @MainActor
    func testDuplicateCompletionIsFalseWithoutWritesOrRestRestartEvenWithDifferentValues() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        let action = WatchAction.completeSet(setID: id, weight: 55, reps: 7, completedAt: Date(), restTimerID: UUID())
        XCTAssertTrue(store.applyWatchAction(action))
        let completed = store.activeWorkout
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(action))
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 1, reps: 1, completedAt: Date(), restTimerID: UUID())))
        XCTAssertEqual(store.activeWorkout, completed)
        XCTAssertEqual(store.revision, revision)
    }

    @MainActor
    func testFinalCompletionClearsRestAndUndoTriggerClearsRest() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let sets = workout.exercises.flatMap(\.sets)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        XCTAssertNotNil(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.uncompleteSet(setID: sets[0].id)))
        XCTAssertNil(store.activeWorkout?.restTimer)
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.uncompleteSet(setID: sets[0].id)))
        XCTAssertEqual(store.revision, revision)
        for set in sets {
            XCTAssertTrue(store.applyWatchAction(.completeSet(setID: set.id, weight: set.weight, reps: set.reps, completedAt: Date(), restTimerID: UUID())))
        }
        XCTAssertNil(store.activeWorkout?.restTimer)
        XCTAssertTrue(try XCTUnwrap(store.watchWorkoutState.active).isFinished)
    }

    @MainActor
    func testStaleSetIDsIgnoredWithoutMutatingCurrentWorkout() async throws {
        let store = WorkoutStore(fileURL: try file())
        let old = try start(store)
        let id = old.exercises[0].sets[0].id
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: old.id)))
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        let current = try start(store)
        let revision = store.revision
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        XCTAssertFalse(store.applyWatchAction(.uncompleteSet(setID: id)))
        XCTAssertEqual(store.activeWorkout, current)
        XCTAssertEqual(store.revision, revision)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testInvalidValuesAndFailedPersistenceDoNotPublishWatchChanges() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        let revision = store.revision
        for action in [WatchAction.completeSet(setID: id, weight: -1, reps: 8, completedAt: Date(), restTimerID: UUID()),
                       .completeSet(setID: id, weight: .infinity, reps: 8, completedAt: Date(), restTimerID: UUID()),
                       .completeSet(setID: id, weight: 50, reps: 0, completedAt: Date(), restTimerID: UUID())] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.activeWorkout, workout)
            XCTAssertEqual(store.revision, revision)
        }
        let db = try SQLiteConnection(url: url)
        try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        XCTAssertFalse(store.applyWatchAction(.completeSet(setID: id, weight: 55, reps: 7, completedAt: Date(), restTimerID: UUID())))
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, workout)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testExtendAndSkipRestActionsUseExistingTimer() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30, requestedAt: Date(), resultingRestTimerID: timer.id)))
        XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, timer.endsAt.addingTimeInterval(30))
        XCTAssertEqual(store.activeWorkout?.restTimer?.id, timer.id)
        XCTAssertEqual(store.activeWorkout?.restSeconds, 75)
        XCTAssertTrue(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testRestActionsRejectEarlierTimerInSameWorkoutWithoutWrites() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let sets = workout.exercises[0].sets
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[0].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        let oldTimer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: sets[1].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        let current = store.watchWorkoutState
        XCTAssertNotEqual(current.active?.restTimerID, oldTimer.id)
        for action in [WatchAction.skipRest(workoutID: workout.id, restTimerID: oldTimer.id),
                       .extendRest(workoutID: workout.id, restTimerID: oldTimer.id, seconds: 30, requestedAt: Date(), resultingRestTimerID: oldTimer.id)] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.watchWorkoutState, current)
            XCTAssertNil(store.errorMessage)
        }
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertTrue(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        let skipped = store.watchWorkoutState
        XCTAssertFalse(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: timer.id)))
        XCTAssertFalse(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30, requestedAt: Date(), resultingRestTimerID: timer.id)))
        XCTAssertEqual(store.watchWorkoutState, skipped)
    }

    @MainActor
    func testFinishSavesOnlyCompletedAndDiscardClearsWithoutHistory() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try start(store)
        let id = workout.exercises[0].sets[0].id
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: id, weight: 55, reps: 7, completedAt: Date(), restTimerID: UUID())))
        XCTAssertTrue(store.applyWatchAction(.finish(workoutID: workout.id)))
        XCTAssertNil(store.activeWorkout)
        let saved = try XCTUnwrap(store.history.first)
        XCTAssertEqual(saved.exercises.count, 1)
        XCTAssertEqual(saved.exercises[0].sets.map(\.id), [id])
        XCTAssertEqual(saved.exercises[0].sets[0].weight, 55)
        XCTAssertNil(saved.restTimer)
        XCTAssertNotNil(saved.finishedAt)
        let second = try start(store)
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: second.id)))
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.history, [saved])
        let reloaded = WorkoutStore(fileURL: url)
        XCTAssertNil(reloaded.activeWorkout)
        XCTAssertEqual(reloaded.history, [saved])
    }
    @MainActor
    func testQueuedWorkoutActionsCannotAffectALaterWorkout() async throws {
        let store = WorkoutStore(fileURL: try file())
        let old = try start(store)
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: old.id)))
        let current = try start(store)
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: current.exercises[0].sets[0].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())))
        let before = store.watchWorkoutState
        let history = store.history
        for action in [WatchAction.finish(workoutID: old.id), .discard(workoutID: old.id),
                       .skipRest(workoutID: old.id, restTimerID: UUID()), .extendRest(workoutID: old.id, restTimerID: UUID(), seconds: 30, requestedAt: Date(), resultingRestTimerID: UUID())] {
            XCTAssertFalse(store.applyWatchAction(action))
            XCTAssertEqual(store.watchWorkoutState, before)
            XCTAssertEqual(store.history, history)
            XCTAssertNil(store.errorMessage)
        }
    }

    @MainActor
    func testOfflineMirrorTimerIdentityIsAcceptedByPhone() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let action = WatchAction.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8, completedAt: Date(), restTimerID: UUID())
        let mirror = store.watchWorkoutState.applyingOptimistically(action)
        XCTAssertTrue(store.applyWatchAction(action))
        let skip = WatchAction.skipRest(workoutID: workout.id, restTimerID: try XCTUnwrap(mirror.active?.restTimerID))
        XCTAssertTrue(store.applyWatchAction(skip))
        XCTAssertNil(store.activeWorkout?.restTimer)
    }

    @MainActor
    func testDelayedCompletionUsesTapDeadlineAndIdentityAcrossReload() async throws {
        let receiptTime = Date()
        for delay: TimeInterval in [30, 75, 7200] {
            let url = try file()
            let store = WorkoutStore(fileURL: url)
            let workout = try start(store)
            let completedAt = receiptTime.addingTimeInterval(-delay)
            let id = UUID()
            let action = WatchAction.completeSet(setID: workout.exercises[0].sets[0].id, weight: 55, reps: 7,
                                                 completedAt: completedAt, restTimerID: id)
            XCTAssertTrue(store.applyWatchAction(action, now: receiptTime))
            XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, completedAt.addingTimeInterval(75))
            XCTAssertEqual(store.activeWorkout?.restTimer?.id, id)
            XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
            let before = store.watchWorkoutState
            XCTAssertFalse(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id,
                                                               weight: 90, reps: 1, completedAt: receiptTime, restTimerID: UUID())))
            XCTAssertEqual(store.watchWorkoutState, before)
        }
    }

    @MainActor
    func testOfflineCompletionExtensionSkipFIFOAndExpiryAutoSkip() async throws {
        let now = Date()
        for extensionDelay: TimeInterval in [10, 75, 3600] {
            let store = WorkoutStore(fileURL: try file())
            let workout = try start(store)
            let complete = WatchAction.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8,
                                                   completedAt: now, restTimerID: UUID())
            let mirror = store.watchWorkoutState.applyingOptimistically(complete)
            let requestTime = now.addingTimeInterval(extensionDelay)
            let extend = try XCTUnwrap(mirror.restExtensionAction(by: 30, at: requestTime, newTimerID: UUID()))
            let extended = mirror.applyingOptimistically(extend)
            let skip = try XCTUnwrap(extended.restExpiryAction(at: requestTime.addingTimeInterval(3600)))
            let deliveredAt = now.addingTimeInterval(7200)
            XCTAssertTrue(store.applyWatchAction(complete, now: deliveredAt))
            XCTAssertEqual(store.activeWorkout?.restTimer?.id, mirror.active?.restTimerID)
            XCTAssertTrue(store.applyWatchAction(extend, now: deliveredAt))
            XCTAssertEqual(store.activeWorkout?.restTimer?.id, extended.active?.restTimerID)
            XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, extended.active?.restEndsAt)
            XCTAssertEqual(store.activeWorkout?.restTimer?.durationSeconds, extended.active?.restDurationSeconds)
            XCTAssertTrue(store.applyWatchAction(skip, now: deliveredAt))
            XCTAssertNil(store.activeWorkout?.restTimer)
        }
    }

    @MainActor
    func testPhoneCreatedTimerAcceptsWatchActionsAndAdoptsSuppliedExtensionIdentity() async throws {
        let store = WorkoutStore(fileURL: try file())
        var workout = try start(store)
        let now = Date()
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout, now: now))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        // Explicit identity wins even when different from the phone's classification.
        let proposed = UUID()
        XCTAssertTrue(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30,
                                                        requestedAt: now, resultingRestTimerID: proposed), now: now))
        XCTAssertEqual(store.activeWorkout?.restTimer?.id, proposed)
        XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, now.addingTimeInterval(105))
        XCTAssertTrue(store.applyWatchAction(.skipRest(workoutID: workout.id, restTimerID: proposed)))
    }

    @MainActor
    func testActionTimesRejectNonfiniteAndClampFutureTimes() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try start(store)
        let setID = workout.exercises[0].sets[0].id
        let now = Date()
        for interval in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(store.applyWatchAction(.completeSet(setID: setID, weight: 50, reps: 8,
                                                               completedAt: Date(timeIntervalSinceReferenceDate: interval), restTimerID: UUID()), now: now))
            XCTAssertEqual(store.activeWorkout, workout)
        }
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: setID, weight: 50, reps: 8,
                                                          completedAt: now.addingTimeInterval(600), restTimerID: UUID()), now: now))
        let timer = try XCTUnwrap(store.activeWorkout?.restTimer)
        XCTAssertEqual(timer.endsAt, now.addingTimeInterval(75))
        let revision = store.revision
        for interval in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30,
                                                              requestedAt: Date(timeIntervalSinceReferenceDate: interval), resultingRestTimerID: UUID()), now: now))
            XCTAssertEqual(store.revision, revision)
        }
        XCTAssertTrue(store.applyWatchAction(.extendRest(workoutID: workout.id, restTimerID: timer.id, seconds: 30,
                                                         requestedAt: now.addingTimeInterval(600), resultingRestTimerID: timer.id), now: now))
        XCTAssertEqual(store.activeWorkout?.restTimer?.endsAt, now.addingTimeInterval(105))
    }

    @MainActor
    func testTerminalReceiptsUseActualResultIncludingAtomicWriteFailures() async throws {
        for isFinish in [true, false] {
            for shouldFail in [true, false] {
                let url = try file()
                let store = WorkoutStore(fileURL: url)
                let workout = try start(store)
                XCTAssertTrue(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id, weight: 50, reps: 8,
                                                                  completedAt: Date(), restTimerID: UUID())))
                let action = isFinish ? WatchAction.finish(workoutID: workout.id) : .discard(workoutID: workout.id)
                let request = WatchActionRequest(operationID: UUID(), action: action)
                let revision = store.revision
                let db = try SQLiteConnection(url: url)
                if shouldFail {
                    try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
                }
                let succeeded = store.applyWatchAction(request.action)
                var receipt = WatchActionReceipt()
                receipt.record(request, succeeded: succeeded)
                let result = try XCTUnwrap(receipt.lastTerminalResult)
                XCTAssertEqual(receipt.processedThroughOperationID, request.operationID)
                XCTAssertEqual(result.operationID, request.operationID)
                XCTAssertEqual(result.workoutID, workout.id)
                XCTAssertEqual(result.isFinish, isFinish)
                XCTAssertEqual(result.succeeded, !shouldFail)
                XCTAssertEqual(store.revision, revision + (shouldFail ? 0 : 1))
                XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
                let data = try JSONEncoder().encode(receipt)
                XCTAssertEqual(try JSONDecoder().decode(WatchActionReceipt.self, from: data), receipt)
                // A stale terminal request also receives an explicit rejection.
                let stale = WatchActionRequest(operationID: UUID(), action: isFinish ? .finish(workoutID: UUID()) : .discard(workoutID: UUID()))
                receipt.record(stale, succeeded: store.applyWatchAction(stale.action))
                XCTAssertEqual(receipt.lastTerminalResult?.operationID, stale.operationID)
                XCTAssertEqual(receipt.lastTerminalResult?.succeeded, false)
                let edit = WatchActionRequest(operationID: UUID(), action: .uncompleteSet(setID: UUID()))
                let terminalResult = receipt.lastTerminalResult
                receipt.record(edit, succeeded: false)
                XCTAssertEqual(receipt.processedThroughOperationID, edit.operationID)
                XCTAssertEqual(receipt.lastTerminalResult, terminalResult)
            }
        }
    }


    @MainActor
    func testLegacyOutboxWaitsForFreshPhoneReceiptAfterRestartBeforeReplayingExtensions() async throws {
        for appliedCount in 0...2 {
            let url = try file()
            let phone = WorkoutStore(fileURL: url)
            let workout = try start(phone, restSeconds: 120)
            let now = Date(timeIntervalSinceReferenceDate: 1000)
            XCTAssertTrue(phone.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id,
                                                              weight: 50, reps: 8, completedAt: now, restTimerID: UUID()), now: now))
            let base = phone.watchWorkoutState
            let first = WatchActionRequest(operationID: UUID(), action: try XCTUnwrap(base.restExtensionAction(by: 30, at: now, newTimerID: UUID())))
            let second = WatchActionRequest(operationID: UUID(), action: try XCTUnwrap(base.applyingOptimistically(first.action)
                .restExtensionAction(by: 30, at: now, newTimerID: UUID())))
            let requests = [first, second]
            var receipt = WatchActionReceipt()
            for request in requests.prefix(appliedCount) {
                XCTAssertTrue(phone.applyWatchAction(request.action, now: now))
                receipt.record(request, succeeded: true)
            }
            // The phone restarts with its latest durable receipt, not the full dedupe window.
            let restarted = WorkoutStore(fileURL: url)
            var watch = WatchWorkoutReconciler(baseState: base)
            requests.forEach { watch.enqueue($0) }
            let legacy = try JSONEncoder().encode(watch) // No transfer checkpoints.
            watch = try JSONDecoder().decode(WatchWorkoutReconciler.self, from: legacy)
            let probeID = UUID()
            watch.beginTransferRecovery(probeID: probeID)
            var replayed: [UUID] = []
            try watch.transferPending(outstandingOperationIDs: [], transfer: { request in
                replayed.append(request.operationID)
                XCTAssertTrue(restarted.applyWatchAction(request.action, now: now))
                receipt.record(request, succeeded: true)
            }, checkpoint: { _ in })
            XCTAssertTrue(replayed.isEmpty)
            // An unrelated publication is not proof that this recovery request was handled.
            var fresh = restarted.watchWorkoutState
            fresh.phoneSessionID = UUID()
            fresh.publicationSequence = 1
            fresh.processedThroughOperationID = receipt.processedThroughOperationID
            fresh.recoveryProbeID = UUID()
            XCTAssertTrue(watch.accept(fresh))
            XCTAssertEqual(watch.transferRecoveryProbeID, appliedCount == 2 ? nil : probeID)
            fresh.publicationSequence += 1
            fresh.recoveryProbeID = probeID
            XCTAssertTrue(watch.accept(fresh))
            XCTAssertNil(watch.transferRecoveryProbeID)
            try watch.transferPending(outstandingOperationIDs: [], transfer: { request in
                replayed.append(request.operationID)
                XCTAssertTrue(restarted.applyWatchAction(request.action, now: now))
                receipt.record(request, succeeded: true)
            }, checkpoint: { _ in })
            XCTAssertEqual(replayed, requests.dropFirst(appliedCount).map(\.operationID))
            XCTAssertEqual(restarted.activeWorkout?.restTimer?.endsAt, now.addingTimeInterval(180))
            XCTAssertEqual(receipt.processedThroughOperationID, second.operationID)
            fresh = restarted.watchWorkoutState
            fresh.phoneSessionID = UUID()
            fresh.publicationSequence = 1
            fresh.processedThroughOperationID = receipt.processedThroughOperationID
            fresh.recoveryProbeID = probeID
            XCTAssertTrue(watch.accept(fresh))
            XCTAssertTrue(watch.pending.isEmpty)
            XCTAssertEqual(watch.state.active?.restEndsAt, now.addingTimeInterval(180))
        }
    }

}
