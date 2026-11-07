import AppIntents
import Foundation

// Foreground execution keeps all writes in the app's single main-actor store and
// requires the device to unlock. No extension opens a competing database writer.
struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Empty Workout"
    static var description = IntentDescription("Start an empty workout in Lift Log.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try SiriWorkoutActions.start(store: AppWorkoutStore.shared, templateID: nil)
        return .result(dialog: "\(message)")
    }
}

struct StartTemplateWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Workout from Template"
    static var description = IntentDescription("Start the current version of a saved workout template.")
    static var openAppWhenRun = true
    @Parameter(title: "Template") var template: WorkoutTemplateEntity
    static var parameterSummary: some ParameterSummary { Summary("Start \(\.$template)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try SiriWorkoutActions.start(store: AppWorkoutStore.shared, templateID: template.id)
        return .result(dialog: "\(message)")
    }
}

struct EndWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "End Workout"
    static var description = IntentDescription("Finish the current workout and save completed sets. Incomplete sets are omitted.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppWorkoutStore.shared
        guard let workout = store.activeWorkout else { throw WorkoutIntentError.noWorkout }
        try await requestConfirmation(result: .result(dialog: "End \(workout.name) and save completed sets? Incomplete sets will be omitted."))
        guard store.activeWorkout == workout else { throw WorkoutIntentError.workoutChanged }
        let message = try SiriWorkoutActions.finish(store: store, expectedWorkoutID: workout.id)
        return .result(dialog: "\(message)")
    }
}

struct AddWorkoutExerciseIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Exercise to Workout"
    static var description = IntentDescription("Add an exercise to the current workout with one set of 10 reps at zero weight. Adjust the values in the app.")
    static var openAppWhenRun = true
    @Parameter(title: "Exercise") var exercise: CatalogExerciseEntity
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$exercise) to the current workout") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppWorkoutStore.shared
        guard let workout = store.activeWorkout else { throw WorkoutIntentError.noWorkout }
        let message = try SiriWorkoutActions.add(store: store, exerciseID: exercise.id, expectedWorkoutID: workout.id)
        return .result(dialog: "\(message)")
    }
}

struct RemoveWorkoutExerciseIntent: AppIntent {
    static var title: LocalizedStringResource = "Remove Exercise from Workout"
    static var description = IntentDescription("Remove a selected exercise from the current workout. Exercises with completed sets must be edited in the app.")
    static var openAppWhenRun = true
    @Parameter(title: "Exercise") var exercise: ActiveExerciseEntity
    static var parameterSummary: some ParameterSummary { Summary("Remove \(\.$exercise) from the current workout") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppWorkoutStore.shared
        guard let workout = store.activeWorkout, workout.id == exercise.workoutID,
              workout.exercises.contains(where: { $0.id == exercise.entryID }) else { throw WorkoutIntentError.workoutChanged }
        try await requestConfirmation(result: .result(dialog: "Remove \(exercise.name), exercise \(exercise.position), from the current workout?"))
        guard store.activeWorkout == workout else { throw WorkoutIntentError.workoutChanged }
        let message = try SiriWorkoutActions.remove(store: store, entryID: exercise.entryID, expectedWorkoutID: exercise.workoutID)
        return .result(dialog: "\(message)")
    }
}

struct CompleteWorkoutSetIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Workout Set"
    static var description = IntentDescription("Mark a selected set completed using its currently entered weight and reps, and start its rest timer when applicable.")
    static var openAppWhenRun = true
    @Parameter(title: "Set") var set: ActiveSetEntity
    static var parameterSummary: some ParameterSummary { Summary("Complete \(\.$set)") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try SiriWorkoutActions.complete(store: AppWorkoutStore.shared, entryID: set.entryID, setID: set.setID, expectedWorkoutID: set.workoutID)
        return .result(dialog: "\(message)")
    }
}

private enum WorkoutIntentError: LocalizedError {
    case noWorkout
    case workoutChanged
    var errorDescription: String? {
        switch self {
        case .noWorkout: "There is no active workout. Start a workout first."
        case .workoutChanged: "The workout changed. Please try again with the current workout."
        }
    }
}

struct LiftLogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartWorkoutIntent(), phrases: ["Start a workout in \(.applicationName)"], shortTitle: "Start Workout", systemImageName: "play.fill")
        AppShortcut(intent: StartTemplateWorkoutIntent(), phrases: ["Start \(\.$template) in \(.applicationName)", "Start a template workout in \(.applicationName)"], shortTitle: "Start Template", systemImageName: "list.bullet.clipboard")
        AppShortcut(intent: EndWorkoutIntent(), phrases: ["End my workout in \(.applicationName)"], shortTitle: "End Workout", systemImageName: "stop.fill")
        AppShortcut(intent: AddWorkoutExerciseIntent(), phrases: ["Add an exercise in \(.applicationName)", "Add \(\.$exercise) in \(.applicationName)"], shortTitle: "Add Exercise", systemImageName: "plus")
        AppShortcut(intent: RemoveWorkoutExerciseIntent(), phrases: ["Remove an exercise in \(.applicationName)"], shortTitle: "Remove Exercise", systemImageName: "minus")
        AppShortcut(intent: CompleteWorkoutSetIntent(), phrases: ["Complete a set in \(.applicationName)"], shortTitle: "Complete Set", systemImageName: "checkmark")
    }
}
