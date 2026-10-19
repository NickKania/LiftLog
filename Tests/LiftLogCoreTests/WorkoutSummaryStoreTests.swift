import Foundation
import XCTest
@testable import LiftLogCore

private final class SummaryTransport: ChatGPTInferenceTransport {
    var requests: [URLRequest] = []
    var responseText = "Summary ready"
    var streamError: Error?
    var streamDelayNanoseconds: UInt64?

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = try JSONSerialization.data(withJSONObject: ["models": [[
            "slug": "summary-model", "display_name": "Summary", "visibility": "list"
        ]]])
        return (data, response(request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests.append(request)
        if let streamError { throw streamError }
        if let streamDelayNanoseconds {
            try await Task.sleep(nanoseconds: streamDelayNanoseconds)
        }
        let output: [[String: Any]] = [[
            "type": "message", "role": "assistant", "status": "completed",
            "content": [["type": "output_text", "text": responseText]]
        ]]
        let event: [String: Any] = [
            "type": "response.completed",
            "response": ["status": "completed", "output": output]
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        return ChatGPTHTTPStream(response: response(request), lines: AsyncThrowingStream { continuation in
            continuation.yield("data: \(String(decoding: data, as: UTF8.self))")
            continuation.yield("")
            continuation.finish()
        })
    }

    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
private final class SummaryHealthProvider: WorkoutHealthDataProviding {
    var reads = 0
    var error: Error?
    var suspend = false
    var emptySamples = false
    private var continuation: CheckedContinuation<WorkoutHealthSnapshot, Error>?
    private var suspendedWorkout: WorkoutSession?
    private var suspendedThrough: Date?

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        reads += 1
        if let error { throw error }
        if suspend {
            suspendedWorkout = workout
            suspendedThrough = through
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            }, onCancel: {
                Task { @MainActor [weak self] in
                    self?.resume(with: CancellationError())
                }
            })
        }
        let end = min(workout.finishedAt ?? through, through)
        let samples: [WorkoutHealthSample] = emptySamples ? [] : [
            WorkoutHealthSample(date: workout.startedAt, value: 145)
        ]
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
                                     startedAt: workout.startedAt, endedAt: end, fetchedAt: through,
                                     metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: samples)])
    }

    func resume(with error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) }
        else {
            let workout = suspendedWorkout!
            let through = suspendedThrough!
            let end = min(workout.finishedAt ?? through, through)
            continuation.resume(returning: WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
                startedAt: workout.startedAt, endedAt: end, fetchedAt: through,
                metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: [
                    WorkoutHealthSample(date: workout.startedAt, value: 145)
                ])]))
        }
        suspendedWorkout = nil
        suspendedThrough = nil
    }
}

final class WorkoutSummaryStoreTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutSummaryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func completedWorkout(in store: WorkoutStore) throws -> WorkoutSession {
        let template = try XCTUnwrap(store.templates.first)
        XCTAssertTrue(store.startWorkout(template: template))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        return try XCTUnwrap(store.history.first)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }

    @MainActor
    func testGeneratesEphemeralSummaryWithoutToolsAndHonorsCustomPrompt() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        XCTAssertTrue(store.setWorkoutSummaryPrompt("Focus on volume and progression."))
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)

        XCTAssertEqual(summary.text, "Summary ready")
        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.errorMessage)
        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 0)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        XCTAssertTrue(inputJSON.contains("targetWorkout"))
        XCTAssertTrue(inputJSON.contains("Focus on volume and progression."))
        XCTAssertTrue((body["instructions"] as? String)?.contains("Never invent a workout") == true)
        XCTAssertEqual(store.history.first, workout)
    }

    @MainActor
    func testHealthIsOptInAndProviderFailureFallsBackWithNotice() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        provider.error = WorkoutHealthDataError.unavailable
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           healthDataProvider: provider)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(provider.reads, 0)
        XCTAssertNil(summary.healthNotice)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true)
        XCTAssertEqual(provider.reads, 1)
        XCTAssertTrue(summary.healthNotice?.contains("unavailable") == true)
        XCTAssertEqual(transport.requests.count, 2)
    }

    @MainActor
    func testHealthSnapshotAndReplyDoNotLeakIntoAFollowingPlainRequest() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           healthDataProvider: provider)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true)
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)

        let request = try XCTUnwrap(transport.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? String)
        let evidence = try XCTUnwrap(content.components(separatedBy: "Evidence JSON:\n").last)
        let evidenceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any])
        XCTAssertNil(evidenceObject["health"] as? [String: Any])
        XCTAssertFalse(content.contains("145"))
        XCTAssertFalse(content.contains("Summary ready"))
    }

    @MainActor
    func testEmptyHealthSnapshotFallsBackToWorkoutOnlyWithNotice() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        provider.emptySamples = true
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           healthDataProvider: provider)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true)

        XCTAssertTrue(summary.healthNotice?.contains("No Apple Health readings") == true)
        let request = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? String)
        let evidence = try XCTUnwrap(content.components(separatedBy: "Evidence JSON:\n").last)
        let evidenceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any])
        XCTAssertNil(evidenceObject["health"] as? [String: Any])
    }

    @MainActor
    func testCancelDuringHealthReadClearsStateAndDoesNotSendRequest() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        provider.suspend = true
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           healthDataProvider: provider)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true) }

        await waitUntil { provider.reads == 1 }
        summary.cancel()
        await generation.value

        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.workoutID)
        XCTAssertEqual(summary.text, "")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testViewTaskCancellationDuringRequestDoesNotPublishLateResult() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let transport = SummaryTransport()
        transport.streamDelayNanoseconds = 10_000_000_000
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)
        let generation = Task {
            await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        }

        await waitUntil { transport.requests.count == 1 }
        generation.cancel()
        await generation.value

        XCTAssertFalse(summary.isWorking)
        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.errorMessage)
    }

    @MainActor
    func testDeletingWorkoutDuringHealthReadRejectsLateResult() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        provider.suspend = true
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           healthDataProvider: provider)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true) }

        await waitUntil { provider.reads == 1 }
        XCTAssertTrue(store.deleteWorkout(id: workout.id))
        provider.resume()
        await generation.value

        XCTAssertFalse(summary.isWorking)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(summary.errorMessage == nil || summary.errorMessage?.contains("changed") == true)
    }

    @MainActor
    func testAccountIdentityChangeRejectsResultBeforeDispatch() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let provider = SummaryHealthProvider()
        provider.suspend = true
        let transport = SummaryTransport()
        var account = "account-a"
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport,
                                           accountIdentity: { account }, healthDataProvider: provider)
        let generation = Task {
            await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: true)
        }

        await waitUntil { provider.reads == 1 }
        account = "account-b"
        provider.resume()
        await generation.value

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(summary.errorMessage?.contains("changed") == true)
        XCTAssertEqual(summary.text, "")
    }

    @MainActor
    func testNetworkFailureCanBeRetriedAndEmptyResponseIsActionable() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let transport = SummaryTransport()
        transport.streamError = ChatGPTInferenceError("Network unavailable.")
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertTrue(summary.errorMessage?.contains("Network unavailable") == true)
        XCTAssertEqual(summary.text, "")

        transport.streamError = nil
        transport.responseText = ""
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertTrue(summary.errorMessage?.contains("empty") == true)
        XCTAssertEqual(summary.text, "")

        transport.responseText = "Retry succeeded"
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Retry succeeded")
        XCTAssertNil(summary.errorMessage)
    }

    @MainActor
    func testRegenerationFailurePreservesPreviousSummaryWithoutReplay() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Summary ready")
        transport.streamError = ChatGPTInferenceError("Temporary network failure.")
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)

        XCTAssertEqual(summary.text, "Summary ready")
        XCTAssertTrue(summary.errorMessage?.contains("Temporary network failure") == true)
        let request = try XCTUnwrap(transport.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? String)
        XCTAssertFalse(content.contains("Summary ready"))
    }

    @MainActor
    func testChangedWorkoutDoesNotRetainEarlierReplyWhenRefreshFails() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Summary ready")
        XCTAssertTrue(store.renameWorkout(id: workout.id, name: "Updated workout"))
        transport.streamError = ChatGPTInferenceError("Temporary network failure.")
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "")
        XCTAssertNotNil(summary.errorMessage)
    }

    @MainActor
    func testAccountChangeClearsDisplayedReply() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: { "token" }, transport: transport)

        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Summary ready")
        summary.accountWillChange()

        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.workoutID)
        XCTAssertNil(summary.errorMessage)
        XCTAssertFalse(summary.isWorking)
    }
}
