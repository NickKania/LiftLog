import Foundation
import XCTest
@testable import LiftLogCore

final class FoundationModelsNullableProposalTests: XCTestCase {
    @MainActor
    func testSingleBatchAndVersionOperationsAcceptOmittedInapplicableNullableArguments() throws {
        for tool in ["propose_edit_exercise", "propose_edit_workout_exercises", "propose_template_version"] {
            for operation in ["add", "update", "remove"] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NullableProposal-\(UUID())")
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
                let tools = WorkoutAgentTools(store: store)
                let template = try XCTUnwrap(store.templates.first)
                let entry = try XCTUnwrap(template.exercises.first)
                var edit: [String: Any] = ["operation": operation]
                if operation != "add" { edit["entry_id"] = entry.id.uuidString }
                if operation != "remove" {
                    edit["exercise_id"] = entry.exercise.id.uuidString
                    edit["sets"] = [["weight": 123, "reps": 7]]
                }
                // Add omits entry_id; remove omits exercise_id and sets. Update
                // needs all three values and proves nullable never means unchecked.
                var arguments: [String: Any] = ["unit": store.unit.rawValue]
                if tool == "propose_template_version" {
                    arguments["template_id"] = template.id.uuidString
                    arguments["base_version_id"] = try XCTUnwrap(template.currentVersion).id.uuidString
                    arguments["operations"] = [edit]
                } else {
                    arguments["target"] = "template"
                    arguments["target_id"] = template.id.uuidString
                    if tool == "propose_edit_exercise" { arguments.merge(edit) { _, new in new } }
                    else { arguments["operations"] = [edit] }
                }
                let before = store.templates
                let output = try tools.execute(name: tool, arguments: json(arguments))
                let proposal = try XCTUnwrap(output.proposal, "\(tool) \(operation)")
                XCTAssertEqual(proposal.status, .pending)
                XCTAssertEqual(store.templates, before, "Native omissions must not bypass review")
                let after = try XCTUnwrap(proposal.afterTemplate)
                switch operation {
                case "add": XCTAssertEqual(after.exercises.count, template.exercises.count + 1)
                case "remove": XCTAssertFalse(after.exercises.contains { $0.id == entry.id })
                default:
                    XCTAssertEqual(after.exercises.first?.id, entry.id)
                    XCTAssertEqual(after.exercises.first?.sets.first?.targetReps, 7)
                    XCTAssertEqual(after.exercises.first?.sets.first?.weight, 123)
                }
                if operation == "update" {
                    var incomplete = edit
                    incomplete.removeValue(forKey: "sets")
                    var invalid = arguments
                    if tool == "propose_edit_exercise" { invalid.removeValue(forKey: "sets") }
                    else { invalid["operations"] = [incomplete] }
                    XCTAssertThrowsError(try tools.execute(name: tool, arguments: json(invalid)))
                }
            }
        }
    }

    @MainActor
    func testActiveWorkoutAddAndRemoveOmitUnusedNullableArgumentsWithoutSaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NullableActive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkoutStore(fileURL: directory.appendingPathComponent("workouts.sqlite"))
        let template = try XCTUnwrap(store.templates.first)
        XCTAssertTrue(store.startWorkout(template: template))
        let workout = try XCTUnwrap(store.activeWorkout)
        let entry = try XCTUnwrap(workout.exercises.first)
        let tools = WorkoutAgentTools(store: store)
        let add: [String: Any] = ["operation": "add", "exercise_id": entry.exercise.id.uuidString, "sets": [["weight": 50, "reps": 8]]]
        let remove: [String: Any] = ["operation": "remove", "entry_id": entry.id.uuidString]
        let arguments: [String: Any] = ["target": "active_workout", "target_id": workout.id.uuidString,
                                         "unit": workout.unit.rawValue, "operations": [add, remove]]
        let proposal = try XCTUnwrap(tools.execute(name: "propose_edit_workout_exercises", arguments: json(arguments)).proposal)
        XCTAssertEqual(store.activeWorkout, workout)
        XCTAssertFalse(proposal.afterWorkout?.exercises.contains { $0.id == entry.id } ?? true)
        XCTAssertEqual(proposal.afterWorkout?.exercises.count, workout.exercises.count)
        XCTAssertTrue(store.history.isEmpty)
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}
