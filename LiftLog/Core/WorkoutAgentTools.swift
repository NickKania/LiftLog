import Foundation
import CoreFoundation

/// The model can read and propose. Only a direct UI review action can call applyProposal.
@MainActor
final class WorkoutAgentTools {
    private let store: WorkoutStore
    private var proposals: [UUID: WorkoutAgentProposal] = [:]
    private var revisions: [UUID: UInt64] = [:]
    private var proposalOrder: [UUID] = []
    var pendingProposals: [WorkoutAgentProposal] {
        proposalOrder.compactMap { proposals[$0] }.filter { $0.status == .pending }
    }
    var definitions: [[String: Any]] { Self.definitions }

    init(store: WorkoutStore) { self.store = store }

    func proposal(_ id: UUID) -> WorkoutAgentProposal? { proposals[id] }

    func execute(name: String, arguments: String) throws -> WorkoutAgentToolResult {
        try execute(name: name, argumentsJSONString: arguments)
    }

    func execute(name: String, argumentsJSONString: String) throws -> WorkoutAgentToolResult {
        let toolName = name.hasPrefix("liftlog.") ? String(name.dropFirst(8)) : name
        guard argumentsJSONString.utf8.count <= 65_536,
              let data = argumentsJSONString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let args = object as? [String: Any] else {
            throw WorkoutAgentToolError.invalidArguments("Tool arguments must be a JSON object under 64 KB.")
        }
        switch toolName {
        case "get_workout_data":
            try keys(args, allowed: [])
            return try result(Overview(unit: store.unit, activeWorkout: store.activeWorkout,
                                       templateCount: store.templates.count, completedWorkoutCount: store.history.count))
        case "get_templates":
            try keys(args, allowed: [])
            return try result(store.templates.map { WorkoutAgentTemplateSnapshot(template: $0, unit: store.unit) })
        case "get_template_versions":
            try keys(args, allowed: ["template_id", "limit", "offset"])
            let templateID = try uuid(args, "template_id")
            guard let template = store.templates.first(where: { $0.id == templateID }) else { throw WorkoutAgentToolError.missingTarget }
            let limit = try integer(args, "limit", default: 5, range: 1...20)
            let offset = try integer(args, "offset", default: 0, range: 0...Int.max)
            return try result(TemplateVersionsPage(templateID: template.id, currentVersionID: template.currentVersion?.id,
                                                  versions: Array(template.versions.reversed().dropFirst(offset).prefix(limit)),
                                                  total: template.versions.count, offset: offset))
        case "get_history":
            try keys(args, allowed: ["limit", "offset"])
            let limit = try integer(args, "limit", default: 20, range: 1...100)
            let offset = try integer(args, "offset", default: 0, range: 0...Int.max)
            let sessions = Array(store.history.sorted { $0.startedAt > $1.startedAt }.dropFirst(offset).prefix(limit))
            return try result(HistoryPage(workouts: sessions, total: store.history.count, offset: offset))
        case "get_exercise_catalog":
            try keys(args, allowed: ["query", "limit", "offset"])
            let query = try optionalString(args, "query") ?? ""
            guard query.count <= 120 else { throw invalid("Search text is too long.") }
            let limit = try integer(args, "limit", default: 50, range: 1...100)
            let offset = try integer(args, "offset", default: 0, range: 0...Int.max)
            let matches = store.exercises.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            return try result(CatalogPage(exercises: Array(matches.dropFirst(offset).prefix(limit)), total: matches.count, offset: offset))
        case "graph_workout_history": return try graph(args)
        case "propose_create_template", "propose_create_workout":
            try keys(args, allowed: ["name", "unit", "exercises"])
            let name = try boundedName(args, "name")
            let inputUnit = try unit(args, "unit")
            let entries = try exerciseEntries(args, inputUnit: inputUnit, outputUnit: store.unit)
            if toolName == "propose_create_template" {
                let template = WorkoutTemplate(name: name, exercises: entries)
                return try propose(summary: "Create template “\(name)”", afterTemplate: template)
            }
            guard store.activeWorkout == nil else { throw WorkoutAgentToolError.activeWorkoutExists }
            let workout = WorkoutSession(name: name, unit: store.unit, exercises: entries.map {
                workoutEntry($0)
            })
            return try propose(summary: "Start workout “\(name)”", afterWorkout: workout)
        case "propose_edit_exercise": return try register(editedProposal(args))
        case "propose_edit_workout_exercises": return try editExercises(args)
        case "propose_template_version":
            try keys(args, allowed: ["template_id", "base_version_id", "unit", "operations"])
            let templateID = try uuid(args, "template_id")
            let baseVersionID = try uuid(args, "base_version_id")
            guard let template = store.templates.first(where: { $0.id == templateID }) else { throw WorkoutAgentToolError.missingTarget }
            guard template.currentVersion?.id == baseVersionID else { throw WorkoutAgentToolError.staleProposal }
            return try editExercises(["target": "template", "target_id": templateID.uuidString,
                                      "unit": args["unit"] ?? NSNull(), "operations": args["operations"] ?? NSNull()])
        default: throw WorkoutAgentToolError.unknownTool
        }
    }

