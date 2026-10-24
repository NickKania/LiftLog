import Foundation
import XCTest
@testable import LiftLogCore

final class FoundationModelsRequestTests: XCTestCase {
    func testWorkoutSummarySelectsGuidedFieldsWhileChatKeepsCompletedAnswer() throws {
        let request = try FoundationModelsRequest(input: [["role": "user", "content": "Summarize.", "responseFormat": "workoutSummary"]],
            tools: [], instructions: "", contextTokens: 5_000)
        XCTAssertTrue(request.isWorkoutSummary)
        let schema = try XCTUnwrap(request.textStage.schema)
        XCTAssertEqual(schema.name, "WorkoutSummaryResponse")
        XCTAssertTrue(try schema.jsonString.contains("exerciseFindings"))
        XCTAssertTrue(try schema.jsonString.contains("nextSession"))
        XCTAssertLessThanOrEqual(request.textStage.estimatedTotalTokens, 5_000)
        guard case .object(let properties) = schema.kind else { return XCTFail("Expected summary object") }
        XCTAssertEqual(Set(properties.filter(\.isRequired).map(\.name)), ["headline", "exerciseFindings", "nextSession", "completion"])
        for name in ["healthNote", "limitations"] {
            let property = try XCTUnwrap(properties.first { $0.name == name })
            XCTAssertTrue(property.isOptional)
            XCTAssertTrue(property.schema.isNullable)
        }
        guard case .array(let finding, let minimum, let maximum) = properties.first(where: { $0.name == "exerciseFindings" })?.schema.kind,
              case .object(let findingFields) = finding.kind,
              case .string(let verdicts, _, _) = findingFields.first(where: { $0.name == "verdict" })?.schema.kind,
              case .array(_, let nextMinimum, let nextMaximum) = properties.first(where: { $0.name == "nextSession" })?.schema.kind else {
            return XCTFail("Expected bounded findings, verdicts and suggestions")
        }
        XCTAssertEqual(minimum, 1)
        XCTAssertEqual(maximum, 12)
        XCTAssertEqual(Set(findingFields.filter(\.isRequired).map(\.name)), ["exercise", "finding", "verdict"])
        XCTAssertEqual(verdicts, ["improved", "maintained", "regressed", "mixed", "insufficientData"])
        XCTAssertEqual(nextMinimum, 1)
        XCTAssertEqual(nextMaximum, 2)

        let chat = try FoundationModelsRequest(input: [["role": "user", "content": "Help me train."]], tools: [], instructions: "")
        XCTAssertFalse(chat.isWorkoutSummary)
        let expected = try FoundationModelsSchema(json: ["type": "object", "properties": [
            "answer": ["type": "string", "description": "The complete concise answer to the user."],
            "completion": ["type": "string", "enum": ["complete"], "description": "Emit only after the answer is finished."]
        ], "required": ["answer", "completion"]], name: "CompletedAnswer")
        XCTAssertEqual(chat.textStage.schema, expected)
        XCTAssertEqual(chat.textStage.maximumResponseTokens, 900)
    }

    func testWorkoutSummaryFlagRequiresExactStringOnAnyInputItem() throws {
        let flagged = try FoundationModelsRequest(input: [["role": "user", "responseFormat": "workoutSummary"],
            ["role": "assistant", "content": "Other input"]], tools: [], instructions: "")
        XCTAssertTrue(flagged.isWorkoutSummary)
        for format: Any in [true, ["workoutSummary"], "WorkoutSummary", "chat"] {
            let request = try FoundationModelsRequest(input: [["role": "user", "responseFormat": format]], tools: [], instructions: "")
            XCTAssertFalse(request.isWorkoutSummary)
        }
    }

    func testLargerInjectedContextAdmitsWholePayloadRejectedByDefault() throws {
        let content = String(repeating: "Recorded workout evidence. ", count: 400)
        let input: [[String: Any]] = [["role": "user", "content": content, "responseFormat": "workoutSummary"]]
        XCTAssertThrowsError(try FoundationModelsRequest(input: input, tools: [], instructions: "")) {
            XCTAssertEqual(($0 as? AppleFoundationModelsError)?.kind, .contextTooLarge)
        }
        let request = try FoundationModelsRequest(input: input, tools: [], instructions: "", contextTokens: 8_192)
        XCTAssertEqual(request.textStage.contextTokens, 8_192)
        XCTAssertGreaterThan(request.textStage.estimatedTotalTokens, FoundationModelsBudget.contextTokens)
        XCTAssertLessThanOrEqual(request.textStage.estimatedTotalTokens, 8_192)
        XCTAssertNoThrow(try request.textStage.validate())
        XCTAssertTrue(request.prompt.contains(content))
        XCTAssertFalse(request.omittedEarlierTurns)
    }

