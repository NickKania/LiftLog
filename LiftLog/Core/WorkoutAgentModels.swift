import Foundation

struct WorkoutAgentToolResult {
    let outputJSONString: String
    let proposal: WorkoutAgentProposal?
    let chart: WorkoutAgentChart?
}

/// The current prescription, without copying the entire saved version history into every tool call.
struct WorkoutAgentTemplateSnapshot: Encodable {
    let id: UUID
    let name: String
    let exercises: [TemplateExercise]
    let restSeconds: Int
    let unit: WeightUnit
    let currentVersionID: UUID?
    let currentVersionNumber: Int?

    init(template: WorkoutTemplate, unit: WeightUnit) {
        id = template.id
        name = template.name
        exercises = template.exercises
        restSeconds = template.restSeconds
        self.unit = unit
        currentVersionID = template.currentVersion?.id
        currentVersionNumber = template.currentVersion?.number
    }
}

struct WorkoutAgentProposal: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case pending, applied, rejected, stale }
    let id: UUID
    let summary: String
    var status: Status
    let beforeTemplate: WorkoutTemplate?
    let afterTemplate: WorkoutTemplate?
    let beforeWorkout: WorkoutSession?
    let afterWorkout: WorkoutSession?
    let unit: WeightUnit
}

/// Semantic chart data computed locally from completed history, never model-authored points.
struct WorkoutAgentChart: Codable, Equatable, Identifiable {
    enum Metric: String, Codable, CaseIterable {
        case volume
        case maxWeight = "max_weight"
        case completedSets = "completed_sets"

        var label: String {
            switch self {
            case .volume: return "Completed volume"
            case .maxWeight: return "Maximum weight"
            case .completedSets: return "Completed sets"
            }
        }
    }
    struct Point: Codable, Equatable, Identifiable {
        let id: UUID
        let date: Date
        let value: Double
        let workoutName: String
    }
    let id: UUID
    let title: String
    let metric: Metric
    let unit: WeightUnit?
    let points: [Point]
}

enum WorkoutAgentToolError: LocalizedError, Equatable {
    case invalidArguments(String)
    case unknownTool
    case missingTarget
    case activeWorkoutExists
    case completedSetsProtected
    case unknownProposal
    case proposalAlreadyResolved
    case staleProposal
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): return message
        case .unknownTool: return "This workout tool is not supported."
        case .missingTarget: return "The selected workout, template, exercise, or entry no longer exists."
        case .activeWorkoutExists: return "Finish or discard your active workout before creating another."
        case .completedSetsProtected: return "Completed sets are recorded work. Edit an exercise with only uncompleted sets."
        case .unknownProposal: return "This proposal is not available for review."
        case .proposalAlreadyResolved: return "This proposal has already been resolved."
        case .staleProposal: return "Your workout data changed after this proposal. Request a fresh proposal."
        case .persistence(let message): return message
        }
    }
}
