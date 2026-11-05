#if DEBUG
import Foundation

/// Fully local workout-summary data. Every entry point requires all three launch
/// flags so a normal UI test or app launch cannot seed synthetic records.
@MainActor
enum WorkoutSummaryUITestFixture {
    static var isEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing")
            && arguments.contains("--workout-summary-ui-fixture")
            && arguments.contains("--assistant-ui-fixture")
    }

    static func makeStore(store: WorkoutStore, accounts: ChatGPTAccountStore,
                          assistant: WorkoutAssistant? = nil) -> WorkoutSummaryStore {
        precondition(isEnabled, "Workout summary fixtures require an explicit UI test launch.")
        seedWorkouts(in: store)
        return WorkoutSummaryStore(
            store: store,
            accessToken: { try await accounts.accessToken() },
            transport: WorkoutSummaryFixtureTransport(),
            accountIdentity: { "\(accounts.currentAccount?.id ?? "none"):summary:\(accounts.revision):\(accounts.canUsePlan)" },
            healthDataProvider: WorkoutSummaryFixtureHealthProvider.shared,
            selectedProvider: { assistant?.selectedProvider ?? .chatGPT },
            localInferenceClient: WorkoutSummaryFixtureLocalInferenceClient(availability: {
                assistant?.appleFoundationModelsAvailability ?? .available
            })
        )
    }

    /// Adds two earlier comparable sessions and leaves one active session with a
    /// completed set so the finish flow can be exercised without entering data.
    static func seedWorkouts(in store: WorkoutStore, now: Date = Date()) {
        precondition(isEnabled, "Workout summary fixtures require an explicit UI test launch.")
        guard let exercise = store.exercises.first(where: { $0.name == "Bench Press" }) else {
            preconditionFailure("The workout summary fixture requires Bench Press in the catalog.")
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -14, to: now) ?? now.addingTimeInterval(-14 * 86_400)
        let earlier = (0..<2).map { index in
            let date = start.addingTimeInterval(Double(index) * 6 * 86_400)
            return WorkoutSession(
                id: identifier(10 + index), name: "Summary Fixture Workout \(index + 1)",
                startedAt: date, finishedAt: date.addingTimeInterval(1_800), unit: .lb,
                importSourceKey: "workout-summary-ui-fixture-history-\(index)",
                exercises: [WorkoutExercise(exercise: exercise, sets: [
                    WorkoutSet(weight: Double(125 + index * 5), reps: 8, isCompleted: true),
                    WorkoutSet(weight: Double(125 + index * 5), reps: 7, isCompleted: true)
                ])]
            )
        }
        let existingKeys = Set(store.history.compactMap(\.importSourceKey))
        let missing = earlier.filter { !existingKeys.contains($0.importSourceKey ?? "") }
        if !missing.isEmpty { _ = store.importWorkouts(missing) }

        guard store.activeWorkout == nil else { return }
        let template = WorkoutTemplate(id: identifier(50), name: "Summary Fixture Workout", exercises: [
            TemplateExercise(id: identifier(51), exercise: exercise, sets: [
                TemplateSet(id: identifier(52), weight: 135, targetReps: 8),
                TemplateSet(id: identifier(53), weight: 135, targetReps: 8)
            ])
        ])
        if !store.templates.contains(where: { $0.id == template.id }) {
            precondition(store.saveTemplate(template), "Could not save the workout summary fixture template.")
        }
        guard let saved = store.templates.first(where: { $0.id == template.id }) else { return }
        guard store.startWorkout(template: saved), var active = store.activeWorkout else { return }
        for exerciseIndex in active.exercises.indices {
            for setIndex in active.exercises[exerciseIndex].sets.indices {
                active.exercises[exerciseIndex].sets[setIndex].weight = 135
                active.exercises[exerciseIndex].sets[setIndex].reps = 8
                active.exercises[exerciseIndex].sets[setIndex].isCompleted = true
            }
        }
        _ = store.updateActiveWorkout(active)
    }

    private static func identifier(_ suffix: Int) -> UUID {
        UUID(uuidString: "53554D4D-4152-4000-8000-" + String(format: "%012d", suffix)) ?? UUID()
    }
}

@MainActor
private final class WorkoutSummaryFixtureHealthProvider: WorkoutHealthDataProviding {
    static let shared = WorkoutSummaryFixtureHealthProvider()
    private(set) var readCount = 0

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        readCount += 1
        let end = min(workout.finishedAt ?? through, through)
        let firstSampleDate = workout.startedAt
        let secondSampleDate = min(workout.startedAt.addingTimeInterval(1), end)
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name,
            startedAt: workout.startedAt, endedAt: end, fetchedAt: through, metrics: [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: [
                    WorkoutHealthSample(date: firstSampleDate, value: 118),
                    WorkoutHealthSample(date: secondSampleDate, value: 136)
                ]),
                WorkoutHealthMetricSeries(metric: .activeEnergy, samples: [
                    WorkoutHealthSample(date: firstSampleDate, value: 112)
                ])
            ])
    }
}

