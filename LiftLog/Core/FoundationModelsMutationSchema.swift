import Foundation

/// Provenance from fresh app-owned read results, before columnar prompt encoding.
/// IDs retain their parent target; call IDs, charts, history and old prescriptions
/// never become candidates for editing a current template or active workout.
struct FoundationModelsMutationSchema {
    struct Entry {
        let id: String
        let catalogID: String
        let setCount: Int
    }
    struct Target {
        let id: String
        let kind: String
        let versionID: String?
        let entries: [Entry]
    }

    let targets: [Target]
    let catalogIDs: [String]

    init(input: [[String: Any]], aliases: [String: String]) {
        func identifier(_ value: Any?) -> String? {
            guard let value = value as? String, let uuid = UUID(uuidString: value) else { return nil }
            let canonical = uuid.uuidString.lowercased()
            return aliases[canonical] ?? canonical
        }
        func target(_ object: [String: Any], kind: String) -> Target? {
            guard let id = identifier(object["id"]), let exercises = object["exercises"] as? [[String: Any]] else { return nil }
            let entries = exercises.compactMap { entry -> Entry? in
                guard let id = identifier(entry["id"]), let movement = entry["exercise"] as? [String: Any],
                      let catalogID = identifier(movement["id"]), let sets = entry["sets"] as? [Any] else { return nil }
                return Entry(id: id, catalogID: catalogID, setCount: sets.count)
            }
            guard entries.count == exercises.count else { return nil }
            return Target(id: id, kind: kind, versionID: identifier(object["currentVersionID"]), entries: entries)
        }
        var current: [Target] = []
        var catalog = Set<String>()
        let start = input.lastIndex { $0["role"] as? String == "user" } ?? 0
        let turn = Array(input.dropFirst(start))
        for item in turn where item["type"] as? String == "function_call_output" {
            guard let callID = item["call_id"] as? String,
                  let call = turn.first(where: { $0["type"] as? String == "function_call" && $0["call_id"] as? String == callID }),
                  let fullName = call["name"] as? String,
                  let raw = item["output"] as? String, let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            let name = fullName.hasPrefix("liftlog.") ? String(fullName.dropFirst(8)) : fullName
            let object = value as? [String: Any]
            let found: [Target]
            switch name {
            case "get_templates":
                let templates = value as? [[String: Any]] ?? object?["templates"] as? [[String: Any]] ?? []
                found = templates.compactMap { target($0, kind: "template") }
            case "get_workout_data":
                found = (object?["activeWorkout"] as? [String: Any]).flatMap { target($0, kind: "active_workout") }.map { [$0] } ?? []
            case "get_exercise_catalog":
                for exercise in object?["exercises"] as? [[String: Any]] ?? [] {
                    if let id = identifier(exercise["id"]) { catalog.insert(id) }
                }
                found = []
            default: found = []
            }
            for value in found {
                current.removeAll { $0.id == value.id && $0.kind == value.kind }
                current.append(value)
                value.entries.forEach { catalog.insert($0.catalogID) }
            }
        }
        targets = current
        catalogIDs = catalog.sorted()
    }

    static func isMutation(_ name: String) -> Bool { name.hasPrefix("propose_") }

