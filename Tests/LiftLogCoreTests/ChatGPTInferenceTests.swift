import Foundation
import XCTest
@testable import LiftLogCore

private final class InferenceMockTransport: ChatGPTInferenceTransport {
    var requests: [URLRequest] = []
    var catalog = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"}]}".utf8)
    var dataHandler: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    var streamHandler: ((URLRequest) throws -> ChatGPTHTTPStream)?
    var streams: [[String]] = []
    var status = 200
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let dataHandler { return try await dataHandler(request) }
        return (catalog, Self.response(request.url!, status: status))
    }
    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        requests.append(request)
        if let streamHandler { return try streamHandler(request) }
        let lines = streams.isEmpty ? [] : streams.removeFirst()
        return ChatGPTHTTPStream(response: Self.response(request.url!, status: status), lines: AsyncThrowingStream { continuation in
            lines.forEach { continuation.yield($0) }
            continuation.finish()
        })
    }
    static func response(_ url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["x-request-id": "test-request", "Content-Type": "text/event-stream"])!
    }
}

private func event(_ value: [String: Any]) -> [String] {
    let data = try! JSONSerialization.data(withJSONObject: value)
    return ["event: \(value["type"] ?? "")", "data: " + String(decoding: data, as: UTF8.self), ""]
}

private func completed(_ output: [[String: Any]] = []) -> [String] {
    event(["type": "response.completed", "response": ["status": "completed", "output": output]])
}

private func answer(_ text: String) -> [[String: Any]] {
    [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text, "annotations": []]]]]
}

private func call(_ name: String = "get_workout_data", id: String = "call_1", arguments: String = "{}", namespace: String = "liftlog") -> [String: Any] {
    ["type": "function_call", "call_id": id, "name": name, "namespace": namespace, "arguments": arguments, "status": "completed"]
}

final class ChatGPTInferenceTests: XCTestCase {
    @MainActor
    func testModelCatalogFiltersVisibilityAndPreservesAccountOrder() async throws {
        let transport = InferenceMockTransport()
        transport.catalog = Data("{\"models\":[{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hidden\"},{\"slug\":\"second\",\"display_name\":\"Second\",\"visibility\":\"list\"},{\"slug\":\"first\",\"display_name\":\"First\",\"visibility\":\"list\"}]}".utf8)
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        let models = try await client.models()
        XCTAssertEqual(models.map(\.slug), ["second", "first"])
        XCTAssertEqual(models.map(\.displayName), ["Second", "First"])
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-test")
    }

