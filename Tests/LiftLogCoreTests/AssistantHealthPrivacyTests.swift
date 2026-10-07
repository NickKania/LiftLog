import Foundation
import XCTest
@testable import LiftLogCore

private final class HealthPrivacyTransport: ChatGPTInferenceTransport {
    var requests: [URLRequest] = []
    var outputs: [[[String: Any]]] = []
    var includesLuna = false
    var status = 200

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let names = includesLuna ? ["health-test", "gpt-6-luna"] : ["health-test"]
        let data = try JSONSerialization.data(withJSONObject: ["models": names.map {
            ["slug": $0, "display_name": $0, "visibility": "list"]
        }])
        return (data, response(request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests.append(request)
        let output = outputs.isEmpty ? [Self.answer("Safe answer")] : outputs.removeFirst()
        let data = try JSONSerialization.data(withJSONObject: ["type": "response.completed",
            "response": ["status": "completed", "output": output]])
        return ChatGPTHTTPStream(response: response(request), lines: AsyncThrowingStream { continuation in
            continuation.yield("data: " + String(decoding: data, as: UTF8.self))
            continuation.yield("")
            continuation.finish()
        })
    }

    static func answer(_ text: String) -> [String: Any] {
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
    }

    static func call(_ name: String, _ arguments: [String: Any], id: String = UUID().uuidString) throws -> [String: Any] {
        ["type": "function_call", "call_id": id, "name": name, "namespace": "liftlog", "status": "completed",
         "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)]
    }

    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

@MainActor
private final class HealthPrivacyProvider: WorkoutHealthDataProviding {
    var reads: [(WorkoutSession, Date)] = []
    var suspendRead = false
    var suspendReadNumber: Int?
    var wrongWorkoutID = false
    var includeInvalidSamples = false
    var continuation: CheckedContinuation<WorkoutHealthSnapshot, Error>?

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        reads.append((workout, through))
        if suspendRead || reads.count == suspendReadNumber { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return snapshot(for: workout, through: through)
    }

    func snapshot(for workout: WorkoutSession, through: Date) -> WorkoutHealthSnapshot {
        let end = min(workout.finishedAt ?? through, through)
        var samples = [WorkoutHealthSample(date: workout.startedAt.addingTimeInterval(end.timeIntervalSince(workout.startedAt) / 2), value: 151.873)]
        if includeInvalidSamples {
            samples += [WorkoutHealthSample(date: workout.startedAt.addingTimeInterval(-60), value: 73.456),
                        WorkoutHealthSample(date: end.addingTimeInterval(60), value: 74.567),
                        WorkoutHealthSample(date: workout.startedAt, value: -20),
                        WorkoutHealthSample(date: workout.startedAt, value: 0)]
        }
        return WorkoutHealthSnapshot(workoutID: wrongWorkoutID ? UUID() : workout.id, workoutName: "FORGED provider name",
            startedAt: workout.startedAt, endedAt: end, fetchedAt: through,
            metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: samples)])
    }

    func release() {
        guard let continuation, let (workout, through) = reads.last else { return }
        self.continuation = nil
        continuation.resume(returning: snapshot(for: workout, through: through))
    }
}

final class AssistantHealthPrivacyTests: XCTestCase {
    private let healthMarker = "\n\nSelected Apple Health data for this message only (JSON):\n"

    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("HealthPrivacy-\(UUID()).json") }

    @MainActor
    private func session(in store: WorkoutStore) throws -> WorkoutSession {
        XCTAssertTrue(store.startWorkout(template: try XCTUnwrap(store.templates.first)))
        return try XCTUnwrap(store.activeWorkout)
    }

