import Foundation
import XCTest
@testable import LiftLogCore

@MainActor
private final class SetHeartRateTrendProvider: WorkoutHealthDataProviding {
    struct Read {
        let workout: WorkoutSession
        let through: Date
    }

    private(set) var reads: [Read] = []
    private(set) var otherReads = 0
    private(set) var maximumInFlight = 0
    private var inFlight = 0
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    var suspends = false
    var returnOverscopedSamples = false

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        otherReads += 1
        throw WorkoutHealthDataError.unavailable
    }

    func fetchHealthSummary(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        otherReads += 1
        throw WorkoutHealthDataError.unavailable
    }

    func fetchHeartRateSamples(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        reads.append(Read(workout: workout, through: through))
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        if suspends {
            // A real provider might still deliver a response after cancellation.
            try await withCheckedThrowingContinuation { pending[workout.id] = $0 }
        }
        let sample = WorkoutHealthSample(date: workout.startedAt, value: 120)
        var metrics = [WorkoutHealthMetricSeries(metric: .heartRate, samples: [sample])]
        if returnOverscopedSamples {
            let count = WorkoutHealthSnapshot.maximumHeartRateSamples + 1
            let outside = WorkoutHealthSample(date: through.addingTimeInterval(1), value: 500)
            metrics = [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: Array(repeating: sample, count: count) + [outside]),
                WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [sample])
            ]
        }
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: workout.startedAt,
            endedAt: through, fetchedAt: through, metrics: metrics)
    }

    func release(_ workout: WorkoutSession, failing: Bool = false) {
        if failing {
            pending.removeValue(forKey: workout.id)?.resume(throwing: WorkoutHealthDataError.unavailable)
        } else {
            pending.removeValue(forKey: workout.id)?.resume()
        }
    }

    func releaseAll() {
        suspends = false
        for continuation in pending.values { continuation.resume() }
        pending.removeAll()
    }
}

final class HealthDashboardSetHeartRateStoreTests: XCTestCase {
    private func workout(_ minute: Int = 0, age: TimeInterval = 3600, completed: Bool = true,
                         timestamped: Bool = true, setCompleted: Bool = true, marked: Bool = false) -> WorkoutSession {
        let start = Date().addingTimeInterval(-age + TimeInterval(minute * 60))
        let set = WorkoutSet(isCompleted: setCompleted, completedAt: timestamped ? start.addingTimeInterval(30) : nil,
                             isMarkedForHeartRate: marked)
        return WorkoutSession(name: "Workout \(minute)", startedAt: start,
            finishedAt: completed ? start.addingTimeInterval(60) : nil,
            exercises: [WorkoutExercise(exercise: Exercise(name: "Squat"), sets: [set])])
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the Health read")
        return false
    }

