import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutSetListTests: XCTestCase {
    private func exercise(_ name: String, setCount: Int, group: UUID? = nil, restSeconds: Int? = nil) -> WorkoutExercise {
        WorkoutExercise(
            exercise: Exercise(name: name),
            sets: (0..<setCount).map { index in WorkoutSet(weight: Double(index + 1), reps: 8) },
            supersetID: group,
            restSeconds: restSeconds
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
        XCTAssertNil(sections[0].rows[0].restAfterSet)
        XCTAssertNil(sections[1].rows[0].restAfterSet)
    }

    func testSectionsProjectBetweenSetRestForSupersetsAndStandaloneExercisesAndOmitLastRow() throws {
        let group = UUID()
        let first = exercise("Press", setCount: 2, group: group, restSeconds: 30)
        let second = exercise("Row", setCount: 2, group: group, restSeconds: nil)
        let standalone = exercise("Carry", setCount: 2, restSeconds: 45)
        let workout = WorkoutSession(exercises: [first, second, standalone], restSeconds: 120)

        let sections = WorkoutSetList.sections(for: workout)
        let superset = try XCTUnwrap(sections.first)
        XCTAssertEqual(superset.rows.map(\.restAfterSet), [
            WorkoutSetList.RestAfterSet(exerciseID: first.id, seconds: 30, usesWorkoutDefault: false),
            WorkoutSetList.RestAfterSet(exerciseID: second.id, seconds: 120, usesWorkoutDefault: true),
            WorkoutSetList.RestAfterSet(exerciseID: first.id, seconds: 30, usesWorkoutDefault: false),
            nil
        ])
        XCTAssertEqual(sections[1].rows.map(\.restAfterSet), [
            WorkoutSetList.RestAfterSet(exerciseID: standalone.id, seconds: 45, usesWorkoutDefault: false),
            nil
        ])
    }

    func testSupersetBetweenSetRestHandlesOffOverridesWorkoutDefaultOffAndDuplicates() throws {
        let group = UUID()
        let movement = Exercise(name: "Bench Press")
        let first = WorkoutExercise(exercise: movement, sets: [WorkoutSet(), WorkoutSet()], supersetID: group, restSeconds: 0)
        let second = WorkoutExercise(exercise: movement, sets: [WorkoutSet(), WorkoutSet()], supersetID: group, restSeconds: 90)
        let workout = WorkoutSession(exercises: [first, second], restSeconds: 120)

        let section = try XCTUnwrap(WorkoutSetList.sections(for: workout).first)
        XCTAssertEqual(section.rows.map(\.restAfterSet), [
            WorkoutSetList.RestAfterSet(exerciseID: first.id, seconds: 0, usesWorkoutDefault: false),
            WorkoutSetList.RestAfterSet(exerciseID: second.id, seconds: 90, usesWorkoutDefault: false),
            WorkoutSetList.RestAfterSet(exerciseID: first.id, seconds: 0, usesWorkoutDefault: false),
            nil
        ])

        let defaultOffFirst = exercise("Curl", setCount: 2, group: group, restSeconds: nil)
        let defaultOffSecond = exercise("Extension", setCount: 1, group: group, restSeconds: 45)
        let defaultOffWorkout = WorkoutSession(exercises: [defaultOffFirst, defaultOffSecond], restSeconds: 0)
        let defaultOffSection = try XCTUnwrap(WorkoutSetList.sections(for: defaultOffWorkout).first)
        XCTAssertEqual(defaultOffSection.rows.map(\.restAfterSet), [
            WorkoutSetList.RestAfterSet(exerciseID: defaultOffFirst.id, seconds: 0, usesWorkoutDefault: true),
            WorkoutSetList.RestAfterSet(exerciseID: defaultOffSecond.id, seconds: 45, usesWorkoutDefault: false),
            nil
        ])
    }

    func testSupersetWithSingleRemainingSetHasNoBetweenSetRest() throws {
        let group = UUID()
        let first = exercise("Press", setCount: 1, group: group, restSeconds: 30)
        let empty = exercise("Row", setCount: 0, group: group, restSeconds: 90)
        let section = try XCTUnwrap(WorkoutSetList.sections(for: [first, empty], workoutRestSeconds: 120).first)
        XCTAssertEqual(section.rows.map(\.restAfterSet), [nil])
    }
}
