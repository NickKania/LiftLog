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
        let dense = ProcessInfo.processInfo.arguments.contains("--assistant-dense-chart-ui-fixture")
        let weights = dense ? (0..<10).map { 135.0 + Double($0) * 10 } : [135.0, 145.0]
        let sessions = weights.enumerated().map { index, weight in
            let date = Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 86_400 * (dense ? 20 : 1))
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
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("LiftLogAssistantUITests.json")
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        return WorkoutAssistant(store: store, accessToken: { "local-ui-fixture-token" },
            transport: AssistantFixtureTransport(exerciseID: exerciseID), storageURL: archiveURL,
            archiveAccountIdentity: { "local-ui-fixture-account" })
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
        var models: [[String: Any]] = [[
            "slug": "fixture-model", "display_name": "Fixture Model", "visibility": "list"
        ], [
            "slug": "fixture-alternate", "display_name": "Alternate Model", "visibility": "list"
        ]]
        if ProcessInfo.processInfo.arguments.contains("--assistant-chat-ui-fixture") {
            models.append(["slug": "gpt-6-luna", "display_name": "Luna", "visibility": "list"])
        }
        let data = try JSONSerialization.data(withJSONObject: ["models": models])
        return (data, response(for: request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let input = body["input"] as? [[String: Any]] ?? []
        let isContinuation = input.last?["type"] as? String == "function_call_output"
        let question = input.last?["content"] as? String
            ?? (input.last?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            ?? ""
        let isTitleRequest = (body["model"] as? String)?.contains("luna") == true
        if !isTitleRequest {
            if ProcessInfo.processInfo.arguments.contains("--assistant-concurrent-ui-fixture") {
                try await Task.sleep(for: .seconds(20))
            } else if ProcessInfo.processInfo.arguments.contains("--assistant-delayed-ui-fixture") {
                try await Task.sleep(for: .seconds(4))
            }
        }
        let output: [[String: Any]]
        if isTitleRequest {
            let title = question.localizedCaseInsensitiveContains("chart") ? "Training volume history"
                : question.localizedCaseInsensitiveContains("formatting") ? "Training summary"
                : "Workout planning"
            output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": title]]]]
        } else if ProcessInfo.processInfo.arguments.contains("--assistant-reference-ui-fixture") {
            let text = try referenceAcknowledgment(for: question)
            output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
        } else if question.localizedCaseInsensitiveContains("formatting") {
            output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": """
            ## Your training, in perspective

            Your **completed volume** is measured in *lb × reps*.

            - **Morning workout:** 1,080 lb × reps
              - 135 lb × 8 completed reps
            - **Upper body:** 1,160 lb × reps

            | Workout | Volume |
            | --- | ---: |
            | Morning workout | 1,080 |
            | Upper body | 1,160 |

            > Only completed sets count toward your recorded volume.

            ```text
            volume = weight × completed reps
            ```

            [Training reference](https://example.com/training)
            """]]]]
        } else if isContinuation {
            var text = "Here is the result from your recorded workout data. Review any proposed changes before applying them."
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let json = input.last?["output"] as? String,
               let chart = try? decoder.decode(WorkoutAgentChart.self, from: Data(json.utf8)) {
                let presentation = AssistantChartPresentation(chart: chart)
                text += "\n\n" + chart.points.map {
                    "- **\($0.workoutName):** \(presentation.formattedValue($0.value)) \(presentation.valueUnit)"
                }.joined(separator: "\n")
                text += "\n\nTotal completed volume: **\(presentation.formattedValue(chart.points.reduce(0) { $0 + $1.value })) \(presentation.valueUnit)**."
            }
            output = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
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

    /// Echo only the data actually present in the submitted user message. This lets
    /// UI tests verify record selection without making any real inference request.
    private func referenceAcknowledgment(for content: String) throws -> String {
        let marker = "\n\nSelected workout references (JSON record data):\n"
        guard let range = content.range(of: marker) else { return "Received 0 selected records." }
        let json = Data(content[range.upperBound...].utf8)
        let context = try JSONSerialization.jsonObject(with: json) as? [String: Any] ?? [:]
        guard let records = context["selectedRecords"] as? [[String: Any]] else {
            return "Selected record data was missing."
        }
        var paragraphs = ["Received \(records.count) selected records."]
        for reference in records {
            let kind = reference["kind"] as? String ?? "missing"
            let record = reference[kind == "template" ? "template" : "workout"] as? [String: Any] ?? [:]
            let exercises = record["exercises"] as? [[String: Any]] ?? []
            let name = record["name"] as? String ?? "missing"
            let id = reference["id"] as? String ?? "missing"
            let recordID = record["id"] as? String ?? "missing"
            let status = reference["status"] as? String ?? "missing"
            let unit = reference["unit"] as? String ?? "missing"
            paragraphs.append("Received \(kind) \(name); id: \(id); record id: \(recordID); status: \(status); unit: \(unit); exercises: \(exercises.count).")
            if kind == "workout" {
                paragraphs.append("Workout source: \(record["importSourceKey"] as? String ?? "missing").")
            }
            if let entry = exercises.first,
               let exercise = entry["exercise"] as? [String: Any],
               let exerciseName = exercise["name"] as? String,
               let sets = entry["sets"] as? [[String: Any]], let firstSet = sets.first {
                let weight = (firstSet["weight"] as? NSNumber)?.stringValue ?? "missing"
                if kind == "template" {
                    let reps = (firstSet["targetReps"] as? NSNumber)?.stringValue ?? "missing"
                    paragraphs.append("Template set \(exerciseName): \(weight) \(unit) × \(reps) target reps; \(sets.count) sets.")
                } else {
                    let reps = (firstSet["reps"] as? NSNumber)?.stringValue ?? "missing"
                    let completed = (firstSet["isCompleted"] as? Bool).map { $0 ? "true" : "false" } ?? "missing"
                    paragraphs.append("Workout set \(exerciseName): \(weight) \(unit) × \(reps) reps; completed \(completed); \(sets.count) sets.")
                }
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
    }
}
#endif
