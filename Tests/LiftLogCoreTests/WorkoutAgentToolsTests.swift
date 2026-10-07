import XCTest
@testable import LiftLogCore

final class WorkoutAgentToolsTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WorkoutAgentToolsTests-\(UUID())", isDirectory: true).appendingPathComponent("workouts.json")
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    @MainActor private func createArgs(_ store: WorkoutStore, weight: Double = 100, unit: String = "lb") -> [String: Any] {
        ["name": "Assistant plan", "unit": unit, "exercises": [["exercise_id": store.exercises[0].id.uuidString, "sets": [["weight": weight, "reps": 8]]]]]
    }
    @MainActor private func editArgs(_ workout: WorkoutSession, operation: String, entryID: UUID, exerciseID: UUID? = nil) -> [String: Any] {
        ["target": "active_workout", "target_id": workout.id.uuidString, "operation": operation,
         "entry_id": entryID.uuidString, "exercise_id": exerciseID.map { $0.uuidString as Any } ?? NSNull(),
         "sets": exerciseID == nil ? NSNull() : [["weight": 30, "reps": 5]], "unit": "lb"]
    }

    @MainActor func testNamespaceDefinitionsExposeProposalsAndNeverApply() async throws {
        let namespace = try XCTUnwrap(WorkoutAgentTools.definitions.first)
        XCTAssertEqual(namespace["type"] as? String, "namespace")
        XCTAssertEqual(namespace["name"] as? String, "liftlog")
        let tools = try XCTUnwrap(namespace["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("propose_edit_workout_exercises"))
        XCTAssertTrue(names.contains("propose_template_version"))
        XCTAssertTrue(names.contains("get_template_versions"))
        XCTAssertFalse(names.contains("apply_proposal"))
        XCTAssertFalse(names.contains("finish_workout"))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(WorkoutAgentTools.definitions))
    }

    @MainActor func testCreateNeedsReviewAndAppliesExactlyOncePersistently() async throws {
        let url = file()
        let store = WorkoutStore(fileURL: url)
        let tools = WorkoutAgentTools(store: store)
        let original = store.templates
        let disk = try Data(contentsOf: url)
        let response = try tools.execute(name: "liftlog.propose_create_template", argumentsJSONString: json(createArgs(store)))
        let proposal = try XCTUnwrap(response.proposal)
        XCTAssertEqual(store.templates, original)
        XCTAssertEqual(try Data(contentsOf: url), disk)
        XCTAssertEqual(tools.pendingProposals.count, 1)
        XCTAssertNil(proposal.beforeTemplate)
        XCTAssertEqual(proposal.afterTemplate?.exercises.first?.sets.first?.weight, 100)
        XCTAssertEqual(try tools.applyProposal(proposal.id).status, .applied)
        XCTAssertEqual(store.templates.last?.id, proposal.afterTemplate?.id)
        XCTAssertEqual(store.templates.last?.exercises, proposal.afterTemplate?.exercises)
        XCTAssertEqual(store.templates.last?.currentVersion?.number, 1)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates, store.templates)
        XCTAssertThrowsError(try tools.applyProposal(proposal.id)) { XCTAssertEqual($0 as? WorkoutAgentToolError, .proposalAlreadyResolved) }
    }

    @MainActor func testUntrustedArgumentsCannotBypassReviewOrInventHistory() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let before = store.templates
        for name in ["apply_proposal", "finish_workout", "delete_history", "other.get_templates"] {
            XCTAssertThrowsError(try tools.execute(name: name, arguments: "{}"))
        }
        for value in ["[]", "garbage", "{\"isCompleted\":true}"] {
            XCTAssertThrowsError(try tools.execute(name: "get_templates", arguments: value))
        }
        var args = createArgs(store)
        args["isCompleted"] = true
        XCTAssertThrowsError(try tools.execute(name: "propose_create_workout", arguments: json(args)))
        let malformedSets: [[String: Any]] = [
            ["weight": -1, "reps": 8], ["weight": true, "reps": 8], ["weight": 10, "reps": 2.5],
            ["weight": 10, "reps": 0], ["weight": 10, "reps": 8, "isCompleted": true]
        ]
        for set in malformedSets {
            args = createArgs(store)
            args["exercises"] = [["exercise_id": store.exercises[0].id.uuidString, "sets": [set]]]
            XCTAssertThrowsError(try tools.execute(name: "propose_create_template", arguments: json(args)))
        }
        XCTAssertEqual(store.templates, before)
        XCTAssertNil(store.activeWorkout)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertTrue(tools.pendingProposals.isEmpty)
    }

    @MainActor func testStaleProposalsFailEvenWhenUnitChangeIsReverted() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let proposal = try XCTUnwrap(tools.execute(name: "propose_create_template", arguments: json(createArgs(store))).proposal)
        XCTAssertTrue(store.setUnit(.kg))
        XCTAssertTrue(store.setUnit(.lb))
        XCTAssertThrowsError(try tools.applyProposal(proposal.id)) { XCTAssertEqual($0 as? WorkoutAgentToolError, .staleProposal) }
        XCTAssertEqual(tools.proposal(proposal.id)?.status, .stale)
        XCTAssertEqual(store.templates.count, 2)
    }

    @MainActor func testRejectedAndUnknownProposalsCannotApply() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        XCTAssertThrowsError(try tools.applyProposal(UUID())) { XCTAssertEqual($0 as? WorkoutAgentToolError, .unknownProposal) }
        let proposal = try XCTUnwrap(tools.execute(name: "propose_create_template", arguments: json(createArgs(store))).proposal)
        XCTAssertEqual(try tools.rejectProposal(proposal.id).status, .rejected)
        XCTAssertThrowsError(try tools.applyProposal(proposal.id))
        XCTAssertEqual(store.templates.count, 2)
    }

    @MainActor func testFailedWriteLeavesPendingProposalAndStoreUntouched() async throws {
        let url = file()
        let store = WorkoutStore(fileURL: url)
        let tools = WorkoutAgentTools(store: store)
        let original = store.templates
        let proposal = try XCTUnwrap(tools.execute(name: "propose_create_template", arguments: json(createArgs(store))).proposal)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try tools.applyProposal(proposal.id))
        XCTAssertEqual(store.templates, original)
        XCTAssertEqual(tools.proposal(proposal.id)?.status, .pending)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try tools.applyProposal(proposal.id).status, .applied)
    }

    @MainActor func testActiveCreationCannotOverwriteWorkoutAndUsesConvertedPlannedSets() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let proposal = try XCTUnwrap(tools.execute(name: "propose_create_workout", arguments: json(createArgs(store, weight: 45.359237, unit: "kg"))).proposal)
        XCTAssertNil(store.activeWorkout)
        XCTAssertEqual(try tools.applyProposal(proposal.id).status, .applied)
        let active = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(active.exercises[0].sets[0].weight, 100, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(active.exercises[0].sets[0].targetWeight), 100, accuracy: 0.00001)
        XCTAssertFalse(active.exercises[0].sets[0].isCompleted)
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertThrowsError(try tools.execute(name: "propose_create_workout", arguments: json(createArgs(store)))) { XCTAssertEqual($0 as? WorkoutAgentToolError, .activeWorkoutExists) }
        XCTAssertEqual(store.activeWorkout, active)
    }

    @MainActor func testStaleActiveEditPreservesNewCompletion() async throws {
        let store = WorkoutStore(fileURL: file())
        XCTAssertTrue(store.startWorkout(template: store.templates[0]))
        let tools = WorkoutAgentTools(store: store)
        var workout = try XCTUnwrap(store.activeWorkout)
        let proposal = try XCTUnwrap(tools.execute(name: "propose_edit_exercise", arguments: json(editArgs(workout, operation: "remove", entryID: workout.exercises[0].id))).proposal)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        workout = try XCTUnwrap(store.activeWorkout)
        XCTAssertThrowsError(try tools.applyProposal(proposal.id))
        XCTAssertEqual(store.activeWorkout, workout)
    }

    @MainActor func testCompletedActiveEntryRemovalIsReviewedWithoutChangingHistoryOrTemplate() async throws {
        let store = WorkoutStore(fileURL: file())
        let template = store.templates[0]
        XCTAssertTrue(store.startWorkout(template: template))
        var workout = try XCTUnwrap(store.activeWorkout)
        workout.exercises[0].sets[0].isCompleted = true
        XCTAssertTrue(store.updateActiveWorkout(workout))
        workout = try XCTUnwrap(store.activeWorkout)
        let tools = WorkoutAgentTools(store: store)
        XCTAssertThrowsError(try tools.execute(name: "propose_edit_exercise", arguments: json(editArgs(workout, operation: "update", entryID: workout.exercises[0].id, exerciseID: store.exercises[0].id))))
        let proposal = try XCTUnwrap(tools.execute(name: "propose_edit_exercise", arguments: json(editArgs(workout, operation: "remove", entryID: workout.exercises[0].id))).proposal)
        XCTAssertTrue(try XCTUnwrap(proposal.beforeWorkout).exercises[0].sets[0].isCompleted)
        XCTAssertEqual(store.activeWorkout, workout)
        try tools.applyProposal(proposal.id)
        XCTAssertEqual(store.activeWorkout?.exercises.count, workout.exercises.count - 1)
        XCTAssertEqual(store.templates[0], template)
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor func testBatchEditsProduceOneProposalAndPersistTogether() async throws {
        let url = file()
        let store = WorkoutStore(fileURL: url)
        let tools = WorkoutAgentTools(store: store)
        let template = store.templates[0]
        let args: [String: Any] = ["target": "template", "target_id": template.id.uuidString, "unit": "lb", "operations": [
            ["operation": "update", "entry_id": template.exercises[0].id.uuidString, "exercise_id": store.exercises[2].id.uuidString, "sets": [["weight": 70, "reps": 6]]],
            ["operation": "remove", "entry_id": template.exercises[1].id.uuidString, "exercise_id": NSNull(), "sets": NSNull()]
        ]]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_edit_workout_exercises", arguments: json(args)).proposal)
        XCTAssertEqual(tools.pendingProposals.count, 1)
        XCTAssertEqual(store.templates[0], template)
        try tools.applyProposal(proposal.id)
        XCTAssertEqual(store.templates[0].exercises.count, template.exercises.count - 1)
        XCTAssertEqual(store.templates[0].exercises[0].exercise.id, store.exercises[2].id)
        XCTAssertEqual(store.templates[0].exercises[0].sets[0].weight, 70)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates, store.templates)
    }

    @MainActor func testInvalidBatchLeavesNoPartialProposal() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let template = store.templates[0]
        let args: [String: Any] = ["target": "template", "target_id": template.id.uuidString, "unit": "lb", "operations": [
            ["operation": "remove", "entry_id": template.exercises[0].id.uuidString, "exercise_id": NSNull(), "sets": NSNull()],
            ["operation": "remove", "entry_id": UUID().uuidString, "exercise_id": NSNull(), "sets": NSNull()]
        ]]
        XCTAssertThrowsError(try tools.execute(name: "propose_edit_workout_exercises", arguments: json(args)))
        XCTAssertTrue(tools.pendingProposals.isEmpty)
        XCTAssertEqual(store.templates[0], template)
    }

    @MainActor func testTemplateVersionProposalPreservesBeforeAndAfterAndBecomesDefaultAfterReview() async throws {
        let url = file()
        let store = WorkoutStore(fileURL: url)
        let tools = WorkoutAgentTools(store: store)
        let before = store.templates[0]
        let base = try XCTUnwrap(before.currentVersion)
        let entry = before.exercises[0]
        let sets = entry.sets.map { ["weight": $0.weight + 5, "reps": $0.targetReps + 1] as [String: Any] }
        let args: [String: Any] = ["template_id": before.id.uuidString, "base_version_id": base.id.uuidString,
                                  "unit": "lb", "operations": [["operation": "update", "entry_id": entry.id.uuidString,
                                                                "exercise_id": entry.exercise.id.uuidString, "sets": sets]]]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_template_version", arguments: json(args)).proposal)
        XCTAssertEqual(store.templates[0], before)
        XCTAssertEqual(proposal.beforeTemplate, before)
        XCTAssertEqual(proposal.afterTemplate?.exercises[0].sets[0].id, entry.sets[0].id)
        XCTAssertEqual(proposal.afterTemplate?.exercises[0].sets[0].weight, entry.sets[0].weight + 5)
        XCTAssertEqual(proposal.afterTemplate?.exercises[0].sets[0].targetReps, entry.sets[0].targetReps + 1)
        XCTAssertTrue(proposal.summary.contains("version \(base.number + 1)"))
        try tools.applyProposal(proposal.id)
        let updated = store.templates[0]
        XCTAssertEqual(updated.versions.dropLast(), before.versions[...])
        XCTAssertEqual(updated.currentVersion?.number, base.number + 1)
        XCTAssertTrue(store.startWorkout(template: updated))
        let active = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(active.templateVersionID, updated.currentVersion?.id)
        XCTAssertEqual(active.templateVersionNumber, updated.currentVersion?.number)
        XCTAssertEqual(active.exercises[0].sets[0].targetWeight, entry.sets[0].weight + 5)
        XCTAssertEqual(active.exercises[0].sets[0].targetReps, entry.sets[0].targetReps + 1)
        XCTAssertEqual(WorkoutStore(fileURL: url).templates, store.templates)
    }

    @MainActor func testOutdatedBaseVersionRejectedAndPendingVersionBecomesStale() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        var template = store.templates[0]
        let entry = template.exercises[0]
        let base = try XCTUnwrap(template.currentVersion)
        let args: [String: Any] = ["template_id": template.id.uuidString, "base_version_id": base.id.uuidString,
                                  "unit": "lb", "operations": [["operation": "update", "entry_id": entry.id.uuidString,
                                                                "exercise_id": entry.exercise.id.uuidString,
                                                                "sets": [["weight": 140, "reps": 9]]]]]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_template_version", arguments: json(args)).proposal)
        template.exercises[0].sets[0].targetReps += 2
        XCTAssertTrue(store.saveTemplate(template))
        let changed = store.templates[0]
        XCTAssertThrowsError(try tools.execute(name: "propose_template_version", arguments: json(args))) {
            XCTAssertEqual($0 as? WorkoutAgentToolError, .staleProposal)
        }
        XCTAssertThrowsError(try tools.applyProposal(proposal.id)) {
            XCTAssertEqual($0 as? WorkoutAgentToolError, .staleProposal)
        }
        XCTAssertEqual(tools.proposal(proposal.id)?.status, .stale)
        XCTAssertEqual(store.templates[0], changed)
        XCTAssertEqual(tools.pendingProposals.count, 0)
    }

    @MainActor func testCurrentTemplateReadsAreCompactAndVersionHistoryUsesOriginalUnits() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        var template = store.templates[0]
        let first = try XCTUnwrap(template.currentVersion)
        XCTAssertTrue(store.setUnit(.kg))
        template = store.templates[0]
        template.exercises[0].sets[0].weight = 60
        XCTAssertTrue(store.saveTemplate(template))
        let latest = try XCTUnwrap(store.templates[0].currentVersion)
        let output = try tools.execute(name: "get_templates", arguments: "{}").outputJSONString
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])
        XCTAssertEqual(current[0]["unit"] as? String, "kg")
        XCTAssertEqual(current[0]["currentVersionID"] as? String, latest.id.uuidString)
        XCTAssertEqual(current[0]["currentVersionNumber"] as? Int, latest.number)
        XCTAssertNil(current[0]["versions"])
        let pageOutput = try tools.execute(name: "get_template_versions", arguments: json([
            "template_id": template.id.uuidString, "limit": 1, "offset": 1
        ])).outputJSONString
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pageOutput.utf8)) as? [String: Any])
        XCTAssertEqual(page["total"] as? Int, 2)
        XCTAssertEqual(page["offset"] as? Int, 1)
        let versions = try XCTUnwrap(page["versions"] as? [[String: Any]])
        XCTAssertEqual(versions.count, 1)
        XCTAssertEqual(versions[0]["id"] as? String, first.id.uuidString)
        XCTAssertEqual(versions[0]["unit"] as? String, "lb")
        XCTAssertThrowsError(try tools.execute(name: "get_template_versions", arguments: json([
            "template_id": template.id.uuidString, "limit": 21, "offset": 0
        ])))
        XCTAssertThrowsError(try tools.execute(name: "get_template_versions", arguments: json([
            "template_id": UUID().uuidString, "limit": 1, "offset": 0
        ])))
    }

    @MainActor func testActiveActualEditsKeepOriginalPlannedTargetsAndSetIdentity() async throws {
        let store = WorkoutStore(fileURL: file())
        XCTAssertTrue(store.startWorkout(template: store.templates[0]))
        let before = try XCTUnwrap(store.activeWorkout)
        let entry = before.exercises[0]
        let tools = WorkoutAgentTools(store: store)
        let args: [String: Any] = ["target": "active_workout", "target_id": before.id.uuidString,
                                  "operation": "update", "entry_id": entry.id.uuidString,
                                  "exercise_id": entry.exercise.id.uuidString, "unit": before.unit.rawValue,
                                  "sets": entry.sets.map { ["weight": $0.weight + 10, "reps": $0.reps + 2] as [String: Any] }]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_edit_exercise", arguments: json(args)).proposal)
        let draft = try XCTUnwrap(proposal.afterWorkout)
        XCTAssertEqual(draft.exercises[0].sets.map(\.id), entry.sets.map(\.id))
        XCTAssertEqual(draft.exercises[0].sets.map(\.targetReps), entry.sets.map(\.targetReps))
        XCTAssertEqual(draft.exercises[0].sets.map(\.targetWeight), entry.sets.map(\.targetWeight))
        try tools.applyProposal(proposal.id)
        let after = try XCTUnwrap(store.activeWorkout)
        XCTAssertEqual(after.exercises[0].sets[0].weight, entry.sets[0].weight + 10)
        XCTAssertEqual(after.exercises[0].sets[0].reps, entry.sets[0].reps + 2)
        XCTAssertEqual(after.exercises[0].sets[0].targetWeight, entry.sets[0].targetWeight)
        XCTAssertEqual(after.exercises[0].sets[0].targetReps, entry.sets[0].targetReps)
    }

    @MainActor func testUnchangedVersionProposalDoesNotClaimANewVersion() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let template = store.templates[0]
        let entry = template.exercises[0]
        let args: [String: Any] = ["template_id": template.id.uuidString,
                                  "base_version_id": try XCTUnwrap(template.currentVersion).id.uuidString,
                                  "unit": store.unit.rawValue,
                                  "operations": [["operation": "update", "entry_id": entry.id.uuidString,
                                                   "exercise_id": entry.exercise.id.uuidString,
                                                   "sets": entry.sets.map { ["weight": $0.weight, "reps": $0.targetReps] as [String: Any] }]]]
        XCTAssertThrowsError(try tools.execute(name: "propose_template_version", arguments: json(args)))
        XCTAssertTrue(tools.pendingProposals.isEmpty)
        XCTAssertEqual(store.templates[0], template)
    }

    @MainActor func testSemanticallyUnchangedVersionWithNewEntryIDsAndConvertedUnitsIsRejected() async throws {
        let store = WorkoutStore(fileURL: file())
        XCTAssertTrue(store.saveTemplate(WorkoutTemplate(name: "Stable plan", exercises: [
            TemplateExercise(exercise: store.exercises[0], sets: [TemplateSet(weight: 100, targetReps: 8)])
        ])))
        let template = try XCTUnwrap(store.templates.last)
        let entry = template.exercises[0]
        let tools = WorkoutAgentTools(store: store)
        let args: [String: Any] = ["template_id": template.id.uuidString,
                                  "base_version_id": try XCTUnwrap(template.currentVersion).id.uuidString,
                                  "unit": "kg", "operations": [
                                    ["operation": "add", "entry_id": NSNull(), "exercise_id": entry.exercise.id.uuidString,
                                     "sets": [["weight": 45.359237 + 1e-12, "reps": 8]]],
                                    ["operation": "remove", "entry_id": entry.id.uuidString,
                                     "exercise_id": NSNull(), "sets": NSNull()]
                                  ]]
        XCTAssertThrowsError(try tools.execute(name: "propose_template_version", arguments: json(args)))
        XCTAssertTrue(tools.pendingProposals.isEmpty)
        XCTAssertEqual(store.templates.last, template)
    }

    @MainActor func testRestoreInvalidatesPendingVersionWithSameVersionIDAndDifferentUnit() async throws {
        let url = file()
        let store = WorkoutStore(fileURL: url)
        var template = store.templates[0]
        template.exercises[0].sets[0].weight = 100
        XCTAssertTrue(store.saveTemplate(template))
        template = store.templates[0]
        let base = try XCTUnwrap(template.currentVersion)
        let entry = template.exercises[0]

        let backupURL = url.deletingLastPathComponent().appendingPathComponent("kg-backup.sqlite")
        try WorkoutDatabase(url: url).backup(to: backupURL)
        let backupStore = WorkoutStore(fileURL: backupURL)
        XCTAssertTrue(backupStore.setUnit(.kg))
        XCTAssertEqual(backupStore.templates[0].currentVersion?.id, base.id)

        let tools = WorkoutAgentTools(store: store)
        let args: [String: Any] = ["template_id": template.id.uuidString, "base_version_id": base.id.uuidString,
                                  "unit": "lb", "operations": [["operation": "update", "entry_id": entry.id.uuidString,
                                                                "exercise_id": entry.exercise.id.uuidString,
                                                                "sets": [["weight": 140, "reps": 9]]]]]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_template_version", arguments: json(args)).proposal)
        let beforeRestoreRevision = store.revision
        try store.restoreDatabase(from: backupURL)
        XCTAssertGreaterThan(store.revision, beforeRestoreRevision)
        XCTAssertEqual(store.unit, .kg)
        XCTAssertEqual(store.templates[0].currentVersion?.id, base.id)
        let restored = store.templates
        let restoredDisk = try Data(contentsOf: url)
        XCTAssertThrowsError(try tools.applyProposal(proposal.id)) {
            XCTAssertEqual($0 as? WorkoutAgentToolError, .staleProposal)
        }
        XCTAssertEqual(tools.proposal(proposal.id)?.status, .stale)
        XCTAssertEqual(store.templates, restored)
        XCTAssertEqual(store.templates[0].exercises[0].sets[0].weight, 45.359237, accuracy: 1e-10)
        XCTAssertEqual(store.templates[0].currentVersion?.number, base.number)
        XCTAssertEqual(try Data(contentsOf: url), restoredDisk)
    }

    @MainActor func testChartsOnlyUseActualCompletedHistoryAndConvertEachSessionUnit() async throws {
        let store = WorkoutStore(fileURL: file())
        let exercise = store.exercises[0]
        for (index, pair) in [(WeightUnit.lb, 100.0), (.kg, 45.359237)].enumerated() {
            XCTAssertTrue(store.setUnit(pair.0))
            XCTAssertTrue(store.startWorkout())
            var active = try XCTUnwrap(store.activeWorkout)
            active.exercises = [WorkoutExercise(exercise: exercise, sets: [WorkoutSet(weight: pair.1, reps: 10, isCompleted: true), WorkoutSet(weight: 999, reps: 100, isCompleted: false)])]
            XCTAssertTrue(store.updateActiveWorkout(active))
            XCTAssertTrue(store.finishWorkout())
            XCTAssertEqual(store.history.count, index + 1)
        }
        XCTAssertTrue(store.startWorkout(template: store.templates[0]))
        let tools = WorkoutAgentTools(store: store)
        var args: [String: Any] = ["metric": "volume", "unit": "kg", "exercise_id": exercise.id.uuidString, "start_date": NSNull(), "end_date": NSNull()]
        let volume = try XCTUnwrap(tools.execute(name: "graph_workout_history", arguments: json(args)).chart)
        XCTAssertEqual(volume.points.count, 2)
        XCTAssertEqual(volume.unit, .kg)
        for point in volume.points { XCTAssertEqual(point.value, 453.59237, accuracy: 0.00001) }
        args["metric"] = "max_weight"
        args["unit"] = "lb"
        let maximum = try XCTUnwrap(tools.execute(name: "graph_workout_history", arguments: json(args)).chart)
        for point in maximum.points { XCTAssertEqual(point.value, 100, accuracy: 0.00001) }
        args["metric"] = "completed_sets"
        let count = try XCTUnwrap(tools.execute(name: "graph_workout_history", arguments: json(args)).chart)
        XCTAssertNil(count.unit)
        XCTAssertEqual(count.points.map(\.value), [1, 1])
        args["points"] = [["value": 100_000]]
        XCTAssertThrowsError(try tools.execute(name: "graph_workout_history", arguments: json(args)))
    }

    @MainActor func testReadCatalogAndHistoryExposePaginationTotals() async throws {
        let store = WorkoutStore(fileURL: file())
        let tools = WorkoutAgentTools(store: store)
        let response = try tools.execute(name: "get_exercise_catalog", arguments: "{\"query\":\"\",\"limit\":2,\"offset\":1}")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.outputJSONString.utf8)) as? [String: Any])
        XCTAssertEqual(payload["total"] as? Int, store.exercises.count)
        XCTAssertEqual(payload["offset"] as? Int, 1)
        XCTAssertEqual((payload["exercises"] as? [[String: Any]])?.count, 2)
    }
}
