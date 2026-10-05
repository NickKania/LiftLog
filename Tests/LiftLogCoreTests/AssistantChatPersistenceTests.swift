import Foundation
import XCTest
@testable import LiftLogCore

/// Keeps streams under explicit test control so switching chats and cancellation
/// are exercised while inference is actually in flight.
private final class ChatPersistenceTransport: ChatGPTInferenceTransport {
    var catalog = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"}]}".utf8)
    var requests: [URLRequest] = []
    var replies: [[String]] = []
    var holdStreams = false
    var heldModels: Set<String> = []
    var held: [AsyncThrowingStream<String, Error>.Continuation] = []
    var cancelled: [Int] = []

    var inferenceRequests: [URLRequest] { requests.filter { $0.url?.lastPathComponent == "responses" } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (catalog, response(request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests.append(request)
        let model = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["model"] as? String ?? ""
        let shouldHold = holdStreams || heldModels.contains(model)
        let lines = shouldHold || replies.isEmpty ? [] : replies.removeFirst()
        let index = held.count
        let stream = AsyncThrowingStream<String, Error> { continuation in
            if shouldHold { held.append(continuation) }
            else {
                lines.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }
        return ChatGPTHTTPStream(response: response(request), lines: stream,
                                 cancel: { self.cancelled.append(index) })
    }

    func release(_ index: Int, output: [[String: Any]]) {
        chatCompleted(output).forEach { held[index].yield($0) }
        held[index].finish()
    }

    private func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "text/event-stream"])!
    }
}

