import ActivityKit
import Foundation

struct WorkoutActivityAttributes: ActivityAttributes {
    typealias ContentState = WorkoutActivitySnapshot
    let workoutID: UUID

    static let workoutURL = URL(string: "liftlog://workout")!
}
