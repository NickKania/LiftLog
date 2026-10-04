import Foundation
import XCTest
@testable import LiftLogCore

final class PersonalExerciseCatalogTests: XCTestCase {
    private let header = "Date,Workout Name,Duration,Exercise Name,Set Order,Weight,Reps,Distance,Seconds,RPE\n"

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PersonalCatalog-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("workouts.sqlite")
    }

    private func preview(_ exercise: String, day: Int = 1, catalog: [Exercise] = []) throws -> WorkoutImportPreview {
        try StrongWorkoutImporter.preview(
            csv: header + "2026-01-\(String(format: "%02d", day)) 10:00:00,Workout,10m,\(exercise),1,40,8,0,0,\n",
            unit: .lb, timeZone: TimeZone(secondsFromGMT: 0)!, catalog: catalog)
    }

    private func sessions(_ preview: WorkoutImportPreview) -> [WorkoutSession] {
        preview.sessions(selectedIDs: Set(preview.workouts.map(\.id)))
    }

    @MainActor
    func testImportPersistsPersonalExerciseAndMergedCatalogMatchesAfterRelaunch() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let draft = try preview("Fixture Squat")
        let imported = sessions(draft)
        XCTAssertEqual(store.importWorkouts(imported)?.importedCount, 1)
        let personal = try XCTUnwrap(store.personalExercises.first)
        XCTAssertEqual(personal, imported[0].exercises[0].exercise)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertEqual(reloaded.personalExercises, [personal])
        XCTAssertEqual(Array(reloaded.exercises.prefix(ExerciseCatalog.all.count)), ExerciseCatalog.all)
        XCTAssertEqual(reloaded.exercises.filter { $0.name.localizedCaseInsensitiveContains("fixture") }, [personal])
        let matched = try preview(" FIXTURE   squat ", day: 2, catalog: reloaded.exercises)
        XCTAssertEqual(matched.exerciseMappings[0].matchedExercise, personal)
        XCTAssertEqual(sessions(matched)[0].exercises[0].exercise, personal)
    }

    @MainActor
    func testNormalizedNamesReusePersonalIdentityAcrossUnmatchedImportsAndPreferBundledExercise() async throws {
        let store = WorkoutStore(fileURL: try temporaryFile())
        XCTAssertEqual(store.importWorkouts(sessions(try preview("Fixture Squat")))?.importedCount, 1)
        let personal = try XCTUnwrap(store.personalExercises.first)
        XCTAssertEqual(store.importWorkouts(sessions(try preview("FIXTURE   squat", day: 2)))?.importedCount, 1)
        XCTAssertEqual(store.personalExercises, [personal])
        XCTAssertTrue(store.history.allSatisfy { $0.exercises[0].exercise.id == personal.id })
        XCTAssertEqual(store.importWorkouts(sessions(try preview(" BENCH   press ", day: 3)))?.importedCount, 1)
        XCTAssertEqual(store.personalExercises, [personal])
        let bench = try XCTUnwrap(ExerciseCatalog.all.first { $0.name == "Bench Press" })
        XCTAssertEqual(store.history.first?.exercises[0].exercise, bench)
    }

    @MainActor
    func testLegacySnapshotBackfillsAllSourcesWithoutChangingSavedSnapshots() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let imported = sessions(try preview("Legacy Lift"))
        XCTAssertNotNil(store.importWorkouts(imported))
        let templateExercise = Exercise(name: "Retired Template Lift", category: "Legs")
        let activeExercise = Exercise(name: "Retired Active Lift", category: "Back")
        let template = WorkoutTemplate(name: "Legacy", exercises: [TemplateExercise(exercise: templateExercise)])
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.startWorkout())
        var active = try XCTUnwrap(store.activeWorkout)
        active.exercises = [WorkoutExercise(exercise: activeExercise, sets: [WorkoutSet()])]
        XCTAssertTrue(store.updateActiveWorkout(active))
        let history = store.history
        let templates = store.templates
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        json.removeValue(forKey: "personalExercises")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let legacy = file.deletingPathExtension().appendingPathExtension("json")
        try legacyData.write(to: legacy)
        try FileManager.default.removeItem(at: file)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertEqual(Set(reloaded.personalExercises.map(\.name)), ["Legacy Lift", "Retired Template Lift", "Retired Active Lift"])
        XCTAssertEqual(reloaded.history, history)
        XCTAssertEqual(reloaded.templates, templates)
        XCTAssertEqual(reloaded.activeWorkout, active)
        XCTAssertEqual(try Data(contentsOf: legacy), legacyData)
        XCTAssertTrue(reloaded.setUnit(.lb))
        let persisted = WorkoutStore(fileURL: file)
        XCTAssertEqual(persisted.personalExercises, reloaded.personalExercises)
        XCTAssertEqual(persisted.history, history)
    }

    @MainActor
    func testPersistedPersonalNameOverlapPrefersBundledWithoutRewritingHistory() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        XCTAssertNotNil(store.importWorkouts(sessions(try preview("Former Personal Lift"))))
        let collision = Exercise(name: "BENCH   press", category: "Custom")
        var originalHistory = store.history
        originalHistory[0].exercises[0].exercise = collision
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyJSON(from: store)) as? [String: Any])
        json["history"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(originalHistory))
        json["personalExercises"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([collision]))
        let saved = try JSONSerialization.data(withJSONObject: json)
        let legacy = file.deletingPathExtension().appendingPathExtension("json")
        try saved.write(to: legacy)
        try FileManager.default.removeItem(at: file)
        let reloaded = WorkoutStore(fileURL: file)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertTrue(reloaded.personalExercises.isEmpty)
        XCTAssertEqual(reloaded.exercises, ExerciseCatalog.all)
        XCTAssertEqual(reloaded.history, originalHistory)
        XCTAssertEqual(try Data(contentsOf: legacy), saved)
        XCTAssertTrue(reloaded.setUnit(.lb))
        XCTAssertEqual(WorkoutStore(fileURL: file).history, originalHistory)
    }

    @MainActor
    func testSavedTemplateAndActiveCustomExercisesSurviveSourceDeletionAndDiscard() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let custom = Exercise(name: "Template Custom Lift", category: "Custom")
        let template = WorkoutTemplate(name: "Custom", exercises: [TemplateExercise(exercise: custom)])
        XCTAssertTrue(store.saveTemplate(template))
        XCTAssertTrue(store.deleteTemplate(id: template.id))
        XCTAssertTrue(store.startWorkout())
        var active = try XCTUnwrap(store.activeWorkout)
        let activeCustom = Exercise(name: "Active Custom Lift", category: "Custom")
        active.exercises = [WorkoutExercise(exercise: activeCustom, sets: [WorkoutSet()])]
        XCTAssertTrue(store.updateActiveWorkout(active))
        XCTAssertTrue(store.discardWorkout())
        XCTAssertEqual(WorkoutStore(fileURL: file).personalExercises, [custom, activeCustom])
        let duplicate = WorkoutTemplate(name: "Reuse", exercises: [TemplateExercise(exercise: Exercise(name: "TEMPLATE  CUSTOM LIFT", category: "Custom"))])
        XCTAssertTrue(store.saveTemplate(duplicate))
        XCTAssertEqual(store.templates.last?.exercises[0].exercise, custom)
    }

    @MainActor
    func testCancelledPreviewsAndSkippedDuplicatesDoNotRegisterExercises() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let data = try Data(contentsOf: file)
        _ = sessions(try preview("Cancelled Import Lift", catalog: store.exercises))
        _ = WorkoutTemplate(name: "Cancelled", exercises: [TemplateExercise(exercise: Exercise(name: "Cancelled Template Lift", category: "Custom"))])
        XCTAssertTrue(store.personalExercises.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), data)
        var imported = sessions(try preview("Saved Lift"))
        XCTAssertNotNil(store.importWorkouts(imported))
        let personal = store.personalExercises
        imported[0].exercises[0].exercise = Exercise(name: "Duplicate Only Lift", category: "Custom")
        XCTAssertEqual(store.importWorkouts(imported)?.skippedDuplicateCount, 1)
        XCTAssertEqual(store.personalExercises, personal)
        XCTAssertEqual(WorkoutStore(fileURL: file).personalExercises, personal)
    }

    @MainActor
    func testFailedWritesAndInvalidBatchesDoNotPublishPersonalCatalog() async throws {
        let file = try temporaryFile()
        let store = WorkoutStore(fileURL: file)
        let data = try Data(contentsOf: file)
        var invalid = sessions(try preview("Invalid Batch Lift", day: 2))
        invalid[0].exercises[0].sets[0].reps = 0
        XCTAssertNil(store.importWorkouts(sessions(try preview("Valid Batch Lift")) + invalid))
        XCTAssertTrue(store.personalExercises.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), data)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNil(store.importWorkouts(sessions(try preview("Failed Import Lift"))))
        XCTAssertTrue(store.personalExercises.isEmpty)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertFalse(store.saveTemplate(WorkoutTemplate(name: "Failed", exercises: [TemplateExercise(exercise: Exercise(name: "Failed Template Lift", category: "Custom"))])))
        XCTAssertTrue(store.personalExercises.isEmpty)
        try FileManager.default.removeItem(at: file)
        try data.write(to: file)
        XCTAssertTrue(WorkoutStore(fileURL: file).personalExercises.isEmpty)
        XCTAssertTrue(store.startWorkout())
        let active = try XCTUnwrap(store.activeWorkout)
        var draft = active
        draft.exercises = [WorkoutExercise(exercise: Exercise(name: "Failed Active Lift", category: "Custom"), sets: [WorkoutSet()])]
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(store.updateActiveWorkout(draft))
        XCTAssertEqual(store.activeWorkout, active)
        XCTAssertTrue(store.personalExercises.isEmpty)
    }
}
