import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutStoreTests: XCTestCase {
    private func template(name: String = "Upper Body") -> WorkoutTemplate {
        WorkoutTemplate(name: name, exercises: [
            TemplateExercise(exercise: Exercise(name: "Bench Press", category: "Chest"), sets: [
                TemplateSet(weight: 135, targetReps: 8),
                TemplateSet(weight: 135, targetReps: 6)
            ]),
            TemplateExercise(exercise: Exercise(name: "Row", category: "Back"), sets: [
                TemplateSet(weight: 95, targetReps: 10)
            ])
        ])
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiftLogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    @MainActor
    func testDefaultAssistantModelPersistsAndOlderFilesUseAutomatic() throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertNil(store.defaultAssistantModel)
        XCTAssertTrue(store.setDefaultAssistantModel("preferred"))
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(WorkoutStore(fileURL: file).defaultAssistantModel, "preferred")
        XCTAssertTrue(store.setDefaultAssistantModel(""))
        XCTAssertNil(WorkoutStore(fileURL: file).defaultAssistantModel)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        legacy.removeValue(forKey: "defaultAssistantModel")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file.deletingPathExtension().appendingPathExtension("json"))
        try FileManager.default.removeItem(at: file)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNil(reloaded.defaultAssistantModel)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(reloaded.unit, .kg)
    }

    @MainActor
    func testDefaultAssistantModelIsIndependentOfWorkoutDatabaseWrites() throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.setDefaultAssistantModel("preferred"))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertTrue(store.setDefaultAssistantModel("other"))
        XCTAssertEqual(store.defaultAssistantModel, "other")
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testExpandedCatalogPreservesOriginalIdentitiesAndStarterTemplates() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        let originalNames = ["Bench Press", "Squat", "Deadlift", "Overhead Press", "Barbell Row",
                             "Pull Up", "Dumbbell Curl", "Triceps Pushdown", "Romanian Deadlift", "Leg Press"]
        XCTAssertEqual(Array(store.exercises.prefix(10)).map(\.name), originalNames)
        XCTAssertEqual(store.exercises.count, 876)
        XCTAssertEqual(store.exercises.first { $0.name == "Incline Dumbbell Press" }?.id,
                       UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        for (index, exercise) in store.exercises.prefix(10).enumerated() {
            XCTAssertEqual(exercise.id.uuidString, String(format: "00000000-0000-0000-0000-%012d", index + 1))
        }
        XCTAssertEqual(Set(store.exercises.map(\.id)).count, store.exercises.count)
        XCTAssertEqual(Set(store.exercises.map { $0.name.lowercased() }).count, store.exercises.count)
        XCTAssertTrue(store.exercises.allSatisfy { !$0.name.isEmpty && !$0.category.isEmpty })
        XCTAssertTrue(Set(["Chest", "Back", "Shoulders", "Biceps", "Triceps", "Abdominals", "Legs", "Calves"])
            .isSubset(of: Set(store.exercises.map(\.category))))
        XCTAssertEqual(store.templates.map { $0.exercises.map { $0.exercise.name } }, [
            ["Bench Press", "Barbell Row", "Overhead Press", "Dumbbell Curl"],
            ["Squat", "Romanian Deadlift", "Leg Press"]
        ])
    }

    @MainActor
    func testExpandedCatalogIsAvailableWithExistingDataAndNewExercisesPersist() async throws {
        let file = try temporaryFile()
        let originalStore = WorkoutStore(fileURL: file)
        let savedTemplates = originalStore.templates
        let existingData = try Data(contentsOf: file)
        let store = WorkoutStore(fileURL: file)
        XCTAssertEqual(try Data(contentsOf: file), existingData)
        XCTAssertEqual(store.templates, savedTemplates)
        XCTAssertEqual(store.exercises, originalStore.exercises)

        let exercise = try XCTUnwrap(store.exercises.first { $0.name == "Goblet Squat" })
        XCTAssertEqual(exercise.category, "Legs")
        var addedTemplate = WorkoutTemplate(name: "Expanded Catalog", exercises: [TemplateExercise(exercise: exercise)])
        XCTAssertTrue(store.saveTemplate(addedTemplate))
        addedTemplate = try XCTUnwrap(store.templates.first { $0.id == addedTemplate.id })
        XCTAssertTrue(store.startWorkout(template: addedTemplate))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.templates.first { $0.id == addedTemplate.id }, addedTemplate)
        XCTAssertEqual(reloaded.history.first?.exercises.first?.exercise, exercise)
        XCTAssertEqual(reloaded.exercises.first { $0.id == exercise.id }, exercise)
    }

    @MainActor
    func testFormerCatalogSnapshotsSurviveReplacementWithoutRewritingSavedData() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let former = Exercise(id: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!,
                              name: "Dumbbell Goblet Squat", category: "Legs")
        XCTAssertFalse(store.exercises.contains { $0.id == former.id })
        var legacyTemplate = WorkoutTemplate(name: "Existing Workout", exercises: [TemplateExercise(exercise: former)])
        XCTAssertTrue(store.saveTemplate(legacyTemplate))
        legacyTemplate = try XCTUnwrap(store.templates.first { $0.id == legacyTemplate.id })
        XCTAssertTrue(store.startWorkout(template: legacyTemplate))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertTrue(store.startWorkout(template: legacyTemplate))
        let savedData = try Data(contentsOf: file)

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), savedData)
        XCTAssertEqual(reloaded.templates.first { $0.id == legacyTemplate.id }, legacyTemplate)
        XCTAssertEqual(reloaded.activeWorkout?.exercises.first?.exercise, former)
        XCTAssertEqual(reloaded.history.first?.exercises.first?.exercise, former)
    }

    @MainActor
    func testTargetRepsStayIndependentOfActualRepsAndLaterTemplateEdits() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var planned = template()
        XCTAssertTrue(store.saveTemplate(planned))
        planned = try XCTUnwrap(store.templates.first { $0.id == planned.id })
        XCTAssertTrue(store.startWorkout(template: planned))
        var active = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(active.exercises[0].sets.map(\.targetReps), [8, 6])
        active.exercises[0].updateSetValues(weight: 135, reps: 5)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        planned.exercises[0].updateSetValues(weight: 135, targetReps: 12)
        XCTAssertTrue(store.saveTemplate(planned))
        planned = try XCTUnwrap(store.templates.first { $0.id == planned.id })

        let resumed = WorkoutStore(fileURL: file)
        XCTAssertEqual(resumed.activeWorkout?.exercises[0].sets.map(\.targetReps), [8, 6])
        XCTAssertEqual(resumed.activeWorkout?.exercises[0].sets.map(\.reps), [5, 5])
        XCTAssertTrue(resumed.finishWorkout())
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.history.first?.exercises[0].sets[0].targetReps, 8)
        XCTAssertEqual(reloaded.history.first?.exercises[0].sets[0].reps, 5)
        XCTAssertEqual(reloaded.templates.first { $0.id == planned.id }, planned)
        XCTAssertTrue(reloaded.startWorkout(template: planned))
        XCTAssertEqual(reloaded.activeWorkout?.exercises[0].sets.map(\.targetReps), [12, 12])
    }

    @MainActor
    func testLegacyRepFieldsLoadAndSaveWithoutLosingRecordedValues() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var planned = template()
        XCTAssertTrue(store.saveTemplate(planned))
        planned = try XCTUnwrap(store.templates.first { $0.id == planned.id })
        XCTAssertTrue(store.startWorkout(template: planned))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].reps = 5
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertTrue(store.startWorkout(template: planned))
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        func rewriteSets(_ entry: [String: Any], template: Bool) -> [String: Any] {
            var entry = entry
            entry.removeValue(forKey: "versions")
            entry.removeValue(forKey: "templateVersionID")
            entry.removeValue(forKey: "templateVersionNumber")
            entry["exercises"] = (entry["exercises"] as! [[String: Any]]).map { exercise in
                var exercise = exercise
                exercise["sets"] = (exercise["sets"] as! [[String: Any]]).map { set in
                    var set = set
                    if template { set["reps"] = set["targetReps"] }
                    set.removeValue(forKey: "targetReps")
                    set.removeValue(forKey: "targetWeight")
                    return set
                }
                return exercise
            }
            return entry
        }
        snapshot["templates"] = (snapshot["templates"] as! [[String: Any]]).map { rewriteSets($0, template: true) }
        snapshot["history"] = (snapshot["history"] as! [[String: Any]]).map { rewriteSets($0, template: false) }
        snapshot["activeWorkout"] = rewriteSets(snapshot["activeWorkout"] as! [String: Any], template: false)
        let legacy = file.deletingPathExtension().appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: snapshot).write(to: legacy)
        try FileManager.default.removeItem(at: file)

        let migrated = WorkoutStore(fileURL: file)
        XCTAssertNil(migrated.errorMessage)
        XCTAssertEqual(migrated.templates.first { $0.id == planned.id }?.exercises, planned.exercises)
        planned = try XCTUnwrap(migrated.templates.first { $0.id == planned.id })
        XCTAssertEqual(migrated.history.first?.exercises[0].sets[0].reps, 5)
        XCTAssertNil(migrated.history.first?.exercises[0].sets[0].targetReps)
        XCTAssertEqual(migrated.activeWorkout?.exercises[0].sets.map(\.reps), [8, 6])
        XCTAssertNil(migrated.activeWorkout?.exercises[0].sets[0].targetReps)
        XCTAssertTrue(migrated.saveTemplate(planned))
        let persisted = try WorkoutDatabase(url: file).load()
        XCTAssertEqual(persisted.templates.first { $0.id == planned.id }, planned)
        XCTAssertEqual(WorkoutStore(fileURL: file).history, migrated.history)
    }

    @MainActor
    func testTemplateCreateEditDeletePersists() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var original = template()

        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertEqual(store.templates.filter { $0.id == original.id }.count, 1)
        original.name = "Updated Upper Body"
        original.exercises[0].sets[0].weight = 145
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertEqual(store.templates.filter { $0.id == original.id }, [original])

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.templates.first { $0.id == original.id }, original)
        XCTAssertTrue(reloaded.deleteTemplate(id: original.id))
        XCTAssertFalse(WorkoutStore(fileURL: file).templates.contains { $0.id == original.id })
    }

    @MainActor
    func testInvalidTemplatesLeaveExistingDataUnchanged() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        var original = template()
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        let snapshot = store.templates

        var invalid = original
        invalid.name = " \n "
        XCTAssertFalse(store.saveTemplate(invalid))
        XCTAssertNotNil(store.errorMessage)
        invalid = original
        invalid.exercises = []
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid = original
        invalid.exercises[0].sets = []
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid = original
        invalid.exercises[0].sets[0].weight = -1
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid = original
        invalid.exercises[0].sets[0].targetReps = 0
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid = original
        invalid.exercises[0].sets[0].weight = .infinity
        XCTAssertFalse(store.saveTemplate(invalid))
        invalid = original
        invalid.exercises[0].sets[0].weight = .nan
        XCTAssertFalse(store.saveTemplate(invalid))
        XCTAssertEqual(store.templates, snapshot)
    }

    @MainActor
    func testStartCopiesTemplateWithFreshIdentifiersAndIncompleteSets() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        var original = template()
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.startWorkout(template: original))
        let active = try XCTUnwrap(store.activeWorkout)

        XCTAssertEqual(active.templateID, original.id)
        XCTAssertEqual(active.name, original.name)
        XCTAssertNil(active.finishedAt)
        XCTAssertEqual(active.exercises.map { $0.exercise }, original.exercises.map { $0.exercise })
        XCTAssertEqual(active.exercises[0].sets.map { $0.weight }, [135, 135])
        XCTAssertEqual(active.exercises[0].sets.map { $0.reps }, [8, 6])
        XCTAssertTrue(active.exercises.flatMap { $0.sets }.allSatisfy { !$0.isCompleted })
        XCTAssertNotEqual(active.exercises[0].id, original.exercises[0].id)
        XCTAssertNotEqual(active.exercises[0].sets[0].id, original.exercises[0].sets[0].id)

        var edited = active
        edited.exercises[0].sets[0].weight = 155
        edited.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(edited))
        XCTAssertEqual(store.templates.first { $0.id == original.id }, original)
    }

    @MainActor
    func testExerciseSetValuesPropagateAndPersistWithoutChangingOtherExercises() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let original = template()
        var editedTemplate = original
        let plannedIDs = original.exercises[0].sets.map(\.id)
        editedTemplate.exercises[0].updateSetValues(weight: 142.5, targetReps: 7)
        XCTAssertTrue(store.saveTemplate(editedTemplate))
        editedTemplate = try XCTUnwrap(store.templates.first { $0.id == editedTemplate.id })
        let reloadedTemplate = try XCTUnwrap(WorkoutStore(fileURL: file).templates.first { $0.id == original.id })
        XCTAssertEqual(reloadedTemplate.exercises[0].sets.map(\.weight), [142.5, 142.5])
        XCTAssertEqual(reloadedTemplate.exercises[0].sets.map(\.targetReps), [7, 7])
        XCTAssertEqual(reloadedTemplate.exercises[0].sets.map(\.id), plannedIDs)
        XCTAssertEqual(reloadedTemplate.exercises[1], original.exercises[1])

        XCTAssertTrue(store.startWorkout(template: reloadedTemplate))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        let setIDs = active.exercises[0].sets.map(\.id)
        let otherExercise = active.exercises[1]
        active.exercises[0].updateSetValues(weight: 150, reps: 6)
        XCTAssertTrue(store.updateActiveWorkout(active))
        let reloaded = try XCTUnwrap(WorkoutStore(fileURL: file).activeWorkout)
        XCTAssertEqual(reloaded.exercises[0].sets.map(\.weight), [150, 150])
        XCTAssertEqual(reloaded.exercises[0].sets.map(\.reps), [6, 6])
        XCTAssertEqual(reloaded.exercises[0].sets.map(\.id), setIDs)
        XCTAssertEqual(reloaded.exercises[0].sets.map(\.isCompleted), [true, false])
        XCTAssertEqual(reloaded.exercises[1], otherExercise)
        XCTAssertEqual(store.templates.first { $0.id == original.id }, reloadedTemplate)

        active.exercises[0].updateSetValues(weight: -1, reps: 0)
        XCTAssertFalse(store.updateActiveWorkout(active))
        XCTAssertEqual(store.activeWorkout, reloaded)
    }

    @MainActor
    func testCompletedSetValuesSurviveRelaunch() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].weight = 142.5
        active.exercises[0].sets[0].reps = 7
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.activeWorkout, active)
        XCTAssertTrue(reloaded.activeWorkout?.exercises[0].sets[0].isCompleted == true)
        active.exercises[0].sets[0].isCompleted = false
        XCTAssertTrue(reloaded.updateActiveWorkout(active))
        XCTAssertEqual(WorkoutStore(fileURL: file).activeWorkout, active)
    }

    @MainActor
    func testSecondWorkoutCannotReplaceActiveSession() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        XCTAssertTrue(store.startWorkout(template: template()))
        let original = store.activeWorkout
        XCTAssertFalse(store.startWorkout(template: template(name: "Lower Body")))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.activeWorkout, original)
    }

    @MainActor
    func testFinishRecordsOnlyCompletedSetsAndHistoryIsIndependent() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var original = template()
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.startWorkout(template: original))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].weight = 140
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertNil(store.activeWorkout)
        let history = try XCTUnwrap(store.history.first { $0.id == active.id })
        XCTAssertNotNil(history.finishedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(history.finishedAt), history.startedAt)
        XCTAssertEqual(history.exercises.count, 1)
        XCTAssertEqual(history.exercises[0].sets.count, 1)
        XCTAssertEqual(history.exercises[0].sets[0].weight, 140)
        XCTAssertTrue(history.exercises[0].sets[0].isCompleted)

        original.name = "Changed Template"
        original.exercises[0].exercise.name = "Changed Exercise"
        original.exercises[0].sets[0].weight = 200
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.deleteTemplate(id: original.id))
        XCTAssertEqual(store.history.first { $0.id == active.id }, history)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.history.first { $0.id == active.id }, history)
        XCTAssertNil(reloaded.activeWorkout)
    }

    @MainActor
    func testCannotFinishWithoutCompletedSets() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        XCTAssertTrue(store.startWorkout(template: template()))
        let active = store.activeWorkout
        let history = store.history
        XCTAssertFalse(store.finishWorkout())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertEqual(store.history, history)
    }

    @MainActor
    func testDiscardClearsPersistedSessionWithoutRecordingHistory() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        let history = store.history
        XCTAssertTrue(store.discardWorkout())
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(store.history, history)
        XCTAssertNil(WorkoutStore(fileURL: file).activeWorkout)
        XCTAssertTrue(store.startWorkout(template: template()))
    }

    @MainActor
    func testInvalidSessionUpdatesPreserveActiveWorkout() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        XCTAssertTrue(store.startWorkout(template: template()))
        let active = try XCTUnwrap(store.activeWorkout)
        var invalid = active
        invalid.exercises[0].sets[0].weight = -0.5
        XCTAssertFalse(store.updateActiveWorkout(invalid))
        invalid = active
        invalid.exercises[0].sets[0].reps = -1
        XCTAssertFalse(store.updateActiveWorkout(invalid))
        invalid = active
        invalid.exercises[0].sets[0].targetReps = 0
        XCTAssertFalse(store.updateActiveWorkout(invalid))
        invalid = active
        invalid.exercises[0].sets[0].weight = .infinity
        XCTAssertFalse(store.updateActiveWorkout(invalid))
        invalid = active
        invalid.id = UUID()
        XCTAssertFalse(store.updateActiveWorkout(invalid))
        XCTAssertEqual(store.activeWorkout, active)
    }

    @MainActor
    func testUnitChangeConvertsTemplatesAndKeepsRecordedSessionValues() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var original = template()
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.startWorkout(template: original))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))

        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(store.unit, .kg)
        let converted = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertEqual(converted.exercises[0].sets[0].weight, 135 * 0.45359237, accuracy: 0.000001)
        XCTAssertEqual(converted.exercises[0].sets[0].targetReps, 8)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertEqual(store.templates.first { $0.id == original.id }, converted)
        XCTAssertEqual(store.activeWorkout, active)

        // Changing the preference or editing a draft must never relabel recorded loads.
        var edited = active
        edited.unit = .kg
        edited.startedAt = .distantPast
        edited.templateID = nil
        edited.finishedAt = Date()
        XCTAssertTrue(store.updateActiveWorkout(edited))
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history.first?.unit, .lb)
        XCTAssertEqual(store.history.first?.exercises[0].sets[0].weight, 135)
        let history = store.history

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.unit, .kg)
        XCTAssertEqual(reloaded.history, history)
        XCTAssertTrue(reloaded.startWorkout(template: converted))
        XCTAssertEqual(reloaded.activeWorkout?.unit, .kg)
        XCTAssertEqual(reloaded.activeWorkout?.exercises[0].sets[0].weight, converted.exercises[0].sets[0].weight)
        XCTAssertTrue(reloaded.setUnit(.lb))
        let roundTrip = try XCTUnwrap(reloaded.templates.first { $0.id == original.id })
        XCTAssertEqual(roundTrip.exercises[0].sets[0].weight, 135, accuracy: 0.000001)
        XCTAssertEqual(reloaded.history, history)
        XCTAssertEqual(reloaded.activeWorkout?.unit, .kg)
    }

    @MainActor
    func testEmptyWorkoutCanBeBuiltThenFinishedAndBodyweightIsValid() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        XCTAssertTrue(store.startWorkout())
        var active = try XCTUnwrap(store.activeWorkout)
        XCTAssertNil(active.templateID)
        XCTAssertTrue(active.exercises.isEmpty)
        active.name = "Bodyweight"
        active.exercises = [WorkoutExercise(exercise: Exercise(name: "Pull Up"), sets: [
            WorkoutSet(weight: 0, reps: 5, isCompleted: true)
        ])]
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history.first?.exercises[0].sets[0].weight, 0)
        XCTAssertEqual(store.history.first?.exercises[0].sets[0].reps, 5)
    }

    @MainActor
    func testDuplicateItemIdentifiersAreRejected() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        var duplicate = template()
        duplicate.exercises.append(duplicate.exercises[0])
        XCTAssertFalse(store.saveTemplate(duplicate))
        duplicate = template()
        duplicate.exercises[0].sets.append(duplicate.exercises[0].sets[0])
        XCTAssertFalse(store.saveTemplate(duplicate))
        XCTAssertTrue(store.startWorkout(template: template()))
        let active = try XCTUnwrap(store.activeWorkout)
        var duplicatedSession = active
        duplicatedSession.exercises[0].sets.append(duplicatedSession.exercises[0].sets[0])
        XCTAssertFalse(store.updateActiveWorkout(duplicatedSession))
        XCTAssertEqual(store.activeWorkout, active)
    }

    @MainActor
    func testDiskWriteFailureDoesNotApplyAnyMutation() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var original = template()
        XCTAssertTrue(store.saveTemplate(original))
        original = try XCTUnwrap(store.templates.first { $0.id == original.id })
        XCTAssertTrue(store.startWorkout(template: original))
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(active))
        let templates = store.templates
        let history = store.history

        // A nonempty directory at the destination reliably fails atomic writes,
        // including when the tests run as a privileged user.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: file.appendingPathComponent("sentinel"))
        XCTAssertFalse(store.saveTemplate(template(name: "Failed Save")))
        XCTAssertFalse(store.deleteTemplate(id: original.id))
        var edit = active
        edit.exercises[0].sets[0].reps = 9
        XCTAssertFalse(store.updateActiveWorkout(edit))
        XCTAssertFalse(store.setUnit(.kg))
        XCTAssertFalse(store.finishWorkout())
        XCTAssertFalse(store.discardWorkout())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.templates, templates)
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertEqual(store.unit, .lb)

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(WorkoutStore(fileURL: file).history, store.history)
    }

    @MainActor
    func testCorruptExistingFileReportsErrorWithoutOverwritingIt() async throws {
        let file = try temporaryFile()
        let corrupt = Data("this is not workout JSON".utf8)
        try corrupt.write(to: file)
        let store = WorkoutStore(fileURL: file)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.activeWorkout)
        XCTAssertFalse(store.startWorkout())
        XCTAssertFalse(store.setUnit(.kg))
        XCTAssertFalse(store.saveTemplate(template()))
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.templates.isEmpty)
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor
    func testUnsupportedPersistenceVersionIsRejectedWithoutOverwritingIt() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        snapshot["version"] = 999
        let unsupported = try JSONSerialization.data(withJSONObject: snapshot)
        let legacy = file.deletingPathExtension().appendingPathExtension("json")
        try unsupported.write(to: legacy)
        try FileManager.default.removeItem(at: file)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertTrue(reloaded.templates.isEmpty)
        XCTAssertEqual(try Data(contentsOf: legacy), unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testDecodableFileWithInvalidWorkoutValuesIsRejected() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertTrue(store.startWorkout(template: template()))
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        var active = try XCTUnwrap(snapshot["activeWorkout"] as? [String: Any])
        var exercises = try XCTUnwrap(active["exercises"] as? [[String: Any]])
        var sets = try XCTUnwrap(exercises[0]["sets"] as? [[String: Any]])
        sets[0]["weight"] = -5
        exercises[0]["sets"] = sets
        active["exercises"] = exercises
        snapshot["activeWorkout"] = active
        let invalid = try JSONSerialization.data(withJSONObject: snapshot)
        let legacy = file.deletingPathExtension().appendingPathExtension("json")
        try invalid.write(to: legacy)
        try FileManager.default.removeItem(at: file)

        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertNil(reloaded.activeWorkout)
        XCTAssertFalse(reloaded.startWorkout())
        XCTAssertEqual(try Data(contentsOf: legacy), invalid)
    }
}