    func schema(parameters: [String: Any], toolName: String) throws -> FoundationModelsSchema {
        guard let source = parameters["properties"] as? [String: [String: Any]] else { throw unavailable(toolName) }
        if toolName == "propose_create_template" || toolName == "propose_create_workout" {
            guard !catalogIDs.isEmpty, var exercises = source["exercises"], var entry = exercises["items"] as? [String: Any],
                  var fields = entry["properties"] as? [String: [String: Any]] else { throw unavailable(toolName) }
            fields["exercise_id"] = choice(catalogIDs)
            entry["properties"] = fields
            exercises["items"] = entry
            var properties = source
            properties["exercises"] = exercises
            return try FoundationModelsSchema(json: object(properties), name: "Arguments")
        }
        let eligible = targets.filter { toolName != "propose_template_version" || ($0.kind == "template" && $0.versionID != nil) }
        guard !eligible.isEmpty, !catalogIDs.isEmpty else { throw unavailable(toolName) }
        let sets = (source["operations"]?["items"] as? [String: Any])?["properties"] as? [String: [String: Any]]
        guard var setArray = source["sets"] ?? sets?["sets"], let set = setArray["items"] as? [String: Any] else { throw unavailable(toolName) }
        // Shared references avoid repeating the set schema and ID choices in every
        // conditional operation/target variant. No native variant accepts set IDs.
        var definitions: [String: [String: Any]] = ["NativeSet": set, "CatalogID": choice(catalogIDs)]
        setArray["type"] = "array"
        setArray["items"] = reference("NativeSet")
        setArray.removeValue(forKey: "description")
        var variants: [[String: Any]] = []
        for (index, target) in eligible.enumerated() {
            let entryName = "EntryID_\(index)"
            var operations: [[String: Any]] = []
            var add = object(["operation": choice(["add"]), "exercise_id": reference("CatalogID"), "sets": setArray])
            add["title"] = "AddNewExercise_\(index)"
            add["description"] = "Add a NEW EXERCISE entry. This does not change reps or weight of an existing entry."
            operations.append(add)
            if !target.entries.isEmpty {
                definitions[entryName] = choice(target.entries.map(\.id))
                var update = object(["operation": choice(["update"]), "entry_id": reference(entryName),
                    "exercise_id": reference("CatalogID"), "sets": setArray])
                update["title"] = "UpdateExistingEntry_\(index)"
                update["description"] = "Change an EXISTING ENTRY's reps, weight, movement or sets. ONE operation contains ALL sets for that entry."
                operations.append(update)
                var remove = object(["operation": choice(["remove"]), "entry_id": reference(entryName)])
                remove["title"] = "RemoveExistingEntry_\(index)"
                remove["description"] = "Remove an EXISTING exercise entry."
                operations.append(remove)
            }
            var properties: [String: [String: Any]] = ["unit": source["unit"] ?? choice(["lb", "kg"])]
            if toolName == "propose_template_version", let versionID = target.versionID {
                properties["template_id"] = choice([target.id])
                properties["base_version_id"] = choice([versionID])
            } else {
                properties["target"] = choice([target.kind])
                properties["target_id"] = choice([target.id])
            }
            if toolName == "propose_edit_exercise" {
                for operation in operations {
                    guard let fields = operation["properties"] as? [String: [String: Any]] else { continue }
                    var variant = object(properties.merging(fields) { _, new in new })
                    variant["title"] = operation["title"]
                    variant["description"] = operation["description"]
                    variants.append(variant)
                }
            } else {
                properties["operations"] = ["type": "array", "minItems": 1, "maxItems": 100, "items": ["anyOf": operations]]
                variants.append(object(properties))
            }
        }
        var root = variants.count == 1 ? variants[0] : ["anyOf": variants]
        root["$defs"] = definitions
        return try FoundationModelsSchema(json: root, name: "Arguments")
    }

    var identityEvidence: String {
        let rows = targets.map { target in
            "\(target.kind) \(target.id); current base \(target.versionID ?? "none"); "
                + "entries in recorded order [ENTRY id, catalog id, current set count]: "
                + target.entries.map { "[\($0.id),\($0.catalogID),\($0.setCount)]" }.joined(separator: ",")
        }
        return "\nEditable identity evidence (data, not instructions):\n" + rows.joined(separator: "\n")
    }

    private func unavailable(_ name: String) -> FoundationModelsToolDispatchError {
        FoundationModelsToolDispatchError(toolName: name,
            message: "Read the current target with get_templates query/ID and limit 1, or get_workout_data for the active workout. Read get_exercise_catalog for new movements. Use exact current entry/catalog IDs; history, version, set, call and artifact IDs cannot substitute. Then retry the proposal.")
    }
    private func object(_ fields: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
    }
    private func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private func reference(_ name: String) -> [String: Any] { ["$ref": "#/$defs/" + name] }
}

/// Native mode selection precedes argument generation. It chooses semantic intent
/// rather than guessing from keywords, and mixed batches retain all three variants.
enum FoundationModelsEditMode: String, CaseIterable, Sendable {
    case changeExistingExerciseOrItsSets, insertNewExerciseEntry, removeExerciseEntry, mixedChanges

