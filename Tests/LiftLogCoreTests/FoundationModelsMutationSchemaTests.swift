import Foundation
import XCTest
@testable import LiftLogCore

final class FoundationModelsMutationSchemaTests: XCTestCase {
    @MainActor
    func testConditionalOperationsRequireTypedIDsAndRetainMeaningfulVariants() throws {
        let request = try makeRequest(reads: [("get_templates", ["templates": [template(1, version: 2, entry: 3, catalog: 4)]])])
        let stage = try request.argumentStage(forToolNamed: "propose_template_version")
        let schema = try XCTUnwrap(stage.schema)
        let fields = try objectFields(schema)
        XCTAssertEqual(try restoredChoice(fields, "template_id", request), id(1))
        XCTAssertEqual(try restoredChoice(fields, "base_version_id", request), id(2))
        guard case .array(let item, _, _) = try XCTUnwrap(fields["operations"]).schema.kind,
              case .anyOf(let variants) = item.kind else { return XCTFail("Expected conditional operations") }
        XCTAssertEqual(variants.map(\.name), ["AddNewExercise_0", "UpdateExistingEntry_0", "RemoveExistingEntry_0"])
        let add = try objectFields(variants[0])
        let update = try objectFields(variants[1])
        let remove = try objectFields(variants[2])
        XCTAssertNil(add["entry_id"])
        for key in ["entry_id", "exercise_id", "sets"] {
            XCTAssertEqual(update[key]?.isRequired, true)
            XCTAssertEqual(update[key]?.isOptional, false)
        }
        XCTAssertEqual(remove["entry_id"]?.isOptional, false)
        XCTAssertNil(remove["exercise_id"])
        XCTAssertNil(remove["sets"])
        XCTAssertTrue(variants[0].description?.contains("NEW EXERCISE") == true)
        XCTAssertTrue(variants[1].description?.contains("ALL sets") == true)
        let entryIDs = try definitionChoices(schema, "EntryID_0")
        let catalogIDs = try definitionChoices(schema, "CatalogID")
        XCTAssertEqual(try restore(entryIDs, key: "entry_id", request: request), [id(3)])
        XCTAssertEqual(try restore(catalogIDs, key: "exercise_id", request: request), [id(4)])
        XCTAssertFalse(entryIDs.contains(id(99)), "Call IDs are never domain candidates")
        XCTAssertTrue(stage.prompt.contains("ONE operation per exercise ENTRY"))
        XCTAssertTrue(stage.prompt.contains("current set count"))
        XCTAssertEqual(try FoundationModelsSchema(json: schema.json, name: schema.name), schema)
    }

    @MainActor
    func testModelSelectedModesNarrowOperationsWithoutDroppingMixedCapability() throws {
        let request = try makeRequest(reads: [("get_templates", ["templates": [template(1, version: 2, entry: 3, catalog: 4)]])])
        let modeStage = try XCTUnwrap(request.editModeStage(forToolNamed: "propose_template_version"))
        XCTAssertEqual(modeStage.maximumResponseTokens, 80)
        XCTAssertTrue(modeStage.prompt.contains("adding reps/load/sets"))
        for mode in FoundationModelsEditMode.allCases {
            let schema = try XCTUnwrap(request.argumentStage(forToolNamed: "propose_template_version", editMode: mode).schema)
            let fields = try objectFields(schema)
            guard case .array(let operation, _, _) = try XCTUnwrap(fields["operations"]).schema.kind else { return XCTFail("Expected operations") }
            if mode == .mixedChanges {
                guard case .anyOf(let cases) = operation.kind else { return XCTFail("Mixed retains union") }
                XCTAssertEqual(cases.count, 3)
            } else {
                let operationFields = try objectFields(operation)
                guard case .string(let choices, _, _) = try XCTUnwrap(operationFields["operation"]).schema.kind else {
                    return XCTFail("Expected fixed mode")
                }
                XCTAssertEqual(choices, mode.operation.map { [$0] })
                XCTAssertEqual(operationFields["entry_id"] != nil, mode != .insertNewExerciseEntry)
                XCTAssertEqual(operationFields["sets"] != nil, mode != .removeExerciseEntry)
                if mode == .changeExistingExerciseOrItsSets {
                    XCTAssertEqual(operationFields["entry_id"]?.isOptional, false)
                    XCTAssertEqual(operationFields["exercise_id"]?.isOptional, false)
                }
            }
        }
        XCTAssertNil(try request.editModeStage(forToolNamed: "propose_create_template"))
    }