    @MainActor
    func testSubscriptionRequestInvariantsAndFullOutputReplay() async throws {
        let transport = InferenceMockTransport()
        let output = [["type": "reasoning", "id": "rs_1", "encrypted_content": "opaque", "summary": []] as [String: Any]] + answer("Ready")
        transport.streams = [event(["type": "response.output_text.delta", "delta": "Re"]) + completed(output)]
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        var deltas = ""
        let result = try await client.respond(model: "gpt-6.1-sol", input: [["role": "user", "content": "Hi"]], tools: WorkoutAgentTools.definitions, instructions: "Help", onText: { deltas += $0 })
        XCTAssertEqual(deltas, "Re")
        XCTAssertEqual(result.text, "Ready")
        XCTAssertEqual(result.output.first?["encrypted_content"] as? String, "opaque")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["input"] as? [[String: Any]])
        for key in ["previous_response_id", "max_output_tokens", "temperature", "metadata", "background", "conversation"] { XCTAssertNil(body[key]) }
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "namespace")
    }

    func testByteFramerPreservesEmptyLinesAndUTF8AcrossChunks() throws {
        var framer = ChatGPTSSELineFramer()
        var lines: [String] = []
        for byte in "data: one\r\n\r\ndata: café\n\ndata: tail".utf8 {
            if let line = try framer.append(byte: byte) { lines.append(line) }
        }
        if let line = try framer.finish() { lines.append(line) }
        XCTAssertEqual(lines, ["data: one", "", "data: café", "", "data: tail"])
        var invalid = ChatGPTSSELineFramer()
        _ = try invalid.append(byte: 0xff)
        XCTAssertThrowsError(try invalid.append(byte: 10))
    }

    func testSSEMultilineCommentsCRAndFinalFrame() throws {
        var parser = ChatGPTSSEParser()
        XCTAssertNil(try parser.append(line: ": keepalive"))
        XCTAssertNil(try parser.append(line: "event: response.completed"))
        XCTAssertNil(try parser.append(line: "data: {\r"))
        XCTAssertNil(try parser.append(line: "data: \"type\":\"response.completed\"}"))
        XCTAssertEqual(try parser.append(line: "\r"), "{\n\"type\":\"response.completed\"}")
        XCTAssertNil(try parser.append(line: "data: [DONE]"))
        XCTAssertEqual(try parser.finish(), "[DONE]")
    }

    @MainActor
    func testInterruptedStreamKeepsDeltasAndRequiresCompleted() async throws {
        let transport = InferenceMockTransport()
        transport.streams = [event(["type": "response.output_text.delta", "delta": "Partial"]) + ["data: [DONE]", ""]]
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        var text = ""
        do {
            _ = try await client.respond(model: "gpt-6.1-sol", input: [], tools: [], instructions: "", onText: { text += $0 })
            XCTFail("An unterminated response must fail")
        } catch {
            XCTAssertEqual((error as? ChatGPTInferenceError)?.code, "interrupted_stream")
            XCTAssertEqual(text, "Partial")
        }
    }

    @MainActor
    func testFailedUsageLimitAfterStreamingIsNotSuccess() async throws {
        let transport = InferenceMockTransport()
        transport.streams = [event(["type": "response.output_text.delta", "delta": "Partial"]) + event(["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "limit", "param": "model"]]])]
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        do {
            _ = try await client.respond(model: "gpt-6.1-sol", input: [], tools: [], instructions: "", onText: { _ in })
            XCTFail("Usage errors must stop inference")
        } catch let error as ChatGPTInferenceError {
            XCTAssertEqual(error.code, "subscription_sharing_usage_limit_exceeded")
            XCTAssertEqual(error.parameter, "model")
            XCTAssertEqual(error.requestID, "test-request")
            XCTAssertTrue(error.localizedDescription.contains("Settings → Usage"))
            XCTAssertNotNil(error.responseBody)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    @MainActor
    func testIncompleteAndExplicitErrorAreFailures() async throws {
        for payload: [String: Any] in [
            ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]],
            ["type": "error", "code": "subscription_sharing_usage_unavailable", "message": "Unavailable"]
        ] {
            let transport = InferenceMockTransport()
            transport.streams = [event(payload)]
            let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
            do {
                _ = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
                XCTFail("Terminal failure is not success")
            } catch { XCTAssertNotNil(error as? ChatGPTInferenceError) }
        }
    }

    @MainActor
    func testHTTPAdmissionDiagnosticAndStatusArePreserved() async throws {
        let transport = InferenceMockTransport()
        transport.status = 403
        transport.streams = [["{\"detail\":\"Region restricted\"}"]]
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        do {
            _ = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
            XCTFail("Admission must fail")
        } catch let error as ChatGPTInferenceError {
            XCTAssertEqual(error.status, 403)
            XCTAssertNil(error.code)
            XCTAssertEqual(error.diagnostic, "Region restricted")
            XCTAssertEqual(error.requestID, "test-request")
            XCTAssertNotNil(error.responseBody)
        }
    }

    @MainActor
    func testUnnamespacedToolsAndDuplicateCallsAreRejected() async throws {
        let transport = InferenceMockTransport()
        let client = ChatGPTInferenceClient(accessToken: { "oauth-test" }, transport: transport)
        do {
            _ = try await client.respond(model: "model", input: [], tools: [["type": "function", "name": "unsafe"]], instructions: "", onText: { _ in })
            XCTFail("Namespace required")
        } catch { XCTAssertTrue(transport.requests.isEmpty) }
        transport.streams = [completed([call(), call()])]
        do {
            _ = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
            XCTFail("Duplicate call IDs rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("invalid tool call")) }
    }

    @MainActor
    func testAccountChangedDuringTokenRetrievalCannotDispatchRequest() async throws {
        let transport = InferenceMockTransport()
        var identity = "account-a"
        let client = ChatGPTInferenceClient(accessToken: {
            identity = "account-b"
            return "token-b"
        }, transport: transport, accountIdentity: { identity })
        do {
            _ = try await client.respond(model: "model", input: [["role": "user", "content": "Private old history"]], tools: [], instructions: "", onText: { _ in })
            XCTFail("An account change must cancel before dispatch")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testNativeURLSessionStreamingPreservesRealSSEDelimiters() async throws {
        InferenceURLProtocol.payload = Data((event(["type": "response.output_text.delta", "delta": "Café"]) + completed(answer("Café"))).joined(separator: "\n").utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InferenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ChatGPTInferenceClient(accessToken: { "mock-oauth" }, transport: URLSessionChatGPTTransport(session: session))
        var text = ""
        let result = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { text += $0 })
        XCTAssertEqual(result.text, "Café")
        XCTAssertEqual(text, "Café")
    }
}

private final class InferenceURLProtocol: URLProtocol {
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: InferenceMockTransport.response(request.url!), cacheStoragePolicy: .notAllowed)
        // Deliver arbitrarily fragmented UTF-8 and separators through the actual native transport.
        for byte in Self.payload { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WorkoutAssistantTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("AssistantTests-\(UUID()).json")
    }
    @MainActor
    private func waitForCompletion(_ assistant: WorkoutAssistant) async {
        for _ in 0..<10_000 {
            if !assistant.isWorking { return }
            await Task.yield()
        }
        XCTFail("Assistant did not finish")
    }

    @MainActor
    func testDefaultModelPreferenceAndFallback() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = InferenceMockTransport()
        transport.catalog = Data("{\"models\":[{\"slug\":\"first\",\"display_name\":\"First\",\"visibility\":\"list\"},{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"}]}".utf8)
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        XCTAssertEqual(assistant.selectedModel, "gpt-6.1-sol")
        assistant.selectedModel = "first"
        await assistant.refreshModels()
        XCTAssertEqual(assistant.selectedModel, "first")
        transport.catalog = Data("{\"models\":[{\"slug\":\"only\",\"display_name\":\"Only\",\"visibility\":\"list\"}]}".utf8)
        await assistant.refreshModels()
        XCTAssertEqual(assistant.selectedModel, "only")
    }

    @MainActor
    func testToolContinuationPreservesNamespaceReasoningAndFullHistory() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = InferenceMockTransport()
        transport.streams = [completed([["type": "reasoning", "encrypted_content": "opaque", "summary": []], call()]), completed(answer("Ready")), completed(answer("Again"))]
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        assistant.send("Read my data")
        await waitForCompletion(assistant)
        XCTAssertNil(assistant.errorMessage)
        let continuation = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests[2].httpBody)) as? [String: Any])
        let input = try XCTUnwrap(continuation["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(input[2]["namespace"] as? String, "liftlog")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        assistant.send("What next?")
        await waitForCompletion(assistant)
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests[3].httpBody)) as? [String: Any])
        XCTAssertEqual((next["input"] as? [[String: Any]])?.count, 6)
    }

    @MainActor
    func testBoundedLoopAndWrongNamespaceNeverExecuteMutations() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkoutStore(fileURL: url)
        let transport = InferenceMockTransport()
        transport.streams = [completed([call()])]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport, maximumRounds: 1)
        await assistant.refreshModels()
        assistant.send("Loop")
        await waitForCompletion(assistant)
        XCTAssertTrue(assistant.errorMessage?.contains("tool limit") == true)
        XCTAssertEqual(transport.requests.count, 2)
        transport.streams = [completed([call(namespace: "shell")])]
        let other = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport)
        await other.refreshModels()
        other.send("Bad namespace")
        await waitForCompletion(other)
        XCTAssertTrue(other.errorMessage?.contains("invalid workout tool") == true)
    }

    @MainActor
    func testProposalsAreReviewedThenInvalidatedIfStreamFails() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkoutStore(fileURL: url)
        let before = store.templates
        let args = try JSONSerialization.data(withJSONObject: ["name": "Proposed", "unit": "lb", "exercises": [["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": 100, "reps": 5]]]]])
        let transport = InferenceMockTransport()
        transport.streams = [completed([call("propose_create_template", arguments: String(decoding: args, as: UTF8.self))]), event(["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "Limit"]]])]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        assistant.send("Create")
        await waitForCompletion(assistant)
        XCTAssertEqual(store.templates, before)
        XCTAssertEqual(assistant.messages.compactMap(\.proposal).first?.status, .rejected)
        XCTAssertTrue(assistant.usageLimitReached)
        assistant.send("Retry")
        XCTAssertFalse(assistant.isWorking)
        XCTAssertEqual(transport.requests.count, 3)
    }

    @MainActor
    func testStaleProposalUpdatesTranscriptStatusAfterApplyThrows() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkoutStore(fileURL: url)
        let args = try JSONSerialization.data(withJSONObject: ["name": "Draft", "unit": "lb", "exercises": [["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": 100, "reps": 5]]]]])
        let transport = InferenceMockTransport()
        transport.streams = [completed([call("propose_create_template", arguments: String(decoding: args, as: UTF8.self))]), completed(answer("Review the draft"))]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        assistant.send("Draft a template")
        await waitForCompletion(assistant)
        let proposal = try XCTUnwrap(assistant.messages.compactMap(\.proposal).first)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertThrowsError(try assistant.applyProposal(proposal.id))
        XCTAssertEqual(assistant.messages.compactMap(\.proposal).first?.status, .stale)
        XCTAssertEqual(store.templates.count, 2)
    }

    @MainActor
    func testSynchronousAccountChangeRejectsSendAndClearsOldContext() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = InferenceMockTransport()
        var identity = "account-a"
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: transport, accountIdentity: { identity })
        await assistant.refreshModels()
        transport.streams = [completed(answer("Private account A context"))]
        assistant.send("Hello A")
        await waitForCompletion(assistant)
        XCTAssertFalse(assistant.messages.isEmpty)
        identity = "account-b"
        assistant.send("Hello B")
        XCTAssertFalse(assistant.isWorking)
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertTrue(assistant.models.isEmpty)
        XCTAssertEqual(transport.requests.count, 2)
    }

    @MainActor
    func testResetDiscardsStaleCatalogCompletion() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let transport = InferenceMockTransport()
        var resume: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        transport.dataHandler = { request in
            try await withCheckedThrowingContinuation { continuation in resume = continuation }
        }
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: transport)
        let load = Task { await assistant.refreshModels() }
        while resume == nil { await Task.yield() }
        assistant.reset()
        resume?.resume(returning: (transport.catalog, InferenceMockTransport.response(URL(string: "https://api.openai.com/v1/models")!)))
        await load.value
        XCTAssertTrue(assistant.models.isEmpty)
        XCTAssertEqual(assistant.selectedModel, "")
        XCTAssertFalse(assistant.isLoadingModels)
    }

    @MainActor
    func testCancellationInvalidatesDraftsAndStaleResponseCannotRepopulateReset() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkoutStore(fileURL: url)
        let transport = InferenceMockTransport()
        let args = try JSONSerialization.data(withJSONObject: ["name": "Draft", "unit": "lb", "exercises": [["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": 0, "reps": 8]]]]])
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        var rounds = 0
        transport.streamHandler = { request in
            rounds += 1
            let lines = AsyncThrowingStream<String, Error> { stream in
                if rounds == 1 {
                    completed([call("propose_create_template", arguments: String(decoding: args, as: UTF8.self))]).forEach { stream.yield($0) }
                    stream.finish()
                } else { continuation = stream }
            }
            return ChatGPTHTTPStream(response: InferenceMockTransport.response(request.url!), lines: lines)
        }
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        assistant.send("Prepare")
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(assistant.messages.compactMap(\.proposal).first?.status, .pending)
        assistant.cancel()
        XCTAssertEqual(assistant.messages.compactMap(\.proposal).first?.status, .rejected)
        assistant.reset()
        completed(answer("Stale")).forEach { continuation?.yield($0) }
        continuation?.finish()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(assistant.messages.isEmpty)
        XCTAssertTrue(assistant.models.isEmpty)
        XCTAssertFalse(assistant.isWorking)
        XCTAssertEqual(store.templates.count, 2)
    }
}

