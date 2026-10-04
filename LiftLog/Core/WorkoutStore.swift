import Foundation
import Observation

/// Owns local workout data. Mutations commit only after the atomic disk write succeeds.
@Observable @MainActor
final class WorkoutStore {
    private(set) var templates: [WorkoutTemplate] = []
    private(set) var history: [WorkoutSession] = []
    private(set) var activeWorkout: WorkoutSession?
    private(set) var unit: WeightUnit = .lb
    let exercises: [Exercise]
    var errorMessage: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var loadFailure: String?

    private struct Snapshot: Codable {
        var version = 1
        var templates: [WorkoutTemplate]
        var history: [WorkoutSession]
        var activeWorkout: WorkoutSession?
        var unit: WeightUnit
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        exercises = ExerciseCatalog.all
        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let data = try Data(contentsOf: self.fileURL)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                guard snapshot.version == 1 else {
                    throw StoreError.invalid("This workout file uses an unsupported version.")
                }
                try Self.validate(snapshot)
                apply(snapshot)
            } catch {
                let message = "Could not load your workouts: \(error.localizedDescription) Your saved file was preserved. Restore or move the file and relaunch to continue."
                loadFailure = message
                errorMessage = message
            }
        } else {
            templates = Self.starterTemplates(catalog: exercises)
            _ = commit(snapshot)
        }
    }

    @discardableResult
    func saveTemplate(_ template: WorkoutTemplate) -> Bool {
        do {
            try Self.validate(template)
            var next = snapshot
            var trimmed = template
            trimmed.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = next.templates.firstIndex(where: { $0.id == trimmed.id }) {
                next.templates[index] = trimmed
            } else {
                next.templates.append(trimmed)
            }
            return commit(next)
        } catch { return fail(error) }
    }

    @discardableResult
    func deleteTemplate(id: UUID) -> Bool {
        var next = snapshot
        next.templates.removeAll { $0.id == id }
        return commit(next)
    }

    @discardableResult
    func startWorkout(template: WorkoutTemplate? = nil) -> Bool {
        guard activeWorkout == nil else {
            return fail(StoreError.invalid("Finish or discard your current workout before starting another."))
        }
        do {
            if let template { try Self.validate(template) }
            var next = snapshot
            next.activeWorkout = WorkoutSession(
                templateID: template?.id,
                name: template?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Workout",
                unit: unit,
                exercises: template?.exercises.map { item in
                    WorkoutExercise(exercise: item.exercise, sets: item.sets.map {
                        WorkoutSet(weight: $0.weight, reps: $0.targetReps, targetReps: $0.targetReps)
                    })
                } ?? []
            )
            return commit(next)
        } catch { return fail(error) }
    }

    @discardableResult
    func updateActiveWorkout(_ workout: WorkoutSession) -> Bool {
        guard let activeWorkout, workout.id == activeWorkout.id else {
            return fail(StoreError.invalid("This workout is no longer active."))
        }
        do {
            try Self.validate(workout)
            var updated = workout
            // Session identity, start time, template reference, and recorded unit are fixed.
            updated.startedAt = activeWorkout.startedAt
            updated.templateID = activeWorkout.templateID
            updated.unit = activeWorkout.unit
            updated.finishedAt = nil
            var next = snapshot
            next.activeWorkout = updated
            return commit(next)
        } catch { return fail(error) }
    }

    @discardableResult
    func finishWorkout() -> Bool {
        guard var workout = activeWorkout else {
            return fail(StoreError.invalid("There is no active workout to finish."))
        }
        workout.exercises = workout.exercises.compactMap { item in
            var completed = item
            completed.sets = item.sets.filter(\.isCompleted)
            return completed.sets.isEmpty ? nil : completed
        }
        guard !workout.exercises.isEmpty else {
            return fail(StoreError.invalid("Complete at least one set before finishing your workout."))
        }
        workout.finishedAt = Date()
        var next = snapshot
        next.history.insert(workout, at: 0)
        next.activeWorkout = nil
        return commit(next)
    }

    @discardableResult
    func discardWorkout() -> Bool {
        var next = snapshot
        next.activeWorkout = nil
        return commit(next)
    }

    /// Converts template loads to the new preference; existing sessions keep their recorded unit.
    @discardableResult
    func setUnit(_ unit: WeightUnit) -> Bool {
        var next = snapshot
        let factor = unit == self.unit ? 1 : (unit == .kg ? 0.45359237 : 1 / 0.45359237)
        for templateIndex in next.templates.indices {
            for exerciseIndex in next.templates[templateIndex].exercises.indices {
                for setIndex in next.templates[templateIndex].exercises[exerciseIndex].sets.indices {
                    next.templates[templateIndex].exercises[exerciseIndex].sets[setIndex].weight *= factor
                }
            }
        }
        next.unit = unit
        return commit(next)
    }

    /// Imports finished sessions as a single disk commit. Source identity survives reloads.
    func importWorkouts(_ sessions: [WorkoutSession]) -> WorkoutImportResult? {
        var next = snapshot
        var keys = Set(next.history.compactMap(\.importSourceKey))
        var imported = 0
        var duplicates = 0
        for session in sessions {
            guard let key = session.importSourceKey, !key.isEmpty else {
                _ = fail(StoreError.invalid("An imported workout is missing its source identity."))
                return nil
            }
            guard session.startedAt.timeIntervalSince1970.isFinite,
                  let finished = session.finishedAt, finished.timeIntervalSince1970.isFinite,
                  finished >= session.startedAt,
                  finished.timeIntervalSince(session.startedAt) <= 7 * 24 * 3600 else {
                _ = fail(StoreError.invalid("An imported workout has an invalid start time or duration."))
                return nil
            }
            if !keys.insert(key).inserted { duplicates += 1; continue }
            next.history.append(session)
            imported += 1
        }
        next.history.sort { $0.startedAt > $1.startedAt }
        guard commit(next) else { return nil }
        return WorkoutImportResult(importedCount: imported, skippedDuplicateCount: duplicates)
    }

    private var snapshot: Snapshot {
        Snapshot(templates: templates, history: history, activeWorkout: activeWorkout, unit: unit)
    }

    private func apply(_ snapshot: Snapshot) {
        templates = snapshot.templates
        history = snapshot.history
        activeWorkout = snapshot.activeWorkout
        unit = snapshot.unit
    }

    private func commit(_ next: Snapshot) -> Bool {
        guard loadFailure == nil else {
            errorMessage = loadFailure
            return false
        }
        do {
            try Self.validate(next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(next)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            apply(next)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save your workouts: \(error.localizedDescription)"
            return false
        }
    }

    private func fail(_ error: Error) -> Bool {
        errorMessage = error.localizedDescription
        return false
    }

    private enum StoreError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    private static func validateSet(weight: Double, reps: Int) throws {
        guard weight.isFinite, weight >= 0 else {
            throw StoreError.invalid("Weight must be a finite number of zero or more.")
        }
        guard reps > 0 else {
            throw StoreError.invalid("Reps must be greater than zero.")
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalid("Enter a name before saving.")
        }
    }

    private static func validate(_ template: WorkoutTemplate) throws {
        try validateName(template.name)
        guard !template.exercises.isEmpty else {
            throw StoreError.invalid("Add at least one exercise to your template.")
        }
        try validateIDs(template.exercises.map(\.id))
        for item in template.exercises {
            try validateName(item.exercise.name)
            guard !item.sets.isEmpty else {
                throw StoreError.invalid("Each template exercise needs at least one set.")
            }
            try validateIDs(item.sets.map(\.id))
            for set in item.sets { try validateSet(weight: set.weight, reps: set.targetReps) }
        }
    }

    private static func validate(_ workout: WorkoutSession) throws {
        try validateName(workout.name)
        try validateIDs(workout.exercises.map(\.id))
        for item in workout.exercises {
            try validateName(item.exercise.name)
            try validateIDs(item.sets.map(\.id))
            for set in item.sets {
                try validateSet(weight: set.weight, reps: set.reps)
                if let targetReps = set.targetReps, targetReps <= 0 {
                    throw StoreError.invalid("Target reps must be greater than zero.")
                }
            }
        }
    }

    private static func validateIDs(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else {
            throw StoreError.invalid("Workout items must have unique identifiers.")
        }
    }

    private static func validate(_ snapshot: Snapshot) throws {
        try validateIDs(snapshot.templates.map(\.id))
        try validateIDs(snapshot.history.map(\.id))
        for template in snapshot.templates { try validate(template) }
        for workout in snapshot.history {
            try validate(workout)
            guard workout.finishedAt != nil, !workout.exercises.isEmpty,
                  workout.exercises.allSatisfy({ !$0.sets.isEmpty && $0.sets.allSatisfy(\.isCompleted) }) else {
                throw StoreError.invalid("Workout history contains an unfinished session.")
            }
        }
        if let workout = snapshot.activeWorkout {
            try validate(workout)
            guard workout.finishedAt == nil, !snapshot.history.contains(where: { $0.id == workout.id }) else {
                throw StoreError.invalid("The active workout is already finished.")
            }
        }
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LiftLog", isDirectory: true).appendingPathComponent("workouts.json")
    }

    private static func starterTemplates(catalog: [Exercise]) -> [WorkoutTemplate] {
        func item(_ index: Int, reps: Int = 8) -> TemplateExercise {
            TemplateExercise(exercise: catalog[index], sets: (0..<3).map { _ in TemplateSet(targetReps: reps) })
        }
        return [
            WorkoutTemplate(name: "Upper Body", exercises: [item(0), item(4), item(3), item(6, reps: 12)]),
            WorkoutTemplate(name: "Lower Body", exercises: [item(1), item(8), item(9, reps: 12)])
        ]
    }
}
