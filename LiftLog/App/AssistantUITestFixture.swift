#if DEBUG
import Foundation

/// A fully local fixture. Never created outside an explicitly opted-in UI test run.
@MainActor
enum AssistantUITestFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--assistant-ui-fixture")
    }

    static func makeAccounts() -> ChatGPTAccountStore {
        precondition(isEnabled, "Assistant fixtures require an explicit UI test launch.")
        let tokenJSON = """
        {"id_token":"fixture-identity","access_token":"fixture-access","token_type":"Bearer","expires_in":3600,"scope":"resource.invoke chatgpt.tokens.use.direct"}
        """
        let response = try! JSONDecoder().decode(ChatGPTTokenResponse.self, from: Data(tokenJSON.utf8))
        let credentials = try! ChatGPTCredentials(response: response)
        let account = ChatGPTAccount(clientID: "fixture-client", issuer: "https://auth.openai.com",
            subject: "fixture-subject", email: "fixture@example.invalid", label: "Fixture account", credentials: credentials)
        return ChatGPTAccountStore(storage: AssistantFixtureCredentialStorage(
            snapshot: ChatGPTAuthSnapshot(accounts: [account], activeAccountID: account.id)))
    }

    static func seedWorkouts(in store: WorkoutStore) {
        guard let bench = store.exercises.first(where: { $0.name == "Bench Press" }) else { return }
        let sessions = [135.0, 145.0].enumerated().map { index, weight in
            let date = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86_400)
            return WorkoutSession(name: "Recorded Fixture Workout \(index + 1)", startedAt: date,
                finishedAt: date.addingTimeInterval(1800), unit: .lb,
                importSourceKey: "assistant-ui-fixture-\(index)",
                exercises: [WorkoutExercise(exercise: bench, sets: [WorkoutSet(weight: weight, reps: 8, isCompleted: true)])])
        }
        _ = store.importWorkouts(sessions)
    }

    static func makeAssistant(store: WorkoutStore) -> WorkoutAssistant {
        precondition(isEnabled, "Assistant fixtures require an explicit UI test launch.")
        seedWorkouts(in: store)
        let exerciseID = store.exercises.first(where: { $0.name == "Bench Press" })!.id
        return WorkoutAssistant(store: store, accessToken: { "local-ui-fixture-token" },
            transport: AssistantFixtureTransport(exerciseID: exerciseID))
    }
}

private final class AssistantFixtureCredentialStorage: ChatGPTCredentialStorage {
    private var snapshot: ChatGPTAuthSnapshot
    init(snapshot: ChatGPTAuthSnapshot) { self.snapshot = snapshot }
    func load() throws -> ChatGPTAuthSnapshot? { snapshot }
    func save(_ snapshot: ChatGPTAuthSnapshot) throws { self.snapshot = snapshot }
}

private struct AssistantFixtureTransport: ChatGPTInferenceTransport {
    let exerciseID: UUID

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: ["models": [[
            "slug": "fixture-model", "display_name": "Fixture Model", "visibility": "list"
        ]]])
        return (data, response(for: request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        if ProcessInfo.processInfo.arguments.contains("--assistant-delayed-ui-fixture") {
            try await Task.sleep(for: .seconds(4))
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let input = body["input"] as? [[String: Any]] ?? []
        let isContinuation = input.last?["type"] as? String == "function_call_output"
        let question = input.last?["content"] as? String ?? ""
        let output: [[String: Any]]
        if isContinuation {
            output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Here is the result from your recorded workout data. Review any proposed changes before applying them."]]]]
        } else {
            let chartRequest = question.localizedCaseInsensitiveContains("chart")
            let arguments: [String: Any] = chartRequest ? [
                "metric": "volume", "exercise_id": NSNull(), "unit": "lb",
                "start_date": NSNull(), "end_date": NSNull()
            ] : [
                "name": "Assistant Fixture Routine", "unit": "lb",
                "exercises": [["exercise_id": exerciseID.uuidString, "sets": [["weight": 95, "reps": 8]]]]
            ]
            let argumentData = try JSONSerialization.data(withJSONObject: arguments)
            output = [["type": "function_call", "namespace": "liftlog",
                "name": chartRequest ? "graph_workout_history" : "propose_create_template",
                "call_id": UUID().uuidString, "arguments": String(decoding: argumentData, as: UTF8.self)]]
        }
        let event = try JSONSerialization.data(withJSONObject: [
            "type": "response.completed", "response": ["status": "completed", "output": output]
        ])
        let lines = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("data: " + String(decoding: event, as: UTF8.self))
            continuation.yield("")
            continuation.finish()
        }
        return ChatGPTHTTPStream(response: response(for: request), lines: lines)
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
    }
}
#endif
