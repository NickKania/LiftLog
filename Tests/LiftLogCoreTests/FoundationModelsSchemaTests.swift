import Foundation
import XCTest
@testable import LiftLogCore

final class FoundationModelsSchemaTests: XCTestCase {
    func testNullableEnumKeepsChoicesAndNullabilitySeparate() throws {
        let schema = try FoundationModelsSchema(json: ["type": ["string", "null"], "enum": ["lb", "kg", NSNull()]], name: "Unit")
        XCTAssertTrue(schema.isNullable)
        XCTAssertEqual(schema.kind, .string(choices: ["lb", "kg"], minimumLength: nil, maximumLength: nil))
        let encoded = try XCTUnwrap(schema.json["enum"] as? [Any])
        XCTAssertEqual(encoded.compactMap { $0 as? String }, ["lb", "kg"])
        XCTAssertTrue(encoded.last is NSNull)
        XCTAssertThrowsError(try FoundationModelsSchema(json: ["type": "string", "enum": [NSNull()]], name: "Empty"))
    }

    func testRequiredNullableAndAbsentOptionalPropertiesMapToNativeOptionality() throws {
        let schema = try FoundationModelsSchema(json: ["type": "object", "required": ["required", "nullable"], "properties": [
            "required": ["type": "string"], "nullable": ["type": ["integer", "null"]], "optional": ["type": "boolean"]
        ]], name: "Arguments")
        guard case .object(let properties) = schema.kind else { return XCTFail("Expected object") }
        XCTAssertEqual(properties.map(\.name), ["nullable", "optional", "required"])
        XCTAssertEqual(properties.map(\.isRequired), [true, false, true])
        XCTAssertEqual(properties.map(\.isOptional), [true, true, false])
        XCTAssertEqual(try FoundationModelsSchema(json: schema.json, name: schema.name), schema)
    }

    func testEmptyObjectIsPreservedForNoArgumentTools() throws {
        let schema = try FoundationModelsSchema(json: ["type": "object", "properties": [:], "required": []], name: "Arguments")
        XCTAssertEqual(schema.kind, .object([]))
        XCTAssertEqual((schema.json["properties"] as? [String: Any])?.count, 0)
        XCTAssertEqual(schema.json["required"] as? [String], [])
    }

    func testStringIntegerNumberAndArrayBoundsSurviveRoundTrip() throws {
        let cases: [[String: Any]] = [
            ["type": "string", "minLength": 1, "maxLength": 120],
            ["type": "integer", "minimum": -2, "maximum": 10_000],
            ["type": "number", "minimum": 0.25, "maximum": 1_000_000],
            ["type": ["array", "null"], "items": ["type": "string"], "minItems": 1, "maxItems": 50]
        ]
        for json in cases {
            let schema = try FoundationModelsSchema(json: json, name: "Bounded")
            XCTAssertEqual(try FoundationModelsSchema(json: schema.json, name: "Bounded"), schema)
        }
        let name = try FoundationModelsSchema(json: cases[0], name: "Name")
        XCTAssertEqual(name.kind, .string(choices: nil, minimumLength: 1, maximumLength: 120))
        XCTAssertEqual(name.generationDescription, "Minimum string length: 1 characters. Maximum string length: 120 characters.")
        XCTAssertTrue(name.constraintDescriptions.contains("120"))
        XCTAssertEqual(try FoundationModelsSchema(json: cases[1], name: "Reps").kind, .integer(minimum: -2, maximum: 10_000))
        XCTAssertEqual(try FoundationModelsSchema(json: cases[2], name: "Weight").kind, .number(minimum: 0.25, maximum: 1_000_000))
    }

    func testInvalidBoundsAndUnsupportedTypesFailExplicitly() {
        let invalid: [[String: Any]] = [
            ["type": "string", "minLength": -1], ["type": "string", "minLength": 3, "maxLength": 2],
            ["type": "integer", "minimum": 1.5], ["type": "number", "maximum": true],
            ["type": "array", "items": ["type": "boolean"], "maxItems": -1], ["type": "array"],
            ["type": ["string", "integer"]], ["type": "object", "properties": [:], "required": ["missing"]]
        ]
        for json in invalid { XCTAssertThrowsError(try FoundationModelsSchema(json: json, name: "Invalid")) }
    }

    @MainActor
    func testEveryProductionToolSchemaAndNestedOperationsConvertWithoutDroppingConstraints() throws {
        let tools = try XCTUnwrap(WorkoutAgentTools.definitions.first?["tools"] as? [[String: Any]])
        for tool in tools {
            let json = try XCTUnwrap(tool["parameters"] as? [String: Any])
            let schema = try FoundationModelsSchema(json: json, name: "Arguments")
            XCTAssertEqual(try FoundationModelsSchema(json: schema.json, name: "Arguments"), schema, tool["name"] as? String ?? "")
        }
        let edit = try XCTUnwrap(tools.first { $0["name"] as? String == "propose_template_version" })
        let schema = try FoundationModelsSchema(json: XCTUnwrap(edit["parameters"] as? [String: Any]), name: "Arguments")
        guard case .object(let properties) = schema.kind,
              case .array(let operation, let minimum, let maximum) = properties.first(where: { $0.name == "operations" })?.schema.kind,
              case .object(let fields) = operation.kind else { return XCTFail("Expected nested operations") }
        XCTAssertEqual(minimum, 1)
        XCTAssertEqual(maximum, 100)
        XCTAssertEqual(fields.filter(\.isOptional).map(\.name), ["entry_id", "exercise_id", "sets"])
        let sets = try XCTUnwrap(fields.first { $0.name == "sets" })
        XCTAssertTrue(sets.schema.isNullable)
        guard case .array(let set, let setMinimum, let setMaximum) = sets.schema.kind,
              case .object(let setFields) = set.kind else { return XCTFail("Expected set schema") }
        XCTAssertEqual(setMinimum, 1)
        XCTAssertEqual(setMaximum, 50)
        XCTAssertEqual(setFields.first(where: { $0.name == "reps" })?.schema.kind, .integer(minimum: 1, maximum: 10_000))
        XCTAssertEqual(setFields.first(where: { $0.name == "weight" })?.schema.kind, .number(minimum: 0, maximum: 1_000_000))
    }
}
