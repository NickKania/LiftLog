import Foundation

struct ChatGPTModel: Decodable, Identifiable, Equatable {
    let slug: String
    let displayName: String
    let visibility: String
    var id: String { slug }
    enum CodingKeys: String, CodingKey {
        case slug, visibility
        case displayName = "display_name"
    }
}

struct ChatGPTInferenceError: LocalizedError {
    let status: Int?
    let code: String?
    let parameter: String?
    let diagnostic: String
    let requestID: String?
    let responseBody: String?

    init(_ diagnostic: String, status: Int? = nil, code: String? = nil,
         parameter: String? = nil, requestID: String? = nil, responseBody: String? = nil) {
        self.diagnostic = diagnostic
        self.status = status
        self.code = code
        self.parameter = parameter
        self.requestID = requestID
        self.responseBody = responseBody
    }

    var errorDescription: String? {
        let recovery: String
        switch code {
        case "subscription_sharing_usage_limit_exceeded":
            recovery = "ChatGPT plan usage has reached a limit. Check ChatGPT Settings → Usage before trying again."
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
            recovery = "ChatGPT plan usage is temporarily unavailable. Try again later."
        case "subscription_sharing_user_not_eligible":
            recovery = "ChatGPT plan usage is unavailable for this account or workspace."
        case "subscription_sharing_unsupported_capability":
            recovery = "ChatGPT rejected an unsupported capability\(parameter.map { " (\($0))" } ?? "")."
        case "subscription_sharing_invalid_user":
            recovery = "ChatGPT could not validate the selected account. Check your connection in Settings."
        default:
            if status == 401 { recovery = "ChatGPT did not accept this account’s sign-in or plan permission. Check Settings." }
            else if status == 403 { recovery = "ChatGPT plan usage is restricted for this request. \(diagnostic)" }
            else { recovery = diagnostic }
        }
        return recovery + (code.map { " [\($0)]" } ?? "") + (requestID.map { " Request: \($0)" } ?? "")
    }
}

struct ChatGPTHTTPStream {
    let response: HTTPURLResponse
    let lines: AsyncThrowingStream<String, Error>
    let cancel: () -> Void
    init(response: HTTPURLResponse, lines: AsyncThrowingStream<String, Error>, cancel: @escaping () -> Void = {}) {
        self.response = response
        self.lines = lines
        self.cancel = cancel
    }
}

protocol ChatGPTInferenceTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream
}

struct URLSessionChatGPTTransport: ChatGPTInferenceTransport {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTInferenceError("Invalid HTTP response.") }
        return (data, response)
    }
    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTInferenceError("Invalid HTTP response.") }
        var reader: Task<Void, Never>!
        let lines = AsyncThrowingStream<String, Error> { continuation in
            reader = Task {
                do {
                    var framer = ChatGPTSSELineFramer()
                    var totalBytes = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        totalBytes += 1
                        guard totalBytes <= 16_000_000 else { throw ChatGPTInferenceError("ChatGPT response exceeded the size limit.") }
                        if let line = try framer.append(byte: byte) { continuation.yield(line) }
                    }
                    if let line = try framer.finish() { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            let readingTask = reader!
            continuation.onTermination = { _ in readingTask.cancel() }
        }
        let readingTask = reader!
        return ChatGPTHTTPStream(response: response, lines: lines, cancel: { readingTask.cancel() })
    }
}

struct ChatGPTFunctionCall {
    let callID: String
    let name: String
    let namespace: String?
    let arguments: String
}

struct ChatGPTInferenceResponse {
    let text: String
    /// Preserve every output item, including reasoning and namespaced calls, for continuation.
    let output: [[String: Any]]
    let calls: [ChatGPTFunctionCall]
}

/// OAuth subscription inference only. Never retries against a different billing route.
@MainActor
final class ChatGPTInferenceClient {
    private let transport: any ChatGPTInferenceTransport
    private let accessToken: () async throws -> String
    private let accountIdentity: () -> String?
    private let baseURL = URL(string: "https://api.openai.com/v1/")!

    init(accessToken: @escaping () async throws -> String,
         transport: any ChatGPTInferenceTransport = URLSessionChatGPTTransport(),
         accountIdentity: @escaping () -> String? = { nil }) {
        self.accessToken = accessToken
        self.transport = transport
        self.accountIdentity = accountIdentity
    }

