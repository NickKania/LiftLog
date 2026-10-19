import Foundation
import XCTest
@testable import LiftLogCore

final class SupersetTests: XCTestCase {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SupersetTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("workouts.sqlite")
    }

    private func entries(_ count: Int = 4) -> [TemplateExercise] {
        (0..<count).map { TemplateExercise(exercise: ExerciseCatalog.all[$0]) }
    }

    private func groupedTemplate() -> WorkoutTemplate {
        var plan = WorkoutTemplate(name: "Superset plan", exercises: entries(3))
        SupersetGrouping.update(&plan.exercises, anchorID: plan.exercises[0].id,
                                selectedIDs: Set(plan.exercises.prefix(2).map(\.id)))
        return plan
    }

    func testGroupingIncludesAnchorIgnoresStaleSelectionsAndPreservesOrderAndSets() throws {
        var exercises = entries()
        let original = exercises
        SupersetGrouping.update(&exercises, anchorID: exercises[0].id,
                                selectedIDs: [exercises[2].id, UUID()])
        let group = try XCTUnwrap(exercises[0].supersetID)
        XCTAssertEqual(exercises[2].supersetID, group)
        XCTAssertNil(exercises[1].supersetID)
        XCTAssertNil(exercises[3].supersetID)
        XCTAssertEqual(exercises.map(\.id), original.map(\.id))
        XCTAssertEqual(exercises.map(\.sets), original.map(\.sets))
        let grouped = exercises
        SupersetGrouping.update(&exercises, anchorID: UUID(), selectedIDs: Set(exercises.map(\.id)))
        XCTAssertEqual(exercises, grouped)
    }

    func testEditingGroupReusesAnchorIdentityDetachesUnselectedAndClearsDonorSingleton() throws {
        var exercises = entries()
        let first = UUID(), second = UUID()
        for index in 0..<2 { exercises[index].supersetID = first }
        for index in 2..<4 { exercises[index].supersetID = second }
        SupersetGrouping.update(&exercises, anchorID: exercises[0].id,
                                selectedIDs: [exercises[0].id, exercises[2].id])
        XCTAssertEqual(exercises.map(\.supersetID), [first, nil, first, nil])
        SupersetGrouping.update(&exercises, anchorID: exercises[0].id, selectedIDs: [exercises[0].id, UUID()])
        XCTAssertTrue(exercises.allSatisfy { $0.supersetID == nil })
    }

    func testMovingMembersPreservesOtherGroupsWithTwoRemainingMembers() {
        var exercises = entries(5)
        let first = UUID(), second = UUID()
        for index in 0..<2 { exercises[index].supersetID = first }
        for index in 2..<5 { exercises[index].supersetID = second }
        SupersetGrouping.update(&exercises, anchorID: exercises[0].id,
                                selectedIDs: [exercises[0].id, exercises[2].id])
        XCTAssertEqual(exercises.map(\.supersetID), [first, nil, first, second, second])
    }

    func testWorkoutGroupingAndNormalizationClearOnlySingletons() {
        let group = UUID(), orphan = UUID()
        var exercises = (0..<3).map { WorkoutExercise(exercise: ExerciseCatalog.all[$0], supersetID: $0 < 2 ? group : orphan) }
        SupersetGrouping.normalize(&exercises)
        XCTAssertEqual(exercises.map(\.supersetID), [group, group, nil])
        exercises.removeFirst()
        SupersetGrouping.normalize(&exercises)
        XCTAssertTrue(exercises.allSatisfy { $0.supersetID == nil })
        SupersetGrouping.update(&exercises, anchorID: exercises[0].id, selectedIDs: Set(exercises.map(\.id)))
        XCTAssertNotNil(exercises[0].supersetID)
        XCTAssertEqual(exercises[0].supersetID, exercises[1].supersetID)
    }

    func testMembershipComparisonIgnoresGroupEntryAndSetIDsButDetectsDifferentPartners() {
        var original = entries(5)
        let first = UUID(), second = UUID()
        for index in [0, 2] { original[index].supersetID = first }
        for index in [1, 3] { original[index].supersetID = second }
        let replacementFirst = UUID(), replacementSecond = UUID()
        var recreated = original.map { entry in
            TemplateExercise(exercise: entry.exercise,
                             sets: entry.sets.map { TemplateSet(weight: $0.weight, targetReps: $0.targetReps) },
                             supersetID: entry.supersetID.map { $0 == first ? replacementFirst : replacementSecond })
        }
        XCTAssertNotEqual(recreated.map(\.id), original.map(\.id))
        XCTAssertNotEqual(recreated.map(\.sets), original.map(\.sets))
        XCTAssertNotEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(recreated))
        XCTAssertTrue(SupersetGrouping.sameMembership(original, recreated))
        XCTAssertTrue(WorkoutStore.samePrescription(original, recreated))

        recreated.swapAt(2, 3)
        XCTAssertFalse(SupersetGrouping.sameMembership(original, recreated))
        XCTAssertFalse(WorkoutStore.samePrescription(original, recreated))
        XCTAssertTrue(SupersetGrouping.sameMembership(original, Array(original.dropLast())))
        XCTAssertFalse(WorkoutStore.samePrescription(original, Array(original.dropLast())))
        var ungrouped = original
        for index in ungrouped.indices { ungrouped[index].supersetID = nil }
        XCTAssertFalse(SupersetGrouping.sameMembership(original, ungrouped))
        XCTAssertTrue(SupersetGrouping.sameMembership([TemplateExercise](), []))
    }

    func testMembershipComparisonDistinguishesRepeatedCatalogEntries() {
        var original = (0..<4).map { _ in TemplateExercise(exercise: ExerciseCatalog.all[0]) }
        let first = UUID(), second = UUID()
        for index in [0, 1] { original[index].supersetID = first }
        for index in [2, 3] { original[index].supersetID = second }
        var changed = original
        changed.swapAt(1, 2)
        XCTAssertTrue(zip(original, changed).allSatisfy { $0.exercise == $1.exercise })
        XCTAssertFalse(SupersetGrouping.sameMembership(original, changed))
        XCTAssertFalse(WorkoutStore.samePrescription(original, changed))

        let replacementFirst = UUID(), replacementSecond = UUID()
        for index in changed.indices {
            changed[index].supersetID = index < 2 ? replacementFirst : replacementSecond
        }
        XCTAssertTrue(SupersetGrouping.sameMembership(original, changed))
        XCTAssertTrue(WorkoutStore.samePrescription(original, changed))
    }

    func testMembershipComparisonTreatsSingletonsAsUngrouped() {
        var exercises = entries(3)
        let group = UUID()
        for index in 0..<2 { exercises[index].supersetID = group }
        exercises[2].supersetID = UUID()
        var normalized = exercises
        SupersetGrouping.normalize(&normalized)
        XCTAssertTrue(SupersetGrouping.sameMembership(exercises, normalized))
        XCTAssertTrue(WorkoutStore.samePrescription(exercises, normalized))
        XCTAssertNotNil(normalized[0].supersetID)
        XCTAssertNil(normalized[2].supersetID)
    }

    func testAppendingUngroupedExerciseChangesPrescriptionWithoutChangingMembership() {
        let original = groupedTemplate().exercises
        let appended = original + [TemplateExercise(exercise: ExerciseCatalog.all[3])]
        XCTAssertTrue(SupersetGrouping.sameMembership(original, appended))
        XCTAssertTrue(SupersetGrouping.sameMembership(appended, original))
        XCTAssertFalse(WorkoutStore.samePrescription(original, appended))
        XCTAssertFalse(WorkoutStore.samePrescription(appended, original))

        let ungrouped = entries(1)
        XCTAssertTrue(SupersetGrouping.sameMembership([], ungrouped))
        XCTAssertFalse(WorkoutStore.samePrescription([], ungrouped))
    }

    func testMemberIDsIgnoreUngroupedRemovalBeforeBetweenAndAfterGroups() {
        var original = entries(7)
        let first = UUID(), second = UUID()
        for index in [1, 3] { original[index].supersetID = first }
        for index in [4, 5] { original[index].supersetID = second }
        let expected: Set<Set<UUID>> = [
            [original[1].id, original[3].id],
            [original[4].id, original[5].id]
        ]
        XCTAssertEqual(SupersetGrouping.memberIDs(original), expected)
        for index in [0, 2, 6] {
            var removed = original
            removed.remove(at: index)
            XCTAssertEqual(SupersetGrouping.memberIDs(removed), expected)
            XCTAssertFalse(WorkoutStore.samePrescription(original, removed))
            XCTAssertFalse(WorkoutStore.samePrescription(removed, original))
        }
    }

    func testMemberIDsIgnoreRecreatedGroupIDsEntryOrderAndSingletons() {
        var original = entries(5)
        let first = UUID(), second = UUID()
        for index in [0, 2] { original[index].supersetID = first }
        for index in [1, 3] { original[index].supersetID = second }
        original[4].supersetID = UUID()
        var recreated = original
        let replacementFirst = UUID(), replacementSecond = UUID()
        for index in 0..<4 {
            recreated[index].supersetID = original[index].supersetID == first ? replacementFirst : replacementSecond
        }
        SupersetGrouping.normalize(&recreated)
        XCTAssertEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(recreated))
        XCTAssertTrue(WorkoutStore.samePrescription(original, recreated))
        recreated.reverse()
        XCTAssertEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(recreated))
        XCTAssertTrue(SupersetGrouping.memberIDs([TemplateExercise]()).isEmpty)
        XCTAssertTrue(SupersetGrouping.memberIDs([original[4]]).isEmpty)
        XCTAssertTrue(SupersetGrouping.memberIDs(entries(2)).isEmpty)
    }

    func testMemberIDsDetectMovesAndRemovalsOfRepeatedCatalogEntries() {
        var original = (0..<6).map { _ in TemplateExercise(exercise: ExerciseCatalog.all[0]) }
        let first = UUID(), second = UUID()
        for index in 0..<3 { original[index].supersetID = first }
        for index in 3..<6 { original[index].supersetID = second }
        let expected: Set<Set<UUID>> = [
            Set(original.prefix(3).map(\.id)),
            Set(original.suffix(3).map(\.id))
        ]
        XCTAssertEqual(SupersetGrouping.memberIDs(original), expected)

        var moved = original
        moved[2].supersetID = second
        XCTAssertNotEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(moved))
        XCTAssertFalse(WorkoutStore.samePrescription(original, moved))
        var removed = original
        removed.removeFirst()
        XCTAssertNotEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(removed))
        XCTAssertFalse(WorkoutStore.samePrescription(original, removed))

        var reordered = original
        reordered.swapAt(1, 4)
        XCTAssertEqual(SupersetGrouping.memberIDs(original), SupersetGrouping.memberIDs(reordered))
        XCTAssertFalse(SupersetGrouping.sameMembership(original, reordered))
        XCTAssertFalse(WorkoutStore.samePrescription(original, reordered))
    }

    func testMemberIDsUseWorkoutEntryIdentitiesAndIgnoreOrphanedPartners() {
        let group = UUID()
        var exercises = (0..<3).map { WorkoutExercise(exercise: ExerciseCatalog.all[$0], supersetID: group) }
        XCTAssertEqual(SupersetGrouping.memberIDs(exercises), [Set(exercises.map(\.id))])
        exercises.removeLast()
        XCTAssertEqual(SupersetGrouping.memberIDs(exercises), [Set(exercises.map(\.id))])
        exercises.removeLast()
        XCTAssertTrue(SupersetGrouping.memberIDs(exercises).isEmpty)
    }

    func testLegacyExercisesDecodeWithoutSupersetAndGroupedExercisesRoundTrip() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let template = TemplateExercise(exercise: ExerciseCatalog.all[0], supersetID: UUID())
        let workout = WorkoutExercise(exercise: ExerciseCatalog.all[0], supersetID: UUID())
        XCTAssertEqual(try decoder.decode(TemplateExercise.self, from: encoder.encode(template)), template)
        XCTAssertEqual(try decoder.decode(WorkoutExercise.self, from: encoder.encode(workout)), workout)
        func legacyData<T: Encodable>(_ value: T) throws -> Data {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any])
            json.removeValue(forKey: "supersetID")
            return try JSONSerialization.data(withJSONObject: json)
        }
        XCTAssertNil(try decoder.decode(TemplateExercise.self, from: legacyData(template)).supersetID)
        XCTAssertNil(try decoder.decode(WorkoutExercise.self, from: legacyData(workout)).supersetID)
    }

    func testDatabaseJSONAndBackupRoundTripAllGroupedRecords() throws {
        let url = try file()
        var plan = groupedTemplate()
        plan.versions = [WorkoutTemplateVersion(number: 1, name: plan.name, exercises: plan.exercises, unit: .lb)]
        let exercises = plan.exercises.map { WorkoutExercise(exercise: $0.exercise, sets: [WorkoutSet(isCompleted: true)], supersetID: $0.supersetID) }
        let history = WorkoutSession(name: "Finished", startedAt: Date(timeIntervalSinceReferenceDate: 100),
                                     finishedAt: Date(timeIntervalSinceReferenceDate: 200), exercises: exercises)
        let active = WorkoutSession(exercises: exercises)
        let snapshot = WorkoutSnapshot(templates: [plan], history: [history], activeWorkout: active, unit: .lb)
        let database = WorkoutDatabase(url: url)
        try database.save(snapshot)
        let backup = url.deletingLastPathComponent().appendingPathComponent("backup.sqlite")
        try database.backup(to: backup)
        for actual in [try database.load(), try WorkoutDatabase(url: backup).load(),
                       try JSONDecoder().decode(WorkoutSnapshot.self, from: JSONEncoder().encode(snapshot))] {
            XCTAssertEqual(actual.templates, snapshot.templates)
            XCTAssertEqual(actual.history, snapshot.history)
            XCTAssertEqual(actual.activeWorkout, snapshot.activeWorkout)
        }
        XCTAssertEqual(try SQLiteConnection(url: url, readOnly: true).rows("PRAGMA user_version").first?.integer("user_version"), 7)
    }

    func testV3DatabaseReadsWithoutMutationAndV4MigrationRollsBackThenSucceeds() throws {
        let url = try file()
        let original = WorkoutSnapshot(templates: [WorkoutTemplate(name: "Legacy", exercises: entries(2))], history: [], activeWorkout: nil, unit: .lb)
        let database = WorkoutDatabase(url: url)
        try database.save(original)
        do {
            let db = try SQLiteConnection(url: url)
            try db.execute("DROP TABLE exercise_instruction_overrides")
            try db.execute("DROP TABLE favorite_exercises")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN superset_id")
            try db.execute("ALTER TABLE exercise_entries DROP COLUMN template_exercise_id")
            try db.execute("PRAGMA user_version = 3")
            try db.execute("CREATE TRIGGER reject_records BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'failed upgrade'); END")
        }
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(try database.load().templates, original.templates)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var grouped = original
        SupersetGrouping.update(&grouped.templates[0].exercises, anchorID: grouped.templates[0].exercises[0].id,
                                selectedIDs: Set(grouped.templates[0].exercises.map(\.id)))
        XCTAssertThrowsError(try database.save(grouped))
        XCTAssertEqual(try database.load().templates, original.templates)
        do {
            let db = try SQLiteConnection(url: url)
            XCTAssertEqual(try db.rows("PRAGMA user_version").first?.integer("user_version"), 3)
            XCTAssertFalse(try db.rows("PRAGMA table_info(exercise_entries)").contains { try $0.text("name") == "superset_id" })
            try db.execute("DROP TRIGGER reject_records")
        }
        try database.save(grouped)
        XCTAssertEqual(try database.load().templates, grouped.templates)
    }

    @MainActor
    func testRecreatingSameSupersetInDraftDoesNotCreateVersionOrReplaceSavedIdentities() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let initial = groupedTemplate()
        XCTAssertTrue(store.saveTemplate(initial))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        var draft = saved
        let anchorID = draft.exercises[0].id
        let selectedIDs = Set(draft.exercises.prefix(2).map(\.id))
        SupersetGrouping.update(&draft.exercises, anchorID: anchorID, selectedIDs: [anchorID])
        XCTAssertTrue(draft.exercises.allSatisfy { $0.supersetID == nil })
        SupersetGrouping.update(&draft.exercises, anchorID: anchorID, selectedIDs: selectedIDs)
        XCTAssertNotEqual(draft.exercises[0].supersetID, saved.exercises[0].supersetID)
        XCTAssertTrue(WorkoutStore.samePrescription(draft.exercises, saved.exercises))
        XCTAssertTrue(store.saveTemplate(draft))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }, saved)

        draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        SupersetGrouping.update(&draft.exercises, anchorID: anchorID, selectedIDs: [anchorID])
        SupersetGrouping.update(&draft.exercises, anchorID: anchorID, selectedIDs: selectedIDs)
        draft.name = "Renamed superset plan"
        XCTAssertTrue(store.saveTemplate(draft))
        let renamed = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(renamed.name, draft.name)
        XCTAssertEqual(renamed.exercises, saved.exercises)
        XCTAssertEqual(renamed.versions, saved.versions)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates.first { $0.id == initial.id }, renamed)
    }

    @MainActor
    func testSupersetEditsCreateVersionsAndStartArchivedGroupsWithoutMutatingThem() async throws {
        let store = WorkoutStore(fileURL: try file())
        let initial = groupedTemplate()
        XCTAssertTrue(store.saveTemplate(initial))
        var draft = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        let original = try XCTUnwrap(draft.currentVersion)
        SupersetGrouping.update(&draft.exercises, anchorID: draft.exercises[0].id,
                                selectedIDs: Set(draft.exercises.map(\.id)))
        XCTAssertTrue(store.saveTemplate(draft))
        let saved = try XCTUnwrap(store.templates.first { $0.id == initial.id })
        XCTAssertEqual(saved.versions.count, 2)
        XCTAssertEqual(saved.versions[0], original)
        XCTAssertTrue(store.saveTemplate(saved))
        XCTAssertEqual(store.templates.first { $0.id == initial.id }?.versions.count, 2)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertTrue(store.startWorkout(template: saved, versionID: original.id))
        XCTAssertEqual(store.activeWorkout?.exercises.map(\.supersetID), original.exercises.map(\.supersetID))
        XCTAssertNotEqual(store.activeWorkout?.exercises.map(\.id), original.exercises.map(\.id))
    }

    @MainActor
    func testActiveSaveReloadAndFinishPreserveGroupsAndClearUnfinishedPartner() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let plan = groupedTemplate()
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        var workout = try XCTUnwrap(store.activeWorkout)
        for index in 0..<2 { workout.exercises[index].sets[0].isCompleted = true }
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout, store.activeWorkout)
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history[0].exercises.map(\.supersetID), Array(plan.exercises.prefix(2)).map(\.supersetID))
        XCTAssertEqual(WorkoutStore(fileURL: url).history, store.history)
        XCTAssertTrue(store.startWorkout(template: plan))
        workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertTrue(store.finishWorkout())
        XCTAssertEqual(store.history[0].exercises.count, 1)
        XCTAssertNil(store.history[0].exercises[0].supersetID)
    }

    @MainActor
    func testRemovingTemplateOrActivePartnerClearsSingletonBeforeSave() async throws {
        let store = WorkoutStore(fileURL: try file())
        let plan = groupedTemplate()
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises.remove(at: 1)
        XCTAssertTrue(store.updateActiveWorkout(workout))
        XCTAssertNil(store.activeWorkout?.exercises[0].supersetID)
        var draft = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        draft.exercises.remove(at: 1)
        XCTAssertTrue(store.saveTemplate(draft))
        let saved = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        XCTAssertNil(saved.exercises[0].supersetID)
        XCTAssertNil(saved.currentVersion?.exercises[0].supersetID)
    }

    @MainActor
    func testAssistantUpdatesPreserveSupersetAndRemovalDraftsClearSingletons() async throws {
        let store = WorkoutStore(fileURL: try file())
        let plan = groupedTemplate()
        XCTAssertTrue(store.saveTemplate(plan))
        XCTAssertTrue(store.startWorkout(template: plan))
        let tools = WorkoutAgentTools(store: store)
        let template = try XCTUnwrap(store.templates.first { $0.id == plan.id })
        let workout = try XCTUnwrap(store.activeWorkout)
        for (target, id, entryID, exerciseID, group) in [
            ("template", template.id, template.exercises[0].id, template.exercises[0].exercise.id, template.exercises[0].supersetID),
            ("active_workout", workout.id, workout.exercises[0].id, workout.exercises[0].exercise.id, workout.exercises[0].supersetID)
        ] {
            let update: [String: Any] = ["target": target, "target_id": id.uuidString, "operation": "update",
                                         "entry_id": entryID.uuidString, "exercise_id": exerciseID.uuidString,
                                         "sets": [["weight": 25, "reps": 10]], "unit": "lb"]
            let result = try tools.execute(name: "propose_edit_exercise", arguments: String(decoding: JSONSerialization.data(withJSONObject: update), as: UTF8.self))
            let proposal = try XCTUnwrap(result.proposal)
            if target == "template" {
                XCTAssertEqual(proposal.afterTemplate?.exercises[0].supersetID, group)
            } else {
                XCTAssertEqual(proposal.afterWorkout?.exercises[0].supersetID, group)
            }
            var remove = update
            remove["operation"] = "remove"
            remove.removeValue(forKey: "exercise_id")
            remove.removeValue(forKey: "sets")
            let removed = try XCTUnwrap(tools.execute(name: "propose_edit_exercise", arguments: String(decoding: JSONSerialization.data(withJSONObject: remove), as: UTF8.self)).proposal)
            if target == "template" {
                XCTAssertNil(removed.afterTemplate?.exercises[0].supersetID)
            } else {
                XCTAssertNil(removed.afterWorkout?.exercises[0].supersetID)
            }
        }
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertEqual(store.templates.first { $0.id == plan.id }, template)
    }

    @MainActor
    func testReviewedWorkoutStartPreservesGroups() async throws {
        let url = try file()
        let store = WorkoutStore(fileURL: url)
        let plan = groupedTemplate()
        let workout = WorkoutSession(exercises: plan.exercises.map {
            WorkoutExercise(exercise: $0.exercise, supersetID: $0.supersetID)
        })
        XCTAssertTrue(store.startReviewedWorkout(workout))
        XCTAssertEqual(store.activeWorkout?.exercises, workout.exercises)
        XCTAssertEqual(WorkoutStore(fileURL: url).activeWorkout?.exercises, workout.exercises)
    }
}
