import Foundation
import XCTest
@testable import LiftLogCore

private final class ProviderCloudTransport: ChatGPTInferenceTransport {
    var requests = 0
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        throw ChatGPTInferenceError("Unexpected cloud request")
    }
    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests += 1
        throw ChatGPTInferenceError("Unexpected cloud request")
    }
}

@MainActor
private final class ProviderLocalClient: AppleFoundationModelsProviding {
    struct Request {
        let input: [[String: Any]]
        let tools: [[String: Any]]
        let instructions: String
    }
    var availability: AppleFoundationModelsAvailability = .available
    var replies: [ChatGPTInferenceResponse] = []
    var requests: [Request] = []
    var modelLoads = 0
    var failure: Error?
    var suspended = false
    var continuation: CheckedContinuation<ChatGPTInferenceResponse, Error>?
    var lateText: ((String) -> Void)?
    var validatesNativeBudget = false
    var dispatchFailures: [Int: FoundationModelsToolDispatchError] = [:]

    func models() async throws -> [ChatGPTModel] { modelLoads += 1; return AppleFoundationModelsModel.catalog }
    func respond(model: String, input: [[String: Any]], tools: [[String: Any]], instructions: String,
                 onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        XCTAssertEqual(model, AppleFoundationModelsModel.slug)
        if validatesNativeBudget {
            _ = try FoundationModelsRequest(input: input, tools: tools, instructions: instructions)
        }
        requests.append(Request(input: input, tools: tools, instructions: instructions))
        let requestIndex = requests.count - 1
        if suspended {
            return try await withoutActuallyEscaping(onText) { callback in
                lateText = callback
                defer { lateText = nil }
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        if let failure { throw failure }
        if let dispatch = dispatchFailures[requestIndex] { throw dispatch }
        if tools.isEmpty { return Self.answer("Local training conversation") }
        return replies.isEmpty ? Self.answer("Local answer") : replies.removeFirst()
    }

    static func answer(_ text: String) -> ChatGPTInferenceResponse {
        ChatGPTInferenceResponse(text: text, output: [["role": "assistant", "content": text]], calls: [])
    }
    static func call(_ name: String, _ arguments: [String: Any], id: String = UUID().uuidString) throws -> ChatGPTInferenceResponse {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        return ChatGPTInferenceResponse(text: "", output: [["type": "function_call", "call_id": id, "name": name, "arguments": json]],
            calls: [ChatGPTFunctionCall(callID: id, name: name, namespace: "liftlog", arguments: json)])
    }
}

@MainActor
private final class ProviderHealthData: WorkoutHealthDataProviding {
    var reads = 0
    var sampleCount = 1
    var includesAllMetrics = false
    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        reads += 1
        let metrics: [WorkoutHealthMetric] = includesAllMetrics ? [.heartRate, .activeEnergy, .steps] : [.heartRate]
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
            startedAt: workout.startedAt, endedAt: workout.finishedAt ?? through, fetchedAt: through,
            metrics: metrics.map { metric in .init(metric: metric, samples: (0..<sampleCount).map {
                .init(date: workout.startedAt.addingTimeInterval(Double($0 + 1)), value: metric == .heartRate ? 151.873 : 2)
            }) })
    }
}