/// The service can send response.completed while the HTTP body remains open.
/// Cancelling that request's byte reader must not cancel the assistant's next tool round.
private final class OpenEndedInferenceURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var postCount = 0
    static var replayItemEvents = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: Data
        let leaveOpen: Bool
        if request.url?.lastPathComponent == "models" {
            payload = Data("{\"models\":[{\"slug\":\"gpt-6.1-sol\",\"display_name\":\"Sol\",\"visibility\":\"list\"}]}".utf8)
            leaveOpen = false
        } else {
            Self.lock.lock()
            Self.postCount += 1
            let round = Self.postCount
            Self.lock.unlock()
            let output = round == 1 ? [call()] : answer("Your data is ready.")
            let lines: [String]
            if Self.replayItemEvents {
                lines = output.enumerated().flatMap { event(["type": "response.output_item.done", "output_index": $0.offset, "item": $0.element]) } + completed()
            } else { lines = completed(output) }
            payload = Data((lines.joined(separator: "\n") + "\n").utf8)
            leaveOpen = round == 1
        }
        client?.urlProtocol(self, didReceive: InferenceMockTransport.response(request.url!), cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        if !leaveOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

extension WorkoutAssistantTests {
    @MainActor
    func testNativeOpenEndedTerminalReaderCancellationDoesNotAbortToolContinuation() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenEndedInferenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        OpenEndedInferenceURLProtocol.postCount = 0
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: URLSessionChatGPTTransport(session: session))
        await assistant.refreshModels()
        assistant.send("Chart my training volume")
        await waitForCompletion(assistant)
        XCTAssertEqual(OpenEndedInferenceURLProtocol.postCount, 2)
        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(assistant.messages.last?.text, "Your data is ready.")
    }
}