    /// Not exported as an inference tool. Call only from an explicit user review control.
    @discardableResult
    func applyProposal(_ id: UUID) throws -> WorkoutAgentProposal {
        guard var proposal = proposals[id] else { throw WorkoutAgentToolError.unknownProposal }
        guard proposal.status == .pending else { throw WorkoutAgentToolError.proposalAlreadyResolved }
        guard revisions[id] == store.revision else {
            proposal.status = .stale
            proposals[id] = proposal
            throw WorkoutAgentToolError.staleProposal
        }
        let saved: Bool
        if let template = proposal.afterTemplate {
            saved = store.saveTemplate(template, expectedUnit: proposal.unit)
        } else if let workout = proposal.afterWorkout {
            saved = proposal.beforeWorkout == nil ? store.startReviewedWorkout(workout) : store.updateActiveWorkout(workout)
        } else { throw WorkoutAgentToolError.unknownProposal }
        guard saved else { throw WorkoutAgentToolError.persistence(store.errorMessage ?? "Could not save the reviewed workout.") }
        proposal.status = .applied
        proposals[id] = proposal
        return proposal
    }

    @discardableResult
    func rejectProposal(_ id: UUID) throws -> WorkoutAgentProposal {
        guard var proposal = proposals[id] else { throw WorkoutAgentToolError.unknownProposal }
        guard proposal.status == .pending else { throw WorkoutAgentToolError.proposalAlreadyResolved }
        proposal.status = .rejected
        proposals[id] = proposal
        return proposal
    }

