import Foundation
import CoreFoundation

/// Foundation-only representation of the JSON Schema subset used by workout tools.
/// Nullability belongs to a value; requiredness belongs to its containing property.
/// Native guided generation may omit nullable properties. The executor validates
/// the resulting arguments again before it can create a reviewed proposal.
struct FoundationModelsSchema: Equatable, Sendable {
    struct Property: Equatable, Sendable {
        let name: String
        let schema: FoundationModelsSchema
        let isRequired: Bool
        var isOptional: Bool { !isRequired || schema.isNullable }
    }

    indirect enum Kind: Equatable, Sendable {
        case object([Property])
        case array(FoundationModelsSchema, minimum: Int?, maximum: Int?)
        case string(choices: [String]?, minimumLength: Int?, maximumLength: Int?)
        case integer(minimum: Int?, maximum: Int?)
        case number(minimum: Double?, maximum: Double?)
        case boolean
        case anyOf([FoundationModelsSchema])
        case reference(String)
    }

    let name: String
    let description: String?
    let isNullable: Bool
    let kind: Kind
    let definitions: [FoundationModelsSchema]
    private let title: String?

    init(json: [String: Any], name: String) throws {
        try self.init(json: json, name: name, knownReferences: [])
    }

    private init(json: [String: Any], name: String, knownReferences: Set<String>) throws {
        title = json["title"] as? String
        self.name = title ?? name
        let definitionsJSON = json["$defs"] as? [String: [String: Any]] ?? [:]
        let references = knownReferences.union(definitionsJSON.keys)
        definitions = try definitionsJSON.keys.sorted().map { key in
            guard let value = definitionsJSON[key] else { throw Self.invalid }
            return try Self(json: value, name: key, knownReferences: references)
        }
        description = json["description"] as? String
        let types = json["type"] as? [String] ?? (json["type"] as? String).map { [$0] } ?? []
        let choices = json["enum"] as? [Any]
        isNullable = types.contains("null") || choices?.contains(where: { $0 is NSNull }) == true
        if let reference = json["$ref"] as? String {
            let prefix = "#/$defs/"
            guard reference.hasPrefix(prefix), references.contains(String(reference.dropFirst(prefix.count))) else { throw Self.invalid }
            kind = .reference(String(reference.dropFirst(prefix.count)))
            return
        }
        if let options = json["anyOf"] as? [[String: Any]] {
            guard !options.isEmpty else { throw Self.invalid }
            kind = .anyOf(try options.enumerated().map { index, option in
                try Self(json: option, name: name + "_option_\(index)", knownReferences: references)
            })
            return
        }
        guard Set(types.filter { $0 != "null" }).count == 1 else { throw Self.invalid }
        switch types.first(where: { $0 != "null" }) {
        case "object":
            guard let properties = json["properties"] as? [String: [String: Any]] else { throw Self.invalid }
            let required = Set(json["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(properties.keys)) else { throw Self.invalid }
            kind = .object(try properties.keys.sorted().map { key in
                guard let value = properties[key] else { throw Self.invalid }
                return Property(name: key, schema: try Self(json: value, name: name + "_" + key, knownReferences: references), isRequired: required.contains(key))
            })
        case "array":
            guard let item = json["items"] as? [String: Any] else { throw Self.invalid }
            let minimum = try Self.integerBound(json, "minItems")
            let maximum = try Self.integerBound(json, "maxItems")
            try Self.validateBounds(minimum, maximum, nonnegative: true)
            kind = .array(try Self(json: item, name: name + "_item", knownReferences: references), minimum: minimum, maximum: maximum)
        case "string":
            let values = choices?.compactMap { $0 as? String }
            if let choices {
                guard let values, !values.isEmpty, choices.allSatisfy({ $0 is String || $0 is NSNull }) else { throw Self.invalid }
            }
            let minimum = try Self.integerBound(json, "minLength")
            let maximum = try Self.integerBound(json, "maxLength")
            try Self.validateBounds(minimum, maximum, nonnegative: true)
            kind = .string(choices: values, minimumLength: minimum, maximumLength: maximum)
        case "integer":
            guard choices == nil else { throw Self.invalid }
            let minimum = try Self.integerBound(json, "minimum")
            let maximum = try Self.integerBound(json, "maximum")
            try Self.validateBounds(minimum, maximum)
            kind = .integer(minimum: minimum, maximum: maximum)
        case "number":
            guard choices == nil else { throw Self.invalid }
            let minimum = try Self.numberBound(json, "minimum")
            let maximum = try Self.numberBound(json, "maximum")
            try Self.validateBounds(minimum, maximum)
            kind = .number(minimum: minimum, maximum: maximum)
        case "boolean":
            guard choices == nil else { throw Self.invalid }
            kind = .boolean
        default: throw Self.invalid
        }
    }

    /// Canonical schema for conservative context accounting, including all guides.
    /// App maps this IR to DynamicGenerationSchema; Core never imports the framework.
    var json: [String: Any] {
        var value: [String: Any]
        switch kind {
        case .object(let properties):
            value = ["type": "object", "properties": Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema.json) }),
                     "required": properties.filter(\.isRequired).map(\.name), "additionalProperties": false]
        case .array(let item, let minimum, let maximum):
            value = ["type": "array", "items": item.json]
            value["minItems"] = minimum
            value["maxItems"] = maximum
        case .string(let choices, let minimum, let maximum):
            value = ["type": "string"]
            value["enum"] = choices.map { $0.map { $0 as Any } + (isNullable ? [NSNull()] : []) }
            value["minLength"] = minimum
            value["maxLength"] = maximum
        case .integer(let minimum, let maximum):
            value = ["type": "integer"]
            value["minimum"] = minimum
            value["maximum"] = maximum
        case .number(let minimum, let maximum):
            value = ["type": "number"]
            value["minimum"] = minimum
            value["maximum"] = maximum
        case .boolean: value = ["type": "boolean"]
        case .anyOf(let options): value = ["anyOf": options.map(\.json)]
        case .reference(let name): value = ["$ref": "#/$defs/" + name]
        }
        if isNullable, let type = value["type"] as? String { value["type"] = [type, "null"] }
        value["description"] = description
        value["title"] = title
        if !definitions.isEmpty { value["$defs"] = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0.json) }) }
        return value
    }

    /// SystemLanguageModel currently rejects regex guides. Express string bounds
    /// in the native property's description and retain executor enforcement. Keep
    /// this text in fallback accounting too, so unavailable native guides do not
    /// turn into either lost constraints or unbudgeted instructions.
    var generationDescription: String? {
        var parts = description.map { [$0] } ?? []
        if case .string(_, let minimum, let maximum) = kind {
            if let minimum { parts.append("Minimum string length: \(minimum) characters.") }
            if let maximum { parts.append("Maximum string length: \(maximum) characters.") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var constraintDescriptions: String {
        let nested: [String]
        switch kind {
        case .object(let properties): nested = properties.map { $0.schema.constraintDescriptions }
        case .array(let item, _, _): nested = [item.constraintDescriptions]
        case .anyOf(let options): nested = options.map(\.constraintDescriptions)
        default: nested = []
        }
        // Original descriptions are already present in jsonString.
        let own = generationDescription == description ? "" : generationDescription ?? ""
        return ([own] + nested + definitions.map(\.constraintDescriptions)).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var jsonString: String {
        get throws {
            String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }

    private static let invalid = AppleFoundationModelsError("A workout tool has an unsupported argument schema. Try a different task.")

    private static func integerBound(_ json: [String: Any], _ key: String) throws -> Int? {
        guard let value = json[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              let integer = Int(exactly: number.doubleValue) else { throw invalid }
        return integer
    }

    private static func numberBound(_ json: [String: Any], _ key: String) throws -> Double? {
        guard let value = json[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw invalid }
        return number.doubleValue
    }

    private static func validateBounds<T: Comparable & SignedNumeric>(_ minimum: T?, _ maximum: T?, nonnegative: Bool = false) throws {
        if let minimum, let maximum, minimum > maximum { throw invalid }
        if nonnegative, (minimum.map { $0 < 0 } == true || maximum.map { $0 < 0 } == true) { throw invalid }
    }
}
