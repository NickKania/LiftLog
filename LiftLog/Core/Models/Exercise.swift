import Foundation

protocol SupersetExercise: Identifiable where ID == UUID {
    var supersetID: UUID? { get set }
}

enum SupersetGrouping {
    /// Replaces the anchor's group with the selected entries, without reordering them.
    static func update<T: SupersetExercise>(_ exercises: inout [T], anchorID: UUID, selectedIDs: Set<UUID>) {
        guard let anchor = exercises.first(where: { $0.id == anchorID }) else { return }
        let selected = selectedIDs.union([anchorID]).intersection(Set(exercises.map(\.id)))
        let groupID = selected.count >= 2 ? (anchor.supersetID ?? UUID()) : nil
        for index in exercises.indices {
            if selected.contains(exercises[index].id) {
                exercises[index].supersetID = groupID
            } else if let previousGroup = anchor.supersetID, exercises[index].supersetID == previousGroup {
                exercises[index].supersetID = nil
            }
        }
        normalize(&exercises)
    }

    /// A group must have at least two surviving entries in its own workout or template.
    static func normalize<T: SupersetExercise>(_ exercises: inout [T]) {
        let counts = Dictionary(exercises.compactMap(\.supersetID).map { ($0, 1) }, uniquingKeysWith: +)
        for index in exercises.indices {
            if let id = exercises[index].supersetID, counts[id, default: 0] < 2 {
                exercises[index].supersetID = nil
            }
        }
    }
}

struct Exercise: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var category: String

    static func normalizedName(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    init(id: UUID = UUID(), name: String, category: String = "Other") {
        self.id = id
        self.name = name
        self.category = category
    }
}
