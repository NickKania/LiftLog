import Foundation

/// Projects the exercises in a workout into the order in which their sets are
/// performed. A superset's exercises stay together, with one round containing
/// the next available set from each member.
enum WorkoutSetList {
    struct Row: Identifiable, Equatable {
        /// The set identity is also the row identity, so SwiftUI updates the
        /// existing input row when another set is completed or edited.
        let id: UUID
        let exerciseID: UUID
        let setID: UUID
        let setIndex: Int

        init(exerciseID: UUID, setID: UUID, setIndex: Int) {
            self.id = setID
            self.exerciseID = exerciseID
            self.setID = setID
            self.setIndex = setIndex
        }
    }

    struct Section: Identifiable, Equatable {
        /// The first entry's identity remains stable when the section's sets
        /// change. For a superset this is the first member in workout order.
        let id: UUID
        let exercises: [WorkoutExercise]
        let rows: [Row]

        var isSuperset: Bool { exercises.count > 1 }

        fileprivate init(exercises: [WorkoutExercise]) {
            self.id = exercises[0].id
            self.exercises = exercises

            let setCount = exercises.map(\.sets.count).max() ?? 0
            var rows: [Row] = []
            rows.reserveCapacity(exercises.reduce(0) { $0 + $1.sets.count })
            for setIndex in 0..<setCount {
                for exercise in exercises {
                    guard exercise.sets.indices.contains(setIndex) else { continue }
                    let set = exercise.sets[setIndex]
                    rows.append(Row(exerciseID: exercise.id, setID: set.id, setIndex: setIndex))
                }
            }
            self.rows = rows
        }
    }

    /// Builds display sections while preserving the original exercise order.
    /// Entries with a valid shared `supersetID` are merged into the section at
    /// the first member's position. Singleton and orphan group IDs behave as
    /// ordinary individual exercises.
    static func sections(for exercises: [WorkoutExercise]) -> [Section] {
        let groupCounts = Dictionary(
            exercises.compactMap { exercise in exercise.supersetID.map { ($0, 1) } },
            uniquingKeysWith: +
        )
        let validGroups = Set(groupCounts.compactMap { groupID, count in count >= 2 ? groupID : nil })
        var consumedGroups = Set<UUID>()
        var sections: [Section] = []
        sections.reserveCapacity(exercises.count)

        for exercise in exercises {
            guard let groupID = exercise.supersetID, validGroups.contains(groupID) else {
                sections.append(Section(exercises: [exercise]))
                continue
            }
            guard consumedGroups.insert(groupID).inserted else { continue }
            sections.append(Section(exercises: exercises.filter { $0.supersetID == groupID }))
        }
        return sections
    }
}
