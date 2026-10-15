import Foundation

/// Personal instruction text, separate from replaceable catalog content and workout snapshots.
struct ExerciseInstructionOverride: Codable, Equatable, Identifiable {
    var exerciseID: UUID
    var steps: [String]
    var id: UUID { exerciseID }
}
