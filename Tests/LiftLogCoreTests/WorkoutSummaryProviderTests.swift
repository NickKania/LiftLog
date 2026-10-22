import Foundation
import XCTest
@testable import LiftLogCore

@MainActor
private final class SummaryLocalInferenceClient: AppleFoundationModelsProviding {
    struct Request {
        let model: String
        let input: [[String: Any]]
        let tools: [[String: Any]]
        let instructions: String
    }

    var availability: AppleFoundationModelsAvailability = .available
    var requests: [Request] = []
    var responseText = "Local summary ready"
    var error: Error?
    var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func models() async throws -> [ChatGPTModel] { AppleFoundationModelsModel.catalog }

    func respond(model: String, input: [[String: Any]], tools: [[String: Any]],
                 instructions: String, onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        requests.append(Request(model: model, input: input, tools: tools, instructions: instructions))
        _ = try FoundationModelsRequest(input: input, tools: tools, instructions: instructions)
        onText("Uncommitted partial summary")
        if suspend {
            // Deliberately ignore cancellation to verify the store rejects late output.
            await withCheckedContinuation { continuation = $0 }
        }
        if let error { throw error }
        return ChatGPTInferenceResponse(text: responseText, output: [], calls: [])
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

final class WorkoutSummaryProviderTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutSummaryProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    private func completedWorkout(in store: WorkoutStore) throws -> WorkoutSession {
        XCTAssertTrue(store.startWorkout(template: try XCTUnwrap(store.templates.first)))
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

    private func evidence(in request: SummaryLocalInferenceClient.Request) throws -> [String: Any] {
        try XCTUnwrap(request.input.first?["evidence"] as? [String: Any])
    }

    @MainActor
    func testOrdinaryMultiSessionSummaryFitsRealNativeProjection() async throws {
        let store = WorkoutStore(fileURL: try file())
        let sessions = SummaryBudgetFixtures.sessions()
        _ = store.importWorkouts(sessions)
        XCTAssertEqual(store.history.count, 9, store.errorMessage ?? "Fixture import failed")
        let workout = try XCTUnwrap(store.history.first)
        let local = SummaryLocalInferenceClient()
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: {
            XCTFail("A local summary must not read cloud credentials")
            return ""
        }, transport: transport, selectedProvider: { .appleFoundationModels }, localInferenceClient: local)

        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)

        XCTAssertNil(summary.errorMessage)
        XCTAssertEqual(summary.text, "Local summary ready")
        let request = try XCTUnwrap(local.requests.first)
        _ = try FoundationModelsRequest(input: request.input, tools: request.tools, instructions: request.instructions)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testLocalSummaryPreservesRecordedFactsAndPromptWithoutCredentialsOrNetwork() async throws {
        let store = WorkoutStore(fileURL: try file())
        let earlier = try completedWorkout(in: store)
        let workout = try completedWorkout(in: store)
        XCTAssertTrue(store.setWorkoutSummaryPrompt("Compare the recorded targets and completed reps."))
        let transport = SummaryTransport()
        let local = SummaryLocalInferenceClient()
        var provider: AssistantProvider = .appleFoundationModels
        var credentialReads = 0
        let summary = WorkoutSummaryStore(store: store, accessToken: {
            credentialReads += 1
            return "synthetic-token"
        }, transport: transport, selectedProvider: { provider }, localInferenceClient: local)

        await summary.generate(workoutID: workout.id, model: "stale-cloud-model", includeHealth: false)

        XCTAssertEqual(summary.text, "Local summary ready")
        XCTAssertNil(summary.errorMessage)
        XCTAssertEqual(credentialReads, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        let localRequest = try XCTUnwrap(local.requests.first)
        XCTAssertEqual(localRequest.model, AppleFoundationModelsModel.slug)
        XCTAssertTrue(localRequest.tools.isEmpty)
        let payload = try evidence(in: localRequest)
        let target = try XCTUnwrap(payload["completedWorkout"] as? [String: Any])
        XCTAssertEqual(target["name"] as? String, workout.name)
        XCTAssertEqual(target["unit"] as? String, workout.unit.rawValue)
        let history = try XCTUnwrap(payload["earlierCompletedWorkouts"] as? [[String: Any]])
        XCTAssertEqual(history.first?["startedAt"] as? String, ISO8601DateFormatter().string(from: earlier.startedAt))

        summary.providerWillChange()
        provider = .chatGPT
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        let cloudRequest = try XCTUnwrap(transport.requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cloudRequest.httpBody)) as? [String: Any])
        let cloudInput = try XCTUnwrap(body["input"] as? [[String: Any]])
        let cloudContent = try XCTUnwrap(cloudInput.first?["content"] as? String)
        let localContent = try XCTUnwrap(localRequest.input.first?["content"] as? String)
        XCTAssertEqual(cloudContent.components(separatedBy: "Evidence JSON:\n").first?.trimmingCharacters(in: .whitespacesAndNewlines),
                       localContent.trimmingCharacters(in: .whitespacesAndNewlines))
        let cloudEvidence = try XCTUnwrap(cloudContent.components(separatedBy: "Evidence JSON:\n").last)
        let cloudPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cloudEvidence.utf8)) as? [String: Any])
        let cloudTarget = try XCTUnwrap(cloudPayload["targetWorkout"] as? [String: Any])
        XCTAssertEqual(cloudTarget["id"] as? String, workout.id.uuidString)
        XCTAssertEqual(cloudTarget["name"] as? String, target["name"] as? String)
        XCTAssertEqual(cloudTarget["unit"] as? String, target["unit"] as? String)
        let localExercises = try XCTUnwrap(target["exercises"] as? [[String: Any]])
        let set = try XCTUnwrap(workout.exercises.first?.sets.first)
        XCTAssertEqual(localExercises.first?["completedActual"] as? String,
                       "1 sets: \(set.weight) \(workout.unit.rawValue) x \(set.reps) reps each")
        XCTAssertEqual(body["instructions"] as? String, WorkoutSummaryRequest.immutableInstructions)
        XCTAssertTrue(localRequest.instructions.contains("Never invent a workout"))
        XCTAssertTrue(localRequest.instructions.contains("Do not call tools"))
        XCTAssertTrue((localRequest.input.first?["content"] as? String)?.contains(store.workoutSummaryPrompt) == true)
        XCTAssertEqual(store.history.first, workout)
    }

    @MainActor
    func testLocalHealthIsExplicitEphemeralAndExcludedFromNextRequest() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let workout = try completedWorkout(in: store)
        let health = SummaryHealthProvider()
        let local = SummaryLocalInferenceClient()
        let transport = SummaryTransport()
        let summary = WorkoutSummaryStore(store: store, accessToken: {
            XCTFail("Local generation must not request credentials")
            return ""
        }, transport: transport, healthDataProvider: health,
        selectedProvider: { .appleFoundationModels }, localInferenceClient: local)
        XCTAssertEqual(health.reads, 0)

        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        XCTAssertEqual(health.reads, 0)
        XCTAssertNil(try evidence(in: XCTUnwrap(local.requests.last))["health"])

        local.responseText = "Ephemeral Health reply: heart rate 145"
        await summary.generate(workoutID: workout.id, model: "", includeHealth: true)
        XCTAssertEqual(health.reads, 1)
        XCTAssertNotNil(try evidence(in: XCTUnwrap(local.requests.last))["health"])

        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        let plain = try XCTUnwrap(local.requests.last)
        XCTAssertNil(try evidence(in: plain)["health"])
        XCTAssertEqual(plain.input.count, 1)
        XCTAssertFalse((plain.input.first?["content"] as? String)?.contains("Ephemeral Health reply") == true)
        XCTAssertEqual(health.reads, 1)
        XCTAssertTrue(transport.requests.isEmpty)
        summary.cancel()
        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.healthNotice)
        XCTAssertEqual(WorkoutStore(fileURL: url).history, store.history)
    }

    @MainActor
    func testLocalUnavailableAndSizeFailureStayLocalAndCanBeRetried() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let health = SummaryHealthProvider()
        let local = SummaryLocalInferenceClient()
        local.availability = .modelNotReady
        let transport = SummaryTransport()
        var credentialReads = 0
        let summary = WorkoutSummaryStore(store: store, accessToken: {
            credentialReads += 1
            return "synthetic-token"
        }, transport: transport, healthDataProvider: health,
        selectedProvider: { .appleFoundationModels }, localInferenceClient: local)

        await summary.generate(workoutID: workout.id, model: "", includeHealth: true)
        XCTAssertEqual(summary.errorMessage, local.availability.explanation)
        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertEqual(health.reads, 0)

        local.availability = .available
        // A valid preference that exceeds the real local request budget. No fake
        // transport error can stand in for the production projection here.
        XCTAssertTrue(store.setWorkoutSummaryPrompt(String(repeating: "🏋️", count: WorkoutSummaryPrompt.maximumLength)))
        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        XCTAssertTrue(summary.errorMessage?.contains("Shorten your summary prompt") == true)
        XCTAssertFalse(summary.errorMessage?.contains("start a new chat") == true)
        XCTAssertEqual(summary.text, "")
        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertEqual(credentialReads, 0)
        XCTAssertTrue(transport.requests.isEmpty)

        XCTAssertTrue(store.setWorkoutSummaryPrompt(WorkoutSummaryPrompt.defaultPrompt))
        local.responseText = " "
        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        XCTAssertTrue(summary.errorMessage?.contains("Apple Intelligence returned an empty") == true)
        local.responseText = "Retry succeeded locally"
        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        XCTAssertEqual(summary.text, "Retry succeeded locally")
        XCTAssertNil(summary.errorMessage)
    }

    @MainActor
    func testProviderSwitchDuringHealthReadCancelsAndDoesNotForwardConsent() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let health = SummaryHealthProvider()
        health.suspend = true
        let local = SummaryLocalInferenceClient()
        let transport = SummaryTransport()
        var provider: AssistantProvider = .appleFoundationModels
        let summary = WorkoutSummaryStore(store: store, accessToken: { "synthetic-token" }, transport: transport,
            healthDataProvider: health, selectedProvider: { provider }, localInferenceClient: local)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "", includeHealth: true) }
        await waitUntil { health.reads == 1 }

        summary.providerWillChange()
        provider = .chatGPT
        await generation.value

        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(summary.isWorking)
        XCTAssertNil(summary.workoutID)
        XCTAssertNil(summary.errorMessage)
        XCTAssertNil(summary.healthNotice)
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Summary ready")
        XCTAssertEqual(health.reads, 1)
    }

    @MainActor
    func testProviderIdentityIsRecheckedAfterHealthEvenWithoutCancellationCallback() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let health = SummaryHealthProvider()
        health.suspend = true
        let local = SummaryLocalInferenceClient()
        let transport = SummaryTransport()
        var provider: AssistantProvider = .appleFoundationModels
        let summary = WorkoutSummaryStore(store: store, accessToken: { "synthetic-token" }, transport: transport,
            healthDataProvider: health, selectedProvider: { provider }, localInferenceClient: local)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "", includeHealth: true) }
        await waitUntil { health.reads == 1 }

        provider = .chatGPT
        health.resume()
        await generation.value

        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.workoutID)
        XCTAssertNil(summary.healthNotice)
    }

    @MainActor
    func testLateLocalOutputCannotReplaceNewProviderSummary() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let local = SummaryLocalInferenceClient()
        local.suspend = true
        let transport = SummaryTransport()
        var provider: AssistantProvider = .appleFoundationModels
        let summary = WorkoutSummaryStore(store: store, accessToken: { "synthetic-token" }, transport: transport,
            selectedProvider: { provider }, localInferenceClient: local)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "", includeHealth: false) }
        await waitUntil { local.requests.count == 1 }
        XCTAssertEqual(summary.text, "")

        summary.providerWillChange()
        provider = .chatGPT
        await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        XCTAssertEqual(summary.text, "Summary ready")
        local.resume()
        await generation.value

        XCTAssertEqual(summary.text, "Summary ready")
        XCTAssertNil(summary.errorMessage)
        XCTAssertFalse(summary.isWorking)
    }

    @MainActor
    func testProviderSwitchDuringCredentialAcquisitionPreventsCloudDispatch() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let local = SummaryLocalInferenceClient()
        let transport = SummaryTransport()
        var provider: AssistantProvider = .chatGPT
        var credentialContinuation: CheckedContinuation<String, Never>?
        let summary = WorkoutSummaryStore(store: store, accessToken: {
            await withCheckedContinuation { credentialContinuation = $0 }
        }, transport: transport, selectedProvider: { provider }, localInferenceClient: local)
        let generation = Task {
            await summary.generate(workoutID: workout.id, model: "summary-model", includeHealth: false)
        }
        await waitUntil { credentialContinuation != nil }

        summary.providerWillChange()
        provider = .appleFoundationModels
        credentialContinuation?.resume(returning: "synthetic-token")
        await generation.value

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertEqual(summary.text, "")
        await summary.generate(workoutID: workout.id, model: "", includeHealth: false)
        XCTAssertEqual(summary.text, "Local summary ready")
    }

    @MainActor
    func testChatGPTAccountChangesLeaveLocalGenerationAndResponseIntact() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let health = SummaryHealthProvider()
        health.suspend = true
        let local = SummaryLocalInferenceClient()
        var account = "account-a"
        var identityReads = 0
        let summary = WorkoutSummaryStore(store: store, accessToken: { "" }, accountIdentity: {
            identityReads += 1
            return account
        }, healthDataProvider: health, selectedProvider: { .appleFoundationModels }, localInferenceClient: local)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "", includeHealth: true) }
        await waitUntil { health.reads == 1 }

        summary.accountWillChange()
        account = "account-b"
        XCTAssertTrue(summary.isWorking)
        health.resume()
        await generation.value

        XCTAssertEqual(summary.text, "Local summary ready")
        summary.accountWillChange()
        XCTAssertEqual(summary.text, "Local summary ready")
        XCTAssertEqual(identityReads, 0)
        summary.providerWillChange()
        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.workoutID)
    }

    @MainActor
    func testLocalViewTaskCancellationRejectsLateOutput() async throws {
        let store = WorkoutStore(fileURL: try file())
        let workout = try completedWorkout(in: store)
        let local = SummaryLocalInferenceClient()
        local.suspend = true
        let summary = WorkoutSummaryStore(store: store, accessToken: { "" },
            selectedProvider: { .appleFoundationModels }, localInferenceClient: local)
        let generation = Task { await summary.generate(workoutID: workout.id, model: "", includeHealth: false) }
        await waitUntil { local.requests.count == 1 }

        generation.cancel()
        local.resume()
        await generation.value

        XCTAssertEqual(summary.text, "")
        XCTAssertNil(summary.errorMessage)
        XCTAssertFalse(summary.isWorking)
    }
}
