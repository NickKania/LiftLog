import Foundation
import XCTest
@testable import LiftLogCore

final class SetHeartRateAssistantTests: XCTestCase {
    private func workout(name: String = "Timed workout", timed: Bool = true) -> WorkoutSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return WorkoutSession(name: name, startedAt: start, finishedAt: start.addingTimeInterval(300), exercises: [
            WorkoutExercise(exercise: ExerciseCatalog.all[0], sets: [
                WorkoutSet(weight: 100, reps: 5, isCompleted: true,
                           startedAt: timed ? start.addingTimeInterval(20) : nil,
                           completedAt: timed ? start.addingTimeInterval(40) : nil,
                           isMarkedForHeartRate: timed),
                WorkoutSet(weight: 100, reps: 5, isCompleted: true,
                           completedAt: timed ? start.addingTimeInterval(190) : nil)
            ])
        ])
    }

    fileprivate static func health(for workout: WorkoutSession) -> WorkoutHealthSnapshot {
        let start = workout.startedAt
        let finish = start.addingTimeInterval(300)
        let heartRate = [(25.0, 120.0), (35, 160), (100, 130), (175, 140)].map { offset, bpm in
            WorkoutHealthSample(date: start.addingTimeInterval(offset), value: bpm)
        }
        return WorkoutHealthSnapshot(workoutID: workout.id, workoutName: workout.name, startedAt: start,
            endedAt: finish, fetchedAt: finish, metrics: [
                WorkoutHealthMetricSeries(metric: .heartRate, samples: heartRate),
                WorkoutHealthMetricSeries(metric: .steps, samples: [.init(date: finish, value: 50)])
            ])
    }

    func testCloudSummarySeparatesWorkoutTimingFromHealthCorrelations() throws {
        let timed = workout()
        let ordinary = try WorkoutSummaryContext.input(workout: timed, history: [])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ordinary.utf8)) as? [String: Any])
        let target = try XCTUnwrap(payload["targetWorkout"] as? [String: Any])
        let exercises = try XCTUnwrap(target["exercises"] as? [[String: Any]])
        let sets = try XCTUnwrap(exercises.first?["sets"] as? [[String: Any]])
        XCTAssertEqual(sets[0]["markedForHeartRate"] as? Bool, true)
        XCTAssertNotNil(sets[0]["startedAt"])
        XCTAssertNotNil(sets[0]["completedAt"])
        XCTAssertNil(sets[1]["markedForHeartRate"])
        XCTAssertNil(payload["health"])
        XCTAssertFalse(ordinary.contains("setHeartRateCorrelations"))

        let shared = try WorkoutSummaryContext.input(workout: timed, history: [], health: Self.health(for: timed))
        let sharedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        let health = try XCTUnwrap(sharedPayload["health"] as? [String: Any])
        let correlations = try XCTUnwrap(health["setHeartRateCorrelations"] as? [[String: Any]])
        XCTAssertEqual(correlations.map { $0["windowKind"] as? String }, ["timed", "estimated"])
        XCTAssertEqual(correlations[0]["sampleCount"] as? Int, 2)
        XCTAssertEqual(correlations[0]["averageHeartRate"] as? Double, 140)
        XCTAssertEqual(correlations[0]["peakHeartRate"] as? Double, 160)
        XCTAssertEqual(correlations[0]["recoveryDrop60s"] as? Double, 30)
        XCTAssertTrue(correlations[1]["recoveryDrop60s"] is NSNull)
    }

    func testCloudSummaryCapsCorrelationsToTwelvePrioritizingMarkedSets() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sets = (0..<16).map { index in
            WorkoutSet(weight: 100, reps: 5, isCompleted: true,
                       startedAt: start.addingTimeInterval(Double(index) * 120 + 10),
                       completedAt: start.addingTimeInterval(Double(index) * 120 + 40),
                       isMarkedForHeartRate: index >= 12)
        }
        let session = WorkoutSession(name: "High Volume", startedAt: start, finishedAt: start.addingTimeInterval(2_200),
                                     exercises: [WorkoutExercise(exercise: ExerciseCatalog.all[0], sets: sets)])
        let hrSamples = (0..<16).map { index in
            WorkoutHealthSample(date: start.addingTimeInterval(Double(index) * 120 + 25), value: Double(130 + index))
        }
        let health = WorkoutHealthSnapshot(workoutID: session.id, workoutName: session.name, startedAt: start,
                                           endedAt: start.addingTimeInterval(2_200), fetchedAt: start.addingTimeInterval(2_200),
                                           metrics: [WorkoutHealthMetricSeries(metric: .heartRate, samples: hrSamples)])
        let shared = try WorkoutSummaryContext.input(workout: session, history: [], health: health)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        let healthJSON = try XCTUnwrap(payload["health"] as? [String: Any])
        let correlations = try XCTUnwrap(healthJSON["setHeartRateCorrelations"] as? [[String: Any]])
        XCTAssertEqual(correlations.count, 12)
        XCTAssertEqual(correlations.prefix(4).compactMap { $0["markedForHeartRate"] as? Bool }, [true, true, true, true])
    }

    func testLocalSummaryIncludesCompactMarkedFactsAndFitsBudget() throws {
        let timed = workout()
        func request(health: WorkoutHealthSnapshot?) throws -> WorkoutSummaryRequest {
            try WorkoutSummaryRequest(workout: timed, history: [], health: health,
                prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels)
        }
        let ordinary = try request(health: nil)
        let ordinaryEvidence = try XCTUnwrap(ordinary.input.first?["evidence"] as? [String: Any])
        XCTAssertNil(ordinaryEvidence["health"])
        let completed = try XCTUnwrap(ordinaryEvidence["completedWorkout"] as? [String: Any])
        let exercises = try XCTUnwrap(completed["exercises"] as? [[String: Any]])
        XCTAssertEqual(exercises.first?["markedSetNumbers"] as? [Int], [1])

        let shared = try request(health: Self.health(for: timed))
        let evidence = try XCTUnwrap(shared.input.first?["evidence"] as? [String: Any])
        let health = try XCTUnwrap(evidence["health"] as? [String: Any])
        let facts = try XCTUnwrap(health["setCorrelations"] as? [String])
        XCTAssertEqual(facts.count, 2)
        XCTAssertTrue(facts[0].contains("marked, timed 20s"))
        XCTAssertTrue(facts[0].contains("avg 140 bpm, peak 160 bpm, 60s recovery drop 30 bpm"))
        XCTAssertTrue(facts[1].contains("recovery unavailable"))
        let projected = try FoundationModelsRequest(input: shared.input, tools: [], instructions: shared.instructions)
        XCTAssertLessThanOrEqual(projected.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
    }

    func testLocalSummaryDropsUnmarkedCorrelationsBeforeComparableHistory() throws {
        let timed = workout()
        let earlier = WorkoutSession(name: timed.name, startedAt: timed.startedAt.addingTimeInterval(-900),
            finishedAt: timed.startedAt.addingTimeInterval(-600), exercises: [
                WorkoutExercise(exercise: timed.exercises[0].exercise, sets: [
                    WorkoutSet(weight: 95, reps: 5, isCompleted: true)
                ])
            ])
        func request(contextTokens: Int) throws -> WorkoutSummaryRequest {
            try WorkoutSummaryRequest(workout: timed, history: [earlier], health: Self.health(for: timed),
                prompt: WorkoutSummaryPrompt.defaultPrompt, provider: .appleFoundationModels, contextTokens: contextTokens)
        }
        let full = try request(contextTokens: FoundationModelsBudget.contextTokens)
        let projected = try FoundationModelsRequest(input: full.input, tools: [], instructions: full.instructions)
        let compact = try request(contextTokens: projected.textStage.estimatedTotalTokens - 1)
        let evidence = try XCTUnwrap(compact.input.first?["evidence"] as? [String: Any])
        XCTAssertEqual((evidence["earlierCompletedWorkouts"] as? [[String: Any]])?.count, 1)
        let health = try XCTUnwrap(evidence["health"] as? [String: Any])
        let facts = try XCTUnwrap(health["setCorrelations"] as? [String])
        XCTAssertEqual(facts.count, 1)
        XCTAssertTrue(facts[0].contains("marked, timed"))
    }

    @MainActor
    private func store(at directory: URL) throws -> (WorkoutStore, WorkoutSession, WorkoutSession) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workouts.sqlite")
        let timed = workout()
        let legacy = workout(name: "Legacy workout", timed: false)
        try WorkoutDatabase(url: file).save(WorkoutSnapshot(templates: [], history: [timed, legacy], activeWorkout: nil, unit: .lb))
        let store = WorkoutStore(fileURL: file)
        XCTAssertNil(store.errorMessage)
        return (store, timed, legacy)
    }

    @MainActor
    func testHealthChartOverlaysOnlyMarkedSetsWhenAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, timed, legacy) = try store(at: directory)
        let tools = WorkoutAgentTools(store: store)
        func chart(for workout: WorkoutSession, metric: String) throws -> WorkoutAgentChart {
            let result = try tools.execute(name: "graph_workout_health",
                argumentsJSONString: "{\"workout_id\":\"\(workout.id)\",\"metric\":\"\(metric)\"}",
                healthSnapshots: [Self.health(for: workout)])
            return try XCTUnwrap(result.chart)
        }
        let samples = try chart(for: timed, metric: "heartRate")
        let marker = try XCTUnwrap(samples.markers?.first)
        XCTAssertEqual(samples.markers?.count, 1)
        XCTAssertEqual(marker.id, timed.exercises[0].sets[0].id)
        XCTAssertEqual(marker.startDate, timed.exercises[0].sets[0].startedAt)
        XCTAssertEqual(marker.endDate, timed.exercises[0].sets[0].completedAt)
        XCTAssertTrue(marker.isMarked)
        XCTAssertNil(try chart(for: timed, metric: "steps").markers)
        XCTAssertNil(try chart(for: legacy, metric: "heartRate").markers)
    }

    func testLegacyChartDecodesWithoutMarkers() throws {
        let json = """
        {"id":"CF1D226E-0724-4E9B-AF3F-32CB9A8D769D","title":"Set history","metric":"completed_sets","points":[]}
        """
        let chart = try JSONDecoder().decode(WorkoutAgentChart.self, from: Data(json.utf8))
        XCTAssertEqual(chart.title, "Set history")
        XCTAssertNil(chart.markers)
    }

    @MainActor
    func testAssistantUsesCorrelationsOnlyForExplicitHealthTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (store, timed, _) = try store(at: directory)
        let archiveURL = directory.appendingPathComponent("chats.json")
        let provider = SetCorrelationHealthProvider()
        let transport = SetCorrelationTransport()
        let assistant = WorkoutAssistant(store: store, accessToken: { "synthetic" }, transport: transport,
                                         storageURL: archiveURL, healthDataProvider: provider)
        await assistant.refreshModels()

        XCTAssertTrue(assistant.send("Workout only", references: [.init(workout: timed)]))
        await finish(assistant)
        let ordinary = try XCTUnwrap(transport.inputs.last)
        XCTAssertTrue(ordinary.contains("isMarkedForHeartRate"))
        XCTAssertTrue(ordinary.contains("completedAt"))
        XCTAssertFalse(ordinary.contains("setHeartRateCorrelations"))
        XCTAssertEqual(provider.reads, 0)

        XCTAssertTrue(assistant.send("Health question", references: [.init(healthWorkout: timed)]))
        await finish(assistant)
        let shared = try XCTUnwrap(transport.inputs.last)
        XCTAssertTrue(shared.contains("setHeartRateCorrelations"))
        XCTAssertTrue(shared.contains("recoveryDrop60s"))
        XCTAssertEqual(provider.reads, 1)
        XCTAssertTrue(assistant.messages.last?.containsEphemeralHealthData == true)

        XCTAssertTrue(assistant.send("Follow up"))
        await finish(assistant)
        let followUp = try XCTUnwrap(transport.inputs.last)
        XCTAssertFalse(followUp.contains("setHeartRateCorrelations"))
        XCTAssertFalse(followUp.contains("Health question"))
        XCTAssertEqual(provider.reads, 1)

        assistant.saveChats()
        let saved = try AssistantChatArchive.load(from: archiveURL)
        let chat = try XCTUnwrap(saved.accounts["__local__"]?.chats.first)
        XCTAssertFalse(String(decoding: chat.history, as: UTF8.self).contains("setHeartRateCorrelations"))
        XCTAssertFalse(chat.messages.contains { $0.text.contains("Health question") })
    }

    @MainActor
    private func finish(_ assistant: WorkoutAssistant) async {
        for _ in 0..<10_000 {
            if !assistant.isWorking { return }
            await Task.yield()
        }
        XCTFail("Assistant did not finish")
    }
}

@MainActor
private final class SetCorrelationHealthProvider: WorkoutHealthDataProviding {
    private(set) var reads = 0

    func fetchHealthData(for workout: WorkoutSession, through: Date) async throws -> WorkoutHealthSnapshot {
        reads += 1
        return SetHeartRateAssistantTests.health(for: workout)
    }
}

private final class SetCorrelationTransport: ChatGPTInferenceTransport {
    private(set) var inputs: [String] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = Data(#"{"models":[{"slug":"set-hr-test","display_name":"Set HR test","visibility":"list"}]}"#.utf8)
        return (data, try response(request))
    }

    func stream(for request: URLRequest) async throws -> ChatGPTHTTPStream {
        inputs.append(String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self))
        return ChatGPTHTTPStream(response: try response(request), lines: AsyncThrowingStream { continuation in
            continuation.yield(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Synthetic response"}]}]}}"#)
            continuation.yield("")
            continuation.finish()
        })
    }

    private func response(_ request: URLRequest) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
    }
}