    private func editedProposal(_ args: [String: Any], templateDraft: WorkoutTemplate? = nil, workoutDraft: WorkoutSession? = nil) throws -> WorkoutAgentProposal {
        try keys(args, allowed: ["target", "target_id", "operation", "entry_id", "exercise_id", "sets", "unit"])
        let target = try requiredString(args, "target")
        let targetID = try uuid(args, "target_id")
        let operation = try requiredString(args, "operation")
        guard ["add", "update", "remove"].contains(operation) else { throw invalid("Operation must be add, update, or remove.") }
        let entryID = try optionalUUID(args, "entry_id")
        let inputUnit = try unit(args, "unit")
        if operation == "add" {
            guard entryID == nil else { throw invalid("Adding an exercise must not specify an existing entry ID.") }
        } else if entryID == nil { throw invalid("Updating or removing an exercise requires its entry ID.") }
        if operation == "remove" {
            guard isNull(args["sets"]), isNull(args["exercise_id"]) else { throw invalid("Removing an entry does not accept a replacement exercise or sets.") }
        }
        if target == "template" {
            guard let before = templateDraft ?? store.templates.first(where: { $0.id == targetID }) else { throw WorkoutAgentToolError.missingTarget }
            var after = before
            if operation == "add" {
                after.exercises.append(try templateEntry(args, inputUnit: inputUnit, outputUnit: store.unit))
            } else {
                guard let index = after.exercises.firstIndex(where: { $0.id == entryID }) else { throw WorkoutAgentToolError.missingTarget }
                if operation == "remove" { after.exercises.remove(at: index) }
                else {
                    var entry = try templateEntry(args, inputUnit: inputUnit, outputUnit: store.unit)
                    entry.id = after.exercises[index].id
                    for setIndex in entry.sets.indices where after.exercises[index].sets.indices.contains(setIndex) {
                        entry.sets[setIndex].id = after.exercises[index].sets[setIndex].id
                    }
                    after.exercises[index] = entry
                }
            }
            guard !after.exercises.isEmpty, after.exercises.count <= 100 else { throw invalid("A template needs between 1 and 100 exercise entries.") }
            return draft(summary: templateVersionSummary(before), beforeTemplate: before, afterTemplate: after)
        }
        guard target == "active_workout" else { throw invalid("Target must be template or active_workout.") }
        guard let before = workoutDraft ?? store.activeWorkout, before.id == targetID else { throw WorkoutAgentToolError.missingTarget }
        var after = before
        if operation == "add" {
            let entry = try templateEntry(args, inputUnit: inputUnit, outputUnit: before.unit)
            after.exercises.append(workoutEntry(entry))
        } else {
            guard let index = after.exercises.firstIndex(where: { $0.id == entryID }) else { throw WorkoutAgentToolError.missingTarget }
            guard operation == "remove" || !after.exercises[index].sets.contains(where: \.isCompleted) else { throw WorkoutAgentToolError.completedSetsProtected }
            if operation == "remove" { after.exercises.remove(at: index) }
            else {
                let entry = try templateEntry(args, inputUnit: inputUnit, outputUnit: before.unit)
                var replacement = workoutEntry(entry)
                replacement.id = after.exercises[index].id
                let existing = after.exercises[index]
                if existing.exercise.id == replacement.exercise.id {
                    for setIndex in replacement.sets.indices where existing.sets.indices.contains(setIndex) {
                        replacement.sets[setIndex].id = existing.sets[setIndex].id
                        replacement.sets[setIndex].targetReps = existing.sets[setIndex].targetReps
                        replacement.sets[setIndex].targetWeight = existing.sets[setIndex].targetWeight
                    }
                }
                after.exercises[index] = replacement
            }
        }
        guard after.exercises.count <= 100 else { throw invalid("A workout may contain at most 100 exercise entries.") }
        return draft(summary: "\(operation.capitalized) exercise in “\(before.name)”", beforeWorkout: before, afterWorkout: after, displayUnit: before.unit)
    }

    private func workoutEntry(_ entry: TemplateExercise) -> WorkoutExercise {
        WorkoutExercise(exercise: entry.exercise, sets: entry.sets.map {
            WorkoutSet(weight: $0.weight, reps: $0.targetReps, targetReps: $0.targetReps, targetWeight: $0.weight)
        })
    }

    private func exerciseEntries(_ args: [String: Any], inputUnit: WeightUnit, outputUnit: WeightUnit) throws -> [TemplateExercise] {
        guard let entries = args["exercises"] as? [[String: Any]], (1...100).contains(entries.count) else {
            throw invalid("Provide between 1 and 100 exercise entries.")
        }
        return try entries.map {
            try keys($0, allowed: ["exercise_id", "sets"])
            return try templateEntry($0, inputUnit: inputUnit, outputUnit: outputUnit)
        }
    }

    private func templateEntry(_ args: [String: Any], inputUnit: WeightUnit, outputUnit: WeightUnit) throws -> TemplateExercise {
        let id = try uuid(args, "exercise_id")
        guard let exercise = store.exercises.first(where: { $0.id == id }) else { throw WorkoutAgentToolError.missingTarget }
        guard let sets = args["sets"] as? [[String: Any]], (1...50).contains(sets.count) else { throw invalid("Provide between 1 and 50 sets per exercise.") }
        return TemplateExercise(exercise: exercise, sets: try sets.map { set in
            try keys(set, allowed: ["weight", "reps"])
            let weight = try number(set, "weight")
            guard weight >= 0, weight <= 1_000_000 else { throw invalid("Weight must be between 0 and 1,000,000.") }
            let reps = try integer(set, "reps", range: 1...10_000)
            return TemplateSet(weight: convert(weight, from: inputUnit, to: outputUnit), targetReps: reps)
        })
    }

