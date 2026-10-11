import Foundation
import XCTest
@testable import LiftLogCore

@MainActor
private final class DashboardHealthProvider: WorkoutHealthDataProviding {
    enum Outcome { case samples, empty, failure, wrongSession }
    struct Read { let workout: WorkoutSession; let through: Date }
    var reads: [Read] = []
    var outcomes: [UUID: Outcome] = [:]
    var suspends = false
    private var pending: [Int: CheckedContinuation<WorkoutHealthSnapshot, Error>] = [:]

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        let index = reads.count
        reads.append(Read(workout: workout, through: through))
        if suspends {
            // Intentionally ignores task cancellation to exercise stale-result protection.
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }
        switch outcomes[workout.id] ?? .samples {
        case .failure: throw WorkoutHealthDataError.unavailable
        case .empty: return snapshot(for: workout, through: through, value: nil)
        case .wrongSession: return snapshot(for: WorkoutSession(startedAt: workout.startedAt), through: through)
        case .samples: return snapshot(for: workout, through: through)
        }
    }

    func release(_ index: Int, value: Double = 120) {
        let read = reads[index]
        pending.removeValue(forKey: index)?.resume(returning: snapshot(for: read.workout, through: read.through, value: value))
    }

    func snapshot(for workout: WorkoutSession, through: Date, value: Double? = 120) -> WorkoutHealthSnapshot {
        WorkoutHealthSnapshot(workoutID: workout.id, workoutName: "Provider name", startedAt: workout.startedAt,
            endedAt: through, fetchedAt: through,
            metrics: value.map { [WorkoutHealthMetricSeries(metric: .heartRate,
                samples: [WorkoutHealthSample(date: workout.startedAt, value: $0)])] } ?? [])
    }
}