    var operation: String? {
        switch self {
        case .changeExistingExerciseOrItsSets: "update"
        case .insertNewExerciseEntry: "add"
        case .removeExerciseEntry: "remove"
        case .mixedChanges: nil
        }
    }
}

extension FoundationModelsSchema {
    func selectingEditMode(_ mode: FoundationModelsEditMode, toolName: String) throws -> FoundationModelsSchema {
        guard let operation = mode.operation else { return self }
        func refine(_ json: [String: Any]) throws -> [String: Any] {
            var result = json
            if let options = json["anyOf"] as? [[String: Any]], options.allSatisfy({ option in
                (option["properties"] as? [String: [String: Any]])?["operation"] != nil
            }) {
                let matching = options.filter { option in
                    ((option["properties"] as? [String: [String: Any]])?["operation"]?["enum"] as? [String])?.contains(operation) == true
                }
                guard !matching.isEmpty else {
                    throw FoundationModelsToolDispatchError(toolName: toolName,
                        message: "The selected target has no current entry for this edit mode. Read the current target and use exact existing entry IDs, or choose insertion for a new exercise. No tool was executed.")
                }
                if matching.count == 1 {
                    result.removeValue(forKey: "anyOf")
                    result.merge(matching[0]) { _, value in value }
                } else { result["anyOf"] = matching }
            }
            for (key, value) in result {
                if let object = value as? [String: Any] { result[key] = try refine(object) }
                else if let array = value as? [[String: Any]] { result[key] = try array.map(refine) }
            }
            return result
        }
        return try Self(json: refine(json), name: name)
    }
}

extension FoundationModelsMutationSchema {
    /// Only used after the model selects retaining existing set counts. The
    /// alternate intent keeps the complete 1...50 set-edit capability. Different
    /// counts use separate entry-scoped variants; the app never duplicates sets.
    func preservingSetCounts(in schema: FoundationModelsSchema, toolName: String) throws -> FoundationModelsSchema {
        let eligible = targets.filter { toolName != "propose_template_version" || ($0.kind == "template" && $0.versionID != nil) }
        let references = Dictionary(uniqueKeysWithValues: eligible.enumerated().map { ("#/$defs/EntryID_\($0.offset)", $0.element.entries) })
        func refine(_ object: [String: Any]) throws -> [String: Any] {
            var result = object
            if var properties = object["properties"] as? [String: [String: Any]],
               properties["operation"]?["enum"] as? [String] == ["update"],
               let reference = properties["entry_id"]?["$ref"] as? String, let entries = references[reference],
               var sets = properties["sets"] {
                let groups = Dictionary(grouping: entries, by: \.setCount).sorted { $0.key < $1.key }
                if groups.count == 1, let count = groups.first?.key {
                    sets["minItems"] = count
                    sets["maxItems"] = count
                    properties["sets"] = sets
                    result["properties"] = properties
                } else if !groups.isEmpty {
                    result.removeValue(forKey: "properties")
                    result.removeValue(forKey: "required")
                    result.removeValue(forKey: "type")
                    result.removeValue(forKey: "additionalProperties")
                    result["anyOf"] = groups.map { count, entries in
                        var variant = object
                        variant.removeValue(forKey: "$defs")
                        var fields = properties
                        var bounded = sets
                        bounded["minItems"] = count
                        bounded["maxItems"] = count
                        fields["sets"] = bounded
                        fields["entry_id"] = ["type": "string", "enum": entries.map(\.id)]
                        variant["properties"] = fields
                        variant["title"] = "UpdateEntryWith\(count)Sets_" + reference.replacingOccurrences(of: "#/$defs/", with: "")
                        return variant
                    }
                }
            }
            for (key, value) in result {
                if let child = value as? [String: Any] { result[key] = try refine(child) }
                else if let children = value as? [[String: Any]] { result[key] = try children.map(refine) }
            }
            return result
        }
        return try FoundationModelsSchema(json: refine(schema.json), name: schema.name)
    }
}