    @MainActor
    func testNarrowTemplateReadAndChartProposalRoundsFitWithoutSlicingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativePrompt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let tools = WorkoutAgentTools(store: store)
        let template = try XCTUnwrap(store.templates.first)
        let templates = try tools.execute(name: "get_templates", arguments: #"{"template_id":"\#(template.id.uuidString)","limit":1}"#)
        let input: [[String: Any]] = [
            ["role": "user", "content": "Plan the exact template returned by the current read."],
            ["type": "function_call", "call_id": "read", "name": "get_templates", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "read", "output": templates.outputJSONString]
        ]
        let request = try FoundationModelsRequest(input: input, tools: tools.definitions, instructions: WorkoutAssistant.instructions)
        XCTAssertEqual(request.tools.count, 11)
        XCTAssertFalse(request.omittedEarlierTurns)
        XCTAssertTrue(request.prompt.contains(template.name))
        XCTAssertTrue(request.prompt.contains("currentVersionID"))
        XCTAssertTrue(request.prompt.contains("targetReps"))
        XCTAssertNoThrow(try request.textStage.validate())
        XCTAssertNoThrow(try request.decisionStage?.validate())
        let proposal = try tools.execute(name: "propose_create_template", argumentsJSONString: String(decoding:
            JSONSerialization.data(withJSONObject: ["name": "Prompt test", "unit": "lb", "exercises": [
                ["exercise_id": template.exercises[0].exercise.id.uuidString, "sets": [["weight": 100, "reps": 8]]]]]), as: UTF8.self))
        let proposalInput = input + [["type": "function_call_output", "call_id": "proposal", "output": proposal.outputJSONString]]
        let proposalRequest = try FoundationModelsRequest(input: proposalInput, tools: tools.definitions, instructions: WorkoutAssistant.instructions)
        XCTAssertTrue(proposalRequest.prompt.contains("awaiting_user_review"))
        XCTAssertFalse(proposalRequest.omittedEarlierTurns)

        let chart = try tools.execute(name: "graph_workout_history", arguments: #"{"metric":"volume","unit":"lb"}"#)
        let chartRequest = try FoundationModelsRequest(input: input + [["type": "function_call_output", "call_id": "chart", "output": chart.outputJSONString]],
            tools: tools.definitions, instructions: WorkoutAssistant.instructions)
        XCTAssertTrue(chartRequest.prompt.contains("Completed volume"))
        XCTAssertFalse(chartRequest.omittedEarlierTurns)
    }

    func testAliasesRestoreOnlyIDFieldsPreserveNamesAndAvoidLiteralCollisions() throws {
        let id = UUID().uuidString
        let output = String(decoding: try JSONSerialization.data(withJSONObject: ["id": id, "name": "record_1"]), as: UTF8.self)
        let request = try FoundationModelsRequest(input: [["role": "user", "content": "Keep the routine name record_1. The exercise ID is \(id)."],
            ["type": "function_call_output", "call_id": "read", "output": output]],
            tools: [], instructions: "")
        XCTAssertTrue(request.prompt.contains("record_1"))
        XCTAssertTrue(request.prompt.contains("record_2"))
        let json = try request.argumentsJSON(restoringIdentifiersIn: ["name": "record_1", "notes": "record_2",
            "exercises": [["exercise_id": "record_2", "sets": [["weight": 100, "reps": 8]]]]])
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(arguments["name"] as? String, "record_1")
        XCTAssertEqual(arguments["notes"] as? String, "record_2")
        XCTAssertEqual((arguments["exercises"] as? [[String: Any]])?.first?["exercise_id"] as? String, id.lowercased())
        XCTAssertEqual(request.restoringIdentifiers(in: "ID record_2, routine record_1"), "ID \(id.lowercased()), routine record_1")
    }

    func testUUIDTemplateNameInUserProseAndSelectedReferenceRemainsVerbatim() throws {
        let name = "10B04ADD-982B-4A09-8D38-4A8735D26671"
        let question = "Create a template named \(name). Keep this name exactly."
        let selectedReference = #"{"name":"\#(name)","id":"AB866E2C-9D0B-47DB-B3B3-D2649A20F28B"}"#
        let content = question + "\nSelected references: " + selectedReference
        let request = try FoundationModelsRequest(input: [["role": "user", "content": content]], tools: [], instructions: "")
        let item = try XCTUnwrap(try renderedItems(in: request).first)
        XCTAssertEqual(item["content"] as? String, content)
        XCTAssertFalse(request.prompt.contains("record_"))
        let json = try request.argumentsJSON(restoringIdentifiersIn: ["name": name])
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(arguments["name"] as? String, name)
    }

    func testStructuredIDsAliasWithoutChangingUUIDNamesNotesOrDistinctRecordIdentity() throws {
        let first = "10B04ADD-982B-4A09-8D38-4A8735D26671"
        let second = "AB866E2C-9D0B-47DB-B3B3-D2649A20F28B"
        let note = "Literal record_1 and \(first) inside a note; leave both unchanged."
        let records: [[String: Any]] = [
            ["id": first, "name": first, "notes": note, "currentVersionID": second,
             "exerciseIDs": [first, second], "exercise_id": first],
            ["id": second, "name": "record_1", "notes": second]
        ]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self)
        let toolArguments = String(decoding: try JSONSerialization.data(withJSONObject: ["exercise_id": first, "name": first]), as: UTF8.self)
        let request = try FoundationModelsRequest(input: [
            ["role": "user", "content": "The literal name is record_1; also \(first)."],
            ["type": "function_call", "call_id": "read", "arguments": toolArguments],
            ["type": "function_call_output", "call_id": "read", "output": output]
        ], tools: [], instructions: "")
        let items = try renderedItems(in: request)
        let projected = try XCTUnwrap(items.last?["output"] as? [[String: Any]])
        let firstAlias = try XCTUnwrap(projected[0]["id"] as? String)
        let secondAlias = try XCTUnwrap(projected[1]["id"] as? String)
        XCTAssertNotEqual(firstAlias, first)
        XCTAssertNotEqual(secondAlias, second)
        XCTAssertNotEqual(firstAlias, secondAlias)
        XCTAssertNotEqual(firstAlias, "record_1")
        XCTAssertNotEqual(secondAlias, "record_1")
        XCTAssertEqual(projected[0]["currentVersionID"] as? String, secondAlias)
        XCTAssertEqual(projected[0]["exerciseIDs"] as? [String], [firstAlias, secondAlias])
        XCTAssertEqual(projected[0]["exercise_id"] as? String, firstAlias)
        XCTAssertEqual(projected[0]["name"] as? String, first)
        XCTAssertEqual(projected[0]["notes"] as? String, note)
        XCTAssertEqual(projected[1]["name"] as? String, "record_1")
        XCTAssertEqual(projected[1]["notes"] as? String, second)
        let projectedArguments = try XCTUnwrap(items[1]["arguments"] as? [String: Any])
        XCTAssertEqual(projectedArguments["exercise_id"] as? String, firstAlias)
        XCTAssertEqual(projectedArguments["name"] as? String, first)
        let restored = try request.argumentsJSON(restoringIdentifiersIn: ["exercise_id": firstAlias, "currentVersionID": secondAlias,
            "exerciseIDs": [firstAlias, secondAlias], "name": first, "notes": note])
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(restored.utf8)) as? [String: Any])
        XCTAssertEqual(arguments["exercise_id"] as? String, first.lowercased())
        XCTAssertEqual(arguments["currentVersionID"] as? String, second.lowercased())
        XCTAssertEqual(arguments["exerciseIDs"] as? [String], [first.lowercased(), second.lowercased()])
        XCTAssertEqual(arguments["name"] as? String, first)
        XCTAssertEqual(arguments["notes"] as? String, note)
        XCTAssertEqual(request.restoringIdentifiers(in: "record_1 \(firstAlias) \(secondAlias)"), "record_1 \(first.lowercased()) \(second.lowercased())")
    }

    private func renderedItems(in request: FoundationModelsRequest) throws -> [[String: Any]] {
        try request.prompt.split(separator: "\n").dropFirst().map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    func testOversizedCurrentRecordsFailIntactAndOnlyWholePriorTurnsAreOmitted() throws {
        let large = String(repeating: "A", count: FoundationModelsBudget.contextTokens * 6)
        XCTAssertThrowsError(try FoundationModelsRequest(input: [["role": "user", "content": large]], tools: [], instructions: ""))
        let current = "Current question with complete selected record tail"
        let request = try FoundationModelsRequest(input: [["role": "user", "content": large], ["role": "assistant", "content": "Old answer"],
            ["role": "user", "content": current], ["type": "function_call_output", "call_id": "current-call", "output": #"{"id":"complete","targetReps":8}"#]],
            tools: [], instructions: "")
        XCTAssertTrue(request.omittedEarlierTurns)
        XCTAssertTrue(request.prompt.contains(current))
        XCTAssertTrue(request.prompt.contains("current-call"))
        XCTAssertTrue(request.prompt.contains("targetReps"))
        XCTAssertFalse(request.prompt.contains("Old answer"))
    }
}
