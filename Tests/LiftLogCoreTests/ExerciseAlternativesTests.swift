import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseAlternativesTests: XCTestCase {
    private func detail(primary: [String] = ["Chest"], secondary: [String] = ["Triceps"],
                        equipment: String? = "Barbell", type: String? = "Strength",
                        force: String? = "Push", mechanic: String? = "Compound") throws -> ExerciseDetail {
        var detail = try XCTUnwrap(ExerciseCatalog.details.values.first)
        detail.primaryMuscles = primary
        detail.secondaryMuscles = secondary
        detail.equipment = equipment
        detail.type = type
        detail.force = force
        detail.mechanic = mechanic
        return detail
    }

    func testRequiresRecordedPrimaryMusclesTypeAndMovementMatchWithoutUsingNamesOrCategory() throws {
        let source = Exercise(name: "Press", category: "Chest")
        let names = ["Valid", "Secondary only", "Different type", "Different force", "Different mechanic", "Unknown movement", "Unknown type", "No details"]
        let candidates = names.map { Exercise(name: $0, category: "Chest") }
        var details = [source.id: try detail()]
        details[candidates[0].id] = try detail(equipment: "Dumbbell")
        details[candidates[1].id] = try detail(primary: ["Triceps"], secondary: ["Chest"])
        details[candidates[2].id] = try detail(type: "Stretching")
        details[candidates[3].id] = try detail(force: "Pull")
        details[candidates[4].id] = try detail(mechanic: "Isolation")
        details[candidates[5].id] = try detail(force: nil, mechanic: nil)
        details[candidates[6].id] = try detail(type: nil)
        let index = ExerciseAlternatives(exercises: [source] + candidates, details: details)
        XCTAssertEqual(index.alternatives(for: source).map(\.exercise), [candidates[0]])
        XCTAssertEqual(index.alternatives(for: source).first?.reasons,
                       ["Primary muscles: Chest", "Type: Strength", "Force: Push", "Mechanic: Compound"])
        XCTAssertTrue(index.alternatives(for: candidates[7]).isEmpty)
        XCTAssertTrue(index.alternatives(for: candidates[6]).isEmpty)
    }

    func testRanksRecordedMatchesDeterministicallyDeduplicatesAndLimits() throws {
        let source = Exercise(name: "Source")
        let best = Exercise(name: "Z same equipment")
        let first = Exercise(name: "A other equipment")
        let second = Exercise(name: "B other equipment")
        let weaker = Exercise(name: "C partial muscles")
        let details = [
            source.id: try detail(primary: ["Chest", "Shoulders"]),
            best.id: try detail(primary: [" chest ", "Shoulders"], equipment: " BARBELL "),
            first.id: try detail(primary: ["Chest", "Shoulders"], equipment: "Dumbbell"),
            second.id: try detail(primary: ["Chest", "Shoulders"], equipment: "Cable"),
            weaker.id: try detail()
        ]
        let exercises = [second, weaker, best, first, best, source]
        let index = ExerciseAlternatives(exercises: exercises, details: details)
        let result = index.alternatives(for: source)
        XCTAssertEqual(result.map(\.exercise), [best, first, second, weaker])
        XCTAssertEqual(ExerciseAlternatives(exercises: exercises.reversed(), details: details).alternatives(for: source), result)
        XCTAssertEqual(index.alternatives(for: source, limit: 2), Array(result.prefix(2)))
        XCTAssertTrue(index.alternatives(for: source, limit: 0).isEmpty)
        XCTAssertTrue(try XCTUnwrap(result.first).reasons.contains("Equipment: Barbell"))
    }

    func testMissingFieldsNeverSupplyAReasonOrInferBodyweightAndMissingPrimaryPreventsSuggestions() throws {
        let source = Exercise(name: "Source")
        let candidate = Exercise(name: "Candidate")
        let unknown = Exercise(name: "Custom chest movement", category: "Chest")
        let index = ExerciseAlternatives(exercises: [source, candidate, unknown], details: [
            source.id: try detail(equipment: nil, force: nil),
            candidate.id: try detail(equipment: "Bodyweight", force: nil),
            unknown.id: try detail(primary: [], secondary: ["Chest"])
        ])
        XCTAssertEqual(index.alternatives(for: source).map(\.exercise), [candidate])
        XCTAssertEqual(index.alternatives(for: source).first?.reasons,
                       ["Primary muscles: Chest", "Type: Strength", "Mechanic: Compound"])
        XCTAssertTrue(index.alternatives(for: unknown).isEmpty)
    }

    func testBundledAlternativesExcludeSourceAndHaveActualMatchingMetadata() throws {
        let source = try XCTUnwrap(ExerciseCatalog.all.first)
        let before = ExerciseCatalog.all
        let suggestions = ExerciseAlternatives(exercises: before).alternatives(for: source)
        XCTAssertFalse(suggestions.isEmpty)
        let sourceDetail = try XCTUnwrap(ExerciseCatalog.detail(for: source.id))
        for suggestion in suggestions {
            XCTAssertNotEqual(suggestion.id, source.id)
            let detail = try XCTUnwrap(ExerciseCatalog.detail(for: suggestion.id))
            XCTAssertEqual(detail.type, sourceDetail.type)
            XCTAssertFalse(Set(detail.primaryMuscles).intersection(sourceDetail.primaryMuscles).isEmpty)
            if let force = detail.force, let original = sourceDetail.force { XCTAssertEqual(force, original) }
            if let mechanic = detail.mechanic, let original = sourceDetail.mechanic { XCTAssertEqual(mechanic, original) }
        }
        XCTAssertEqual(ExerciseCatalog.all, before)
    }
}