    @MainActor
    func testModelSelectedSetCountPolicyRetainsEachEntryCountAndAllowsExplicitCountChanges() throws {
        var snapshot = template(1, version: 2, entry: 3, catalog: 4)
        var entries = try XCTUnwrap(snapshot["exercises"] as? [[String: Any]])
        var second = try XCTUnwrap(entries.first)
        second["id"] = id(12)
        second["sets"] = Array(try XCTUnwrap(second["sets"] as? [[String: Any]]).prefix(2))
        entries.append(second)
        snapshot["exercises"] = entries
        let request = try makeRequest(reads: [("get_templates", ["templates": [snapshot]])])
        let kept = try XCTUnwrap(request.argumentStage(forToolNamed: "propose_template_version",
            editMode: .changeExistingExerciseOrItsSets, preserveSetCounts: true).schema)
        let root = try objectFields(kept)
        guard case .array(let operation, _, _) = try XCTUnwrap(root["operations"]).schema.kind,
              case .anyOf(let variants) = operation.kind else { return XCTFail("Expected entry count groups") }
        XCTAssertEqual(variants.count, 2)
        for (index, count) in [2, 4].enumerated() {
            let fields = try objectFields(variants[index])
            guard case .array(_, let minimum, let maximum) = try XCTUnwrap(fields["sets"]).schema.kind,
                  case .string(let choices, _, _) = try XCTUnwrap(fields["entry_id"]).schema.kind else { return XCTFail("Expected constrained count") }
            XCTAssertEqual(minimum, count)
            XCTAssertEqual(maximum, count)
            XCTAssertEqual(try restore(XCTUnwrap(choices), key: "entry_id", request: request), [id(count == 2 ? 12 : 3)])
        }
        let changed = try XCTUnwrap(request.argumentStage(forToolNamed: "propose_template_version",
            editMode: .changeExistingExerciseOrItsSets, preserveSetCounts: false).schema)
        guard case .array(let change, _, _) = try XCTUnwrap(objectFields(changed)["operations"]).schema.kind,
              case .array(_, let minimum, let maximum) = try XCTUnwrap(objectFields(change)["sets"]).schema.kind else {
            return XCTFail("Expected original set capability")
        }
        XCTAssertEqual(minimum, 1)
        XCTAssertEqual(maximum, 50)
        XCTAssertEqual(try FoundationModelsSchema(json: kept.json, name: kept.name), kept)
    }

    @MainActor
    func testParentTargetsKeepTheirOwnEntriesAndCurrentVersionDespiteSharedMovement() throws {
        let request = try makeRequest(reads: [("get_templates", ["templates": [
            template(1, version: 2, entry: 3, catalog: 4), template(9, version: 10, entry: 11, catalog: 4)
        ]])])
        let root = try XCTUnwrap(request.argumentStage(forToolNamed: "propose_template_version").schema)
        guard case .anyOf(let variants) = root.kind else { return XCTFail("Expected target variants") }
        XCTAssertEqual(variants.count, 2)
        for (index, values) in [[1, 2, 3], [9, 10, 11]].enumerated() {
            let fields = try objectFields(variants[index])
            XCTAssertEqual(try restoredChoice(fields, "template_id", request), id(values[0]))
            XCTAssertEqual(try restoredChoice(fields, "base_version_id", request), id(values[1]))
            XCTAssertEqual(try restore(definitionChoices(root, "EntryID_\(index)"), key: "entry_id", request: request), [id(values[2])])
        }
        XCTAssertEqual(try restore(definitionChoices(root, "CatalogID"), key: "exercise_id", request: request), [id(4)])
    }

    @MainActor
    func testHistoryVersionsArtifactsAndPreviousTurnsCannotAuthorizeCurrentMutation() throws {
        let historical = template(40, version: 50, entry: 41, catalog: 42)
        let request = try makeRequest(reads: [
            ("get_history", ["workouts": [historical]]),
            ("get_template_versions", ["templateID": id(1), "currentVersionID": id(2), "versions": [historical]]),
            ("graph_workout_history", ["id": id(60), "points": [["id": id(61)]]])
        ])
        XCTAssertThrowsError(try request.argumentStage(forToolNamed: "propose_template_version")) {
            XCTAssertEqual(($0 as? FoundationModelsToolDispatchError)?.toolName, "propose_template_version")
        }
        let earlier = try readInput([( "get_templates", ["templates": [template(1, version: 2, entry: 3, catalog: 4)]])])
        let newTurn = try FoundationModelsRequest(input: earlier + [["role": "user", "content": "Change the first exercise now."]],
            tools: WorkoutAgentTools.definitions, instructions: WorkoutAssistant.instructions)
        XCTAssertThrowsError(try newTurn.argumentStage(forToolNamed: "propose_template_version"))
    }