private func chatEvent(_ value: [String: Any]) -> [String] {
    ["event: \(value["type"] ?? "")",
     "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self), ""]
}

private func chatCompleted(_ output: [[String: Any]]) -> [String] {
    chatEvent(["type": "response.completed", "response": ["status": "completed", "output": output]])
}

private func chatAnswer(_ text: String) -> [[String: Any]] {
    [["type": "message", "role": "assistant", "status": "completed",
      "content": [["type": "output_text", "text": text, "annotations": []]]]]
}

private func chatCall(_ name: String, id: String, arguments: [String: Any]) throws -> [String: Any] {
    ["type": "function_call", "call_id": id, "name": name, "namespace": "liftlog",
     "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self),
     "status": "completed"]
}

final class AssistantChatPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChatPersistence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controlled assistant state", file: file, line: line)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    private func input(_ request: URLRequest) throws -> [[String: Any]] {
        try XCTUnwrap(try body(request)["input"] as? [[String: Any]])
    }

    private func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    @MainActor
    func testRelaunchRestoresOriginalRichTranscriptAndFullInferenceContext() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let archive = directory.appendingPathComponent("chats.json")
        let transport = ChatPersistenceTransport()
        let template = try XCTUnwrap(store.templates.first)
        let exercise = store.exercises[0]
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let workout = WorkoutSession(name: "Historical lift", startedAt: date,
                                     finishedAt: date.addingTimeInterval(600), unit: .lb,
                                     importSourceKey: UUID().uuidString,
                                     exercises: [WorkoutExercise(exercise: exercise,
                                         sets: [WorkoutSet(weight: 100, reps: 5, isCompleted: true)])])
        XCTAssertNotNil(store.importWorkouts([workout]))
        let proposalCall = try chatCall("propose_create_template", id: "proposal-original", arguments: [
            "name": "Saved plan", "unit": "lb", "exercises": [
                ["exercise_id": exercise.id.uuidString, "sets": [["weight": 110, "reps": 5]]]
            ]
        ])
        let chartCall = try chatCall("graph_workout_history", id: "chart-original", arguments: [
            "metric": "volume", "unit": "lb", "exercise_id": exercise.id.uuidString,
            "start_date": NSNull(), "end_date": NSNull()
        ])
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_original", "encrypted_content": "opaque-replay", "summary": []]
        let markdown = "## Your progress\n\n**Keep going** with `5 × 5`.\n\n| Lift | Sets |\n| --- | --- |\n| Squat | 5 |\n\n- Review the proposed plan."
        transport.replies = [chatCompleted([reasoning, chartCall, proposalCall]), chatCompleted(chatAnswer(markdown))]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { "account-a" }, storageURL: archive)
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Chart and plan", references: [AssistantWorkoutReference(template: template), AssistantWorkoutReference(workout: workout)]))
        await waitUntil { !assistant.isWorking }
        XCTAssertNil(assistant.errorMessage)
        let chatID = try XCTUnwrap(assistant.selectedChatID)
        let proposal = try XCTUnwrap(assistant.messages.compactMap(\.proposal).first)
        try assistant.applyProposal(proposal.id)
        XCTAssertTrue(assistant.renameChat(chatID, title: "My saved training review"))
        let original = assistant.messages
        let chart = try XCTUnwrap(original.compactMap(\.chart).first)
        XCTAssertEqual(chart.points.map(\.value), [500])
        XCTAssertTrue(store.deleteTemplate(id: template.id))

        let replay = ChatPersistenceTransport()
        replay.replies = [chatCompleted(chatAnswer("Follow-up"))]
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: replay,
                                        accountIdentity: { "account-a" }, storageURL: archive)
        XCTAssertEqual(reopened.selectedChatID, chatID)
        XCTAssertEqual(reopened.chats.count, 1)
        XCTAssertEqual(reopened.selectedChat?.title, "My saved training review")
        XCTAssertEqual(reopened.messages.map(\.id), original.map(\.id))
        XCTAssertEqual(reopened.messages.map(\.text), original.map(\.text))
        XCTAssertEqual(reopened.messages.map(\.isPartial), original.map(\.isPartial))
        XCTAssertEqual(reopened.messages.map(\.role), original.map(\.role))
        XCTAssertEqual(reopened.messages.map(\.references), original.map(\.references))
        XCTAssertEqual(reopened.messages.compactMap(\.chart), original.compactMap(\.chart))
        XCTAssertEqual(reopened.messages.compactMap(\.proposal), original.compactMap(\.proposal))
        XCTAssertEqual(reopened.messages.compactMap(\.proposal).first?.status, .applied)
        XCTAssertEqual(reopened.messages.first?.references.first?.name, template.name)
        XCTAssertEqual(reopened.messages.last?.text, markdown)
        XCTAssertTrue(replay.requests.isEmpty, "Opening history must render saved content without inference")
        await reopened.refreshModels()
        XCTAssertTrue(reopened.send("Explain this chart"))
        await waitUntil { !reopened.isWorking }
        let resumedInput = try input(XCTUnwrap(replay.inferenceRequests.last))
        let priorInput = try input(XCTUnwrap(transport.inferenceRequests.last))
        XCTAssertEqual(try canonical(Array(resumedInput.prefix(priorInput.count))), try canonical(priorInput))
        XCTAssertEqual(resumedInput[1]["encrypted_content"] as? String, "opaque-replay")
        XCTAssertTrue(resumedInput.contains { $0["call_id"] as? String == "chart-original" && $0["type"] as? String == "function_call_output" })
        XCTAssertTrue(resumedInput.contains { $0["role"] as? String == "developer" && ($0["content"] as? String)?.contains(proposal.id.uuidString) == true })
        XCTAssertEqual(resumedInput.last?["content"] as? String, "Explain this chart")
    }

    @MainActor
    func testTwoChatsStreamConcurrentlyAndSwitchingKeepsEachTranscriptAndHistoryIndependent() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        transport.holdStreams = true
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         storageURL: directory.appendingPathComponent("chats.json"))
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Question A"))
        let firstID = try XCTUnwrap(assistant.selectedChatID)
        await waitUntil { transport.held.count == 1 }
        chatEvent(["type": "response.output_text.delta", "delta": "Partial A"]).forEach { transport.held[0].yield($0) }
        await waitUntil { assistant.messages.last?.text == "Partial A" }
        let secondID = assistant.createChat()
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.send("Question B"))
        await waitUntil { transport.held.count == 2 }
        XCTAssertEqual(Set(assistant.chats.filter(\.isWorking).map(\.id)), Set([firstID, secondID]))
        XCTAssertFalse(assistant.send("Duplicate B"), "A single chat cannot dispatch overlapping turns")
        assistant.selectChat(firstID)
        XCTAssertTrue(assistant.isWorking)
        XCTAssertEqual(assistant.messages.last?.text, "Partial A")
        transport.release(1, output: chatAnswer("Answer B"))
        await waitUntil { assistant.chats.first { $0.id == secondID }?.isWorking == false }
        XCTAssertTrue(assistant.isWorking)
        XCTAssertEqual(assistant.messages.last?.text, "Partial A")
        transport.release(0, output: chatAnswer("Answer A"))
        await waitUntil { !assistant.isWorking }
        XCTAssertEqual(assistant.messages.map(\.text), ["Question A", "Answer A"])
        assistant.selectChat(secondID)
        XCTAssertEqual(assistant.messages.map(\.text), ["Question B", "Answer B"])
        transport.holdStreams = false
        transport.replies = [chatCompleted(chatAnswer("B again"))]
        XCTAssertTrue(assistant.send("Follow-up B"))
        await waitUntil { !assistant.isWorking }
        let users = try input(XCTUnwrap(transport.inferenceRequests.last)).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        XCTAssertEqual(users, ["Question B", "Follow-up B"])
        assistant.selectChat(firstID)
        XCTAssertEqual(assistant.messages.map(\.text), ["Question A", "Answer A"])
    }

    @MainActor
    func testCancellingSelectedChatDoesNotCancelAnotherOrCommitCancelledHistory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ChatPersistenceTransport()
        transport.holdStreams = true
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
                                         accessToken: { "mock" }, transport: transport,
                                         storageURL: directory.appendingPathComponent("chats.json"))
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Cancelled A"))
        let firstID = try XCTUnwrap(assistant.selectedChatID)
        await waitUntil { transport.held.count == 1 }
        let secondID = assistant.createChat()
        XCTAssertTrue(assistant.send("Continuing B"))
        await waitUntil { transport.held.count == 2 }
        assistant.selectChat(firstID)
        assistant.cancel()
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.chats.first { $0.id == secondID }?.isWorking == true)
        transport.release(0, output: chatAnswer("Late cancelled content"))
        transport.release(1, output: chatAnswer("B completed"))
        await waitUntil { assistant.chats.allSatisfy { !$0.isWorking } }
        XCTAssertFalse(assistant.messages.contains { $0.text == "Late cancelled content" })
        assistant.selectChat(secondID)
        XCTAssertEqual(assistant.messages.last?.text, "B completed")
        assistant.selectChat(firstID)
        transport.holdStreams = false
        transport.replies = [chatCompleted(chatAnswer("A retry"))]
        XCTAssertTrue(assistant.send("Retry A"))
        await waitUntil { !assistant.isWorking }
        let users = try input(XCTUnwrap(transport.inferenceRequests.last)).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        XCTAssertEqual(users, ["Retry A"])
    }

    @MainActor
    func testRelaunchMarksInFlightPartialResponseInterruptedWithoutLosingText() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        transport.holdStreams = true
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { "account-a" }, storageURL: archive)
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Long-running request"))
        await waitUntil { transport.held.count == 1 }
        chatEvent(["type": "response.output_text.delta", "delta": "## Saved partial\n\nSome progress"]).forEach { transport.held[0].yield($0) }
        await waitUntil { assistant.messages.last?.text == "## Saved partial\n\nSome progress" }
        assistant.saveChats()
        let ids = assistant.messages.map(\.id)
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                        accountIdentity: { "account-a" }, storageURL: archive)
        XCTAssertEqual(reopened.messages.map(\.id), ids)
        XCTAssertEqual(reopened.messages.last?.text, "## Saved partial\n\nSome progress")
        XCTAssertFalse(reopened.isWorking)
        XCTAssertTrue(reopened.messages.last?.isPartial == true)
        XCTAssertTrue(reopened.errorMessage?.localizedCaseInsensitiveContains("interrupted") == true)
        await reopened.refreshModels()
        XCTAssertTrue(reopened.errorMessage?.localizedCaseInsensitiveContains("interrupted") == true)
        assistant.cancel()
        transport.held[0].finish()
    }

    @MainActor
    func testPendingProposalRestoresForReferenceAndCannotApplyAcrossRelaunch() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        let proposalCall = try chatCall("propose_create_template", id: "pending-plan", arguments: [
            "name": "Pending plan", "unit": "lb", "exercises": [
                ["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": 100, "reps": 5]]]
            ]
        ])
        transport.replies = [chatCompleted([proposalCall]), chatCompleted(chatAnswer("Please review"))]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { "account-a" }, storageURL: archive)
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Propose a plan"))
        await waitUntil { !assistant.isWorking }
        let proposal = try XCTUnwrap(assistant.messages.compactMap(\.proposal).first)
        XCTAssertEqual(proposal.status, .pending)
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                        accountIdentity: { "account-a" }, storageURL: archive)
        let restored = try XCTUnwrap(reopened.messages.compactMap(\.proposal).first)
        XCTAssertEqual(restored.id, proposal.id)
        XCTAssertEqual(restored.afterTemplate, proposal.afterTemplate)
        XCTAssertEqual(restored.beforeTemplate, proposal.beforeTemplate)
        XCTAssertEqual(restored.status, .stale)
        let before = store.templates
        XCTAssertThrowsError(try reopened.applyProposal(proposal.id))
        XCTAssertEqual(store.templates, before)
    }

    @MainActor
    func testAccountSwitchRestoresOnlyItsOwnChatsAndIgnoresLateOldAccountOutput() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        var account = "account-a"
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { account }, storageURL: archive)
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Private answer A"))]
        XCTAssertTrue(assistant.send("Private question A"))
        await waitUntil { !assistant.isWorking }
        let firstID = try XCTUnwrap(assistant.selectedChatID)
        transport.holdStreams = true
        XCTAssertTrue(assistant.send("In-flight A"))
        await waitUntil { transport.held.count == 1 }
        chatEvent(["type": "response.output_text.delta", "delta": "Saved before account change"]).forEach { transport.held[0].yield($0) }
        await waitUntil { assistant.messages.last?.text == "Saved before account change" }
        assistant.accountWillChange()
        XCTAssertFalse(assistant.isWorking)
        account = "account-b"
        assistant.reconcileAccount()
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertFalse(assistant.chats.contains { $0.id == firstID })
        await assistant.refreshModels()
        transport.holdStreams = false
        transport.replies = [chatCompleted(chatAnswer("Private answer B"))]
        XCTAssertTrue(assistant.send("Private question B"))
        await waitUntil { !assistant.isWorking }
        transport.release(0, output: chatAnswer("Stale account A output"))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(assistant.messages.map(\.text), ["Private question B", "Private answer B"])
        let secondID = try XCTUnwrap(assistant.selectedChatID)
        XCTAssertNotEqual(firstID, secondID)
        account = "account-a"
        assistant.reconcileAccount()
        XCTAssertTrue(assistant.chats.contains { $0.id == firstID })
        XCTAssertFalse(assistant.chats.contains { $0.id == secondID })
        XCTAssertTrue(assistant.messages.contains { $0.text == "Private answer A" })
        XCTAssertTrue(assistant.messages.contains { $0.text == "Saved before account change" })
        XCTAssertFalse(assistant.messages.contains { $0.text == "Private answer B" || $0.text == "Stale account A output" })
        let reopenedB = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                         accountIdentity: { "account-b" }, storageURL: archive)
        XCTAssertEqual(reopenedB.selectedChatID, secondID)
        XCTAssertEqual(reopenedB.messages.map(\.text), ["Private question B", "Private answer B"])
    }

    @MainActor
    func testCorruptArchiveIsPreservedAndStorageErrorVisibleWhenUserAttemptsToCreateOrRename() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let corrupted = Data("{existing saved chats that cannot be decoded".utf8)
        try corrupted.write(to: archive)
        let transport = ChatPersistenceTransport()
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
                                         accessToken: { "mock" }, transport: transport, storageURL: archive)
        XCTAssertNotNil(assistant.storageErrorMessage)
        let id = assistant.createChat()
        _ = assistant.renameChat(id, title: "Do not replace saved history")
        XCTAssertEqual(try Data(contentsOf: archive), corrupted)
        XCTAssertNotNil(assistant.storageErrorMessage)
        XCTAssertTrue(transport.requests.isEmpty)
        await assistant.refreshModels()
        XCTAssertFalse(assistant.send("Do not overwrite corrupt history"))
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertNotNil(assistant.errorMessage)
        XCTAssertTrue(transport.inferenceRequests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), corrupted)
    }

    @MainActor
    func testWriteFailureReportsStorageErrorWithoutOverwritingBlockingPath() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("not-a-directory")
        let original = Data("preserve me".utf8)
        try original.write(to: blocker)
        let archive = blocker.appendingPathComponent("chats.json")
        let transport = ChatPersistenceTransport()
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
                                         accessToken: { "mock" }, transport: transport, storageURL: archive)
        let id = assistant.createChat()
        _ = assistant.renameChat(id, title: "Unsaved chat")
        XCTAssertNotNil(assistant.storageErrorMessage)
        XCTAssertEqual(try Data(contentsOf: blocker), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        await assistant.refreshModels()
        XCTAssertFalse(assistant.send("Do not start an unsaved turn"))
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertNotNil(assistant.errorMessage)
        XCTAssertTrue(transport.inferenceRequests.isEmpty)
    }
}

