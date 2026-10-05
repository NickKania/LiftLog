import Foundation
import Observation

/// Owns local workout data. Mutations publish only after the SQLite transaction succeeds.
@Observable @MainActor
final class WorkoutStore {
    private(set) var templates: [WorkoutTemplate] = []
    private(set) var history: [WorkoutSession] = []
    private(set) var activeWorkout: WorkoutSession?
    private(set) var unit: WeightUnit = .lb
    private(set) var personalExercises: [Exercise] = []
    var exercises: [Exercise] { ExerciseCatalog.all + personalExercises }
    var errorMessage: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var loadFailure: String?
    /// Advances only after a successful atomic save; review drafts bind to this revision.
    @ObservationIgnored private(set) var revision: UInt64 = 0

    private typealias Snapshot = WorkoutSnapshot
    let cloudBackup: CloudBackupManager
    private(set) var isRestoring = false

    init(fileURL: URL? = nil, legacyFileURL: URL? = nil, cloudBackup: CloudBackupManager? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.cloudBackup = cloudBackup ?? CloudBackupManager(databaseURL: self.fileURL, available: fileURL == nil)
        let legacyURL = legacyFileURL ?? self.fileURL.deletingPathExtension().appendingPathExtension("json")
        do {
            let database = WorkoutDatabase(url: self.fileURL)
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let saved = try database.load(recoverInterruptedWrite: true)
                try Self.validate(saved)
                apply(Self.backfillingCatalog(saved))
            } else if FileManager.default.fileExists(atPath: legacyURL.path) {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: legacyURL))
                guard saved.version == 1 else { throw StoreError.invalid("This workout file uses an unsupported version.") }
                try Self.validate(saved)
                let migrated = Self.backfillingCatalog(saved)
                // Publish a complete database only after migration succeeds. Keep the original JSON.
                let staging = self.fileURL.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).sqlite")
                defer { try? FileManager.default.removeItem(at: staging) }
                try WorkoutDatabase(url: staging).save(migrated)
                try FileManager.default.moveItem(at: staging, to: self.fileURL)
                apply(migrated)
            } else {
                templates = Self.starterTemplates(catalog: exercises)
                _ = commit(snapshot)
            }
        } catch {
            let message = "Could not load your workouts: \(error.localizedDescription) Your saved data was preserved. Restore a backup in Settings or restore the saved file and relaunch."
            loadFailure = message
            errorMessage = message
        }
    }

    @discardableResult
    func saveTemplate(_ template: WorkoutTemplate) -> Bool {
        do {
            try Self.validate(template)
            var next = snapshot
            var trimmed = template
            trimmed.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for index in trimmed.exercises.indices {
                trimmed.exercises[index].exercise = Self.register(trimmed.exercises[index].exercise, in: &next)
            }
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
            var workout = WorkoutSession(
                templateID: template?.id,
                name: template?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Workout",
                unit: unit,
                exercises: template?.exercises.map { item in
                    WorkoutExercise(exercise: item.exercise, sets: item.sets.map {
                        WorkoutSet(weight: $0.weight, reps: $0.targetReps, targetReps: $0.targetReps)
                    })
                } ?? []
            )
            for index in workout.exercises.indices {
                workout.exercises[index].exercise = Self.register(workout.exercises[index].exercise, in: &next)
            }
            next.activeWorkout = workout
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
            for index in updated.exercises.indices {
                updated.exercises[index].exercise = Self.register(updated.exercises[index].exercise, in: &next)
            }
            next.activeWorkout = updated
            return commit(next)
        } catch { return fail(error) }
    }

    /// Starts the exact reviewed draft in one commit without manufacturing completed work.
    @discardableResult
    func startReviewedWorkout(_ workout: WorkoutSession) -> Bool {
        guard activeWorkout == nil else {
            return fail(StoreError.invalid("Finish or discard your current workout before starting another."))
        }
        guard workout.finishedAt == nil, workout.importSourceKey == nil,
              workout.unit == unit, workout.templateID == nil,
              !history.contains(where: { $0.id == workout.id }),
              workout.exercises.allSatisfy({ !$0.sets.isEmpty && $0.sets.allSatisfy { !$0.isCompleted } }) else {
            return fail(StoreError.invalid("The proposed workout must contain only planned, uncompleted sets in your current unit."))
        }
        do {
            try Self.validate(workout)
            var next = snapshot
            var reviewed = workout
            reviewed.startedAt = Date()
            for index in reviewed.exercises.indices {
                reviewed.exercises[index].exercise = Self.register(reviewed.exercises[index].exercise, in: &next)
            }
            next.activeWorkout = reviewed
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
            var saved = session
            for index in saved.exercises.indices {
                saved.exercises[index].exercise = Self.register(saved.exercises[index].exercise, in: &next)
            }
            next.history.append(saved)
            imported += 1
        }
        next.history.sort { $0.startedAt > $1.startedAt }
        guard commit(next) else { return nil }
        return WorkoutImportResult(importedCount: imported, skippedDuplicateCount: duplicates)
    }

    private var snapshot: Snapshot {
        Snapshot(templates: templates, history: history, activeWorkout: activeWorkout, unit: unit, personalExercises: personalExercises)
    }

    private func apply(_ snapshot: Snapshot) {
        templates = snapshot.templates
        history = snapshot.history
        activeWorkout = snapshot.activeWorkout
        unit = snapshot.unit
        personalExercises = snapshot.personalExercises
    }

    /// Registers only in the proposed snapshot; failed writes and abandoned drafts publish nothing.
    /// Picker-created and unmatched import entries use Custom and adopt a reusable identity.
    /// Other supplied snapshots preserve their recorded metadata, including retired catalog entries.
    private static func register(_ exercise: Exercise, in snapshot: inout Snapshot) -> Exercise {
        let name = Exercise.normalizedName(exercise.name)
        if let canonical = ExerciseCatalog.all.first(where: { Exercise.normalizedName($0.name) == name }) {
            return exercise.category == "Custom" ? canonical : exercise
        }
        if let canonical = snapshot.personalExercises.first(where: { Exercise.normalizedName($0.name) == name }) {
            return exercise.category == "Custom" ? canonical : exercise
        }
        var personal = exercise
        personal.name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExerciseCatalog.all.contains(where: { $0.id == personal.id }) || snapshot.personalExercises.contains(where: { $0.id == personal.id }) {
            personal.id = UUID()
        }
        snapshot.personalExercises.append(personal)
        return exercise.category == "Custom" ? personal : exercise
    }

    /// Old workout snapshots stay byte-for-byte untouched on load. Their exercises become reusable
    /// in memory and join the same atomic snapshot on the next successful mutation.
    private static func backfillingCatalog(_ snapshot: Snapshot) -> Snapshot {
        var next = snapshot
        next.personalExercises = []
        let saved = snapshot.personalExercises
            + snapshot.history.flatMap { $0.exercises.map(\.exercise) }
            + snapshot.templates.flatMap { $0.exercises.map(\.exercise) }
            + (snapshot.activeWorkout?.exercises.map(\.exercise) ?? [])
        for exercise in saved { _ = register(exercise, in: &next) }
        return next
    }

    private func commit(_ next: Snapshot) -> Bool {
        guard loadFailure == nil else {
            errorMessage = loadFailure
            return false
        }
        do {
            try Self.validate(next)
            guard !isRestoring else { throw StoreError.invalid("Wait for the backup restore to finish before making changes.") }
            try WorkoutDatabase(url: fileURL).save(next)
            apply(next)
            revision &+= 1
            errorMessage = nil
            cloudBackup.scheduleBackup()
            return true
        } catch {
            errorMessage = "Could not save your workouts: \(error.localizedDescription)"
            return false
        }
    }

    func beginRestore() { isRestoring = true }
    func endRestore() { isRestoring = false }

    /// A valid standalone file replaces local storage atomically, even if the old database is damaged.
    func restoreDatabase(from source: URL) throws {
        let saved = try WorkoutDatabase(url: source).load()
        try Self.validate(saved)
        let restored = Self.backfillingCatalog(saved)
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent("restoring-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try WorkoutDatabase(url: staging).save(restored)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let recovery = folder.appendingPathComponent("before-restore-\(UUID().uuidString).sqlite")
            if loadFailure == nil {
                try WorkoutDatabase(url: fileURL).backup(to: recovery)
            } else {
                // Preserve damaged bytes when SQLite cannot open the current database.
                try FileManager.default.copyItem(at: fileURL, to: recovery)
            }
        }
        try Data(contentsOf: staging).write(to: fileURL, options: .atomic)
        apply(restored)
        loadFailure = nil
        errorMessage = nil
        cloudBackup.scheduleBackup()
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

    nonisolated private static func validateSet(weight: Double, reps: Int) throws {
        guard weight.isFinite, weight >= 0 else {
            throw StoreError.invalid("Weight must be a finite number of zero or more.")
        }
        guard reps > 0 else {
            throw StoreError.invalid("Reps must be greater than zero.")
        }
    }

    nonisolated private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalid("Enter a name before saving.")
        }
    }

    nonisolated private static func validate(_ template: WorkoutTemplate) throws {
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

    nonisolated private static func validate(_ workout: WorkoutSession) throws {
        try validateName(workout.name)
        guard workout.startedAt.timeIntervalSinceReferenceDate.isFinite,
              workout.finishedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= workout.startedAt }) ?? true else {
            throw StoreError.invalid("A workout contains invalid dates.")
        }
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

    nonisolated private static func validateIDs(_ ids: [UUID]) throws {
        guard Set(ids).count == ids.count else {
            throw StoreError.invalid("Workout items must have unique identifiers.")
        }
    }

    nonisolated static func validate(_ snapshot: WorkoutSnapshot) throws {
        try validateIDs(snapshot.personalExercises.map(\.id))
        for exercise in snapshot.personalExercises { try validateName(exercise.name) }
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
        return base.appendingPathComponent("LiftLog", isDirectory: true).appendingPathComponent("workouts.sqlite")
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