final class AssistantProviderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantProviders-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled provider state", file: file, line: line)
    }

    @MainActor
    func testLocalModelsAnswersAndTitlesNeverUseCloudOrCredentials() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient(), cloud = ProviderCloudTransport()
        var tokenReads = 0
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let assistant = WorkoutAssistant(store: store, accessToken: { tokenReads += 1; return "unused" },
            transport: cloud, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        await assistant.refreshModels()
        XCTAssertTrue(assistant.canUseSelectedProvider)
        XCTAssertEqual(assistant.models, AppleFoundationModelsModel.catalog)
        XCTAssertTrue(assistant.send("Help me train consistently"))
        await wait { !assistant.isWorking && assistant.selectedChat?.hasGeneratedTitle == true }
        XCTAssertEqual(assistant.selectedChat?.title, "Local training conversation")
        XCTAssertEqual(cloud.requests, 0)
        XCTAssertEqual(tokenReads, 0)
        XCTAssertEqual(local.requests.count, 2)
        XCTAssertTrue(local.requests.last?.tools.isEmpty == true)
    }

    @MainActor
    func testAvailabilityReasonsAndRuntimeChangeNeverFallbackToCloud() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient(), cloud = ProviderCloudTransport()
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
            accessToken: { XCTFail("Unexpected token read"); return "unused" }, transport: cloud, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        for availability: AppleFoundationModelsAvailability in [.requiresIOS26, .deviceNotEligible, .appleIntelligenceNotEnabled,
            .modelNotReady, .frameworkUnavailable, .unavailable] {
            local.availability = availability
            await assistant.refreshModels()
            XCTAssertFalse(assistant.canUseSelectedProvider)
            XCTAssertEqual(assistant.appleFoundationModelsAvailability.explanation, availability.explanation)
            XCTAssertFalse(assistant.send("Hello"))
            XCTAssertNil(assistant.errorMessage, "Availability already has a dedicated UI reason")
        }
        local.availability = .available
        assistant.refreshProviderAvailability()
        XCTAssertTrue(assistant.canUseSelectedProvider)
        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertEqual(cloud.requests, 0)
    }

    @MainActor
    func testLocalChartsAndProposalsUseSameValidatedToolsAndExplicitApply() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let bench = try XCTUnwrap(store.exercises.first)
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try XCTUnwrap(store.importWorkouts([WorkoutSession(name: "Recorded", startedAt: date,
            finishedAt: date.addingTimeInterval(1800), unit: .lb, importSourceKey: "provider-chart", exercises: [
                WorkoutExercise(exercise: bench, sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])]))
        let local = ProviderLocalClient()
        local.replies = [try ProviderLocalClient.call("graph_workout_history", ["metric": "volume", "unit": "lb"]),
                         ProviderLocalClient.answer("Recorded chart"),
                         try ProviderLocalClient.call("propose_create_template", ["name": "Reviewed local plan", "unit": "lb",
                            "exercises": [["exercise_id": bench.id.uuidString, "sets": [["weight": 100, "reps": 8]]]]]),
                         ProviderLocalClient.answer("Ready for review")]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected token read"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Chart my volume"))
        await wait { !assistant.isWorking && assistant.selectedChat?.isGeneratingTitle == false }
        XCTAssertEqual(assistant.messages.compactMap(\.chart).first?.points.map(\.value), [800])
        XCTAssertTrue(assistant.send("Create a plan for review"))
        await wait { !assistant.isWorking }
        let proposal = try XCTUnwrap(assistant.messages.compactMap(\.proposal).first)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertFalse(store.templates.contains { $0.name == "Reviewed local plan" })
        try assistant.applyProposal(proposal.id)
        XCTAssertEqual(store.templates.first { $0.name == "Reviewed local plan" }?.exercises.first?.sets.count, 1)
        XCTAssertEqual(assistant.messages.compactMap(\.proposal).first?.status, .applied)
        XCTAssertThrowsError(try assistant.applyProposal(proposal.id))
    }

    @MainActor
    func testLocalHealthIsPerMessageEphemeralAndExcludedFromTitlesAndArchives() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Private session", startedAt: date, finishedAt: date.addingTimeInterval(1800),
            unit: .lb, importSourceKey: "provider-health", exercises: [WorkoutExercise(exercise: try XCTUnwrap(store.exercises.first), sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])
        _ = try XCTUnwrap(store.importWorkouts([workout]))
        let local = ProviderLocalClient(), health = ProviderHealthData()
        local.replies = [ProviderLocalClient.answer("PrivatePulseAnswer-97248"), ProviderLocalClient.answer("Ordinary answer")]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected token"); return "" },
            storageURL: archive, healthDataProvider: health, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("PrivateHealthQuestion-8842", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await wait { !assistant.isWorking }
        XCTAssertEqual(health.reads, 1)
        XCTAssertEqual(local.requests.count, 1, "No title generation for Health turns")
        let healthTools = local.requests[0].tools.flatMap { $0["tools"] as? [[String: Any]] ?? [] }.compactMap { $0["name"] as? String }
        XCTAssertTrue(healthTools.contains("graph_workout_health"))
        XCTAssertFalse(healthTools.contains { $0.hasPrefix("propose_") })
        XCTAssertTrue(assistant.send("Ordinary question"))
        await wait { !assistant.isWorking && assistant.selectedChat?.hasGeneratedTitle == true }
        let nextInputs = try JSONSerialization.data(withJSONObject: local.requests.dropFirst().map(\.input))
        let saved = try Data(contentsOf: archive)
        for secret in ["151.873", "selectedHealthSnapshots", "PrivatePulseAnswer-97248", "PrivateHealthQuestion-8842"] {
            XCTAssertFalse(String(decoding: nextInputs, as: UTF8.self).contains(secret))
            XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(secret))
        }
        XCTAssertEqual(health.reads, 1)
    }

    @MainActor
    func testProviderArchivesPersistSelectionAndChatGPTAccountChangesLeaveLocalWorkStable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let local = ProviderLocalClient()
        var account = "A"
        let assistant = WorkoutAssistant(store: store, accessToken: { "unused" }, accountIdentity: { account },
            storageURL: archive, archiveAccountIdentity: { account }, appleFoundationModels: local)
        let cloudChat = try XCTUnwrap(assistant.selectedChatID)
        XCTAssertTrue(assistant.renameChat(cloudChat, title: "Cloud A"))
        assistant.selectedProvider = .appleFoundationModels
        let localChat = assistant.selectedChatID
        local.suspended = true
        XCTAssertTrue(assistant.send("Local work survives account change"))
        await wait { local.continuation != nil }
        assistant.accountWillChange()
        account = "B"
        assistant.reconcileAccount()
        XCTAssertEqual(assistant.selectedChatID, localChat)
        XCTAssertTrue(assistant.isWorking)
        local.suspended = false
        local.continuation?.resume(returning: ProviderLocalClient.answer("Completed locally"))
        local.continuation = nil
        await wait { !assistant.isWorking && assistant.selectedChat?.hasGeneratedTitle == true }
        assistant.saveChats()
        let reopened = WorkoutAssistant(store: store, accessToken: { "unused" }, accountIdentity: { account },
            storageURL: archive, archiveAccountIdentity: { account }, appleFoundationModels: local)
        XCTAssertEqual(reopened.selectedProvider, .appleFoundationModels)
        XCTAssertEqual(reopened.selectedChatID, localChat)
        XCTAssertTrue(reopened.messages.contains { $0.text == "Completed locally" })
        reopened.selectedProvider = .chatGPT
        XCTAssertFalse(reopened.chats.contains { $0.id == cloudChat })
        reopened.accountWillChange()
        account = "A"
        reopened.reconcileAccount()
        XCTAssertEqual(reopened.selectedChat?.title, "Cloud A")
        reopened.selectedProvider = .appleFoundationModels
        XCTAssertEqual(reopened.selectedChatID, localChat)
    }

    @MainActor
    func testProviderSwitchCancelsAndRejectsLateOutputAndCallsSynchronously() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient()
        local.suspended = true
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
            accessToken: { "unused" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Pending local request"))
        let localChat = assistant.selectedChat
        await wait { local.continuation != nil }
        var synchronouslyNotified = false
        assistant.onProviderChange = {
            XCTAssertEqual(assistant.selectedProvider, .appleFoundationModels)
            synchronouslyNotified = true
        }
        assistant.selectedProvider = .chatGPT
        XCTAssertTrue(synchronouslyNotified)
        local.lateText?("Must not appear")
        local.continuation?.resume(returning: ProviderLocalClient.answer("Late result"))
        local.continuation = nil
        await Task.yield()
        XCTAssertFalse(localChat?.isWorking ?? true)
        XCTAssertFalse(localChat?.messages.contains { $0.text.contains("Must not appear") || $0.text == "Late result" } ?? true)
        XCTAssertTrue(assistant.messages.isEmpty)
    }

    @MainActor
    func testLocalToolRoundLimitLeavesNoApplicableProposal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient()
        local.replies = [try ProviderLocalClient.call("get_templates", [:])]
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
            accessToken: { "unused" }, maximumRounds: 1, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Read templates"))
        await wait { !assistant.isWorking }
        XCTAssertTrue(assistant.errorMessage?.contains("tool limit") == true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
    }

    @MainActor
    func testOversizedLocalReferencesFailBeforeAppendingOrSavingTheTurn() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let exercise = try XCTUnwrap(store.exercises.first)
        let template = WorkoutTemplate(name: "Large selected prescription", exercises: (0..<16).map { _ in
            TemplateExercise(exercise: exercise, sets: (0..<10).map { _ in TemplateSet(weight: 100, targetReps: 8) })
        })
        XCTAssertTrue(store.saveTemplate(template))
        let local = ProviderLocalClient(), archive = directory.appendingPathComponent("chats.json")
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" },
            storageURL: archive, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        let saved = try Data(contentsOf: archive)
        let title = assistant.selectedChat?.title
        let reference = AssistantWorkoutReference(template: try XCTUnwrap(store.templates.first { $0.id == template.id }))
        XCTAssertFalse(assistant.send("Preserve this draft for a smaller request", references: [reference]))
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
        XCTAssertEqual(assistant.selectedChat?.title, title)
        XCTAssertEqual(try Data(contentsOf: archive), saved)
        XCTAssertTrue(local.requests.isEmpty)
        XCTAssertTrue(assistant.errorMessage?.contains("context") == true)
    }

    @MainActor
    func testOversizedHistoryAndLibraryRecoverThenProgressAfterSixReadsAndArgumentRetry() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let exercise = try XCTUnwrap(store.exercises.first { $0.name == "Bench Press" })
        for index in 0..<10 {
            XCTAssertTrue(store.saveTemplate(WorkoutTemplate(name: "Progression \(index)", exercises: [
                TemplateExercise(exercise: exercise, sets: [TemplateSet(weight: 100, targetReps: 8)])
            ])))
        }
        let history = (0..<30).map { index in
            let start = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86_400)
            return WorkoutSession(name: "Recorded progression \(index)", startedAt: start,
                finishedAt: start.addingTimeInterval(1800), unit: .lb, importSourceKey: "recovery-\(index)",
                exercises: [WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])],
                notes: String(repeating: "Recorded session note. ", count: 30))
        }
        _ = try XCTUnwrap(store.importWorkouts(history))
        let target = try XCTUnwrap(store.templates.first { $0.name == "Progression 9" })
        let version = try XCTUnwrap(target.currentVersion)
        let entry = try XCTUnwrap(target.exercises.first)
        func proposal(_ reps: Int) throws -> ChatGPTInferenceResponse {
            try ProviderLocalClient.call("propose_template_version", ["template_id": target.id.uuidString,
                "base_version_id": version.id.uuidString, "unit": "lb", "operations": [
                    ["operation": "update", "entry_id": entry.id.uuidString, "exercise_id": exercise.id.uuidString,
                     "sets": [["weight": 100, "reps": reps]]]
                ]])
        }
        let local = ProviderLocalClient()
        local.validatesNativeBudget = true
        local.replies = [
            try ProviderLocalClient.call("get_history", ["limit": 100, "offset": 0], id: "large-history"),
            try ProviderLocalClient.call("get_history", ["limit": 1, "offset": 0]),
            try ProviderLocalClient.call("get_templates", [:], id: "large-library"),
            try ProviderLocalClient.call("get_templates", ["query": target.name, "limit": 1, "offset": 0]),
            try ProviderLocalClient.call("get_workout_data", [:]),
            try ProviderLocalClient.call("get_exercise_catalog", ["query": "Bench Press", "limit": 1, "offset": 0]),
            try proposal(0), try proposal(9), ProviderLocalClient.answer("Review the proposed progression")
        ]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Plan one more rep in Progression 9 using recent history. Prepare a proposal for review."))
        await wait { !assistant.isWorking && assistant.selectedChat?.isGeneratingTitle == false }
        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(local.requests.filter { !$0.tools.isEmpty }.count, 9)
        for id in ["large-history", "large-library"] {
            let item = try XCTUnwrap(local.requests.flatMap(\.input).first { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == id })
            let output = try XCTUnwrap(item["output"] as? String)
            let error = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "on_device_context_limit")
            XCTAssertNil(error["workouts"])
            XCTAssertNil(error["templates"])
        }
        let pending = try XCTUnwrap(assistant.messages.compactMap(\.proposal).last)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(store.templates.first { $0.id == target.id }?.currentVersion?.id, version.id)
        try assistant.applyProposal(pending.id)
        XCTAssertEqual(store.templates.first { $0.id == target.id }?.exercises.first?.sets.first?.targetReps, 9)
    }

    @MainActor
    func testDenseLocalHealthUsesCompleteAggregatesAndKeepsFullChartWithExplicitReceipt() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Dense Health", startedAt: start, finishedAt: start.addingTimeInterval(1800),
            unit: .lb, importSourceKey: "dense-local-health", exercises: [WorkoutExercise(exercise: try XCTUnwrap(store.exercises.first),
                sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])
        _ = try XCTUnwrap(store.importWorkouts([workout]))
        let health = ProviderHealthData(), local = ProviderLocalClient()
        health.sampleCount = 600
        health.includesAllMetrics = true
        local.validatesNativeBudget = true
        local.replies = [try ProviderLocalClient.call("graph_workout_health", ["workout_id": workout.id.uuidString, "metric": "activeEnergy"]),
                         ProviderLocalClient.answer("Inspect your recorded energy chart")]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" },
            healthDataProvider: health, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Graph the energy for this session", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await wait { !assistant.isWorking }
        XCTAssertNil(assistant.errorMessage)
        let first = try XCTUnwrap(local.requests.first?.input.last?["content"] as? String)
        let marker = "\n\nSelected Apple Health data for this message only (JSON):\n"
        let range = try XCTUnwrap(first.range(of: marker))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first[range.upperBound...].utf8)) as? [String: Any])
        XCTAssertNotNil(payload["aggregationNotice"])
        let snapshot = try XCTUnwrap((payload["selectedHealthSnapshots"] as? [[String: Any]])?.first)
        let metrics = try XCTUnwrap(snapshot["metrics"] as? [[String: Any]])
        for metric in metrics {
            let samples = try XCTUnwrap(metric["samples"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(samples.count, 24)
            let values = samples.compactMap { $0["value"] as? Double }
            if metric["metric"] as? String == "heartRate" {
                XCTAssertEqual(values.reduce(0, +) / Double(values.count), 151.873, accuracy: 0.000001)
            } else { XCTAssertEqual(values.reduce(0, +), 1200, accuracy: 0.000001) }
        }
        let chart = try XCTUnwrap(assistant.messages.compactMap(\.chart).first)
        XCTAssertEqual(chart.points.count, 600)
        XCTAssertEqual(chart.points.map(\.value).reduce(0, +), 1200)
        let receiptJSON = try XCTUnwrap(local.requests.last?.input.last?["output"] as? String)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receiptJSON.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["status"] as? String, "artifact_created")
        XCTAssertEqual(receipt["artifact_id"] as? String, chart.id.uuidString)
        XCTAssertEqual(receipt["details_omitted_from_model_context"] as? Bool, true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
    }

    @MainActor
    func testPostReadLocalHealthOverflowIsActionableAndNeverBlamesHealthAccess() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Health budget boundary", startedAt: start, finishedAt: start.addingTimeInterval(1800),
            unit: .lb, importSourceKey: "health-budget-boundary", exercises: [WorkoutExercise(exercise: try XCTUnwrap(store.exercises.first),
                sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])
        _ = try XCTUnwrap(store.importWorkouts([workout]))
        let referenceJSON = String(decoding: try JSONSerialization.data(withJSONObject: ["selectedRecords": [
            ["kind": "health", "id": workout.id.uuidString, "status": "completed", "unit": "lb"]
        ]], options: [.sortedKeys]), as: UTF8.self)
        let definitions = WorkoutAgentTools(store: store).definitions(includingHealth: true, allowingProposals: false)
        func question(_ words: Int) -> String { String(repeating: "training ", count: words) + "question" }
        var lower = 0, upper = 4000
        while upper - lower > 1 {
            let middle = (upper + lower) / 2
            let content = question(middle) + "\n\nSelected workout references (JSON record data):\n" + referenceJSON
            do {
                _ = try FoundationModelsRequest(input: [["role": "user", "content": content]], tools: definitions, instructions: WorkoutAssistant.instructions)
                lower = middle
            } catch let error as AppleFoundationModelsError where error.kind == .contextTooLarge { upper = middle }
        }
        let local = ProviderLocalClient(), health = ProviderHealthData()
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" },
            healthDataProvider: health, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send(question(lower), references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await wait { !assistant.isWorking }
        XCTAssertEqual(health.reads, 1)
        XCTAssertTrue(local.requests.isEmpty, "Overflow must be detected before inference")
        XCTAssertTrue(assistant.errorMessage?.contains("context") == true)
        XCTAssertTrue(assistant.errorMessage?.contains("Select fewer Health tags") == true)
        XCTAssertFalse(assistant.errorMessage?.contains("access") == true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
    }

    @MainActor
    func testRepeatedLocalChartAndProposalCallsReuseArtifactsButRepeatedReadsRemainAvailable() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let exercise = try XCTUnwrap(store.exercises.first)
        let local = ProviderLocalClient()
        local.validatesNativeBudget = true
        let chart: [String: Any] = ["metric": "completed_sets", "unit": "lb"]
        let proposal: [String: Any] = ["name": "Only one proposal", "unit": "lb", "exercises": [
            ["exercise_id": exercise.id.uuidString, "sets": [["weight": 100, "reps": 8]]]
        ]]
        local.replies = [
            try ProviderLocalClient.call("graph_workout_history", chart, id: "chart-first"),
            try ProviderLocalClient.call("liftlog.graph_workout_history", chart, id: "chart-repeat"),
            try ProviderLocalClient.call("propose_create_template", proposal, id: "proposal-first"),
            try ProviderLocalClient.call("propose_create_template", proposal, id: "proposal-repeat"),
            try ProviderLocalClient.call("get_workout_data", [:], id: "read-first"),
            try ProviderLocalClient.call("get_workout_data", [:], id: "read-repeat"),
            ProviderLocalClient.answer("Inspect the chart and review the single proposal")
        ]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Chart completed sets and propose one new plan"))
        await wait { !assistant.isWorking && assistant.selectedChat?.isGeneratingTitle == false }
        XCTAssertNil(assistant.errorMessage)
        let charts = assistant.messages.compactMap(\.chart), proposals = assistant.messages.compactMap(\.proposal)
        XCTAssertEqual(charts.count, 1)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.status, .pending)
        XCTAssertFalse(store.templates.contains { $0.name == "Only one proposal" })
        let context = local.requests.flatMap(\.input)
        for (id, artifactID) in [("chart-repeat", charts.first?.id.uuidString), ("proposal-repeat", proposals.first?.id.uuidString)] {
            let output = try XCTUnwrap(context.first { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == id }?["output"] as? String)
            let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(receipt["already_created"] as? Bool, true)
            XCTAssertEqual(receipt["artifact_id"] as? String, artifactID)
        }
        for id in ["read-first", "read-repeat"] {
            let output = try XCTUnwrap(context.first { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == id }?["output"] as? String)
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            if id == "read-first", record["code"] as? String == "on_device_context_limit" {
                XCTAssertNil(record["completedWorkoutCount"], "The next identical read must be able to recover after explicit context omission")
            } else { XCTAssertEqual(record["completedWorkoutCount"] as? Int, 0, id) }
            XCTAssertNil(record["already_created"], "Read results must never use the artifact cache")
        }
    }

    @MainActor
    func testLocalDefaultRoundBudgetStillStopsAtTwentyFourToolCalls() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient()
        local.validatesNativeBudget = true
        local.replies = try (0..<25).map { _ in try ProviderLocalClient.call("get_workout_data", [:]) }
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
            accessToken: { XCTFail("Unexpected cloud access"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Read again until the bounded limit"))
        await wait { !assistant.isWorking }
        XCTAssertEqual(local.requests.count, 25)
        XCTAssertTrue(assistant.errorMessage?.contains("tool limit") == true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
    }

    @MainActor
    func testLocalModelHealthFailureRedactsDiagnosticsWithoutBlamingHealthPermissions() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Health model failure", startedAt: start, finishedAt: start.addingTimeInterval(1800),
            unit: .lb, importSourceKey: "health-model-failure", exercises: [WorkoutExercise(exercise: try XCTUnwrap(store.exercises.first),
                sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])
        _ = try XCTUnwrap(store.importWorkouts([workout]))
        let local = ProviderLocalClient(), health = ProviderHealthData()
        local.failure = AppleFoundationModelsError("PrivatePulse-151.873 native diagnostic")
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud access"); return "" },
            healthDataProvider: health, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Review Health", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await wait { !assistant.isWorking }
        XCTAssertTrue(assistant.errorMessage?.contains("Apple Intelligence") == true)
        XCTAssertFalse(assistant.errorMessage?.contains("151.873") == true)
        XCTAssertFalse(assistant.errorMessage?.contains("access") == true)
        XCTAssertFalse(assistant.errorMessage?.contains("permission") == true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
    }

    @MainActor
    func testLocalDispatchFailuresReturnPairedErrorsAndRecoverWithoutInvalidatingProposal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let template = try XCTUnwrap(store.templates.first), entry = try XCTUnwrap(store.templates.first?.exercises.first)
        let version = try XCTUnwrap(template.currentVersion)
        let local = ProviderLocalClient()
        local.validatesNativeBudget = true
        local.dispatchFailures = [
            0: FoundationModelsToolDispatchError(toolName: "get_templates", message: "Selected arguments exceed context. Retry a narrower query."),
            2: FoundationModelsToolDispatchError(toolName: "propose_template_version", message: "Tool arguments were incomplete. Read fresh entry IDs and retry."),
            4: FoundationModelsToolDispatchError(toolName: "propose_template_version", message: "Selected arguments could not be generated. Retry a smaller edit or answer using the existing proposal.")
        ]
        local.replies = [try ProviderLocalClient.call("get_templates", ["query": template.name, "limit": 1, "offset": 0]),
            try ProviderLocalClient.call("propose_template_version", ["template_id": template.id.uuidString,
                "base_version_id": version.id.uuidString, "unit": store.unit.rawValue, "operations": [["operation": "update",
                    "entry_id": entry.id.uuidString, "exercise_id": entry.exercise.id.uuidString,
                    "sets": entry.sets.map { ["weight": $0.weight, "reps": $0.targetReps + 1] as [String: Any] }]]]),
            ProviderLocalClient.answer("The proposal is ready for review")]
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud request"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("Add one rep to the first exercise and prepare a proposal"))
        await wait { !assistant.isWorking && assistant.selectedChat?.isGeneratingTitle == false }
        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(local.requests.filter { !$0.tools.isEmpty }.count, 6)
        let observed = local.requests.flatMap(\.input)
        let errorOutputs = observed.filter { item in
            guard let output = item["output"] as? String else { return false }
            return output.contains("tool_dispatch_failed")
        }
        let ids = Set(errorOutputs.compactMap { $0["call_id"] as? String })
        XCTAssertEqual(ids.count, 3)
        for id in ids {
            let call = try XCTUnwrap(observed.first { $0["type"] as? String == "function_call" && $0["call_id"] as? String == id })
            XCTAssertEqual(call["arguments"] as? String, "{}")
            XCTAssertEqual(call["namespace"] as? String, "liftlog")
            let output = try XCTUnwrap(errorOutputs.first { $0["call_id"] as? String == id }?["output"] as? String)
            let error = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            XCTAssertEqual(error["executed"] as? Bool, false)
        }
        let proposals = assistant.messages.compactMap(\.proposal)
        XCTAssertEqual(proposals.count, 1)
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertFalse(assistant.messages.contains { $0.role == .assistant && $0.isPartial })
        XCTAssertEqual(store.templates.first { $0.id == template.id }?.currentVersion?.id, version.id)
        try assistant.applyProposal(proposal.id)
        XCTAssertEqual(store.templates.first { $0.id == template.id }?.exercises.first?.sets.map(\.targetReps), entry.sets.map { $0.targetReps + 1 })
    }

    @MainActor
    func testLocalDispatchFailureBudgetHonorsExplicitRoundsAndDefaultToolLimit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (rounds, calls, expectedRequests): (Int?, Int, Int) in [(nil, 24, 25), (nil, 2, 3), (1, 24, 1)] {
            let local = ProviderLocalClient()
            local.validatesNativeBudget = true
            local.dispatchFailures = Dictionary(uniqueKeysWithValues: (0..<25).map { index in
                (index, FoundationModelsToolDispatchError(toolName: "get_templates", message: "Read fresh data and retry a smaller tool request."))
            })
            let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("budget-\(expectedRequests).sqlite")),
                accessToken: { XCTFail("Unexpected cloud request"); return "" }, maximumRounds: rounds,
                maximumToolCalls: calls, appleFoundationModels: local)
            assistant.selectedProvider = .appleFoundationModels
            XCTAssertTrue(assistant.send("Try a bounded retry"))
            await wait { !assistant.isWorking }
            XCTAssertEqual(local.requests.count, expectedRequests)
            XCTAssertTrue(assistant.errorMessage?.contains("tool limit") == true)
            XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
            XCTAssertTrue(assistant.messages.compactMap(\.proposal).isEmpty)
        }
    }

    @MainActor
    func testLateDispatchErrorAfterStopProviderSwitchOrDeletionIsIgnored() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for action in ["stop", "provider", "delete"] {
            let local = ProviderLocalClient()
            local.suspended = true
            let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("late-\(action).sqlite")),
                accessToken: { "unused" }, appleFoundationModels: local)
            assistant.selectedProvider = .appleFoundationModels
            XCTAssertTrue(assistant.send("Wait for the native request"))
            let chat = try XCTUnwrap(assistant.selectedChat)
            await wait { local.continuation != nil }
            switch action {
            case "stop": assistant.cancel()
            case "provider": assistant.selectedProvider = .chatGPT
            default: XCTAssertTrue(assistant.deleteChat(chat.id))
            }
            local.continuation?.resume(throwing: FoundationModelsToolDispatchError(toolName: "get_templates", message: "Late tool dispatch error"))
            local.continuation = nil
            await wait { local.lateText == nil }
            XCTAssertEqual(local.requests.count, 1)
            XCTAssertFalse(chat.isWorking)
            XCTAssertTrue(chat.history.isEmpty)
            XCTAssertNil(assistant.errorMessage)
        }
    }

    @MainActor
    func testHealthDispatchRecoveryIsEphemeralAndAbsentFromLaterRequestsAndTitles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let workout = WorkoutSession(name: "Health dispatch recovery", startedAt: start, finishedAt: start.addingTimeInterval(1800),
            unit: .lb, importSourceKey: "health-dispatch", exercises: [WorkoutExercise(exercise: try XCTUnwrap(store.exercises.first),
                sets: [WorkoutSet(weight: 100, reps: 8, isCompleted: true)])])
        _ = try XCTUnwrap(store.importWorkouts([workout]))
        let local = ProviderLocalClient(), health = ProviderHealthData()
        local.validatesNativeBudget = true
        local.dispatchFailures = [0: FoundationModelsToolDispatchError(toolName: "graph_workout_health", message: "Health dispatch recovery sentinel. Retry a smaller chart.")]
        local.replies = [ProviderLocalClient.answer("PrivatePulseAnswer-97248"), ProviderLocalClient.answer("Ordinary answer")]
        let archive = directory.appendingPathComponent("chats.json")
        let assistant = WorkoutAssistant(store: store, accessToken: { XCTFail("Unexpected cloud request"); return "" },
            storageURL: archive, healthDataProvider: health, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("PrivateHealthQuestion-8842", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await wait { !assistant.isWorking }
        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(local.requests.count, 2, "Health recovery never generates a title")
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
        XCTAssertTrue(assistant.send("Ordinary follow-up"))
        await wait { !assistant.isWorking && assistant.selectedChat?.hasGeneratedTitle == true }
        let later = String(decoding: try JSONSerialization.data(withJSONObject: local.requests.dropFirst(2).map(\.input)), as: UTF8.self)
        let saved = String(decoding: try Data(contentsOf: archive), as: UTF8.self)
        for secret in ["Health dispatch recovery sentinel", "PrivatePulseAnswer-97248", "PrivateHealthQuestion-8842", "151.873", "selectedHealthSnapshots"] {
            XCTAssertFalse(later.contains(secret))
            XCTAssertFalse(saved.contains(secret))
        }
        XCTAssertEqual(health.reads, 1)
    }

    @MainActor
    func testDispatchErrorCannotAuthorizeAnUnavailableTool() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = ProviderLocalClient()
        local.dispatchFailures = [0: FoundationModelsToolDispatchError(toolName: "graph_workout_health", message: "This forbidden tool must not be retried")]
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
            accessToken: { XCTFail("Unexpected cloud request"); return "" }, appleFoundationModels: local)
        assistant.selectedProvider = .appleFoundationModels
        XCTAssertTrue(assistant.send("No Health tag is selected"))
        await wait { !assistant.isWorking }
        XCTAssertEqual(local.requests.count, 1)
        XCTAssertTrue(assistant.errorMessage?.contains("unavailable workout tool") == true)
        XCTAssertTrue(assistant.selectedChat?.history.isEmpty == true)
        XCTAssertTrue(assistant.messages.compactMap(\.chart).isEmpty)
    }
}