extension AssistantChatPersistenceTests {
    @MainActor
    func testManualRenameWinsAgainstDelayedLunaTitleAndPersistsWithoutChangingTranscript() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        transport.catalog = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"},{\"slug\":\"gpt-6-luna\",\"display_name\":\"Luna\",\"visibility\":\"list\"},{\"slug\":\"gpt-6.1-luna\",\"display_name\":\"Latest Luna\",\"visibility\":\"list\"}]}".utf8)
        transport.heldModels = ["gpt-6.1-luna"]
        transport.replies = [chatCompleted(chatAnswer("Your actual answer"))]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { "account-a" }, storageURL: archive)
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Review my squats"))
        await waitUntil { transport.held.count == 1 }
        let chatID = try XCTUnwrap(assistant.selectedChatID)
        let transcript = assistant.messages.map(\.text)
        XCTAssertTrue(assistant.selectedChat?.isGeneratingTitle == true)
        XCTAssertEqual(try body(XCTUnwrap(transport.inferenceRequests.last))["model"] as? String, "gpt-6.1-luna")
        XCTAssertTrue(assistant.renameChat(chatID, title: "  My chosen title  "))
        XCTAssertFalse(assistant.selectedChat?.isGeneratingTitle == true)
        transport.release(0, output: chatAnswer("Late automatic title"))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(assistant.selectedChat?.title, "My chosen title")
        XCTAssertEqual(assistant.messages.map(\.text), transcript)
        XCTAssertFalse(assistant.renameChat(chatID, title: "  \n "))
        XCTAssertFalse(assistant.renameChat(chatID, title: String(repeating: "x", count: 121)))
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                        accountIdentity: { "account-a" }, storageURL: archive)
        XCTAssertEqual(reopened.selectedChat?.title, "My chosen title")
        XCTAssertEqual(reopened.messages.map(\.text), transcript)
    }

    @MainActor
    func testFailedTurnRemainsVisibleButCannotPoisonRelaunchedConversationContext() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        transport.replies = [chatCompleted(chatAnswer("Committed answer")),
            chatEvent(["type": "response.output_text.delta", "delta": "Uncommitted partial"])
                + chatEvent(["type": "response.failed", "response": ["error": ["code": "server_error", "message": "Temporary failure"]]])]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { "account-a" }, storageURL: archive)
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("Committed question"))
        await waitUntil { !assistant.isWorking }
        XCTAssertTrue(assistant.send("Failed question"))
        await waitUntil { !assistant.isWorking }
        XCTAssertNotNil(assistant.errorMessage)
        XCTAssertEqual(assistant.messages.last?.text, "Uncommitted partial")
        let replay = ChatPersistenceTransport()
        replay.replies = [chatCompleted(chatAnswer("Retry completed"))]
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: replay,
                                        accountIdentity: { "account-a" }, storageURL: archive)
        XCTAssertEqual(reopened.messages.map(\.text), assistant.messages.map(\.text))
        await reopened.refreshModels()
        XCTAssertTrue(reopened.send("Retry question"))
        await waitUntil { !reopened.isWorking }
        let users = try input(XCTUnwrap(replay.inferenceRequests.last)).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        XCTAssertEqual(users, ["Committed question", "Retry question"])
        XCTAssertFalse(String(decoding: try canonical(input(XCTUnwrap(replay.inferenceRequests.last))), as: UTF8.self).contains("Uncommitted partial"))
    }

    @MainActor
    func testCredentialRevisionUsesStableArchiveIdentityWithoutLeakingAcrossAccounts() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let transport = ChatPersistenceTransport()
        var revision = "account-a-revision-1"
        var account = "account-a"
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { revision }, storageURL: archive,
                                         archiveAccountIdentity: { account })
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Saved before refresh"))]
        XCTAssertTrue(assistant.send("Before credential refresh"))
        await waitUntil { !assistant.isWorking }
        let savedID = try XCTUnwrap(assistant.selectedChatID)
        assistant.accountWillChange()
        revision = "account-a-revision-2"
        assistant.reconcileAccount()
        XCTAssertTrue(assistant.chats.contains { $0.id == savedID })
        XCTAssertEqual(assistant.selectedChatID, savedID)
        XCTAssertEqual(assistant.messages.map(\.text), ["Before credential refresh", "Saved before refresh"])
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Saved after refresh"))]
        XCTAssertTrue(assistant.send("After credential refresh"))
        await waitUntil { !assistant.isWorking }
        let users = try input(XCTUnwrap(transport.inferenceRequests.last)).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        XCTAssertEqual(users, ["Before credential refresh", "After credential refresh"])
        let saved = try AssistantChatArchive.load(from: archive)
        XCTAssertEqual(Set(saved.accounts.keys), Set(["account-a"]))
        assistant.accountWillChange()
        account = "account-b"
        revision = "account-b-revision-1"
        assistant.reconcileAccount()
        XCTAssertFalse(assistant.chats.contains { $0.id == savedID })
        let reopened = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                        accountIdentity: { "account-a-revision-3" }, storageURL: archive,
                                        archiveAccountIdentity: { "account-a" })
        XCTAssertTrue(reopened.chats.contains { $0.id == savedID })
        reopened.selectChat(savedID)
        XCTAssertEqual(reopened.messages.last?.text, "Saved after refresh")
    }
}

