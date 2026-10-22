import Foundation
import XCTest
@testable import LiftLogCore

final class FoundationModelsBudgetTests: XCTestCase {
    func testOutputAndFramingReserveAreIncludedAtExactBoundary() throws {
        let available = FoundationModelsBudget.contextTokens - FoundationModelsBudget.framingReserveTokens
        for output in [FoundationModelsBudget.textResponseTokens, FoundationModelsBudget.argumentResponseTokens, FoundationModelsBudget.decisionResponseTokens] {
            XCTAssertNoThrow(try FoundationModelsBudget.validate(inputTokens: available - output, outputTokens: output))
            XCTAssertThrowsError(try FoundationModelsBudget.validate(inputTokens: available - output + 1, outputTokens: output)) {
                XCTAssertEqual(($0 as? AppleFoundationModelsError)?.kind, .contextTooLarge)
            }
        }
    }

    func testFallbackAccountsForPunctuationUnicodeAndLongIdentifiers() {
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "abcdef"), 3)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "1234567890"), 5)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "deadbeef"), 4)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "ghijkl"), 2)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "[1,2,3]"), 7)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "健身"), 6)
        XCTAssertEqual(FoundationModelsBudget.estimatedTokens(in: "💪"), 4)
        XCTAssertGreaterThan(FoundationModelsBudget.estimatedTokens(in: String(repeating: "{\"x\":1},", count: 100)), 500)
    }

    func testNoToolsPreflightIncludesExactNativeInstructionsAndTextOutput() throws {
        let base = "Keep the supplied evidence intact."
        let request = try FoundationModelsRequest(input: [["role": "user", "content": "Summarize these facts."]], tools: [], instructions: base)
        XCTAssertEqual(request.instructions, FoundationModelsBudget.instructions(base: base, hasTools: false))
        XCTAssertTrue(request.instructions.hasPrefix(base))
        XCTAssertTrue(request.instructions.contains("completion field"))
        XCTAssertEqual(request.stages.count, 1)
        XCTAssertNil(request.decisionStage)
        XCTAssertEqual(request.textStage.maximumResponseTokens, 900)
        XCTAssertEqual(request.textStage.estimatedTotalTokens, request.textStage.estimatedInputTokens + 900 + 128)
    }

    @MainActor
    func testOrdinarySixExerciseFourSetTemplateFitsWithEverySelectedToolSchemaAndOutputReserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        for index in 1...8 {
            let template = WorkoutTemplate(name: "Synthetic Plan \(index)", exercises: store.exercises.prefix(6).map {
                TemplateExercise(exercise: $0, sets: (0..<4).map { _ in TemplateSet(weight: 100, targetReps: 8) })
            })
            XCTAssertTrue(store.saveTemplate(template))
        }
        XCTAssertEqual(store.templates.count, 10)
        let tools = WorkoutAgentTools(store: store)
        let arguments = #"{"query":"Synthetic Plan 8","limit":1,"offset":0}"#
        let result = try tools.execute(name: "get_templates", arguments: arguments)
        let overview = try tools.execute(name: "get_workout_data", arguments: "{}")
        let question = "In my template named Synthetic Plan 8, add one rep to every set of the first exercise. Find this exact template using a narrow template search, then prepare a new version for my review."
        let callID = "2D7FC16E-8EA8-44B9-966A-088003458D5A"
        let overviewCallID = "770379E4-1736-4E10-A9A3-E4716B074BBE"
        let request = try FoundationModelsRequest(input: [["role": "user", "content": question],
            ["type": "function_call", "call_id": overviewCallID, "namespace": "liftlog", "name": "get_workout_data", "arguments": "{}"],
            ["type": "function_call_output", "call_id": overviewCallID, "output": overview.outputJSONString],
            ["type": "function_call", "call_id": callID, "namespace": "liftlog", "name": "get_templates", "arguments": arguments],
            ["type": "function_call_output", "call_id": callID, "output": result.outputJSONString]],
            tools: tools.definitions, instructions: WorkoutAssistant.instructions)
        XCTAssertTrue(request.prompt.contains(question))
        XCTAssertTrue(request.prompt.contains("Synthetic Plan 8"))
        XCTAssertFalse(request.omittedEarlierTurns)
        XCTAssertEqual(request.stages.count, request.tools.count + 2)
        XCTAssertEqual(request.decisionStage?.maximumResponseTokens, 80)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "propose_template_version").maximumResponseTokens, 900)
        for name in ["propose_template_version", "propose_edit_exercise", "propose_edit_workout_exercises"] {
            let stage = try request.argumentStage(forToolNamed: name)
            XCTAssertTrue(stage.prompt.contains("Changing existing reps/weight uses operation update"))
            XCTAssertTrue(stage.prompt.contains("ENTRY id, NEVER catalog exercise.id or set.id"))
            XCTAssertTrue(stage.prompt.contains("add = NEW EXERCISE"))
            XCTAssertTrue(stage.prompt.contains("Executor creates new IDs"))
            XCTAssertTrue(stage.prompt.contains("never request user-created IDs"))
        }
        XCTAssertEqual(try request.argumentStage(forToolNamed: "get_workout_data").maximumResponseTokens, 32)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "get_history").maximumResponseTokens, 80)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "get_templates").maximumResponseTokens, 150)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "get_exercise_catalog").maximumResponseTokens, 150)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "get_template_versions").maximumResponseTokens, 150)
        XCTAssertEqual(try request.argumentStage(forToolNamed: "graph_workout_history").maximumResponseTokens, 200)
        // Send reserves text and action selection. The chosen native argument
        // schema is independently token-counted at dispatch, never every unused tool.
        try request.textStage.validate()
        try XCTUnwrap(request.decisionStage).validate()
        let projectedItems = try request.prompt.split(separator: "\n").dropFirst().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let output = try XCTUnwrap(projectedItems.last?["output"])
        let expanded = try XCTUnwrap(expandTables(output) as? [String: Any])
        let restored = try request.argumentsJSON(restoringIdentifiersIn: expanded)
        let restoredObject = try JSONSerialization.jsonObject(with: Data(restored.utf8)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(result.outputJSONString.lowercasingUUIDStrings.utf8)) as? NSDictionary
        XCTAssertEqual(restoredObject, original, "Columnar projection must preserve every field, ID, set and numeric value")
    }

    @MainActor
    func testReadOnlyHealthToolsRetainEvidenceWithoutMutationSizedOutputReservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeReadBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let tools = WorkoutAgentTools(store: store)
        let evidence = "Complete scoped evidence: " + String(repeating: "Z", count: 5_700)
        let input: [[String: Any]] = [["role": "user", "content": evidence]]
        let request = try FoundationModelsRequest(input: input,
            tools: tools.definitions(includingHealth: true, allowingProposals: false), instructions: WorkoutAssistant.instructions)
        XCTAssertEqual(request.tools.count, 7)
        XCTAssertFalse(request.omittedEarlierTurns)
        XCTAssertTrue(request.prompt.contains(evidence))
        XCTAssertEqual(try request.argumentStage(forToolNamed: "graph_workout_health").maximumResponseTokens, 200)
        XCTAssertTrue(request.stages.allSatisfy { $0.estimatedTotalTokens <= FoundationModelsBudget.contextTokens })
        XCTAssertNoThrow(try FoundationModelsRequest(input: input,
            tools: tools.definitions(includingHealth: true), instructions: WorkoutAssistant.instructions),
            "Unused mutation schemas must not reject an answerable Health/read question")
    }

    @MainActor
    func testNameSearchSchemaCannotInventTemplateIDAndKnownIDsRemainExact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeSearchSchema-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let tools = WorkoutAgentTools(store: store)
        let definitions = tools.definitions
        let nameInput: [[String: Any]] = [["role": "user", "content": "Read the template named Synthetic Plan 8."]]
        let nameRequest = try FoundationModelsRequest(input: nameInput, tools: definitions, instructions: WorkoutAssistant.instructions)
        guard case .object(let searchFields) = try nameRequest.argumentStage(forToolNamed: "get_templates").schema?.kind else {
            return XCTFail("Expected search object")
        }
        XCTAssertEqual(searchFields.map(\.name), ["limit", "offset", "query"])
        let originalTools = try XCTUnwrap(definitions.first?["tools"] as? [[String: Any]])
        let original = try XCTUnwrap(originalTools.first { $0["name"] as? String == "get_templates" }?["parameters"] as? [String: Any])
        XCTAssertNotNil((original["properties"] as? [String: Any])?["template_id"], "Shared/executor definition stays intact")

        let id = "AB866E2C-9D0B-47DB-B3B3-D2649A20F28B"
        let output = #"{"id":"\#(id)","name":"Synthetic Plan 8"}"#
        let knownRequest = try FoundationModelsRequest(input: nameInput + [["type": "function_call_output", "call_id": "read", "output": output]],
            tools: definitions, instructions: WorkoutAssistant.instructions)
        guard case .object(let knownFields) = try knownRequest.argumentStage(forToolNamed: "get_templates").schema?.kind,
              let filter = knownFields.first(where: { $0.name == "template_id" }),
              case .string(let choices, _, _) = filter.schema.kind else { return XCTFail("Expected constrained ID filter") }
        XCTAssertEqual(choices, ["record_1"])
        XCTAssertTrue(filter.isOptional)
        let directRequest = try FoundationModelsRequest(input: [["role": "user", "content": "Read the template with exact ID \(id)."]],
            tools: definitions, instructions: WorkoutAssistant.instructions)
        guard case .object(let directFields) = try directRequest.argumentStage(forToolNamed: "get_templates").schema?.kind,
              case .string(let directChoices, _, _) = directFields.first(where: { $0.name == "template_id" })?.schema.kind else {
            return XCTFail("Expected explicit UUID filter")
        }
        XCTAssertEqual(directChoices, [id])
        XCTAssertTrue(directRequest.prompt.contains(id), "User prose remains verbatim")
    }

    func testUnusedOversizedArgumentSchemaDoesNotBlockSendButSelectedDispatchFailsBudget() throws {
        let properties = Dictionary(uniqueKeysWithValues: (0..<300).map { ("long_argument_\($0)", ["type": "string"]) })
        let tools: [[String: Any]] = [["tools": [["name": "read_large_arguments", "description": "Read a chosen record.",
            "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys)]]]]]
        let request = try FoundationModelsRequest(input: [["role": "user", "content": "Explain how to log my workout."]], tools: tools, instructions: "")
        XCTAssertNoThrow(try request.textStage.validate())
        XCTAssertNoThrow(try request.decisionStage?.validate())
        let selected = try request.argumentStage(forToolNamed: "read_large_arguments")
        XCTAssertThrowsError(try selected.validate()) { XCTAssertEqual(($0 as? AppleFoundationModelsError)?.kind, .contextTooLarge) }
    }

    func testStructuredAnswerRequiresCompleteObjectAndCompletionField() throws {
        let answer = "A complete answer containing quoted completion text and a closing fence ``` ."
        XCTAssertEqual(try FoundationModelsTextCompletion.completedAnswer(answer, completion: "complete", isComplete: true), answer)
        XCTAssertThrowsError(try FoundationModelsTextCompletion.completedAnswer(answer, completion: nil, isComplete: true))
        XCTAssertThrowsError(try FoundationModelsTextCompletion.completedAnswer(answer, completion: "complete", isComplete: false))
        XCTAssertThrowsError(try FoundationModelsTextCompletion.completedAnswer("", completion: "complete", isComplete: true))
    }

    private func expandTables(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            if Set(object.keys) == ["columns", "rows"], let columns = object["columns"] as? [String], let rows = object["rows"] as? [[Any]] {
                return rows.map { row in Dictionary(uniqueKeysWithValues: zip(columns, row.map(expandTables))) }
            }
            return object.mapValues(expandTables)
        }
        if let array = value as? [Any] { return array.map(expandTables) }
        return value
    }
}

private extension String {
    var lowercasingUUIDStrings: String {
        guard let expression = try? NSRegularExpression(pattern: "[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}") else { return self }
        return expression.matches(in: self, range: NSRange(startIndex..., in: self)).reversed().reduce(self) { text, match in
            guard let range = Range(match.range, in: text) else { return text }
            return text.replacingCharacters(in: range, with: text[range].lowercased())
        }
    }
}