    @MainActor
    func testSelectionFiltersWorkoutsAndLoadsOnlyNewestTwentyOnRequest() async throws {
        let provider = SetHeartRateTrendProvider()
        let store = HealthDashboardSetHeartRateStore(provider: provider)
        XCTAssertNil(store.load())
        XCTAssertTrue(provider.reads.isEmpty)
        let sessions = (0..<25).map { workout($0, marked: $0 == 0) }
        let excluded = [
            workout(25, completed: false), workout(26, timestamped: false),
            workout(27, setCompleted: false), workout(age: 365 * 24 * 3600)
        ]
        store.updateWorkouts(sessions + excluded, range: .month)
        await Task.yield()
        XCTAssertTrue(provider.reads.isEmpty)
        XCTAssertEqual(store.eligibleWorkoutCount, 25)
        XCTAssertEqual(store.selectedWorkoutCount, 20)
        XCTAssertEqual(store.omittedWorkoutCount, 5)
        XCTAssertTrue(store.hasMarkedSetsInEligibleWorkouts)
        XCTAssertFalse(store.hasMarkedSetsInSelectedWorkouts)

        let task = try XCTUnwrap(store.load())
        await task.value
        XCTAssertEqual(Set(provider.reads.map(\.workout.id)), Set(sessions.suffix(20).map(\.id)))
        XCTAssertTrue(provider.reads.allSatisfy { $0.through == $0.workout.finishedAt })
        XCTAssertEqual(provider.otherReads, 0)
        XCTAssertEqual(store.completedCount, 20)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testConcurrentReadsStayBoundedAndCancelDiscardsLateResults() async throws {
        let provider = SetHeartRateTrendProvider()
        provider.suspends = true
        defer { provider.releaseAll() }
        let store = HealthDashboardSetHeartRateStore(provider: provider)
        store.updateWorkouts((0..<7).map { workout($0) }, range: .all)
        let task = try XCTUnwrap(store.load())
        let limit = HealthDashboardSetHeartRateStore.maximumConcurrentReads
        guard await waitUntil({ provider.reads.count >= limit }) else { return }
        XCTAssertEqual(provider.reads.count, 4)
        XCTAssertNil(store.load())
        provider.release(try XCTUnwrap(provider.reads.first?.workout))
        guard await waitUntil({ provider.reads.count >= limit + 1 }) else { return }
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(provider.maximumInFlight, 4)

        store.cancel()
        provider.releaseAll()
        await task.value
        XCTAssertEqual(provider.reads.count, limit + 1)
        assertCleared(store)
    }

    @MainActor
    func testRangeChangeWithIdenticalSelectionCancelsAndClearsPartialResults() async throws {
        let provider = SetHeartRateTrendProvider()
        provider.suspends = true
        defer { provider.releaseAll() }
        let sessions = [workout(0), workout(1), workout(2)]
        let store = HealthDashboardSetHeartRateStore(provider: provider)
        store.updateWorkouts(sessions, range: .year)
        let task = try XCTUnwrap(store.load())
        guard await waitUntil({ provider.reads.count == sessions.count }) else { return }
        provider.release(sessions[0])
        provider.release(sessions[1], failing: true)
        guard await waitUntil({ store.completedCount == 2 }) else { return }
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.failures.count, 1)
        store.updateWorkouts(sessions, range: .year)
        XCTAssertTrue(store.isLoading)

        store.updateWorkouts(sessions, range: .all)
        XCTAssertTrue(task.isCancelled)
        assertCleared(store)
        provider.releaseAll()
        await task.value
        assertCleared(store)
        XCTAssertEqual(provider.reads.count, sessions.count)
    }

    @MainActor
    func testPartialFailuresUseNewestFirstSelectionOrderAndSnapshotsAreScoped() async throws {
        let provider = SetHeartRateTrendProvider()
        provider.suspends = true
        provider.returnOverscopedSamples = true
        defer { provider.releaseAll() }
        let sessions = [workout(0), workout(1), workout(2)]
        let store = HealthDashboardSetHeartRateStore(provider: provider)
        store.updateWorkouts(sessions, range: .all)
        let task = try XCTUnwrap(store.load())
        guard await waitUntil({ provider.reads.count == sessions.count }) else { return }
        provider.release(sessions[0], failing: true)
        guard await waitUntil({ store.completedCount == 1 }) else { return }
        provider.release(sessions[2], failing: true)
        provider.release(sessions[1])
        await task.value

        XCTAssertEqual(store.failures.map(\.id), [sessions[2].id, sessions[0].id])
        let snapshot = try XCTUnwrap(store.snapshots[sessions[1].id])
        XCTAssertEqual(snapshot.metrics.map(\.metric), [.heartRate])
        let samples = try XCTUnwrap(snapshot.metrics.first?.samples)
        XCTAssertEqual(samples.count, WorkoutHealthSnapshot.maximumHeartRateSamples)
        XCTAssertTrue(samples.allSatisfy { $0.date == snapshot.startedAt && $0.value == 120 })
        XCTAssertEqual(store.completedCount, 3)
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    private func assertCleared(_ store: HealthDashboardSetHeartRateStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(store.snapshots.isEmpty, file: file, line: line)
        XCTAssertTrue(store.failures.isEmpty, file: file, line: line)
        XCTAssertEqual(store.completedCount, 0, file: file, line: line)
        XCTAssertFalse(store.isLoading, file: file, line: line)
        XCTAssertFalse(store.hasLoaded, file: file, line: line)
    }
}
