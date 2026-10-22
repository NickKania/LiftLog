import Foundation
import XCTest
@testable import LiftLogCore

final class WatchWorkoutPayloadTests: XCTestCase {
    func testRecoveryProbeRoundTripsAndRejectsMalformedOrOlderProtocol() throws {
        let id = UUID()
        var dictionary = WatchWorkoutTransport.encodeRecoveryProbe(id: id)
        XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0))
        XCTAssertEqual(try WatchWorkoutTransport.decodeRecoveryProbe(from: dictionary), id)
        dictionary[WatchWorkoutTransport.recoveryProbeKey] = "invalid"
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeRecoveryProbe(from: dictionary))
        dictionary[WatchWorkoutTransport.versionKey] = 1
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeRecoveryProbe(from: dictionary))
        var state = WatchWorkoutState(templates: [], active: nil, unitRaw: "lb", revision: 1)
        state.recoveryProbeID = id
        XCTAssertEqual(try WatchWorkoutTransport.decodeState(from: WatchWorkoutTransport.encode(state: state)), state)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "recoveryProbeID")
        XCTAssertNil(try JSONDecoder().decode(WatchWorkoutState.self,
                                              from: JSONSerialization.data(withJSONObject: json)).recoveryProbeID)
    }

    private func active(exercises: [WatchExerciseState]) -> WatchActiveWorkout {
        WatchActiveWorkout(id: UUID(), name: "Routine", startedAt: Date(timeIntervalSinceReferenceDate: 1000),
                           restSeconds: 120, restEndsAt: Date(timeIntervalSinceReferenceDate: 1120),
                           restTimerID: UUID(), exercises: exercises, restDurationSeconds: 45)
    }

    private func set(completed: Bool = false) -> WatchSetState {
        WatchSetState(id: UUID(), weight: 52.5, reps: 7, targetWeight: 50, targetReps: 8, isCompleted: completed)
    }

    func testProgressAndNextSetFollowExerciseOrderIncludingOutOfOrderSetsAndSupersets() {
        let group = UUID()
        let pending = set()
        let workout = active(exercises: [
            .init(id: UUID(), name: "Empty entry", supersetID: nil, sets: []),
            .init(id: UUID(), name: "First", supersetID: group, sets: [set(completed: true), pending, set(completed: true)]),
            .init(id: UUID(), name: "Second", supersetID: group, sets: [set()])
        ])
        XCTAssertEqual(workout.totalSets, 4)
        XCTAssertEqual(workout.completedSets, 2)
        XCTAssertEqual(workout.nextIncompleteSet?.exerciseIndex, 1)
        XCTAssertEqual(workout.nextIncompleteSet?.setIndex, 1)
        XCTAssertEqual(workout.nextIncompleteSet?.set, pending)
        XCTAssertTrue(workout.canFinish)
        XCTAssertFalse(workout.isFinished)
        let completed = active(exercises: [.init(id: UUID(), name: "Done", supersetID: nil, sets: [set(completed: true)])])
        XCTAssertTrue(completed.isFinished)
        XCTAssertNil(completed.nextIncompleteSet)
        let empty = active(exercises: [])
        XCTAssertFalse(empty.canFinish)
        XCTAssertFalse(empty.isFinished)
        XCTAssertEqual(empty.totalSets, 0)
        XCTAssertNil(empty.nextIncompleteSet)
    }

    func testStateAndAllActionsRoundTripThroughPropertyListSafeDictionaries() throws {
        let workout = active(exercises: [.init(id: UUID(), name: "Squat", supersetID: nil, sets: [set()], restSeconds: 45)])
        var state = WatchWorkoutState(templates: [.init(id: UUID(), name: "Plan", exerciseCount: 1, setCount: 3)],
                                      active: workout, unitRaw: "kg", revision: UInt64.max)
        let terminalRequest = WatchActionRequest(operationID: UUID(), action: .finish(workoutID: workout.id))
        state.processedThroughOperationID = terminalRequest.operationID
        state.lastTerminalResult = WatchTerminalResult(request: terminalRequest, succeeded: false)
        state.phoneSessionID = UUID()
        state.publicationSequence = UInt64.max
        let dictionary = try WatchWorkoutTransport.encode(state: state)
        let plist = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        let transported = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(try WatchWorkoutTransport.decodeState(from: transported), state)
        var v1State = dictionary
        v1State[WatchWorkoutTransport.versionKey] = 1
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeState(from: v1State)) { error in
            XCTAssertEqual(error as? WatchWorkoutTransport.PayloadError, .unsupportedVersion)
        }
        let actions: [WatchAction] = [.startTemplate(id: UUID()), .startEmpty,
                                     .completeSet(setID: UUID(), weight: 52.5, reps: 7, completedAt: Date(), restTimerID: UUID()), .uncompleteSet(setID: UUID()),
                                     .skipRest(workoutID: UUID(), restTimerID: UUID()), .extendRest(workoutID: UUID(), restTimerID: UUID(), seconds: 30, requestedAt: Date(), resultingRestTimerID: UUID()), .finish(workoutID: UUID()), .discard(workoutID: UUID())]
        for action in actions {
            let request = WatchActionRequest(operationID: UUID(), action: action)
            XCTAssertEqual(try WatchWorkoutTransport.decodeRequest(from: WatchWorkoutTransport.encode(request: request)), request)
        }
        let idle = WatchWorkoutState(templates: [], active: nil, unitRaw: "lb", revision: 0)
        XCTAssertEqual(try WatchWorkoutTransport.decodeState(from: WatchWorkoutTransport.encode(state: idle)), idle)
    }

    func testEarlierV2SnapshotWithoutRestOverridesOrCapturedDurationDecodes() throws {
        let state = WatchWorkoutState(templates: [], active: active(exercises: [
            .init(id: UUID(), name: "Bench", supersetID: nil, sets: [set()], restSeconds: 45)
        ]), unitRaw: "lb", revision: 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var workout = try XCTUnwrap(json["active"] as? [String: Any])
        workout.removeValue(forKey: "restDurationSeconds")
        var exercises = try XCTUnwrap(workout["exercises"] as? [[String: Any]])
        exercises[0].removeValue(forKey: "restSeconds")
        workout["exercises"] = exercises
        json["active"] = workout
        let decoded = try JSONDecoder().decode(WatchWorkoutState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.active?.restDurationSeconds)
        XCTAssertNil(decoded.active?.exercises[0].restSeconds)
        XCTAssertEqual(decoded.active?.restSeconds, 120)
    }

    func testTransportRejectsMissingUnsupportedAndMalformedPayloads() throws {
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeState(from: [:]))
        var dictionary = try WatchWorkoutTransport.encode(request: .init(operationID: UUID(), action: .skipRest(workoutID: UUID(), restTimerID: UUID())))
        dictionary[WatchWorkoutTransport.versionKey] = 1
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeRequest(from: dictionary))
        dictionary[WatchWorkoutTransport.versionKey] = WatchWorkoutTransport.payloadVersion
        dictionary[WatchWorkoutTransport.actionKey] = "not Data"
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeRequest(from: dictionary))
        dictionary[WatchWorkoutTransport.actionKey] = Data("malformed JSON".utf8)
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeRequest(from: dictionary))
        dictionary = try WatchWorkoutTransport.encode(request: .init(operationID: UUID(), action: .skipRest(workoutID: UUID(), restTimerID: UUID())))
        XCTAssertThrowsError(try WatchWorkoutTransport.decodeState(from: dictionary))
    }

    @MainActor
    func testStoreProjectionPreservesStableIDsTargetsRestAndRecordedUnit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let template = try XCTUnwrap(store.templates.first)
        let idle = store.watchWorkoutState
        XCTAssertNil(idle.active)
        XCTAssertEqual(idle.templates.first?.id, template.id)
        XCTAssertEqual(idle.templates.first?.exerciseCount, template.exercises.count)
        XCTAssertEqual(idle.templates.first?.setCount, template.exercises.reduce(0) { $0 + $1.sets.count })
        XCTAssertTrue(store.applyWatchAction(.startTemplate(id: template.id)))
        var workout = try XCTUnwrap(store.activeWorkout)
        let group = UUID()
        workout.exercises[0].supersetID = group
        workout.exercises[1].supersetID = group
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertTrue(store.applyWatchAction(.completeSet(setID: workout.exercises[0].sets[0].id, weight: 55, reps: 7, completedAt: Date(), restTimerID: UUID())))
        XCTAssertTrue(store.setUnit(.kg))
        workout = try XCTUnwrap(store.activeWorkout)
        let state = store.watchWorkoutState
        let active = try XCTUnwrap(state.active)
        XCTAssertEqual(state.revision, store.revision)
        XCTAssertGreaterThan(state.revision, idle.revision)
        XCTAssertEqual(state.unitRaw, "lb")
        XCTAssertEqual(active.id, workout.id)
        XCTAssertEqual(active.name, workout.name)
        XCTAssertEqual(active.startedAt, workout.startedAt)
        XCTAssertEqual(active.restSeconds, workout.restSeconds)
        XCTAssertEqual(active.restTimerID, workout.restTimer?.id)
        XCTAssertEqual(active.restDurationSeconds, workout.restTimer.map { workout.restDuration(for: $0) })
        XCTAssertEqual(active.restEndsAt, workout.restTimer?.endsAt)
        XCTAssertEqual(active.exercises[0].id, workout.exercises[0].id)
        XCTAssertEqual(active.exercises[0].name, workout.exercises[0].exercise.name)
        XCTAssertEqual(active.exercises[0].supersetID, group)
        let set = try XCTUnwrap(active.exercises[0].sets.first)
        XCTAssertEqual(set.id, workout.exercises[0].sets[0].id)
        XCTAssertEqual(set.weight, 55)
        XCTAssertEqual(set.reps, 7)
        XCTAssertEqual(set.targetWeight, workout.exercises[0].sets[0].targetWeight)
        XCTAssertEqual(set.targetReps, workout.exercises[0].sets[0].targetReps)
        XCTAssertTrue(set.isCompleted)
        XCTAssertEqual(active.completedSets, 1)
        XCTAssertTrue(store.applyWatchAction(.discard(workoutID: workout.id)))
        XCTAssertEqual(store.watchWorkoutState.unitRaw, "kg")
    }
}
