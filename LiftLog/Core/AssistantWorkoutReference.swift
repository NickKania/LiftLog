import Foundation

/// A display snapshot whose record is resolved by kind and ID when a message is sent.
struct AssistantWorkoutReference: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case template, workout, health }

    let kind: Kind
    let id: UUID
    let name: String
    let startedAt: Date?
    let finishedAt: Date?
    let summary: String?
    let templateVersionNumber: Int?

    init(kind: Kind, id: UUID, name: String, startedAt: Date? = nil, finishedAt: Date? = nil, summary: String? = nil, templateVersionNumber: Int? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.templateVersionNumber = templateVersionNumber
    }

    /// Templates and workout sessions may legitimately share a UUID.
    var key: String { "\(kind.rawValue):\(id.uuidString)" }
    var isActive: Bool { kind != .template && finishedAt == nil }

    var subtitle: String {
        guard kind != .template else {
            return templateVersionNumber.map { "Template · Version \($0)" } ?? "Template"
        }
        let status = kind == .health ? (isActive ? "Apple Health · Active session" : "Apple Health · Completed session") : (isActive ? "Active workout" : "Completed workout")
        guard let startedAt else { return status }
        return "\(status) · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    init(template: WorkoutTemplate) {
        let exerciseNames = template.exercises.prefix(3).map { $0.exercise.name }.joined(separator: ", ")
        let count = template.exercises.count
        let sets = template.exercises.reduce(0) { $0 + $1.sets.count }
        self.init(kind: .template, id: template.id, name: template.name,
                  summary: "\(count) \(count == 1 ? "exercise" : "exercises") · \(sets) \(sets == 1 ? "set" : "sets") · \(exerciseNames)\(count > 3 ? ", …" : "")",
                  templateVersionNumber: template.currentVersion?.number)
    }

    /// Selecting this reference grants health sharing for this message only.
    init(healthWorkout: WorkoutSession) {
        self.init(kind: .health, id: healthWorkout.id, name: healthWorkout.name,
                  startedAt: healthWorkout.startedAt, finishedAt: healthWorkout.finishedAt,
                  summary: "Share this session’s Apple Health data for this message only")
    }

    init(workout: WorkoutSession) {
        self.init(kind: .workout, id: workout.id, name: workout.name,
                  startedAt: workout.startedAt, finishedAt: workout.finishedAt)
    }
}