extension WorkoutAssistantTests {
    @MainActor
    func testNativeStreamedOutputItemsSurviveAnEmptyCompletedOutputArray() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenEndedInferenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        OpenEndedInferenceURLProtocol.postCount = 0
        OpenEndedInferenceURLProtocol.replayItemEvents = true
        defer { OpenEndedInferenceURLProtocol.replayItemEvents = false }
        let assistant = WorkoutAssistant(store: WorkoutStore(fileURL: url), accessToken: { "mock" }, transport: URLSessionChatGPTTransport(session: session))
        await assistant.refreshModels()
        assistant.send("Chart my training volume")
        await waitForCompletion(assistant)
        XCTAssertEqual(OpenEndedInferenceURLProtocol.postCount, 2)
        XCTAssertNil(assistant.errorMessage)
        XCTAssertEqual(assistant.messages.last?.text, "Your data is ready.")
    }
}

extension ChatGPTInferenceTests {
    @MainActor
    func testNonemptyTerminalOutputIsAuthoritativeOverStreamedItems() async throws {
        let transport = InferenceMockTransport()
        transport.streams = [event(["type": "response.output_item.done", "output_index": 0, "item": call()]) + completed(answer("Authoritative answer"))]
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        let response = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
        XCTAssertEqual(response.text, "Authoritative answer")
        XCTAssertTrue(response.calls.isEmpty)
        XCTAssertEqual(response.output.count, 1)
    }