private struct WorkoutSummaryFixtureTransport: ChatGPTInferenceTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: ["models": [[
            "slug": "fixture-summary-model", "display_name": "Fixture Summary Model", "visibility": "list"
        ]]])
        return (data, response(for: request, contentType: "application/json"))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        if ProcessInfo.processInfo.arguments.contains("--workout-summary-error-ui-fixture") {
            let event = try JSONSerialization.data(withJSONObject: [
                "type": "error", "error": ["message": "Fixture summary request failed", "code": "fixture_error"]
            ])
            let lines = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield("data: " + String(decoding: event, as: UTF8.self))
                continuation.yield("")
                continuation.finish()
            }
            return ChatGPTHTTPStream(response: response(for: request), lines: lines)
        }
        if ProcessInfo.processInfo.arguments.contains("--workout-summary-delayed-ui-fixture") {
            try await Task.sleep(for: .seconds(8))
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let text = WorkoutSummaryFixtureResponse.text(input: body["input"] as? [[String: Any]] ?? [])
        let output: [[String: Any]] = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
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

    private func response(for request: URLRequest, contentType: String = "text/event-stream") -> HTTPURLResponse {
        HTTPURLResponse(url: request.url ?? URL(string: "https://api.openai.com")!, statusCode: 200,
                        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
    }
}

/// Exercises the same summary/privacy path without invoking Foundation Models,
/// credentials, networking, or real HealthKit on a simulator.
@MainActor
private final class WorkoutSummaryFixtureLocalInferenceClient: AppleFoundationModelsProviding {
    private let currentAvailability: () -> AppleFoundationModelsAvailability
    var availability: AppleFoundationModelsAvailability { currentAvailability() }

    init(availability: @escaping () -> AppleFoundationModelsAvailability) {
        currentAvailability = availability
    }

    func models() async throws -> [ChatGPTModel] { AppleFoundationModelsModel.catalog }

    func respond(model: String, input: [[String: Any]], tools: [[String: Any]],
                 instructions: String, onText: (String) -> Void) async throws -> ChatGPTInferenceResponse {
        if ProcessInfo.processInfo.arguments.contains("--workout-summary-error-ui-fixture") {
            throw FixtureError.requestFailed
        }
        if ProcessInfo.processInfo.arguments.contains("--workout-summary-delayed-ui-fixture") {
            try await Task.sleep(for: .seconds(8))
        }
        try Task.checkCancellation()
        let text = WorkoutSummaryFixtureResponse.text(input: input)
        return ChatGPTInferenceResponse(text: text, output: [], calls: [])
    }

    private enum FixtureError: LocalizedError {
        case requestFailed

        var errorDescription: String? { "Fixture summary request failed" }
    }
}

private enum WorkoutSummaryFixtureResponse {
    static func text(input: [[String: Any]]) -> String {
        let content = input.last?["content"] as? String ?? ""
        let hasHealth: Bool = {
            let payload: [String: Any]?
            if let structured = input.last?["evidence"] as? [String: Any] {
                payload = structured
            } else {
                let evidence = content.components(separatedBy: "Evidence JSON:\n").last ?? content
                payload = try? JSONSerialization.jsonObject(with: Data(evidence.utf8)) as? [String: Any]
            }
            guard let health = payload?["health"] as? [String: Any],
                  let metrics = health["metrics"] as? [[String: Any]] else { return false }
            return !metrics.isEmpty
        }()
        return hasHealth
            ? "## Workout insights\n\nYour workout is recorded locally. **Heart rate and active energy were included for this request only.**\n\nKeep the load steady and aim for one more clean rep next time if your form remains strong."
            : """
            ## Workout insights

            Your workout is recorded locally with **2 completed sets**. Compared with your earlier sessions, the load is trending up.

            | Exercise | Actual performance | Earlier-session comparison |
            | --- | --- | --- |
            | Bench press | 135 lb: **8/8** | **+5 lb** versus your previous session, with the same completed reps. |
            | Earlier bench press | 130 lb: **8/7** | A synthetic earlier session for comparison. |

            ### Next session

            1. **Keep the load steady.** Try adding one rep next session before increasing weight.
            2. Keep your technique controlled and record any changes in effort.
            """
    }
}
#endif