    private func editExercises(_ args: [String: Any]) throws -> WorkoutAgentToolResult {
        try keys(args, allowed: ["target", "target_id", "unit", "operations"])
        guard let operations = args["operations"] as? [[String: Any]], (1...100).contains(operations.count) else {
            throw invalid("Provide between 1 and 100 exercise operations.")
        }
        var edited: WorkoutAgentProposal?
        var original: WorkoutAgentProposal?
        for operation in operations {
            try keys(operation, allowed: ["operation", "entry_id", "exercise_id", "sets"])
            var fields = operation
            for key in ["target", "target_id", "unit"] { fields[key] = args[key] }
            let next = try editedProposal(fields, templateDraft: edited?.afterTemplate, workoutDraft: edited?.afterWorkout)
            if original == nil { original = next }
            edited = next
        }
        guard let original, let edited else { throw invalid("No exercise edits were provided.") }
        return try propose(summary: original.beforeTemplate.map(templateVersionSummary) ?? "Apply \(operations.count) exercise edits",
                           beforeTemplate: original.beforeTemplate, afterTemplate: edited.afterTemplate,
                           beforeWorkout: original.beforeWorkout, afterWorkout: edited.afterWorkout, displayUnit: edited.unit)
    }

    private func templateVersionSummary(_ template: WorkoutTemplate) -> String {
        "Save version \((template.currentVersion?.number ?? 0) + 1) of “\(template.name)” for future workouts"
    }

    private func draft(summary: String, beforeTemplate: WorkoutTemplate? = nil, afterTemplate: WorkoutTemplate? = nil,
                       beforeWorkout: WorkoutSession? = nil, afterWorkout: WorkoutSession? = nil, displayUnit: WeightUnit? = nil) -> WorkoutAgentProposal {
        WorkoutAgentProposal(id: UUID(), summary: summary, status: .pending,
                             beforeTemplate: beforeTemplate, afterTemplate: afterTemplate,
                             beforeWorkout: beforeWorkout, afterWorkout: afterWorkout, unit: displayUnit ?? store.unit)
    }

    private func propose(summary: String, beforeTemplate: WorkoutTemplate? = nil, afterTemplate: WorkoutTemplate? = nil,
                         beforeWorkout: WorkoutSession? = nil, afterWorkout: WorkoutSession? = nil, displayUnit: WeightUnit? = nil) throws -> WorkoutAgentToolResult {
        try register(draft(summary: summary, beforeTemplate: beforeTemplate, afterTemplate: afterTemplate,
                           beforeWorkout: beforeWorkout, afterWorkout: afterWorkout, displayUnit: displayUnit))
    }

    private func register(_ proposal: WorkoutAgentProposal) throws -> WorkoutAgentToolResult {
        if let before = proposal.beforeTemplate, let after = proposal.afterTemplate,
           before.name == after.name, before.restSeconds == after.restSeconds, WorkoutStore.samePrescription(before.exercises, after.exercises) {
            throw invalid("The proposed template prescription is unchanged. Change reps, weight, or exercises to save a new version.")
        }
        guard pendingProposals.count < 20 else { throw invalid("Review or dismiss the pending proposals before creating more.") }
        proposals[proposal.id] = proposal
        revisions[proposal.id] = store.revision
        proposalOrder.append(proposal.id)
        return try result(ProposalReceipt(proposalID: proposal.id, status: "awaiting_user_review", summary: proposal.summary), proposal: proposal)
    }

    private func graph(_ args: [String: Any]) throws -> WorkoutAgentToolResult {
        try keys(args, allowed: ["metric", "exercise_id", "unit", "start_date", "end_date"])
        guard let metric = WorkoutAgentChart.Metric(rawValue: try requiredString(args, "metric")) else { throw invalid("Unsupported chart metric.") }
        let outputUnit = try unit(args, "unit")
        let exerciseID = try optionalUUID(args, "exercise_id")
        if let exerciseID, !store.exercises.contains(where: { $0.id == exerciseID }) { throw WorkoutAgentToolError.missingTarget }
        let start = try date(args, "start_date")
        let end = try date(args, "end_date")
        if let start, let end, start > end { throw invalid("Start date must be before end date.") }
        let points = try store.history.sorted { $0.startedAt < $1.startedAt }.compactMap { session -> WorkoutAgentChart.Point? in
            guard session.finishedAt != nil, start.map({ session.startedAt >= $0 }) ?? true,
                  end.map({ session.startedAt <= $0 }) ?? true else { return nil }
            let sets = session.exercises.filter { exerciseID == nil || $0.exercise.id == exerciseID }
                .flatMap(\.sets).filter(\.isCompleted)
            guard !sets.isEmpty else { return nil }
            let value: Double
            switch metric {
            case .volume: value = sets.reduce(0) { $0 + convert($1.weight, from: session.unit, to: outputUnit) * Double($1.reps) }
            case .maxWeight: value = sets.map { convert($0.weight, from: session.unit, to: outputUnit) }.max() ?? 0
            case .completedSets: value = Double(sets.count)
            }
            guard value.isFinite else { throw invalid("Saved values are too large to chart.") }
            return WorkoutAgentChart.Point(id: session.id, date: session.startedAt, value: value, workoutName: session.name)
        }
        let exerciseName = exerciseID.flatMap { id in store.exercises.first { $0.id == id }?.name }
        let chart = WorkoutAgentChart(id: UUID(), title: metric.label + (exerciseName.map { " · \($0)" } ?? ""), metric: metric,
                                      unit: metric == .completedSets ? nil : outputUnit, points: points)
        return try result(chart, chart: chart)
    }