    @MainActor
    func testFinishedStreamItemsKeepOriginalOrderAndEncryptedReasoning() async throws {
        let transport = InferenceMockTransport()
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "opaque"]
        transport.streams = [event(["type": "response.output_item.done", "output_index": 2, "item": call()])
            + event(["type": "response.output_item.done", "output_index": 0, "item": reasoning]) + completed()]
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        let response = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
        XCTAssertEqual(response.output.map { $0["type"] as? String }, ["reasoning", "function_call"])
        XCTAssertEqual(response.output.first?["encrypted_content"] as? String, "opaque")
        XCTAssertEqual(response.calls.first?.namespace, "liftlog")
        XCTAssertEqual(response.calls.first?.callID, "call_1")
    }

    @MainActor
    func testIncompleteStreamedCallAndOutOfRangeItemAreRejected() async throws {
        var unfinishedCall = call()
        unfinishedCall["status"] = "in_progress"
        for (index, item) in [(0, unfinishedCall), (256, call())] {
            let transport = InferenceMockTransport()
            transport.streams = [event(["type": "response.output_item.done", "output_index": index, "item": item]) + completed()]
            let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
            do {
                _ = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
                XCTFail("An invalid or unfinished call cannot execute")
            } catch { XCTAssertTrue(error.localizedDescription.contains("invalid")) }
        }
    }

    @MainActor
    func testGenuinelyEmptyCompletionProducesVisibleFailure() async throws {
        let transport = InferenceMockTransport()
        transport.streams = [completed()]
        let client = ChatGPTInferenceClient(accessToken: { "mock" }, transport: transport)
        do {
            _ = try await client.respond(model: "model", input: [], tools: [], instructions: "", onText: { _ in })
            XCTFail("An empty completion cannot silently remove the reply")
        } catch let error as ChatGPTInferenceError {
            XCTAssertEqual(error.code, "empty_response")
            XCTAssertEqual(error.requestID, "test-request")
        }
    }
}

extension WorkoutAssistantTests {
    @MainActor
    func testFinishedToolItemCannotCreateProposalWithoutCompletedResponse() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkoutStore(fileURL: url)
        let args = try JSONSerialization.data(withJSONObject: ["name": "Never staged", "unit": "lb", "exercises": [["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": 100, "reps": 5]]]]])
        let transport = InferenceMockTransport()
        transport.streams = [event(["type": "response.output_item.done", "output_index": 0, "item": call("propose_create_template", arguments: String(decoding: args, as: UTF8.self))])
            + event(["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "Limit"]]])]
        let assistant = WorkoutAssistant(store: store, accessToken: { "mock" }, transport: transport)
        await assistant.refreshModels()
        assistant.send("Create a template")
        await waitForCompletion(assistant)
        XCTAssertTrue(assistant.messages.compactMap(\.proposal).isEmpty)
        XCTAssertEqual(store.templates.count, 2)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertTrue(assistant.usageLimitReached)
    }
}
