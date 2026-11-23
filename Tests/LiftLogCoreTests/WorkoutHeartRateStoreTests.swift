import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutHeartRateStoreTests: XCTestCase {
    @MainActor
    func testUpdatingWorkoutDoesNotFetchUntilExplicitLoad() async throws {
        let provider = ControlledHeartRateProvider()
        let store = WorkoutHeartRateStore(provider: provider)
        let workout = makeWorkout()
        XCTAssertNil(store.load())
        store.updateWorkout(workout)
        XCTAssertEqual(provider.readCount, 0)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertNil(store.correlation)

        let task = try XCTUnwrap(store.load())
        await provider.waitForRead()
        XCTAssertEqual(provider.readCount, 1)
        XCTAssertEqual(provider.requestedWorkout, workout)
        XCTAssertEqual(provider.requestedEnd, workout.finishedAt)
        XCTAssertTrue(store.isLoading)
        provider.finish(with: .success(snapshot(for: workout)))
        await task.value

        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.correlation?.heartRateSamples.map(\.value), [125])
        XCTAssertNil(store.errorMessage)
        store.updateWorkout(workout)
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testCorrectionClearsResultsAndDiscardsPendingRead() async throws {
        let provider = ControlledHeartRateProvider()
        let store = WorkoutHeartRateStore(provider: provider)
        let workout = makeWorkout()
        store.updateWorkout(workout)
        let initial = try XCTUnwrap(store.load())
        await provider.waitForRead()
        provider.finish(with: .success(snapshot(for: workout)))
        await initial.value
        XCTAssertNotNil(store.correlation)

        var corrected = workout
        corrected.name = "Corrected"
        store.updateWorkout(corrected)
        assertCleared(store)
        XCTAssertEqual(provider.readCount, 1)

        let pending = try XCTUnwrap(store.load())
        await provider.waitForRead()
        store.updateWorkout(workout)
        XCTAssertTrue(pending.isCancelled)
        provider.finish(with: .success(snapshot(for: corrected)))
        await pending.value
        assertCleared(store)
    }

    @MainActor
    func testCancelDiscardsLateResponse() async throws {
        let provider = ControlledHeartRateProvider()
        let store = WorkoutHeartRateStore(provider: provider)
        let workout = makeWorkout()
        store.updateWorkout(workout)
        let task = try XCTUnwrap(store.load())
        await provider.waitForRead()
        store.cancel()
        XCTAssertTrue(task.isCancelled)
        provider.finish(with: .success(snapshot(for: workout)))
        await task.value
        assertCleared(store)
    }

    @MainActor
    func testProviderErrorIsDisplayedAndRetryClearsIt() async throws {
        let provider = ControlledHeartRateProvider()
        let store = WorkoutHeartRateStore(provider: provider)
        let workout = makeWorkout()
        store.updateWorkout(workout)
        let task = try XCTUnwrap(store.load())
        await provider.waitForRead()
        provider.finish(with: .failure(WorkoutHealthDataError.unavailable))
        await task.value
        XCTAssertEqual(store.errorMessage, WorkoutHealthDataError.unavailable.localizedDescription)
        XCTAssertNil(store.correlation)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.hasLoaded)

        let retry = try XCTUnwrap(store.load())
        XCTAssertNil(store.errorMessage)
        await provider.waitForRead()
        provider.finish(with: .failure(CancellationError()))
        await retry.value
        assertCleared(store)
    }

    @MainActor
    private func assertCleared(_ store: WorkoutHeartRateStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(store.correlation, file: file, line: line)
        XCTAssertNil(store.errorMessage, file: file, line: line)
        XCTAssertFalse(store.isLoading, file: file, line: line)
        XCTAssertFalse(store.hasLoaded, file: file, line: line)
    }

    private func makeWorkout() -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_000)
        return WorkoutSession(startedAt: start, finishedAt: start.addingTimeInterval(90))
    }

    private func snapshot(for workout: WorkoutSession) -> WorkoutHealthSnapshot {
        WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: workout.startedAt,
                              endedAt: workout.startedAt.addingTimeInterval(100), fetchedAt: Date(),
                              metrics: [.init(metric: .heartRate, samples: [
                                  .init(date: workout.startedAt.addingTimeInterval(30), value: 125),
                                  .init(date: workout.startedAt.addingTimeInterval(95), value: 155)
                              ])])
    }
}

@MainActor
private final class ControlledHeartRateProvider: WorkoutHealthDataProviding {
    private(set) var readCount = 0
    private(set) var requestedWorkout: WorkoutSession?
    private(set) var requestedEnd: Date?
    private var pending: CheckedContinuation<WorkoutHealthSnapshot, Error>?
    private var started: CheckedContinuation<Void, Never>?

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        XCTFail("Expected a heart-rate-only provider read")
        throw WorkoutHealthDataError.unavailable
    }

    func fetchHeartRateSamples(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        readCount += 1
        requestedWorkout = workout
        requestedEnd = through
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }

    func waitForRead() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(with result: Result<WorkoutHealthSnapshot, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}