final class HealthDashboardHealthStoreTests: XCTestCase {
    private func workout(_ name: String = "Workout") -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return WorkoutSession(name: name, startedAt: start, finishedAt: start.addingTimeInterval(600))
    }

    @MainActor
    private func waitForReads(_ count: Int, provider: DashboardHealthProvider) async {
        for _ in 0..<10_000 {
            if provider.reads.count == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) Health reads; saw \(provider.reads.count)")
    }

    @MainActor
    func testInitializationAndHistoryChangesNeverReadUntilExplicitLoad() async throws {
        let provider = DashboardHealthProvider()
        let store = HealthDashboardHealthStore(provider: provider)
        XCTAssertNil(store.load())
        let completed = workout()
        store.updateWorkouts([completed, WorkoutSession()])
        await Task.yield()
        XCTAssertTrue(provider.reads.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(store.workoutCount, 1)
        let task = try XCTUnwrap(store.load())
        await task.value
        XCTAssertEqual(provider.reads.map(\.workout.id), [completed.id])
        XCTAssertEqual(provider.reads.first?.through, completed.finishedAt)
        XCTAssertEqual(store.snapshots[completed.id]?.workoutName, completed.name)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        store.updateWorkouts([completed])
        XCTAssertTrue(store.hasLoaded, "Unchanged inputs preserve the explicitly requested result")
        store.updateWorkouts([workout("New history")])
        await Task.yield()
        XCTAssertEqual(provider.reads.count, 1)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertFalse(store.hasLoaded)
    }

    @MainActor
    func testReadsAreSequentialAndCancelStopsFurtherSessionsAndClearsResults() async throws {
        let provider = DashboardHealthProvider()
        provider.suspends = true
        let store = HealthDashboardHealthStore(provider: provider)
        store.updateWorkouts([workout("First"), workout("Second"), workout("Third")])
        let task = try XCTUnwrap(store.load())
        await waitForReads(1, provider: provider)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(provider.reads.count, 1)
        provider.release(0)
        await waitForReads(2, provider: provider)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.completedCount, 1)
        store.cancel()
        provider.release(1)
        await task.value
        XCTAssertEqual(provider.reads.count, 2)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertEqual(store.completedCount, 0)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasLoaded)
    }

    @MainActor
    func testChangedSessionInvalidatesSuspendedReadEvenWhenIDStaysTheSame() async throws {
        let provider = DashboardHealthProvider()
        provider.suspends = true
        let store = HealthDashboardHealthStore(provider: provider)
        var session = workout()
        store.updateWorkouts([session])
        let oldTask = try XCTUnwrap(store.load())
        await waitForReads(1, provider: provider)
        session.finishedAt = session.finishedAt?.addingTimeInterval(300)
        store.updateWorkouts([session])
        provider.release(0)
        await oldTask.value
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(provider.reads.count, 1, "Changing history does not start a replacement read")
    }

    @MainActor
    func testRangeChangeClearsLoadedReadingsEvenWhenWorkoutsAreIdentical() async throws {
        let provider = DashboardHealthProvider()
        let store = HealthDashboardHealthStore(provider: provider)
        let sessions = [workout("Measured"), workout("Failed")]
        provider.outcomes[sessions[1].id] = .failure
        store.updateWorkouts(sessions, range: .year)
        let task = try XCTUnwrap(store.load())
        await task.value
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.failures.count, 1)
        XCTAssertEqual(store.completedCount, 2)
        XCTAssertTrue(store.hasLoaded)

        store.updateWorkouts(sessions, range: .year)
        XCTAssertTrue(store.hasLoaded, "The same workouts and range preserve requested readings")
        store.updateWorkouts(sessions, range: .all)
        await Task.yield()
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertEqual(store.completedCount, 0)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(provider.reads.count, 2, "Changing the range does not automatically read Health")

        let reload = try XCTUnwrap(store.load())
        await reload.value
        XCTAssertEqual(provider.reads.count, 4)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testRangeChangeClearsPartialResultsAndRejectsSuspendedStaleRead() async throws {
        let provider = DashboardHealthProvider()
        provider.suspends = true
        let store = HealthDashboardHealthStore(provider: provider)
        let sessions = [workout("First"), workout("Second"), workout("Third")]
        store.updateWorkouts(sessions, range: .year)
        let staleTask = try XCTUnwrap(store.load())
        await waitForReads(1, provider: provider)
        provider.release(0)
        await waitForReads(2, provider: provider)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.completedCount, 1)

        store.updateWorkouts(sessions, range: .all)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(store.completedCount, 0)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.hasLoaded)
        provider.release(1)
        await staleTask.value
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.failures.isEmpty)
        XCTAssertEqual(store.completedCount, 0)
        XCTAssertFalse(store.hasLoaded)
        XCTAssertEqual(provider.reads.count, 2, "The old read must not continue or start a replacement")
    }

    @MainActor
    func testOlderRefreshCannotOverwriteNewerResult() async throws {
        let provider = DashboardHealthProvider()
        provider.suspends = true
        let store = HealthDashboardHealthStore(provider: provider)
        let session = workout()
        store.updateWorkouts([session])
        let oldTask = try XCTUnwrap(store.load())
        await waitForReads(1, provider: provider)
        let newTask = try XCTUnwrap(store.load())
        await waitForReads(2, provider: provider)
        provider.release(1, value: 140)
        await newTask.value
        provider.release(0, value: 90)
        await oldTask.value
        XCTAssertEqual(store.snapshots[session.id]?.metrics.first?.samples.first?.value, 140)
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertTrue(store.hasLoaded)
    }

    @MainActor
    func testPartialFailuresAndEmptyReadsRemainDistinctAndDoNotInventMetrics() async throws {
        let provider = DashboardHealthProvider()
        let sessions = [workout("Measured"), workout("Empty"), workout("Failed"), workout("Wrong session")]
        provider.outcomes[sessions[1].id] = .empty
        provider.outcomes[sessions[2].id] = .failure
        provider.outcomes[sessions[3].id] = .wrongSession
        let store = HealthDashboardHealthStore(provider: provider)
        store.updateWorkouts(sessions)
        let task = try XCTUnwrap(store.load())
        await task.value
        XCTAssertEqual(provider.reads.map(\.workout.id), sessions.map(\.id))
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.emptyWorkoutCount, 1)
        XCTAssertTrue(try XCTUnwrap(store.snapshots[sessions[1].id]).metrics.isEmpty)
        XCTAssertEqual(store.failures.map(\.id), [sessions[2].id, sessions[3].id])
        XCTAssertEqual(store.failures.first?.message, WorkoutHealthDataError.unavailable.localizedDescription)
        XCTAssertEqual(store.completedCount, 4)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isLoading)
    }
}
