import Foundation
import XCTest
@testable import LiftLogCore

final class WatchWorkoutReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func base() -> WatchWorkoutState {
        .init(templates: [], active: .init(id: UUID(), name: "Offline", startedAt: now, restSeconds: 120,
                                         restEndsAt: nil, restTimerID: nil,
                                         exercises: [.init(id: UUID(), name: "Bench", supersetID: nil,
                                                           sets: (0..<3).map { _ in
            .init(id: UUID(), weight: 50, reps: 8, targetWeight: 50, targetReps: 8, isCompleted: false)
        })]), unitRaw: "lb", revision: 1, phoneSessionID: UUID(), publicationSequence: 1)
    }

    private func request(_ action: WatchAction) -> WatchActionRequest {
        .init(operationID: UUID(), action: action)
    }

    private func completion(_ setID: UUID, weight: Double = 50) -> WatchActionRequest {
        request(.completeSet(setID: setID, weight: weight, reps: 8, completedAt: now, restTimerID: UUID()))
    }

    func testPostFirstAckReplaysSecondOfflineCompletionWithoutRollingBackNextSet() throws {
        let base = base()
        let sets = try XCTUnwrap(base.active?.exercises.first?.sets)
        let first = completion(sets[0].id)
        let second = completion(sets[1].id, weight: 60)
        var ledger = WatchWorkoutReconciler(baseState: base)
        XCTAssertTrue(ledger.accept(base))
        ledger.enqueue(first)
        ledger.enqueue(second)
        let projected = ledger.state
        var postFirst = base.applyingOptimistically(first.action)
        postFirst.publicationSequence = 2
        postFirst.processedThroughOperationID = first.operationID
        XCTAssertTrue(ledger.accept(postFirst))
        XCTAssertEqual(ledger.pending, [second])
        XCTAssertEqual(ledger.state.active, projected.active)
        // The Adjust sheet keys off this ID. No transient first-ack rollback reaches it.
        XCTAssertEqual(ledger.state.active?.nextIncompleteSet?.set.id, sets[2].id)
        var postSecond = projected
        postSecond.publicationSequence = 3
        postSecond.processedThroughOperationID = second.operationID
        XCTAssertTrue(ledger.accept(postSecond))
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(ledger.state, postSecond)
        XCTAssertEqual(postSecond.applyingPending([]), postSecond)
    }

    func testAcknowledgedExtensionDoesNotDoubleApplyAndUnknownWatermarkRetiresNothing() throws {
        let base = base()
        let first = completion(try XCTUnwrap(base.active?.nextIncompleteSet?.set.id))
        let resting = base.applyingOptimistically(first.action)
        let extend = request(try XCTUnwrap(resting.restExtensionAction(by: 30, at: now, newTimerID: UUID())))
        var ledger = WatchWorkoutReconciler(baseState: resting)
        ledger.enqueue(extend)
        let expected = ledger.state.active?.restEndsAt
        var unrelated = resting
        unrelated.processedThroughOperationID = UUID()
        XCTAssertTrue(ledger.accept(unrelated))
        XCTAssertEqual(ledger.pending, [extend])
        var ack = resting.applyingOptimistically(extend.action)
        ack.processedThroughOperationID = extend.operationID
        ack.publicationSequence += 1
        XCTAssertTrue(ledger.accept(ack))
        XCTAssertEqual(ledger.state.active?.restEndsAt, expected)
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testRejectedEditAckRetiresAtUnchangedRevision() throws {
        let base = base()
        let edit = completion(try XCTUnwrap(base.active?.nextIncompleteSet?.set.id))
        var ledger = WatchWorkoutReconciler(baseState: base)
        ledger.enqueue(edit)
        XCTAssertEqual(ledger.state.active?.completedSets, 1)
        var rejection = base
        rejection.processedThroughOperationID = edit.operationID
        rejection.publicationSequence += 1
        XCTAssertTrue(ledger.accept(rejection))
        XCTAssertTrue(ledger.pending.isEmpty)
        XCTAssertEqual(ledger.state, rejection)
        XCTAssertEqual(ledger.state.revision, base.revision)
    }

    func testPublicationOrderingAndNewPhoneSessionBaseline() {
        var base = base()
        base.publicationSequence = 400
        var ledger = WatchWorkoutReconciler(baseState: base)
        XCTAssertTrue(ledger.accept(base))
        XCTAssertFalse(ledger.accept(base))
        var older = base
        older.publicationSequence = 399
        older.active = nil
        XCTAssertFalse(ledger.accept(older))
        XCTAssertEqual(ledger.state, base)
        var relaunched = older
        relaunched.phoneSessionID = UUID()
        relaunched.publicationSequence = 1
        XCTAssertTrue(ledger.accept(relaunched))
        XCTAssertEqual(ledger.state, relaunched)
        XCTAssertFalse(ledger.accept(relaunched))
    }

    func testTerminalWaitsForMatchingReceiptRegardlessOfActiveWorkoutOrRevision() throws {
        for isFinish in [true, false] {
            let base = base()
            let workoutID = try XCTUnwrap(base.active?.id)
            let terminal = request(isFinish ? .finish(workoutID: workoutID) : .discard(workoutID: workoutID))
            var ledger = WatchWorkoutReconciler(baseState: base)
            ledger.enqueue(terminal)
            XCTAssertEqual(ledger.terminalWorkoutID, workoutID)
            XCTAssertEqual(ledger.showSaved, isFinish)
            XCTAssertFalse(ledger.savedConfirmed)
            var incoming = WatchWorkoutState(templates: base.templates, active: base.active, unitRaw: base.unitRaw,
                                             revision: base.revision + 20, phoneSessionID: base.phoneSessionID,
                                             publicationSequence: base.publicationSequence + 1)
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertEqual(ledger.pendingTerminal, terminal)
            incoming.active = nil
            incoming.publicationSequence += 1
            incoming.processedThroughOperationID = terminal.operationID
            // Even an acknowledged prefix and nil active cannot confirm a terminal result.
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertEqual(ledger.pendingTerminal, terminal)
            incoming = base
            incoming.publicationSequence += 3
            incoming.lastTerminalResult = WatchTerminalResult(request: request(terminal.action), succeeded: true)
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertEqual(ledger.pendingTerminal, terminal)
            // Unchanged store revision plus matching rejection restores the workout.
            incoming.lastTerminalResult = WatchTerminalResult(request: terminal, succeeded: false)
            incoming.processedThroughOperationID = terminal.operationID
            incoming.publicationSequence += 1
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertNil(ledger.terminalWorkoutID)
            XCTAssertFalse(ledger.showSaved)
            XCTAssertNotNil(ledger.errorMessage)
            XCTAssertEqual(ledger.state.active?.id, workoutID)
        }
    }

    func testSuccessfulTerminalReceiptConfirmsOnceWithoutReplayedPresentation() throws {
        for isFinish in [true, false] {
            let base = base()
            let id = try XCTUnwrap(base.active?.id)
            let terminal = request(isFinish ? .finish(workoutID: id) : .discard(workoutID: id))
            var ledger = WatchWorkoutReconciler(baseState: base)
            ledger.enqueue(terminal)
            var incoming = base
            incoming.active = nil
            incoming.publicationSequence += 1
            incoming.lastTerminalResult = WatchTerminalResult(request: terminal, succeeded: true)
            incoming.processedThroughOperationID = terminal.operationID
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertNil(ledger.pendingTerminal)
            XCTAssertTrue(ledger.pending.isEmpty)
            XCTAssertEqual(ledger.showSaved, isFinish)
            XCTAssertEqual(ledger.savedConfirmed, isFinish)
            ledger.dismissSaved()
            incoming.publicationSequence += 1
            XCTAssertTrue(ledger.accept(incoming))
            XCTAssertFalse(ledger.showSaved)
        }
    }

    func testTransportErrorsRemoveOnlyMatchingPendingEditAndUnhideTerminal() throws {
        let base = base()
        let sets = try XCTUnwrap(base.active?.exercises.first?.sets)
        let first = completion(sets[0].id)
        let second = completion(sets[1].id)
        let terminal = request(.finish(workoutID: try XCTUnwrap(base.active?.id)))
        var ledger = WatchWorkoutReconciler(baseState: base)
        [first, second, terminal].forEach { ledger.enqueue($0) }
        XCTAssertFalse(ledger.fail(operationID: UUID()))
        XCTAssertTrue(ledger.fail(operationID: first.operationID))
        XCTAssertEqual(ledger.pending, [second, terminal])
        XCTAssertEqual(ledger.state.active?.completedSets, 1)
        XCTAssertNotNil(ledger.terminalWorkoutID)
        XCTAssertTrue(ledger.fail(operationID: terminal.operationID))
        XCTAssertNil(ledger.terminalWorkoutID)
        XCTAssertFalse(ledger.showSaved)
        ledger.clearError()
        XCTAssertFalse(ledger.fail(operationID: terminal.operationID))
        XCTAssertNil(ledger.errorMessage)
        var ack = base.applyingOptimistically(second.action)
        ack.publicationSequence += 1
        ack.processedThroughOperationID = second.operationID
        XCTAssertTrue(ledger.accept(ack))
        XCTAssertFalse(ledger.fail(operationID: second.operationID))
        XCTAssertNil(ledger.errorMessage)
    }

    func testRelaunchRestoresDeliveredButUnacknowledgedEditsAndTerminalRequests() throws {
        for terminalKind in 0...2 {
            let base = base()
            let id = try XCTUnwrap(base.active?.id)
            let first = completion(try XCTUnwrap(base.active?.nextIncompleteSet?.set.id))
            var ledger = WatchWorkoutReconciler(baseState: base)
            XCTAssertTrue(ledger.accept(base))
            ledger.enqueue(first)
            if terminalKind > 0 {
                ledger.enqueue(request(terminalKind == 1 ? .finish(workoutID: id) : .discard(workoutID: id)))
            }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = WatchWorkoutJournal(url: directory.appendingPathComponent("journal.json"))
            try journal.save(ledger)
            // No outstanding transport is needed: delivery is not a phone receipt.
            var restored = try XCTUnwrap(journal.load())
            XCTAssertEqual(restored.pending, ledger.pending)
            XCTAssertEqual(restored.state, ledger.state)
            XCTAssertEqual(restored.terminalWorkoutID, ledger.terminalWorkoutID)
            XCTAssertEqual(restored.showSaved, terminalKind == 1)
            XCTAssertFalse(restored.savedConfirmed)
            XCTAssertFalse(restored.accept(base))
            var ack = base.applyingOptimistically(first.action)
            ack.publicationSequence += 1
            ack.processedThroughOperationID = first.operationID
            XCTAssertTrue(restored.accept(ack))
            XCTAssertEqual(restored.state.active?.completedSets, 1)
            XCTAssertEqual(restored.pending.count, terminalKind == 0 ? 0 : 1)
            try journal.save(restored)
            XCTAssertEqual(try journal.load()?.pending, restored.pending)
            if let terminal = restored.pendingTerminal {
                ack.publicationSequence += 1
                ack.processedThroughOperationID = terminal.operationID
                ack.lastTerminalResult = WatchTerminalResult(request: terminal, succeeded: true)
                ack.active = nil
                XCTAssertTrue(restored.accept(ack))
                try journal.save(restored)
                var confirmed = try XCTUnwrap(journal.load())
                XCTAssertTrue(confirmed.pending.isEmpty)
                XCTAssertNil(confirmed.pendingTerminal)
                XCTAssertEqual(confirmed.savedConfirmed, terminalKind == 1)
                confirmed.dismissSaved()
                try journal.save(confirmed)
                XCTAssertEqual(try journal.load()?.showSaved, false)
            }
        }
    }

    func testJournalPreservesUnreadableDataAndPriorStateAfterFailedWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = WatchWorkoutJournal(url: directory.appendingPathComponent("journal.json"))
        XCTAssertNil(try journal.load())
        try journal.save(WatchWorkoutReconciler(baseState: base()))
        let original = try Data(contentsOf: journal.url)
        let invalid = Data("unreadable".utf8)
        try invalid.write(to: journal.url)
        XCTAssertThrowsError(try journal.load())
        XCTAssertEqual(try Data(contentsOf: journal.url), invalid)
        try original.write(to: journal.url)
        // A nonfinite payload cannot replace the last recoverable ledger.
        var ledger = try XCTUnwrap(journal.load())
        ledger.enqueue(request(.completeSet(setID: UUID(), weight: .infinity, reps: 8,
                                           completedAt: now, restTimerID: UUID())))
        XCTAssertThrowsError(try journal.save(ledger))
        XCTAssertEqual(try Data(contentsOf: journal.url), original)
        XCTAssertTrue(try XCTUnwrap(journal.load()).pending.isEmpty)
        var futureArchive = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        futureArchive["version"] = 2
        let futureData = try JSONSerialization.data(withJSONObject: futureArchive)
        try futureData.write(to: journal.url)
        XCTAssertThrowsError(try journal.load())
        XCTAssertEqual(try Data(contentsOf: journal.url), futureData)
        let blockedURL = directory.appendingPathComponent("blocked")
        try Data("file instead of directory".utf8).write(to: blockedURL)
        let blockedJournal = WatchWorkoutJournal(url: blockedURL.appendingPathComponent("journal.json"))
        XCTAssertThrowsError(try blockedJournal.save(WatchWorkoutReconciler(baseState: base())))
        XCTAssertEqual(try Data(contentsOf: journal.url), futureData)
    }

    func testRelaunchKeepsTerminalHiddenWhenWatermarkArrivesWithoutTerminalReceipt() throws {
        let base = base()
        let terminal = request(.finish(workoutID: try XCTUnwrap(base.active?.id)))
        var ledger = WatchWorkoutReconciler(baseState: base)
        ledger.enqueue(terminal)
        var ack = base
        ack.processedThroughOperationID = terminal.operationID
        ack.publicationSequence += 1
        XCTAssertTrue(ledger.accept(ack))
        XCTAssertTrue(ledger.pending.isEmpty)
        let data = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(WatchWorkoutReconciler.self, from: data)
        XCTAssertEqual(restored.pendingTerminal, terminal)
        XCTAssertEqual(restored.terminalWorkoutID, base.active?.id)
        XCTAssertTrue(restored.showSaved)
        XCTAssertFalse(restored.savedConfirmed)
        ack.lastTerminalResult = WatchTerminalResult(request: terminal, succeeded: false)
        ack.publicationSequence += 1
        XCTAssertTrue(restored.accept(ack))
        XCTAssertNil(restored.terminalWorkoutID)
        XCTAssertFalse(restored.showSaved)
        XCTAssertNotNil(restored.errorMessage)
    }

    func testReachablePhoneMustConfirmExactRestBeforeWatchHandsOffAlert() throws {
        let base = base()
        let completion = completion(try XCTUnwrap(base.active?.nextIncompleteSet?.set.id))
        var ledger = WatchWorkoutReconciler(baseState: base)
        ledger.enqueue(completion)
        let resting = ledger.state
        XCTAssertFalse(resting.hasSameRest(as: ledger.baseState))
        XCTAssertTrue(resting.shouldScheduleLocalRestAlert(isReachable: true,
                                                          phoneHasCurrentRest: false, at: now))
        var ack = resting
        ack.publicationSequence += 1
        ack.processedThroughOperationID = completion.operationID
        XCTAssertTrue(ledger.accept(ack))
        XCTAssertTrue(ledger.state.hasSameRest(as: ledger.baseState))
        XCTAssertFalse(ledger.state.shouldScheduleLocalRestAlert(isReachable: true,
                                                                phoneHasCurrentRest: true, at: now))
        XCTAssertTrue(ledger.state.shouldScheduleLocalRestAlert(isReachable: false,
                                                               phoneHasCurrentRest: true, at: now))
        let extensionRequest = request(try XCTUnwrap(resting.restExtensionAction(by: 30, at: now, newTimerID: UUID())))
        ledger.enqueue(extensionRequest)
        XCTAssertFalse(ledger.state.hasSameRest(as: ack)) // Same timer ID, different deadline.
        XCTAssertTrue(ledger.state.shouldScheduleLocalRestAlert(isReachable: true,
                                                               phoneHasCurrentRest: ledger.state.hasSameRest(as: ack), at: now))
        ack = ledger.state
        ack.publicationSequence += 1
        ack.processedThroughOperationID = extensionRequest.operationID
        XCTAssertTrue(ledger.accept(ack))
        XCTAssertTrue(ledger.state.hasSameRest(as: ack))
        XCTAssertFalse(ledger.state.shouldScheduleLocalRestAlert(isReachable: true,
                                                                phoneHasCurrentRest: true, at: now))
        XCTAssertFalse(ledger.state.shouldScheduleLocalRestAlert(isReachable: false,
                                                                phoneHasCurrentRest: false, at: now.addingTimeInterval(151)))
        let otherWorkout = self.base()
        XCTAssertFalse(resting.hasSameRest(as: otherWorkout))
        XCTAssertFalse(otherWorkout.shouldScheduleLocalRestAlert(isReachable: false,
                                                                phoneHasCurrentRest: false, at: now))
    }

}
