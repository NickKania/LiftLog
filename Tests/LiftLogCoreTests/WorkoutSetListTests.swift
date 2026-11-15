import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSetListTests: XCTestCase {
    private func exercise(_ name: String, setCount: Int, group: UUID? = nil) -> WorkoutExercise {
        WorkoutExercise(
            exercise: Exercise(name: name),
            sets: (0..<setCount).map { index in WorkoutSet(weight: Double(index + 1), reps: 8) },
            supersetID: group
        )
    }

    func testSupersetIsOneSectionWithRoundRobinRows() throws {
        let group = UUID()
        let first = exercise("Press", setCount: 2, group: group)
        let second = exercise("Row", setCount: 2, group: group)
        let standalone = exercise("Carry", setCount: 1)

        let sections = WorkoutSetList.sections(for: [first, second, standalone])
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].id, first.id)
        XCTAssertEqual(sections[0].exercises.map(\.id), [first.id, second.id])
        XCTAssertTrue(sections[0].isSuperset)
        XCTAssertEqual(sections[0].rows.map(\.exerciseID), [first.id, second.id, first.id, second.id])
        XCTAssertEqual(sections[0].rows.map(\.setIndex), [0, 0, 1, 1])
        XCTAssertEqual(sections[0].rows.map(\.setID), [first.sets[0].id, second.sets[0].id, first.sets[1].id, second.sets[1].id])
        XCTAssertEqual(sections[1].exercises.map(\.id), [standalone.id])
        XCTAssertFalse(sections[1].isSuperset)
    }

    func testGroupSectionStartsAtFirstMemberAndKeepsOtherExerciseSectionsInOrder() {
        let group = UUID()
        let before = exercise("Warmup", setCount: 1)
        let first = exercise("Press", setCount: 1, group: group)
        let between = exercise("Mobility", setCount: 1)
        let second = exercise("Row", setCount: 1, group: group)
        let after = exercise("Carry", setCount: 1)

        let sections = WorkoutSetList.sections(for: [before, first, between, second, after])
        XCTAssertEqual(sections.map { $0.exercises.map(\.id) }, [[before.id], [first.id, second.id], [between.id], [after.id]])
    }

    func testUnequalAndEmptySetCountsSkipMissingRowsAndKeepSetIdentity() {
        let group = UUID()
        let first = exercise("Press", setCount: 3, group: group)
        let empty = exercise("Row", setCount: 0, group: group)
        let third = exercise("Carry", setCount: 1, group: group)

        let section = try! XCTUnwrap(WorkoutSetList.sections(for: [first, empty, third]).first)
        XCTAssertEqual(section.rows.map(\.exerciseID), [first.id, third.id, first.id, first.id])
        XCTAssertEqual(section.rows.map(\.setIndex), [0, 0, 1, 2])
        XCTAssertEqual(section.rows.map(\.setID), [first.sets[0].id, third.sets[0].id, first.sets[1].id, first.sets[2].id])
    }

    func testSingletonSupersetIDsRemainIndividualSections() {
        let orphan = UUID()
        let first = exercise("Press", setCount: 1, group: orphan)
        let second = exercise("Row", setCount: 1)

        let sections = WorkoutSetList.sections(for: [first, second])
        XCTAssertEqual(sections.map { $0.exercises.map(\.id) }, [[first.id], [second.id]])
        XCTAssertFalse(sections[0].isSuperset)
    }
}
