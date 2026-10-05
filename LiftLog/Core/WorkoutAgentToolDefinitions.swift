import Foundation

extension WorkoutAgentTools {
    /// Responses namespace wrapper required by the ChatGPT plan inference route.
    static var definitions: [[String: Any]] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        func string(_ choices: [String]? = nil, nullable: Bool = false) -> [String: Any] {
            var value: [String: Any] = ["type": nullable ? ["string", "null"] : "string"]
            if let choices { value["enum"] = nullable ? choices.map { $0 as Any } + [NSNull()] : choices }
            return value
        }
        func function(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
            ["type": "function", "name": name, "description": description, "parameters": object(properties), "strict": true]
        }
        let set = object(["weight": ["type": "number", "minimum": 0, "maximum": 1_000_000],
                          "reps": ["type": "integer", "minimum": 1, "maximum": 10_000]])
        let sets: [String: Any] = ["type": "array", "items": set, "minItems": 1, "maxItems": 50]
        let entry = object(["exercise_id": string(), "sets": sets])
        let create: [String: Any] = ["name": ["type": "string", "minLength": 1, "maxLength": 120],
                                      "unit": string(["lb", "kg"]),
                                      "exercises": ["type": "array", "items": entry, "minItems": 1, "maxItems": 100]]
        var nullableSets = sets
        nullableSets["type"] = ["array", "null"]
        let operations: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 100,
                                       "items": object(["operation": string(["add", "update", "remove"]), "entry_id": string(nullable: true),
                                                        "exercise_id": string(nullable: true), "sets": nullableSets])]
        let tools = [
            function("get_workout_data", "Read current unit, full active workout, and counts. Use other read tools for saved templates and completed history.", [:]),
            function("get_templates", "Read each template's current prescription, unit, exercise entry IDs, currentVersionID, and currentVersionNumber. Weights use the returned unit. Saved version history is omitted; use get_template_versions for older prescriptions.", [:]),
            function("get_template_versions", "Read immutable saved template versions newest first, including version ID/number, creation date, original unit, and prescribed sets. Versions may use different units. Paginated with total and offset.",
                     ["template_id": string(), "limit": ["type": "integer", "minimum": 1, "maximum": 20], "offset": ["type": "integer", "minimum": 0]]),
            function("get_history", "Read actual completed workouts with recorded session units, paginated with total and offset. Never infer completion from a template.",
                     ["limit": ["type": "integer", "minimum": 1, "maximum": 100], "offset": ["type": "integer", "minimum": 0]]),
            function("get_exercise_catalog", "Search the offline exercise catalog by name and retrieve IDs for proposals. Empty query matches all. Paginated with total and offset.",
                     ["query": string(), "limit": ["type": "integer", "minimum": 1, "maximum": 100], "offset": ["type": "integer", "minimum": 0]]),
            function("graph_workout_history", "Create a native chart of actual completed sets in saved history. Volume is sum(weight × reps); max_weight is maximum completed load per session. No invented points. This is a chart, not general image generation. Dates are inclusive ISO 8601 timestamps; null includes all dates/exercises.",
                     ["metric": string(["volume", "max_weight", "completed_sets"]), "exercise_id": string(nullable: true),
                      "unit": string(["lb", "kg"]), "start_date": string(nullable: true), "end_date": string(nullable: true)]),
            function("propose_create_template", "Propose a new named template using catalog exercise IDs and sets. Weight is interpreted in the supplied unit and converted locally. Does not save until the user reviews and taps Apply.", create),
            function("propose_create_workout", "Propose a new active workout with uncompleted prescribed sets. Fails if a workout is active. Does not start until the user reviews and taps Apply. Never records completed work.", create),
            function("propose_edit_exercise", "Propose add/update/remove of one exercise entry in a saved template or active workout. Template edits save a new default version and preserve previous prescriptions after user review. target_id is the template/session ID; entry_id is the entry ID for update/remove and null for add. exercise_id and sets are required for add/update, null for remove. For the same exercise in an active workout, existing set IDs and original planned targets are preserved while actual weight/reps change. Updating entries containing completed sets is blocked. Removing a completed entry requires visible user review and does not change history. Weight is converted from supplied unit to target unit. User review is required to save.",
                     ["target": string(["template", "active_workout"]), "target_id": string(), "operation": string(["add", "update", "remove"]),
                      "entry_id": string(nullable: true), "exercise_id": string(nullable: true), "sets": nullableSets, "unit": string(["lb", "kg"])]),
            function("propose_edit_workout_exercises", "Propose multiple exercise edits to one template or active workout as ONE atomic reviewed change. Prefer this tool when a request changes multiple entries. Same operation rules as propose_edit_exercise; all operations validate before a proposal is produced.",
                     ["target": string(["template", "active_workout"]), "target_id": string(), "unit": string(["lb", "kg"]),
                      "operations": operations]),
            function("propose_template_version", "Plan the next workout by proposing a new default version of an existing template. Read get_templates first and pass its currentVersionID as base_version_id; outdated versions are rejected. Use add/update/remove operations and supply every prescribed set for an updated entry. Increment reps or weight only as requested. Weights use supplied unit and are converted locally. Changes require explicit user review and Apply, preserve earlier versions and recorded workouts, and become the default for future workouts.",
                     ["template_id": string(), "base_version_id": string(), "unit": string(["lb", "kg"]), "operations": operations])
        ]
        return [["type": "namespace", "name": "liftlog", "description": "Read local workout data, chart completed workouts, and propose changes for explicit user review.", "tools": tools]]
    }
}