    @MainActor
    func testActiveTargetsUseSessionEntryIDsAndCreateUsesCatalogOnly() throws {
        var active = template(20, version: 21, entry: 22, catalog: 4)
        active["templateID"] = id(1)
        active["templateVersionID"] = id(2)
        active.removeValue(forKey: "currentVersionID")
        let request = try makeRequest(reads: [("get_workout_data", ["activeWorkout": active]),
            ("get_exercise_catalog", ["exercises": [["id": id(30), "name": "New movement", "category": "Back"]]])])
        let edit = try XCTUnwrap(request.argumentStage(forToolNamed: "propose_edit_workout_exercises").schema)
        let fields = try objectFields(edit)
        XCTAssertEqual(try restoredChoice(fields, "target_id", request), id(20))
        XCTAssertEqual(try restore(definitionChoices(edit, "EntryID_0"), key: "entry_id", request: request), [id(22)])
        XCTAssertEqual(Set(try restore(definitionChoices(edit, "CatalogID"), key: "exercise_id", request: request)), [id(4), id(30)])
        XCTAssertThrowsError(try request.argumentStage(forToolNamed: "propose_template_version"))
        XCTAssertNoThrow(try request.argumentStage(forToolNamed: "propose_create_template"))
    }

    private func id(_ number: Int) -> String { String(format: "a1000000-0000-4000-8000-%012d", number) }
    private func template(_ identity: Int, version: Int, entry: Int, catalog: Int) -> [String: Any] {
        ["id": id(identity), "currentVersionID": id(version), "name": "Synthetic", "unit": "lb", "exercises": [
            ["id": id(entry), "exercise": ["id": id(catalog), "name": "Bench Press", "category": "Chest"],
             "sets": (0..<4).map { ["id": id(70 + $0), "weight": 100, "targetReps": 8] as [String: Any] }]
        ]]
    }
    @MainActor private func makeRequest(reads: [(String, [String: Any])]) throws -> FoundationModelsRequest {
        try FoundationModelsRequest(input: readInput(reads), tools: WorkoutAgentTools.definitions, instructions: WorkoutAssistant.instructions)
    }
    private func readInput(_ reads: [(String, [String: Any])]) throws -> [[String: Any]] {
        var input: [[String: Any]] = [["role": "user", "content": "Change the first entry's four sets from 8 to 9 reps."]]
        for (index, read) in reads.enumerated() {
            let callID = id(99 + index)
            input.append(["type": "function_call", "call_id": callID, "name": read.0, "arguments": "{}"])
            input.append(["type": "function_call_output", "call_id": callID,
                          "output": String(decoding: try JSONSerialization.data(withJSONObject: read.1), as: UTF8.self)])
        }
        return input
    }
    private func objectFields(_ schema: FoundationModelsSchema) throws -> [String: FoundationModelsSchema.Property] {
        guard case .object(let fields) = schema.kind else { XCTFail("Expected object"); return [:] }
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
    }
    private func definitionChoices(_ schema: FoundationModelsSchema, _ name: String) throws -> [String] {
        let definition = try XCTUnwrap(schema.definitions.first { $0.name == name })
        guard case .string(let choices, _, _) = definition.kind else { XCTFail("Expected choices"); return [] }
        return try XCTUnwrap(choices)
    }
    private func restoredChoice(_ fields: [String: FoundationModelsSchema.Property], _ key: String, _ request: FoundationModelsRequest) throws -> String {
        guard case .string(let choices, _, _) = try XCTUnwrap(fields[key]).schema.kind else { XCTFail("Expected choice"); return "" }
        return try XCTUnwrap(restore(XCTUnwrap(choices), key: key, request: request).first)
    }
    private func restore(_ values: [String], key: String, request: FoundationModelsRequest) throws -> [String] {
        let json = try request.argumentsJSON(restoringIdentifiersIn: [key: values])
        return try XCTUnwrap((JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?[key] as? [String])
    }
}