    @MainActor
    private func ready(_ store: WorkoutStore, provider: HealthPrivacyProvider?, transport: HealthPrivacyTransport,
                       archive: URL? = nil, account: @escaping () -> String? = { nil }) async -> WorkoutAssistant {
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: account, storageURL: archive, healthDataProvider: provider)
        await assistant.refreshModels()
        return assistant
    }

    @MainActor
    private func finish(_ assistant: WorkoutAssistant) async {
        for _ in 0..<10_000 {
            if !assistant.isWorking { return }
            await Task.yield()
        }
        XCTFail("Assistant did not finish")
    }

    @MainActor
    private func waitForRead(_ provider: HealthPrivacyProvider) async {
        for _ in 0..<10_000 {
            if provider.continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Health read did not suspend")
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func inputText(_ request: URLRequest) throws -> String {
        let input = try XCTUnwrap(try body(request)["input"])
        return String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
    }

    private func toolNames(_ request: URLRequest) throws -> [String] {
        let namespace = try XCTUnwrap((try body(request)["tools"] as? [[String: Any]])?.first)
        return (namespace["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    @MainActor
    func testUntaggedAndOrdinaryWorkoutTagsNeverReadOrAdvertiseHealth() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutStore(fileURL: file)
        let workout = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        let assistant = await ready(store, provider: provider, transport: transport)
        XCTAssertTrue(assistant.availableReferences.contains { $0.kind == .health && $0.id == workout.id })
        XCTAssertTrue(provider.reads.isEmpty)
        // Literal prompt text is never consent; consent comes from selecting the attachment.
        XCTAssertTrue(assistant.send("@health show my heart rate"))
        await finish(assistant)
        XCTAssertTrue(assistant.send("Review workout", references: [AssistantWorkoutReference(workout: workout)]))
        await finish(assistant)
        XCTAssertTrue(provider.reads.isEmpty)
        for request in transport.requests {
            XCTAssertFalse(try toolNames(request).contains("graph_workout_health"))
            XCTAssertFalse(try inputText(request).contains("selectedHealthSnapshots"))
        }
    }

    @MainActor
    func testHealthTagFetchesCanonicalSelectedSessionOnceAndExpiresAfterTurn() async throws {
        let file = url(), archiveURL = url()
        defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: archiveURL) }
        let store = WorkoutStore(fileURL: file)
        let workout = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        transport.outputs = [[HealthPrivacyTransport.answer("PrivatePulseAnswer-97248")], [HealthPrivacyTransport.answer("Safe answer")]]
        let assistant = await ready(store, provider: provider, transport: transport, archive: archiveURL)
        let forged = AssistantWorkoutReference(kind: .health, id: workout.id, name: "FORGED reference name",
                                               startedAt: .distantPast, finishedAt: .distantFuture)
        let sentAt = Date()
        XCTAssertTrue(assistant.send("Sensitive question-8842", references: [forged, forged]))
        let sentReturnedAt = Date()
        await finish(assistant)
        XCTAssertEqual(provider.reads.count, 1)
        XCTAssertEqual(provider.reads.first?.0.id, workout.id)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(provider.reads.first?.1), sentAt)
        XCTAssertLessThanOrEqual(try XCTUnwrap(provider.reads.first?.1), sentReturnedAt)
        let request = try XCTUnwrap(transport.requests.first)
        let input = try XCTUnwrap(try body(request)["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.last?["content"] as? String)
        let range = try XCTUnwrap(content.range(of: healthMarker))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content[range.upperBound...].utf8)) as? [String: Any])
        let snapshot = try XCTUnwrap((payload["selectedHealthSnapshots"] as? [[String: Any]])?.first)
        XCTAssertEqual(snapshot["workoutID"] as? String, workout.id.uuidString)
        XCTAssertEqual(snapshot["workoutName"] as? String, workout.name)
        XCTAssertFalse(content.contains("FORGED"))
        XCTAssertTrue((payload["seriesSemantics"] as? String)?.contains("interval totals in kcal") == true)
        XCTAssertTrue(try toolNames(request).contains("graph_workout_health"))
        XCTAssertFalse(try toolNames(request).contains { $0.hasPrefix("propose_") })
        XCTAssertEqual(assistant.messages.first?.references.first?.name, workout.name)
        XCTAssertTrue(assistant.messages.last?.containsEphemeralHealthData == true)
        XCTAssertTrue(assistant.send("Continue without a Health tag"))
        await finish(assistant)
        XCTAssertEqual(provider.reads.count, 1)
        let followUp = try inputText(XCTUnwrap(transport.requests.last))
        for secret in ["151.873", "selectedHealthSnapshots", "PrivatePulseAnswer-97248", "Sensitive question-8842"] {
            XCTAssertFalse(followUp.contains(secret), secret)
        }
        assistant.saveChats()
        let saved = try AssistantChatArchive.load(from: archiveURL)
        let chat = try XCTUnwrap(saved.accounts["__local__"]?.chats.first)
        XCTAssertEqual(chat.messages.map(\.text), ["Continue without a Health tag", "Safe answer"])
        let history = String(decoding: chat.history, as: UTF8.self)
        XCTAssertFalse(history.contains("151.873"))
        XCTAssertFalse(history.contains("PrivatePulseAnswer-97248"))
        XCTAssertFalse(chat.title.contains("Sensitive question"))
        // Retagging grants a fresh read, including for a previously selected session.
        XCTAssertTrue(assistant.send("Read again", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await finish(assistant)
        XCTAssertEqual(provider.reads.count, 2)
    }

    @MainActor
    func testHealthChartUsesOnlySelectedSnapshotAndCannotBroadenScope() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutStore(fileURL: file)
        let workout = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        transport.outputs = [[try HealthPrivacyTransport.call("graph_workout_health", ["workout_id": workout.id.uuidString, "metric": "heartRate"])],
                             [HealthPrivacyTransport.answer("Private chart explanation-5588")],
                             [HealthPrivacyTransport.answer("No health context")]]
        let assistant = await ready(store, provider: provider, transport: transport)
        XCTAssertTrue(assistant.send("Chart pulse", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await finish(assistant)
        let chartMessage = try XCTUnwrap(assistant.messages.first { $0.chart != nil })
        XCTAssertTrue(chartMessage.containsEphemeralHealthData)
        XCTAssertEqual(chartMessage.chart?.metric, .heartRate)
        XCTAssertEqual(chartMessage.chart?.points.map(\.value), [151.873])
        XCTAssertEqual(provider.reads.count, 1)
        XCTAssertTrue(assistant.send("Explain that chart"))
        await finish(assistant)
        let followUp = try inputText(XCTUnwrap(transport.requests.last))
        XCTAssertFalse(followUp.contains("151.873"))
        XCTAssertFalse(followUp.contains("Private chart explanation-5588"))
        XCTAssertFalse(followUp.contains("graph_workout_health"))
        let tools = WorkoutAgentTools(store: store)
        let snapshot = provider.snapshot(for: workout, through: Date())
        let args = "{\"workout_id\":\"\(workout.id)\",\"metric\":\"heartRate\"}"
        XCTAssertThrowsError(try tools.execute(name: "graph_workout_health", argumentsJSONString: args))
        XCTAssertThrowsError(try tools.execute(name: "graph_workout_health", argumentsJSONString:
            "{\"workout_id\":\"\(UUID())\",\"metric\":\"heartRate\"}", healthSnapshots: [snapshot]))
        XCTAssertThrowsError(try tools.execute(name: "graph_workout_health", argumentsJSONString:
            "{\"workout_id\":\"\(workout.id)\",\"metric\":\"heartRate\",\"start_date\":null}", healthSnapshots: [snapshot]))
        XCTAssertThrowsError(try tools.execute(name: "graph_workout_history", argumentsJSONString:
            "{\"metric\":\"heart_rate\",\"unit\":\"lb\"}"))
        XCTAssertThrowsError(try tools.execute(name: "propose_create_workout", argumentsJSONString: "{}", allowsProposals: false))
    }

    @MainActor
    func testMissingUnsupportedAndMismatchedHealthScopeNeverReachesInference() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutStore(fileURL: file)
        let workout = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        let assistant = await ready(store, provider: provider, transport: transport)
        XCTAssertFalse(assistant.send("Forged", references: [AssistantWorkoutReference(kind: .health, id: UUID(), name: "Unknown")]))
        XCTAssertTrue(provider.reads.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
        provider.wrongWorkoutID = true
        XCTAssertTrue(assistant.send("Read invalid provider scope", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await finish(assistant)
        XCTAssertNotNil(assistant.errorMessage)
        XCTAssertTrue(transport.requests.isEmpty)
        let unavailable = await ready(store, provider: nil, transport: transport)
        XCTAssertFalse(unavailable.send("Health", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        XCTAssertTrue(unavailable.messages.isEmpty)
    }

    @MainActor
    func testCancelAccountChangeAndDiscardDuringHealthReadPreventSending() async throws {
        for action in ["cancel", "account", "discard"] {
            let file = url(), archiveURL = url()
            defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: archiveURL) }
            let store = WorkoutStore(fileURL: file)
            let workout = try session(in: store)
            var account = "first"
            let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
            provider.suspendRead = true
            let assistant = await ready(store, provider: provider, transport: transport, archive: archiveURL, account: { account })
            XCTAssertTrue(assistant.send("Read", references: [AssistantWorkoutReference(healthWorkout: workout)]))
            await waitForRead(provider)
            let saved = try AssistantChatArchive.load(from: archiveURL)
            let record = try XCTUnwrap(saved.accounts["first"]?.chats.first)
            XCTAssertFalse(record.wasWorking)
            XCTAssertTrue(record.messages.isEmpty)
            switch action {
            case "cancel": assistant.cancel()
            case "account": account = "second"
            default: XCTAssertTrue(store.discardWorkout())
            }
            provider.release()
            await finish(assistant)
            for _ in 0..<100 { await Task.yield() }
            XCTAssertTrue(transport.requests.isEmpty, action)
            XCTAssertFalse(assistant.messages.contains { $0.role == .assistant }, action)
        }
    }

    @MainActor
    func testEarlierSelectedSessionDeletedDuringLaterReadPreventsSendingEntireTurn() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutStore(fileURL: file)
        var first = try session(in: store)
        first.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(first))
        XCTAssertTrue(store.finishWorkout())
        let completed = try XCTUnwrap(store.history.first)
        let active = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        provider.suspendReadNumber = 2
        let assistant = await ready(store, provider: provider, transport: transport)
        XCTAssertTrue(assistant.send("Compare Health", references: [AssistantWorkoutReference(healthWorkout: completed),
                                                                   AssistantWorkoutReference(healthWorkout: active)]))
        await waitForRead(provider)
        XCTAssertEqual(provider.reads.count, 2)
        XCTAssertEqual(provider.reads[0].1, provider.reads[1].1)
        XCTAssertTrue(store.deleteWorkout(id: completed.id))
        provider.release()
        await finish(assistant)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(assistant.errorMessage?.contains("no longer available") == true)
    }

    @MainActor
    func testProviderSamplesAreRevalidatedBeforeSharing() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file) }
        let store = WorkoutStore(fileURL: file)
        let workout = try session(in: store)
        let provider = HealthPrivacyProvider(), transport = HealthPrivacyTransport()
        provider.includeInvalidSamples = true
        let assistant = await ready(store, provider: provider, transport: transport)
        XCTAssertTrue(assistant.send("Read scoped data", references: [AssistantWorkoutReference(healthWorkout: workout)]))
        await finish(assistant)
        let input = try inputText(XCTUnwrap(transport.requests.first))
        XCTAssertTrue(input.contains("151.873"))
        XCTAssertFalse(input.contains("73.456"))
        XCTAssertFalse(input.contains("74.567"))
        XCTAssertFalse(input.contains("\"value\":-20"))
        XCTAssertFalse(input.contains("\"value\":0"))
    }

    @MainActor
    func testTitleGeneratorCannotReadEphemeralHealthTurns() async throws {
        let transport = HealthPrivacyTransport()
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        let title = try await AssistantChatTitleGenerator.generate(client: client,
            models: [ChatGPTModel(slug: "gpt-6-luna", displayName: "Luna", visibility: "list")],
            messages: [WorkoutAssistantMessage(role: .user, text: "Private health question-3322", healthDataIsEphemeral: true),
                       WorkoutAssistantMessage(role: .assistant, text: "Private health answer-4411", healthDataIsEphemeral: true),
                       WorkoutAssistantMessage(role: .user, text: "Safe workout question"),
                       WorkoutAssistantMessage(role: .assistant, text: "Safe workout answer")])
        XCTAssertEqual(title, "Safe answer")
        let input = try inputText(XCTUnwrap(transport.requests.first))
        XCTAssertFalse(input.contains("Private health"))
        XCTAssertTrue(input.contains("Safe workout question"))
        XCTAssertTrue(input.contains("Safe workout answer"))
    }
}