    private func result<T: Encodable>(_ payload: T, proposal: WorkoutAgentProposal? = nil, chart: WorkoutAgentChart? = nil) throws -> WorkoutAgentToolResult {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return WorkoutAgentToolResult(outputJSONString: String(decoding: data, as: UTF8.self), proposal: proposal, chart: chart)
    }

    private struct Overview: Encodable { let unit: WeightUnit; let activeWorkout: WorkoutSession?; let templateCount: Int; let completedWorkoutCount: Int }
    private struct HistoryPage: Encodable { let workouts: [WorkoutSession]; let total: Int; let offset: Int }
    private struct CatalogPage: Encodable { let exercises: [Exercise]; let total: Int; let offset: Int }
    private struct TemplateVersionsPage: Encodable {
        let templateID: UUID
        let currentVersionID: UUID?
        let versions: [WorkoutTemplateVersion]
        let total: Int
        let offset: Int
    }
    private struct ProposalReceipt: Encodable { let proposalID: UUID; let status: String; let summary: String }

    private func invalid(_ message: String) -> WorkoutAgentToolError { .invalidArguments(message) }
    private func keys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw invalid("Unknown argument fields are not allowed.") }
    }
    private func isNull(_ value: Any?) -> Bool { value == nil || value is NSNull }
    private func optionalString(_ args: [String: Any], _ key: String) throws -> String? {
        guard !isNull(args[key]) else { return nil }
        guard let value = args[key] as? String else { throw invalid("\(key) must be a string.") }
        return value
    }
    private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(args, key) else { throw invalid("\(key) is required.") }
        return value
    }
    private func boundedName(_ args: [String: Any], _ key: String) throws -> String {
        let name = try requiredString(args, key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw invalid("A name must contain between 1 and 120 characters.") }
        return name
    }
    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(args, key)) else { throw invalid("\(key) must be a valid UUID.") }
        return id
    }
    private func optionalUUID(_ args: [String: Any], _ key: String) throws -> UUID? {
        guard !isNull(args[key]) else { return nil }
        return try uuid(args, key)
    }
    private func number(_ args: [String: Any], _ key: String) throws -> Double {
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw invalid("\(key) must be a finite number.")
        }
        return number.doubleValue
    }
    private func integer(_ args: [String: Any], _ key: String, default fallback: Int? = nil, range: ClosedRange<Int>) throws -> Int {
        if isNull(args[key]), let fallback { return fallback }
        let value = try number(args, key)
        guard value.rounded() == value, value >= Double(range.lowerBound), value < Double(Int.max), value <= Double(range.upperBound) else {
            throw invalid("\(key) must be an integer in the supported range.")
        }
        return Int(value)
    }
    private func unit(_ args: [String: Any], _ key: String) throws -> WeightUnit {
        guard let unit = WeightUnit(rawValue: try requiredString(args, key)) else { throw invalid("Weight unit must be lb or kg.") }
        return unit
    }
    private func date(_ args: [String: Any], _ key: String) throws -> Date? {
        guard let raw = try optionalString(args, key) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { throw invalid("\(key) must be an ISO 8601 date and time.") }
        return date
    }
    private func convert(_ weight: Double, from: WeightUnit, to: WeightUnit) -> Double {
        from == to ? weight : weight * (to == .kg ? 0.45359237 : 1 / 0.45359237)
    }
}