    func models() async throws -> [ChatGPTModel] {
        let request = try await authorizedRequest(path: "models")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw Self.httpError(data: data, response: response) }
        struct Catalog: Decodable { let models: [ChatGPTModel] }
        let models = try JSONDecoder().decode(Catalog.self, from: data).models
        return models.filter { $0.visibility == "list" && !$0.slug.isEmpty }
    }

    func respond(model: String, input: [[String: Any]], tools: [[String: Any]],
                 instructions: String, onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        guard !model.isEmpty else { throw ChatGPTInferenceError("Select an available ChatGPT model first.") }
        guard tools.allSatisfy({ $0["type"] as? String == "namespace" }) else {
            throw ChatGPTInferenceError("Function tools must be grouped in namespaces.")
        }
        var request = try await authorizedRequest(path: "responses")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": input, "instructions": instructions,
            "tools": tools, "store": false, "stream": true
        ])
        guard (request.httpBody?.count ?? 0) <= 2_000_000 else {
            throw ChatGPTInferenceError("This conversation is too large. Start a new chat to continue.")
        }
        let stream = try await transport.stream(for: request)
        defer { stream.cancel() }
        try Task.checkCancellation()
        guard (200..<300).contains(stream.response.statusCode) else {
            var body = ""
            for try await line in stream.lines {
                try Task.checkCancellation()
                body += line + "\n"
                if body.utf8.count > 65_536 { break }
            }
            throw Self.httpError(data: Data(body.utf8), response: stream.response)
        }
        var parser = ChatGPTSSEParser()
        var streamedOutput = ChatGPTStreamOutput()
        var totalBytes = 0
        for try await line in stream.lines {
            try Task.checkCancellation()
            totalBytes += line.utf8.count
            guard totalBytes <= 16_000_000 else { throw ChatGPTInferenceError("ChatGPT response exceeded the size limit.") }
            if let event = try parser.append(line: line) {
                if let result = try Self.consume(event: event, response: stream.response, streamedOutput: &streamedOutput, onText: onText) { return result }
            }
        }
        if let event = try parser.finish() {
            if let result = try Self.consume(event: event, response: stream.response, streamedOutput: &streamedOutput, onText: onText) { return result }
        }
        throw ChatGPTInferenceError("The connection ended before ChatGPT completed its response. The partial reply was kept; try again.", code: "interrupted_stream")
    }

    private func authorizedRequest(path: String) async throws -> URLRequest {
        let identity = accountIdentity()
        let token = try await accessToken()
        try Task.checkCancellation()
        guard identity == accountIdentity() else { throw CancellationError() }
        guard !token.isEmpty else { throw ChatGPTInferenceError("Connect your ChatGPT account in Settings.") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func consume(event: String, response: HTTPURLResponse,
                                streamedOutput: inout ChatGPTStreamOutput, onText: (String) -> Void) throws -> ChatGPTInferenceResponse? {
        guard event != "[DONE]" else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            throw ChatGPTInferenceError("ChatGPT sent an invalid streaming event.")
        }
        if type == "response.output_item.done" {
            guard let index = object["output_index"] as? Int, let item = object["item"] as? [String: Any] else {
                throw ChatGPTInferenceError("ChatGPT sent an invalid finalized output item.")
            }
            try streamedOutput.record(item: item, at: index)
        }
        if type == "response.output_text.delta", let delta = object["delta"] as? String { onText(delta) }
        if type == "response.refusal.delta", let delta = object["delta"] as? String { onText(delta) }
        if type == "error" || type == "response.failed" || type == "response.incomplete" {
            let body = object["response"] as? [String: Any] ?? object
            let error = body["error"] as? [String: Any] ?? object["error"] as? [String: Any] ?? body
            let reason = (body["incomplete_details"] as? [String: Any])?["reason"] as? String
            throw ChatGPTInferenceError(error["message"] as? String ?? reason ?? "ChatGPT did not complete its response.",
                status: response.statusCode, code: error["code"] as? String ?? type,
                parameter: error["param"] as? String, requestID: response.value(forHTTPHeaderField: "x-request-id"), responseBody: event)
        }
        guard type == "response.completed" else { return nil }
        guard let final = object["response"] as? [String: Any],
              let terminalOutput = final["output"] as? [[String: Any]], terminalOutput.count <= 256,
              final["status"] as? String == "completed" else {
            throw ChatGPTInferenceError("ChatGPT sent an invalid completed response.")
        }
        // The subscription stream can complete with output: [] after emitting canonical
        // output_item.done events. Finalized items remain staged until this terminal event.
        let output = streamedOutput.reconcile(with: terminalOutput)
        var text = ""
        var calls: [ChatGPTFunctionCall] = []
        var callIDs = Set<String>()
        for item in output {
            if item["type"] as? String == "function_call" {
                guard item["status"] == nil || item["status"] as? String == "completed",
                      item["namespace"] == nil || item["namespace"] is String,
                      let id = item["call_id"] as? String, !id.isEmpty, callIDs.insert(id).inserted,
                      let name = item["name"] as? String, !name.isEmpty,
                      let arguments = item["arguments"] as? String, arguments.utf8.count <= 65_536 else {
                    throw ChatGPTInferenceError("ChatGPT sent an invalid tool call.")
                }
                calls.append(ChatGPTFunctionCall(callID: id, name: name, namespace: item["namespace"] as? String, arguments: arguments))
            }
            for content in item["content"] as? [[String: Any]] ?? [] {
                text += content["text"] as? String ?? content["refusal"] as? String ?? ""
            }
        }
        guard !text.isEmpty || !calls.isEmpty else {
            throw ChatGPTInferenceError("ChatGPT completed without a reply or a workout action. Try again.", code: "empty_response",
                requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        return ChatGPTInferenceResponse(text: text, output: output, calls: calls)
    }

    private static func httpError(data: Data, response: HTTPURLResponse) -> ChatGPTInferenceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = object["error"] as? [String: Any] ?? [:]
        return ChatGPTInferenceError(error["message"] as? String ?? object["detail"] as? String ?? "ChatGPT request failed (HTTP \(response.statusCode)).",
            status: response.statusCode, code: error["code"] as? String, parameter: error["param"] as? String,
            requestID: response.value(forHTTPHeaderField: "x-request-id"), responseBody: String(data: data, encoding: .utf8))
    }
}

/// SSE framing supports comments, CRLF, multi-line data, and a final frame without a blank line.
struct ChatGPTSSEParser {
    private var data: [String] = []
    private var bytes = 0
    mutating func append(line: String) throws -> String? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty { return take() }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            bytes += value.utf8.count
            guard bytes <= 2_000_000 else { throw ChatGPTInferenceError("ChatGPT streaming event exceeded the size limit.") }
            data.append(value)
        }
        return nil
    }
    mutating func finish() throws -> String? { take() }
    private mutating func take() -> String? {
        defer { data.removeAll(keepingCapacity: true); bytes = 0 }
        return data.isEmpty ? nil : data.joined(separator: "\n")
    }
}

