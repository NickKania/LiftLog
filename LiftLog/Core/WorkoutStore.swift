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
    private(set) var favoriteExerciseIDs: [UUID] = []
    private(set) var exerciseInstructionOverrides: [ExerciseInstructionOverride] = []
    private(set) var defaultAssistantModel: String?
    var exercises: [Exercise] { ExerciseCatalog.all + personalExercises }
    var errorMessage: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var defaultAssistantModelKey = ""
    @ObservationIgnored private var loadFailure: String?
    /// Advances only after a successful atomic save; review drafts bind to this revision.
    @ObservationIgnored private(set) var revision: UInt64 = 0

    private typealias Snapshot = WorkoutSnapshot
    let cloudBackup: CloudBackupManager
    private(set) var isRestoring = false

    init(fileURL: URL? = nil, legacyFileURL: URL? = nil, cloudBackup: CloudBackupManager? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.defaultAssistantModelKey = "defaultAssistantModel.\(self.fileURL.standardizedFileURL.path)"
        self.defaultAssistantModel = UserDefaults.standard.string(forKey: defaultAssistantModelKey)
        self.cloudBackup = cloudBackup ?? CloudBackupManager(databaseURL: self.fileURL, available: fileURL == nil)
        let legacyURL = legacyFileURL ?? self.fileURL.deletingPathExtension().appendingPathExtension("json")
        do {
            let database = WorkoutDatabase(url: self.fileURL)
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let saved = try database.load(recoverInterruptedWrite: true)
                try Self.validate(saved)
                let migrated = Self.backfillingVersions(Self.backfillingCatalog(saved))
                if migrated.templates != saved.templates { try database.save(migrated) }
                apply(migrated)
            } else if FileManager.default.fileExists(atPath: legacyURL.path) {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: legacyURL))
                guard (1...2).contains(saved.version) else { throw StoreError.invalid("This workout file uses an unsupported version.") }
                try Self.validate(saved)
                let migrated = Self.backfillingExerciseReferences(Self.backfillingVersions(Self.backfillingCatalog(saved)))
                // Publish a complete database only after migration succeeds. Keep the original JSON.
                let staging = self.fileURL.deletingLastPathComponent().appendingPathComponent("migration-\(UUID().uuidString).sqlite")
                defer { try? FileManager.default.removeItem(at: staging) }
                try WorkoutDatabase(url: staging).save(migrated)
                try FileManager.default.moveItem(at: staging, to: self.fileURL)
                apply(migrated)
            } else {
                let initial = Snapshot(templates: Self.starterTemplates(catalog: exercises), history: [], activeWorkout: nil, unit: unit)
                let seeded = Self.backfillingVersions(initial)
                apply(seeded)
                _ = commit(seeded)
            }
        } catch {
            let message = "Could not load your workouts: \(error.localizedDescription) Your saved data was preserved. Restore a backup in Settings or restore the saved file and relaunch."
            loadFailure = message
            errorMessage = message
        }
    }

    @discardableResult
    func setExerciseFavorite(_ exerciseID: UUID, isFavorite: Bool) -> Bool {
        guard !isFavorite || exercises.contains(where: { $0.id == exerciseID }) else {
            return fail(StoreError.invalid("This exercise is no longer available. Choose an exercise from the catalog to favorite it."))
        }
        guard favoriteExerciseIDs.contains(exerciseID) != isFavorite else { return true }
        var next = snapshot
        if isFavorite { next.favoriteExerciseIDs.append(exerciseID) }
        else { next.favoriteExerciseIDs.removeAll { $0 == exerciseID } }
        return commit(next)
    }

    func exerciseInstructions(for exerciseID: UUID) -> [String] {
        exerciseInstructionOverrides.first { $0.exerciseID == exerciseID }?.steps
            ?? ExerciseCatalog.detail(for: exerciseID)?.instructions ?? []
    }

    func hasCustomExerciseInstructions(_ exerciseID: UUID) -> Bool {
        exerciseInstructionOverrides.contains { $0.exerciseID == exerciseID }
    }

    /// Saving the bundled steps restores the default instead of pinning a redundant override.
    @discardableResult
    func setExerciseInstructions(_ steps: [String], for exerciseID: UUID) -> Bool {
        do {
            let trimmed = steps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            try Self.validateInstructionSteps(trimmed)
            guard exercises.contains(where: { $0.id == exerciseID }) else {
                throw StoreError.invalid("This exercise is no longer available. Choose an exercise from the catalog to edit its steps.")
            }
            let defaults = ExerciseCatalog.detail(for: exerciseID)?.instructions.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []
            if trimmed == defaults { return resetExerciseInstructions(for: exerciseID) }
            if exerciseInstructionOverrides.first(where: { $0.exerciseID == exerciseID })?.steps == trimmed { return true }
            var next = snapshot
            if let index = next.exerciseInstructionOverrides.firstIndex(where: { $0.exerciseID == exerciseID }) {
                next.exerciseInstructionOverrides[index].steps = trimmed
            } else {
                next.exerciseInstructionOverrides.append(ExerciseInstructionOverride(exerciseID: exerciseID, steps: trimmed))
            }
            return commit(next)
        } catch {
            return fail(error)
        }
    }

    /// Orphaned catalog identities retain their text until explicitly reset.
    @discardableResult
    func resetExerciseInstructions(for exerciseID: UUID) -> Bool {
        guard hasCustomExerciseInstructions(exerciseID) else { return true }
        var next = snapshot
        next.exerciseInstructionOverrides.removeAll { $0.exerciseID == exerciseID }
        return commit(next)
    }

    @discardableResult
    func saveTemplate(_ template: WorkoutTemplate, expectedUnit: WeightUnit? = nil) -> Bool {
        do {
            guard expectedUnit == nil || expectedUnit == unit else {
                throw StoreError.invalid("Your weight unit changed after you opened this plan. Reopen it before saving.")
            }
            try Self.validate(template)
            var next = snapshot
            var trimmed = template
            SupersetGrouping.normalize(&trimmed.exercises)
            trimmed.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for index in trimmed.exercises.indices {
                trimmed.exercises[index].exercise = Self.register(trimmed.exercises[index].exercise, in: &next)
            }
            if let index = next.templates.firstIndex(where: { $0.id == trimmed.id }) {
                let saved = next.templates[index]
                guard trimmed.currentVersion?.id == saved.currentVersion?.id else {
                    throw StoreError.invalid("This template changed after you opened it. Reopen it before saving a new version.")
                }
                // Drafts may reference the current version but never replace saved archives.
                trimmed.versions = saved.versions
                if trimmed.restSeconds != saved.restSeconds || !Self.samePrescription(trimmed.exercises, saved.exercises) {
                    trimmed.versions.append(WorkoutTemplateVersion(number: saved.versions.count + 1, name: trimmed.name, exercises: trimmed.exercises, unit: unit, restSeconds: trimmed.restSeconds))
                } else {
                    // Renaming changes template metadata, not its immutable prescription.
                    trimmed.exercises = saved.exercises
                }
                next.templates[index] = trimmed
            } else {
                guard template.versions.isEmpty else { throw StoreError.invalid("This template was deleted. Create a new template to save this plan.") }
                trimmed.versions = [WorkoutTemplateVersion(number: 1, name: trimmed.name, exercises: trimmed.exercises, unit: unit, restSeconds: trimmed.restSeconds)]
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
    func startWorkout(template: WorkoutTemplate? = nil, versionID: UUID? = nil) -> Bool {
        guard activeWorkout == nil else {
            return fail(StoreError.invalid("Finish or discard your current workout before starting another."))
        }
        do {
            var source = template
            var version: WorkoutTemplateVersion?
            if let template, let saved = templates.first(where: { $0.id == template.id }) {
                source = saved
                version = versionID.flatMap { id in saved.versions.first(where: { $0.id == id }) } ?? (versionID == nil ? saved.currentVersion : nil)
                guard let version else { throw StoreError.invalid("This template version is no longer available.") }
                if versionID != nil { source?.name = version.name }
                source?.exercises = version.exercises(in: unit)
                source?.restSeconds = version.restSeconds
            } else if versionID != nil {
                throw StoreError.invalid("Choose a saved template before selecting a version.")
            }
            if var plan = source {
                SupersetGrouping.normalize(&plan.exercises)
                try Self.validate(plan)
                source = plan
            }
            var next = snapshot
            var workout = WorkoutSession(
                templateID: source?.id, templateVersionID: version?.id, templateVersionNumber: version?.number,
                name: source?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Workout",
                unit: unit,
                exercises: source?.exercises.map { item in
                    WorkoutExercise(exercise: item.exercise, sets: item.sets.map {
                        WorkoutSet(weight: $0.weight, reps: $0.targetReps, targetReps: $0.targetReps, targetWeight: $0.weight)
                    }, supersetID: item.supersetID, templateExerciseID: item.id)
                } ?? [],
                restSeconds: source?.restSeconds ?? 120
            )
            for index in workout.exercises.indices {
                workout.exercises[index].exercise = Self.register(workout.exercises[index].exercise, in: &next)
            }
            next.activeWorkout = workout
            return commit(next)
        } catch { return fail(error) }
    }

    /// The captured entry prevents a delayed picker from overwriting newly logged work.
    @discardableResult
    func replaceActiveExercise(in sessionID: UUID, expectedEntry: WorkoutExercise, with exerciseID: UUID) -> Bool {
        guard let activeWorkout, activeWorkout.id == sessionID else {
            return fail(StoreError.invalid("This workout is no longer active."))
        }
        guard let replacement = exercises.first(where: { $0.id == exerciseID }) else {
            return fail(StoreError.invalid("This exercise is no longer available. Reopen the swap and choose an available exercise."))
        }
        do {
            let updated = try ExerciseReplacement.replacing(activeWorkout, expectedEntry: expectedEntry, with: replacement)
            return updateActiveWorkout(updated)
        } catch { return fail(error) }
    }

    @discardableResult
    func updateActiveWorkout(_ workout: WorkoutSession, now: Date = Date()) -> Bool {
        guard let activeWorkout, workout.id == activeWorkout.id else {
            return fail(StoreError.invalid("This workout is no longer active."))
        }
        do {
            var updated = workout
            SupersetGrouping.normalize(&updated.exercises)
            // Session identity, start time, template reference, and recorded unit are fixed.
            updated.startedAt = activeWorkout.startedAt
            updated.templateID = activeWorkout.templateID
            updated.templateVersionID = activeWorkout.templateVersionID
            updated.templateVersionNumber = activeWorkout.templateVersionNumber
            updated.restSeconds = activeWorkout.restSeconds
            updated.restTimer = activeWorkout.restTimer
            updated.unit = activeWorkout.unit
            updated.finishedAt = nil
            try Self.validate(updated)
            // Logged values may change; targets remain the prescription originally started.
            for exerciseIndex in updated.exercises.indices {
                guard let original = activeWorkout.exercises.first(where: { $0.id == updated.exercises[exerciseIndex].id }) else { continue }
                // A replacement belongs only to this session, even when its entry ID is reused.
                updated.exercises[exerciseIndex].templateExerciseID =
                    updated.exercises[exerciseIndex].exercise.id == original.exercise.id ? original.templateExerciseID : nil
                // A different movement never inherits the original prescription,
                // including through callers that retain an entry ID during replacement.
                if original.exercise.id != updated.exercises[exerciseIndex].exercise.id {
                    guard !original.sets.contains(where: \.isCompleted),
                          !updated.exercises[exerciseIndex].sets.contains(where: \.isCompleted) else {
                        throw StoreError.invalid("An exercise with completed sets cannot be replaced.")
                    }
                    for setIndex in updated.exercises[exerciseIndex].sets.indices {
                        updated.exercises[exerciseIndex].sets[setIndex].targetReps = nil
                        updated.exercises[exerciseIndex].sets[setIndex].targetWeight = nil
                    }
                    continue
                }
                for setIndex in updated.exercises[exerciseIndex].sets.indices {
                    guard let set = original.sets.first(where: { $0.id == updated.exercises[exerciseIndex].sets[setIndex].id }) else { continue }
                    updated.exercises[exerciseIndex].sets[setIndex].targetReps = set.targetReps
                    updated.exercises[exerciseIndex].sets[setIndex].targetWeight = set.targetWeight
                }
            }
            var next = snapshot
            for index in updated.exercises.indices {
                updated.exercises[index].exercise = Self.register(updated.exercises[index].exercise, in: &next)
            }
            updated.restTimer = WorkoutRestTimer.updated(previous: activeWorkout, current: updated, now: now)
            next.activeWorkout = updated
            return commit(next)
        } catch { return fail(error) }
    }

    /// Session entries eligible to reorder the current template. Check movement identity too
    /// so stale links saved by older versions cannot move a different template exercise.
    func templateLinkedExerciseIDs(in workout: WorkoutSession) -> Set<UUID> {
        guard let template = templates.first(where: { $0.id == workout.templateID }) else { return [] }
        let entries = Dictionary(uniqueKeysWithValues: template.exercises.map { ($0.id, $0.exercise.id) })
        return Set(workout.exercises.filter { item in
            guard let sourceID = item.templateExerciseID else { return false }
            return entries[sourceID] == item.exercise.id
        }.map(\.id))
    }

    /// Saves only the exercise order, using the latest logged values and template prescription.
    @discardableResult
    func reorderActiveWorkout(id: UUID, exerciseIDs: [UUID], expectedExerciseIDs: [UUID]) -> Bool {
        do {
            guard var workout = activeWorkout, workout.id == id,
                  workout.exercises.map(\.id) == expectedExerciseIDs else {
                throw StoreError.invalid("This workout changed after you opened the exercise order. Reopen Reorder Exercises and try again.")
            }
            guard exerciseIDs.count == expectedExerciseIDs.count,
                  Set(exerciseIDs) == Set(expectedExerciseIDs) else {
                throw StoreError.invalid("The exercise order must include every workout exercise exactly once.")
            }
            guard exerciseIDs != expectedExerciseIDs else { return true }
            let entries = Dictionary(uniqueKeysWithValues: workout.exercises.map { ($0.id, $0) })
            workout.exercises = exerciseIDs.compactMap { entries[$0] }
            var next = snapshot
            if let templateIndex = next.templates.firstIndex(where: { $0.id == workout.templateID }) {
                var template = next.templates[templateIndex]
                let templateEntries = Dictionary(uniqueKeysWithValues: template.exercises.map { ($0.id, $0) })
                let linkedIDs = templateLinkedExerciseIDs(in: workout)
                let orderedIDs = workout.exercises.filter { linkedIDs.contains($0.id) }.compactMap(\.templateExerciseID)
                guard Set(orderedIDs).count == orderedIDs.count else {
                    throw StoreError.invalid("The workout contains duplicate template exercise references.")
                }
                let matchingIDs = Set(orderedIDs)
                var ordered = orderedIDs.makeIterator()
                let originalIDs = template.exercises.map(\.id)
                // Template-only entries keep their positions; session-only additions stay local.
                for index in template.exercises.indices where matchingIDs.contains(template.exercises[index].id) {
                    if let entryID = ordered.next(), let entry = templateEntries[entryID] {
                        template.exercises[index] = entry
                    }
                }
                if template.exercises.map(\.id) != originalIDs {
                    template.versions.append(WorkoutTemplateVersion(number: template.versions.count + 1,
                        name: template.name, exercises: template.exercises, unit: unit, restSeconds: template.restSeconds))
                    next.templates[templateIndex] = template
                }
            }
            next.activeWorkout = workout
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
              workout.templateVersionID == nil, workout.templateVersionNumber == nil,
              !history.contains(where: { $0.id == workout.id }),
              workout.restTimer == nil,
              workout.exercises.allSatisfy({ !$0.sets.isEmpty && $0.sets.allSatisfy { !$0.isCompleted } }) else {
            return fail(StoreError.invalid("The proposed workout must contain only planned, uncompleted sets in your current unit."))
        }
        do {
            try Self.validate(workout)
            var next = snapshot
            var reviewed = workout
            SupersetGrouping.normalize(&reviewed.exercises)
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
        SupersetGrouping.normalize(&workout.exercises)
        guard !workout.exercises.isEmpty else {
            return fail(StoreError.invalid("Complete at least one set before finishing your workout."))
        }
        workout.restTimer = nil
        workout.finishedAt = Date()
        var next = snapshot
        next.history.insert(workout, at: 0)
        next.activeWorkout = nil
        return commit(next)
    }

    @discardableResult
    func renameWorkout(id: UUID, name: String) -> Bool {
        do {
            try Self.validateName(name)
            var next = snapshot
            guard let index = next.history.firstIndex(where: { $0.id == id }) else {
                throw StoreError.invalid("This workout is no longer in your history.")
            }
            next.history[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return commit(next)
        } catch { return fail(error) }
    }

    @discardableResult
    func deleteWorkout(id: UUID) -> Bool {
        var next = snapshot
        next.history.removeAll { $0.id == id }
        return commit(next)
    }

    @discardableResult
    func discardWorkout() -> Bool {
        var next = snapshot
        next.activeWorkout = nil
        return commit(next)
    }

    @discardableResult
    func skipRest() -> Bool {
        guard var workout = activeWorkout else { return false }
        workout.restTimer = nil
        var next = snapshot
        next.activeWorkout = workout
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

    @discardableResult
    func setDefaultAssistantModel(_ model: String?) -> Bool {
        let normalized = model.flatMap { $0.isEmpty ? nil : $0 }
        defaultAssistantModel = normalized
        if let normalized { UserDefaults.standard.set(normalized, forKey: defaultAssistantModelKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultAssistantModelKey) }
        return true
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
            SupersetGrouping.normalize(&saved.exercises)
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
        Snapshot(templates: templates, history: history, activeWorkout: activeWorkout, unit: unit, personalExercises: personalExercises, favoriteExerciseIDs: favoriteExerciseIDs, exerciseInstructionOverrides: exerciseInstructionOverrides)
    }

    private func apply(_ snapshot: Snapshot) {
        templates = snapshot.templates
        history = snapshot.history
        activeWorkout = snapshot.activeWorkout
        unit = snapshot.unit
        personalExercises = snapshot.personalExercises
        favoriteExerciseIDs = snapshot.favoriteExerciseIDs
        exerciseInstructionOverrides = snapshot.exerciseInstructionOverrides
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

    /// Legacy sessions have no source entry IDs. Only unambiguous matches are safe to infer.
    nonisolated static func backfillingExerciseReferences(_ snapshot: WorkoutSnapshot) -> WorkoutSnapshot {
        var next = snapshot
        guard var workout = next.activeWorkout,
              let template = next.templates.first(where: { $0.id == workout.templateID }) else { return next }
        let source: [TemplateExercise]
        if let versionID = workout.templateVersionID {
            guard let version = template.versions.first(where: { $0.id == versionID }) else { return next }
            source = version.exercises
        } else {
            // Pre-version sessions can safely match unique movement identities in the
            // surviving template, without inventing version attribution or set targets.
            source = template.exercises
        }
        let sessionGroups = Dictionary(grouping: workout.exercises, by: { $0.exercise.id })
        let sourceGroups = Dictionary(grouping: source, by: { $0.exercise.id })
        for index in workout.exercises.indices where workout.exercises[index].templateExerciseID == nil {
            let catalogID = workout.exercises[index].exercise.id
            if sessionGroups[catalogID]?.count == 1, let matches = sourceGroups[catalogID], matches.count == 1 {
                workout.exercises[index].templateExerciseID = matches[0].id
            }
        }
        next.activeWorkout = workout
        return next
    }

    /// Legacy sessions retain unknown version provenance and targets. Only template plans gain a baseline.
    private static func backfillingVersions(_ snapshot: Snapshot) -> Snapshot {
        var next = snapshot
        for index in next.templates.indices where next.templates[index].versions.isEmpty {
            let template = next.templates[index]
            next.templates[index].versions = [WorkoutTemplateVersion(number: 1, name: template.name, exercises: template.exercises, unit: snapshot.unit, restSeconds: template.restSeconds)]
        }
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
        let restored = Self.backfillingVersions(Self.backfillingCatalog(saved))
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
        revision &+= 1
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

    nonisolated private static func validateRest(_ seconds: Int) throws {
        guard (0...3600).contains(seconds) else {
            throw StoreError.invalid("Rest must be between zero and 60 minutes.")
        }
    }

    nonisolated private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.invalid("Enter a name before saving.")
        }
    }

    nonisolated private static func validate(_ template: WorkoutTemplate) throws {
        try validateName(template.name)
        try validateRest(template.restSeconds)
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
        try validateRest(workout.restSeconds)
        if let timer = workout.restTimer {
            guard workout.finishedAt == nil, timer.endsAt.timeIntervalSinceReferenceDate.isFinite else {
                throw StoreError.invalid("A workout contains an invalid rest timer.")
            }
        }
        guard workout.startedAt.timeIntervalSinceReferenceDate.isFinite,
              workout.finishedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 >= workout.startedAt }) ?? true else {
            throw StoreError.invalid("A workout contains invalid dates.")
        }
        try validateIDs(workout.exercises.map(\.id))
        guard (workout.templateVersionID == nil) == (workout.templateVersionNumber == nil),
              workout.templateVersionNumber.map({ $0 > 0 && workout.templateID != nil }) ?? true else {
            throw StoreError.invalid("A workout has an invalid template version reference.")
        }
        for item in workout.exercises {
            try validateName(item.exercise.name)
            try validateIDs(item.sets.map(\.id))
            for set in item.sets {
                try validateSet(weight: set.weight, reps: set.reps)
                if let targetReps = set.targetReps, targetReps <= 0 {
                    throw StoreError.invalid("Target reps must be greater than zero.")
                }
                if let targetWeight = set.targetWeight, !targetWeight.isFinite || targetWeight < 0 {
                    throw StoreError.invalid("Target weight must be a finite number of zero or more.")
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
        try validateIDs(snapshot.favoriteExerciseIDs)
        try validateIDs(snapshot.exerciseInstructionOverrides.map(\.exerciseID))
        for override in snapshot.exerciseInstructionOverrides { try validateInstructionSteps(override.steps) }
        try validateIDs(snapshot.personalExercises.map(\.id))
        for exercise in snapshot.personalExercises { try validateName(exercise.name) }
        try validateIDs(snapshot.templates.map(\.id))
        try validateIDs(snapshot.templates.flatMap { $0.versions.map(\.id) })
        try validateIDs(snapshot.history.map(\.id))
        for template in snapshot.templates {
            try validate(template)
            try validateIDs(template.versions.map(\.id))
            for (index, version) in template.versions.enumerated() {
                guard version.number == index + 1, version.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw StoreError.invalid("A template contains invalid saved versions.")
                }
                try validate(WorkoutTemplate(name: version.name, exercises: version.exercises, restSeconds: version.restSeconds))
            }
            if let version = template.currentVersion {
                guard template.restSeconds == version.restSeconds, samePrescription(template.exercises, version.exercises(in: snapshot.unit)) else {
                    throw StoreError.invalid("A template's current plan does not match its saved version.")
                }
            }
        }
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

    nonisolated private static func validateInstructionSteps(_ steps: [String]) throws {
        guard !steps.isEmpty, steps.count <= 100 else {
            throw StoreError.invalid("Add between 1 and 100 instruction steps.")
        }
        guard steps.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 10_000 }) else {
            throw StoreError.invalid("Each instruction step must contain text and be no longer than 10,000 characters.")
        }
    }

    nonisolated static func samePrescription(_ left: [TemplateExercise], _ right: [TemplateExercise]) -> Bool {
        guard left.count == right.count, SupersetGrouping.sameMembership(left, right) else { return false }
        return zip(left, right).allSatisfy { lhs, rhs in
            lhs.exercise == rhs.exercise && lhs.sets.count == rhs.sets.count && zip(lhs.sets, rhs.sets).allSatisfy { a, b in
                abs(a.weight - b.weight) <= max(1, abs(a.weight), abs(b.weight)) * 1e-12 && a.targetReps == b.targetReps
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