extension AssistantChatPersistenceTests {
    @MainActor
    func testTitleCompletionDoesNotStopConcurrentFollowUpOrPolluteConversationHistory() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ChatPersistenceTransport()
        transport.catalog = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"},{\"slug\":\"gpt-6-luna\",\"display_name\":\"Luna\",\"visibility\":\"list\"}]}".utf8)
        transport.heldModels = ["gpt-6-luna"]
        transport.replies = [chatCompleted(chatAnswer("First answer"))]
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
                                         accessToken: { "mock" }, transport: transport,
                                         storageURL: directory.appendingPathComponent("chats.json"))
        await assistant.refreshModels()
        XCTAssertTrue(assistant.send("First question"))
        await waitUntil { transport.held.count == 1 }
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.selectedChat?.isGeneratingTitle == true)
        transport.holdStreams = true
        XCTAssertTrue(assistant.send("Second question"))
        await waitUntil { transport.held.count == 2 }
        transport.release(0, output: chatAnswer("Generated training title"))
        await waitUntil { assistant.selectedChat?.isGeneratingTitle == false }
        XCTAssertEqual(assistant.selectedChat?.title, "Generated training title")
        XCTAssertTrue(assistant.isWorking)
        transport.release(1, output: chatAnswer("Second answer"))
        await waitUntil { !assistant.isWorking }
        XCTAssertEqual(assistant.messages.map(\.text), ["First question", "First answer", "Second question", "Second answer"])
        let secondInput = try input(XCTUnwrap(transport.inferenceRequests.last))
        XCTAssertEqual(secondInput.filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }, ["First question", "Second question"])
        XCTAssertFalse(String(decoding: try canonical(secondInput), as: UTF8.self).contains("Generated training title"))
        XCTAssertEqual(transport.held.count, 2, "A successful title is generated once per chat")
    }
}