/// Unlike AsyncBytes.lines, preserves empty lines used as SSE event delimiters.
struct ChatGPTSSELineFramer {
    private var buffer = Data()
    private var previousWasCR = false
    mutating func append(byte: UInt8) throws -> String? {
        if previousWasCR {
            previousWasCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            previousWasCR = byte == 13
            return try take()
        }
        guard buffer.count < 2_000_000 else { throw ChatGPTInferenceError("ChatGPT streaming line exceeded the size limit.") }
        buffer.append(byte)
        return nil
    }
    mutating func finish() throws -> String? { buffer.isEmpty ? nil : try take() }
    private mutating func take() throws -> String {
        guard let line = String(data: buffer, encoding: .utf8) else {
            throw ChatGPTInferenceError("ChatGPT sent invalid UTF-8 in its response.")
        }
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}

/// Only canonical finished items are replayed; added items and argument deltas never execute.
private struct ChatGPTStreamOutput {
    private var items: [Int: [String: Any]] = [:]
    private var sizes: [Int: Int] = [:]
    private var totalBytes = 0

    mutating func record(item: [String: Any], at index: Int) throws {
        guard (0..<256).contains(index), item["type"] is String else {
            throw ChatGPTInferenceError("ChatGPT sent an invalid finalized output item.")
        }
        let size = try JSONSerialization.data(withJSONObject: item).count
        let nextBytes = totalBytes - (sizes[index] ?? 0) + size
        guard size <= 2_000_000, nextBytes <= 8_000_000 else {
            throw ChatGPTInferenceError("ChatGPT finalized output exceeded the size limit.")
        }
        items[index] = item
        sizes[index] = size
        totalBytes = nextBytes
    }

    func reconcile(with terminal: [[String: Any]]) -> [[String: Any]] {
        // A supplied terminal array is authoritative. On the subscription route,
        // an empty array can follow complete output_item.done events instead.
        if !terminal.isEmpty { return terminal }
        return items.keys.sorted().compactMap { items[$0] }
    }
}
