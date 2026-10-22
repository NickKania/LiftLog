import Foundation

extension WorkoutStore {
    var watchWorkoutState: WatchWorkoutState {
        WatchWorkoutState(templates: templates.map { template in
            WatchTemplateSummary(id: template.id, name: template.name,
                                 exerciseCount: template.exercises.count,
                                 setCount: template.exercises.reduce(0) { $0 + $1.sets.count })
        }, active: activeWorkout.map { workout in
            WatchActiveWorkout(id: workout.id, name: workout.name, startedAt: workout.startedAt,
                               restSeconds: workout.restSeconds, restEndsAt: workout.restTimer?.endsAt,
                               restTimerID: workout.restTimer?.id, exercises: workout.exercises.map { exercise in
                WatchExerciseState(id: exercise.id, name: exercise.exercise.name, supersetID: exercise.supersetID,
                                   sets: exercise.sets.map { set in
                    WatchSetState(id: set.id, weight: set.weight, reps: set.reps,
                                  targetWeight: set.targetWeight, targetReps: set.targetReps,
                                  isCompleted: set.isCompleted)
                })
            })
        }, unitRaw: (activeWorkout?.unit ?? unit).rawValue, revision: revision)
    }

    /// All writes use the same validation, rest derivation and atomic commit as phone edits.
    @discardableResult
    func applyWatchAction(_ action: WatchAction, now: Date = Date()) -> Bool {
        switch action {
        case .startTemplate(let id):
            guard activeWorkout == nil, let template = templates.first(where: { $0.id == id }) else { return false }
            return startWorkout(template: template)
        case .startEmpty:
            guard activeWorkout == nil else { return false }
            return startWorkout(template: nil)
        case .completeSet(let setID, let weight, let reps, let completedAt, let restTimerID):
            guard completedAt.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
                  var workout = activeWorkout,
                  let exerciseIndex = workout.exercises.firstIndex(where: { $0.sets.contains { $0.id == setID } }),
                  let setIndex = workout.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }),
                  !workout.exercises[exerciseIndex].sets[setIndex].isCompleted else { return false }
            // Phone numeric edits apply to every incomplete set in this entry, even earlier
            // ones completed out of order. Completed results and original targets stay fixed.
            workout.exercises[exerciseIndex].updateSetValues(weight: weight, reps: reps)
            workout.exercises[exerciseIndex].sets[setIndex].isCompleted = true
            return updateActiveWorkout(workout, now: min(completedAt, now), newRestTimerID: restTimerID)
        case .uncompleteSet(let setID):
            guard var workout = activeWorkout,
                  let exerciseIndex = workout.exercises.firstIndex(where: { $0.sets.contains { $0.id == setID } }),
                  let setIndex = workout.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }),
                  workout.exercises[exerciseIndex].sets[setIndex].isCompleted else { return false }
            workout.exercises[exerciseIndex].sets[setIndex].isCompleted = false
            return updateActiveWorkout(workout)
        case .skipRest(let workoutID, let restTimerID):
            guard activeWorkout?.id == workoutID, activeWorkout?.restTimer?.id == restTimerID else { return false }
            return skipRest()
        case .extendRest(let workoutID, let restTimerID, let seconds, let requestedAt, let resultingRestTimerID):
            guard requestedAt.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite,
                  activeWorkout?.id == workoutID, activeWorkout?.restTimer?.id == restTimerID else { return false }
            return extendRest(by: seconds, now: min(requestedAt, now), resultingRestTimerID: resultingRestTimerID)
        case .finish(let workoutID):
            guard activeWorkout?.id == workoutID else { return false }
            return finishWorkout()
        case .discard(let workoutID):
            guard activeWorkout?.id == workoutID else { return false }
            return discardWorkout()
        }
    }
}
