import Foundation

/// A display snapshot whose record is resolved by kind and ID when a message is sent.
struct AssistantWorkoutReference: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case template, workout }

    let kind: Kind
    let id: UUID
    let name: String
    let startedAt: Date?
    let finishedAt: Date?

    init(kind: Kind, id: UUID, name: String, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
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
        self.init(kind: .template, id: template.id, name: template.name)
    }

    init(workout: WorkoutSession) {
        self.init(kind: .workout, id: workout.id, name: workout.name,
                  startedAt: workout.startedAt, finishedAt: workout.finishedAt)
    }
}
