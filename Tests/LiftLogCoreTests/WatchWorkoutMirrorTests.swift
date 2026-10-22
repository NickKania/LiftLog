import Foundation
import XCTest
@testable import LiftLogCore

final class WatchWorkoutMirrorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func state(restSeconds: Int = 120, sets: [WatchSetState], endsAt: Date? = nil, timerID: UUID? = nil) -> WatchWorkoutState {
        .init(templates: [], active: .init(id: UUID(), name: "Push", startedAt: now.addingTimeInterval(-60),
                                         restSeconds: restSeconds, restEndsAt: endsAt, restTimerID: timerID,
                                         exercises: [.init(id: UUID(), name: "Bench", supersetID: UUID(), sets: sets)]),
              unitRaw: "lb", revision: 40)
    }

    private func set(completed: Bool = false, weight: Double = 135) -> WatchSetState {
        .init(id: UUID(), weight: weight, reps: 8, targetWeight: 135, targetReps: 8, isCompleted: completed)
    }

    func testCompletionPropagatesOnlyIncompleteValuesPreservesTargetsAndStartsRest() throws {
        let completed = set(completed: true, weight: 130)
        let next = set()
        let later = set()
        let before = state(sets: [completed, next, later])
        let timerID = UUID()
        let mirrored = before.applyingOptimistically(.completeSet(setID: next.id, weight: 140, reps: 7, completedAt: now, restTimerID: timerID))
        let workout = try XCTUnwrap(mirrored.active)
        XCTAssertEqual(workout.exercises[0].sets[0], completed)
        XCTAssertEqual(workout.exercises[0].sets[1].weight, 140)
        XCTAssertEqual(workout.exercises[0].sets[2].weight, 140)
        XCTAssertEqual(workout.exercises[0].sets[2].reps, 7)
        XCTAssertFalse(workout.exercises[0].sets[2].isCompleted)
        XCTAssertEqual(workout.exercises[0].sets.map(\.targetWeight), [135, 135, 135])
        XCTAssertEqual(workout.restEndsAt, now.addingTimeInterval(120))
        XCTAssertEqual(workout.restTimerID, timerID)
        XCTAssertEqual(workout.restDurationSeconds, 120)
        XCTAssertEqual(workout.id, before.active?.id)
        XCTAssertEqual(mirrored.revision, before.revision)
        XCTAssertEqual(mirrored.applyingOptimistically(.completeSet(setID: next.id, weight: 1, reps: 1, completedAt: now, restTimerID: UUID())), mirrored)
    }

    func testRestOffAndFinalSetNeverStartRest() {
        let next = set()
        for before in [state(restSeconds: 0, sets: [next, set()]), state(sets: [next])] {
            let mirrored = before.applyingOptimistically(.completeSet(setID: next.id, weight: 135, reps: 8, completedAt: now, restTimerID: UUID()))
            XCTAssertNil(mirrored.active?.restEndsAt)
            XCTAssertNil(mirrored.active?.restTimerID)
        }
    }

    func testExtendActiveKeepsDeadlineAndIdentityAndExpiredStartsNewTimer() throws {
        let timerID = UUID()
        let newID = UUID()
        // Include exact expiry and long-expired rest as well as a still-active timer.
        for offset: TimeInterval in [60, 0, -10, -3600] {
            let before = state(sets: [set(completed: true), set()], endsAt: now.addingTimeInterval(offset), timerID: timerID)
            let id = try XCTUnwrap(before.active?.id)
            let extended = before.applyingOptimistically(try XCTUnwrap(before.restExtensionAction(by: 30, at: now, newTimerID: newID)))
            XCTAssertEqual(extended.active?.restEndsAt, now.addingTimeInterval(max(0, offset) + 30))
            XCTAssertEqual(extended.active?.restTimerID, offset > 0 ? timerID : newID)
            XCTAssertEqual(extended.active?.restSeconds, 120)
            XCTAssertEqual(extended.active?.restDurationSeconds, offset > 0 ? 150 : 30)
            let capped = before.applyingOptimistically(try XCTUnwrap(before.restExtensionAction(by: Int.max, at: now, newTimerID: newID)))
            XCTAssertEqual(capped.active?.restEndsAt, now.addingTimeInterval(3600))
            XCTAssertEqual(capped.active?.restDurationSeconds, 3600)
            let extendedID = try XCTUnwrap(extended.active?.restTimerID)
            let skipped = extended.applyingOptimistically(.skipRest(workoutID: id, restTimerID: extendedID))
            XCTAssertNil(skipped.active?.restEndsAt)
            XCTAssertNil(skipped.active?.restTimerID)
            XCTAssertNil(skipped.active?.restDurationSeconds)
        }
    }

    func testStaleInvalidAndTerminalActionsDoNotChangeMirror() throws {
        let next = set()
        let timerID = UUID()
        let before = state(sets: [next, set()], endsAt: now.addingTimeInterval(60), timerID: timerID)
        let id = try XCTUnwrap(before.active?.id)
        for action in [WatchAction.skipRest(workoutID: UUID(), restTimerID: timerID), .extendRest(workoutID: UUID(), restTimerID: timerID, seconds: 30, requestedAt: now, resultingRestTimerID: timerID),
                       .skipRest(workoutID: id, restTimerID: UUID()),
                       .extendRest(workoutID: id, restTimerID: UUID(), seconds: 30, requestedAt: now, resultingRestTimerID: UUID()),
                       .extendRest(workoutID: id, restTimerID: timerID, seconds: 0, requestedAt: now, resultingRestTimerID: timerID), .completeSet(setID: UUID(), weight: 135, reps: 8, completedAt: now, restTimerID: UUID()),
                       .completeSet(setID: next.id, weight: .infinity, reps: 8, completedAt: now, restTimerID: UUID()),
                       .completeSet(setID: next.id, weight: 135, reps: 0, completedAt: now, restTimerID: UUID()), .uncompleteSet(setID: next.id),
                       .finish(workoutID: id), .discard(workoutID: id), .startEmpty] {
            XCTAssertEqual(before.applyingOptimistically(action), before)
        }
    }

    func testRestExpiryAutoAdvancesWithoutUserAcknowledgement() throws {
        let timerID = UUID()
        let resting = state(sets: [set(completed: true), set()], endsAt: now.addingTimeInterval(60), timerID: timerID)
        let workoutID = try XCTUnwrap(resting.active?.id)
        // Still resting: no auto-advance yet.
        XCTAssertNil(resting.restExpiryAction(at: now))
        XCTAssertNil(resting.restExpiryAction(at: now.addingTimeInterval(59)))
        // At and after the deadline the Watch rolls into the next set unaided.
        let expected = WatchAction.skipRest(workoutID: workoutID, restTimerID: timerID)
        XCTAssertEqual(resting.restExpiryAction(at: now.addingTimeInterval(60)), expected)
        XCTAssertEqual(resting.restExpiryAction(at: now.addingTimeInterval(600)), expected)
        // Applying it clears the timer so the next set is what the user sees.
        let advanced = resting.applyingOptimistically(expected)
        XCTAssertNil(advanced.active?.restEndsAt)
        XCTAssertNil(advanced.active?.restTimerID)
        // No timer, no action.
        XCTAssertNil(state(sets: [set()]).restExpiryAction(at: now))
    }

    func testUndoRetainsNumbersAndClearsLocalAlertWithoutTriggerIdentity() throws {
        let done = set(completed: true)
        let before = state(sets: [done, set()], endsAt: now.addingTimeInterval(60), timerID: UUID())
        let mirrored = before.applyingOptimistically(.uncompleteSet(setID: done.id))
        let undone = try XCTUnwrap(mirrored.active?.exercises[0].sets.first)
        XCTAssertFalse(undone.isCompleted)
        XCTAssertEqual(undone.weight, done.weight)
        XCTAssertEqual(undone.targetWeight, done.targetWeight)
        XCTAssertNil(mirrored.active?.restEndsAt)
    }
    func testMirrorPreservesReceiptAndPhonePublicationMetadata() throws {
        let next = set()
        var before = state(sets: [next, set()])
        let terminal = WatchActionRequest(operationID: UUID(), action: .finish(workoutID: try XCTUnwrap(before.active?.id)))
        before.processedThroughOperationID = UUID()
        before.lastTerminalResult = WatchTerminalResult(request: terminal, succeeded: false)
        before.phoneSessionID = UUID()
        before.publicationSequence = 230
        let mirrored = before.applyingOptimistically(.completeSet(setID: next.id, weight: 135, reps: 8,
                                                                  completedAt: now, restTimerID: UUID()))
        XCTAssertEqual(mirrored.processedThroughOperationID, before.processedThroughOperationID)
        XCTAssertEqual(mirrored.lastTerminalResult, before.lastTerminalResult)
        XCTAssertEqual(mirrored.phoneSessionID, before.phoneSessionID)
        XCTAssertEqual(mirrored.publicationSequence, before.publicationSequence)
    }

}
