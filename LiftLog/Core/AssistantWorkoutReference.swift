import Foundation

/// A display snapshot whose record is resolved by kind and ID when a message is sent.
struct AssistantWorkoutReference: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case template, workout }

    let kind: Kind
    let id: UUID
    let name: String
    let startedAt: Date?
    let finishedAt: Date?
    let summary: String?

    init(kind: Kind, id: UUID, name: String, startedAt: Date? = nil, finishedAt: Date? = nil, summary: String? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
    }

    /// Templates and workout sessions may legitimately share a UUID.
    var key: String { "\(kind.rawValue):\(id.uuidString)" }
    var isActive: Bool { kind == .workout && finishedAt == nil }

    var subtitle: String {
        guard kind == .workout else { return "Template" }
        let status = isActive ? "Active workout" : "Completed workout"
        guard let startedAt else { return status }
        return "\(status) · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    init(template: WorkoutTemplate) {
        let exerciseNames = template.exercises.prefix(3).map { $0.exercise.name }.joined(separator: ", ")
        let count = template.exercises.count
        let sets = template.exercises.reduce(0) { $0 + $1.sets.count }
        self.init(kind: .template, id: template.id, name: template.name,
                  summary: "\(count) \(count == 1 ? "exercise" : "exercises") · \(sets) \(sets == 1 ? "set" : "sets") · \(exerciseNames)\(count > 3 ? ", …" : "")")
    }

    init(workout: WorkoutSession) {
        self.init(kind: .workout, id: workout.id, name: workout.name,
                  startedAt: workout.startedAt, finishedAt: workout.finishedAt)
    }
}