extension AssistantChatPersistenceTests {
    @MainActor
    func testOfflineRelaunchRestoresLastAccountHistoryAndSigningInAnotherAccountUsesItsOwnChats() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("chats.json")
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let signedInTransport = ChatPersistenceTransport()
        signedInTransport.replies = [chatCompleted(chatAnswer("Account A saved answer"))]
        let signedIn = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: signedInTransport,
                                        accountIdentity: { "account-a-revision-1" }, storageURL: archive,
                                        archiveAccountIdentity: { "account-a" })
        await signedIn.refreshModels()
        XCTAssertTrue(signedIn.send("Account A saved question"))
        await waitUntil { !signedIn.isWorking }
        let accountAChat = try XCTUnwrap(signedIn.selectedChatID)
        let originalIDs = signedIn.messages.map(\.id)

        var account: String?
        var credentialRevision: String?
        let offlineTransport = ChatPersistenceTransport()
        var tokenReads = 0
        let offline = WorkoutAssistant(store: store, accessToken: {
            tokenReads += 1
            return "mock"
        }, transport: offlineTransport, accountIdentity: { credentialRevision }, storageURL: archive,
           archiveAccountIdentity: { account })
        XCTAssertEqual(offline.selectedChatID, accountAChat)
        XCTAssertEqual(offline.messages.map(\.id), originalIDs)
        XCTAssertEqual(offline.messages.map(\.text), ["Account A saved question", "Account A saved answer"])
        XCTAssertTrue(offline.models.isEmpty)
        XCTAssertFalse(offline.send("Cannot infer while disconnected"))
        XCTAssertEqual(tokenReads, 0)
        XCTAssertTrue(offlineTransport.requests.isEmpty)
        XCTAssertTrue(offline.renameChat(accountAChat, title: "Reviewed while offline"))

        offline.accountWillChange()
        account = "account-b"
        credentialRevision = "account-b-revision-1"
        offline.reconcileAccount()
        XCTAssertTrue(offline.messages.isEmpty)
        XCTAssertFalse(offline.chats.contains { $0.id == accountAChat })
        await offline.refreshModels()
        offlineTransport.replies = [chatCompleted(chatAnswer("Account B saved answer"))]
        XCTAssertTrue(offline.send("Account B saved question"))
        await waitUntil { !offline.isWorking }
        let accountBChat = try XCTUnwrap(offline.selectedChatID)
        XCTAssertNotEqual(accountBChat, accountAChat)
        let accountBIDs = offline.messages.map(\.id)
        let requestCount = offlineTransport.requests.count
        let tokenCount = tokenReads
        offline.accountWillChange()
        account = nil
        credentialRevision = nil
        offline.reconcileAccount()
        XCTAssertEqual(offline.selectedChatID, accountBChat)
        XCTAssertEqual(offline.messages.map(\.id), accountBIDs)
        XCTAssertFalse(offline.send("Disconnected follow-up"))
        XCTAssertEqual(offlineTransport.requests.count, requestCount)
        XCTAssertEqual(tokenReads, tokenCount)

        let reopenedOffline = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                               accountIdentity: { nil }, storageURL: archive,
                                               archiveAccountIdentity: { nil })
        XCTAssertEqual(reopenedOffline.selectedChatID, accountBChat)
        XCTAssertEqual(reopenedOffline.messages.map(\.text), ["Account B saved question", "Account B saved answer"])
        let reopenedA = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: ChatPersistenceTransport(),
                                         accountIdentity: { "account-a-revision-2" }, storageURL: archive,
                                         archiveAccountIdentity: { "account-a" })
        XCTAssertEqual(reopenedA.selectedChatID, accountAChat)
        XCTAssertEqual(reopenedA.selectedChat?.title, "Reviewed while offline")
        XCTAssertEqual(reopenedA.messages.map(\.id), originalIDs)
        XCTAssertFalse(reopenedA.chats.contains { $0.id == accountBChat })
        let saved = try AssistantChatArchive.load(from: archive)
        XCTAssertEqual(Set(saved.accounts.keys), Set(["account-a", "account-b"]))
        XCTAssertEqual(saved.lastAccount, "account-b")
    }

    @MainActor
    func testAccountSwitchingRetainsChatsAndHistoryWhenDiskPersistenceIsDisabled() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ChatPersistenceTransport()
        var account = "account-a"
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite")),
                                         accessToken: { "mock" }, transport: transport,
                                         accountIdentity: { account }, storageURL: nil)
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Memory answer A"))]
        XCTAssertTrue(assistant.send("Memory question A"))
        await waitUntil { !assistant.isWorking }
        let firstID = try XCTUnwrap(assistant.selectedChatID)
        assistant.accountWillChange()
        account = "account-b"
        assistant.reconcileAccount()
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Memory answer B"))]
        XCTAssertTrue(assistant.send("Memory question B"))
        await waitUntil { !assistant.isWorking }
        let secondID = try XCTUnwrap(assistant.selectedChatID)
        assistant.accountWillChange()
        account = "account-a"
        assistant.reconcileAccount()
        XCTAssertEqual(assistant.selectedChatID, firstID)
        XCTAssertEqual(assistant.messages.map(\.text), ["Memory question A", "Memory answer A"])
        await assistant.refreshModels()
        transport.replies = [chatCompleted(chatAnswer("Memory follow-up answer A"))]
        XCTAssertTrue(assistant.send("Memory follow-up A"))
        await waitUntil { !assistant.isWorking }
        let users = try input(XCTUnwrap(transport.inferenceRequests.last)).filter { $0["role"] as? String == "user" }.compactMap { $0["content"] as? String }
        XCTAssertEqual(users, ["Memory question A", "Memory follow-up A"])
        assistant.accountWillChange()
        account = "account-b"
        assistant.reconcileAccount()
        XCTAssertEqual(assistant.selectedChatID, secondID)
        XCTAssertEqual(assistant.messages.map(\.text), ["Memory question B", "Memory answer B"])
        XCTAssertNil(assistant.storageErrorMessage)
    }
}
