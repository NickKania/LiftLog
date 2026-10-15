import Foundation
import XCTest
@testable import LiftLogCore

final class ExerciseDiscoveryTests: XCTestCase {
    private func detail(equipment: String? = "Barbell", primary: [String] = ["Chest"],
                        secondary: [String] = ["Triceps"], type: String? = "Strength") throws -> ExerciseDetail {
        var detail = try XCTUnwrap(ExerciseCatalog.details.values.first)
        detail.equipment = equipment
        detail.primaryMuscles = primary
        detail.secondaryMuscles = secondary
        detail.type = type
        return detail
    }

    private func session(_ exercises: [WorkoutExercise], at date: Date = Date(timeIntervalSince1970: 100),
                         finished: Bool = true, id: UUID = UUID()) -> WorkoutSession {
        WorkoutSession(id: id, name: "Synthetic training", startedAt: date,
                       finishedAt: finished ? date.addingTimeInterval(60) : nil, exercises: exercises)
    }

    private func performed(_ exercise: Exercise) -> WorkoutExercise {
        WorkoutExercise(exercise: exercise, sets: [WorkoutSet(isCompleted: true)])
    }

    private func rows(_ sections: [ExerciseDiscoverySection]) -> [Exercise] {
        sections.flatMap(\.exercises)
    }

    func testSubstringSearchNormalizesCaseDiacriticsAndWhitespaceInNameAndCategory() {
        let press = Exercise(name: "Café   Incline\nPress", category: "Upper   Body")
        let squat = Exercise(name: "Squat", category: "Legs")
        let index = ExerciseDiscoveryIndex(exercises: [press, squat], details: [:])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(searchText: " CAFE \n incline ").results(in: index)), [press])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(searchText: "UPPER\tBODY").results(in: index)), [press])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(searchText: "quat").results(in: index)), [squat])
        XCTAssertTrue(ExerciseDiscoveryQuery(searchText: "incline squat").results(in: index).isEmpty)
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(searchText: " \n ").results(in: index)), [press, squat])
        XCTAssertFalse(ExerciseDiscoveryQuery(searchText: " \n ").hasFilters)
    }

    func testMetadataFiltersCombineByIdentityAndIncludeSecondaryMuscles() throws {
        let bench = Exercise(name: "Press", category: "Chest")
        let sameName = Exercise(name: "Press", category: "Chest")
        let dumbbell = Exercise(name: "Incline Press", category: "Chest")
        let index = ExerciseDiscoveryIndex(exercises: [bench, sameName, dumbbell], details: [
            bench.id: try detail(),
            sameName.id: try detail(primary: ["Shoulders"], secondary: [], type: "Stretching"),
            dumbbell.id: try detail(equipment: "Dumbbell")
        ])
        let query = ExerciseDiscoveryQuery(searchText: "press", equipment: .value(" BARBELL "),
                                           muscle: .value("tríceps"), type: .value("strength"))
        XCTAssertEqual(rows(query.results(in: index)), [bench])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(muscle: .value("Shoulders")).results(in: index)), [sameName])
        XCTAssertTrue(ExerciseDiscoveryQuery(equipment: .value("Cable"), muscle: .value("Triceps")).results(in: index).isEmpty)
    }

    func testUnknownMetadataIncludesCustomExercisesWithoutInferringFromTheirCategory() throws {
        let unknownEquipment = Exercise(name: "Missing equipment", category: "Chest")
        let bodyweight = Exercise(name: "Bodyweight", category: "Chest")
        let custom = Exercise(name: "Custom press", category: "Chest")
        let missingFields = Exercise(name: "Blank source fields")
        let index = ExerciseDiscoveryIndex(exercises: [unknownEquipment, bodyweight, custom, missingFields], details: [
            unknownEquipment.id: try detail(equipment: nil),
            bodyweight.id: try detail(equipment: "Bodyweight"),
            missingFields.id: try detail(equipment: " \n ", primary: [" "], secondary: [], type: "\n")
        ])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(equipment: .unknown).results(in: index)), [unknownEquipment, custom, missingFields])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(equipment: .value("Bodyweight")).results(in: index)), [bodyweight])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(muscle: .unknown, type: .unknown).results(in: index)), [custom, missingFields])
        XCTAssertEqual(rows(ExerciseDiscoveryQuery(muscle: .value("Chest")).results(in: index)), [unknownEquipment, bodyweight])
    }

    func testFilterOptionsIncludeAllUnknownAndDeduplicatedPrimaryAndSecondaryLabels() throws {
        let first = Exercise(name: "First")
        let second = Exercise(name: "Second")
        let index = ExerciseDiscoveryIndex(exercises: [first, second], details: [
            first.id: try detail(equipment: " Barbell ", primary: ["Chest"], secondary: ["Triceps", " chest "]),
            second.id: try detail(equipment: "barbell", primary: ["Biceps"], secondary: [], type: "Stretching")
        ])
        XCTAssertEqual(index.equipmentOptions, [.all, .value("Barbell"), .unknown])
        XCTAssertEqual(index.muscleOptions, [.all, .value("Biceps"), .value("Chest"), .value("Triceps"), .unknown])
        XCTAssertEqual(index.typeOptions, [.all, .value("Strength"), .value("Stretching"), .unknown])
        XCTAssertEqual(ExerciseDiscoveryFilter.unknown.label, "Unknown")
        XCTAssertEqual(ExerciseDiscoveryIndex(exercises: [], details: [:]).equipmentOptions, [.all, .unknown])
    }

    func testSectionsUseStableUniqueExerciseIDsAndApplySearchAndFiltersEverywhere() throws {
        let favorite = Exercise(name: "Bench Press")
        let recent = Exercise(name: "Incline Press")
        let other = Exercise(name: "Floor Press")
        let filteredOut = Exercise(name: "Squat")
        let exercises = [favorite, recent, other, filteredOut]
        let details = try Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, try detail()) })
        let index = ExerciseDiscoveryIndex(exercises: exercises + [favorite], details: details)
        let history = [session([performed(favorite), performed(recent), performed(filteredOut)])]
        let query = ExerciseDiscoveryQuery(searchText: "press", equipment: .value("Barbell"))
        let sections = query.results(in: index, favoriteExerciseIDs: [filteredOut.id, favorite.id, favorite.id, UUID()], history: history)
        XCTAssertEqual(sections.map(\.kind), [.favorites, .recentlyTrained, .allExercises])
        XCTAssertEqual(sections.map(\.exercises), [[favorite], [recent], [other]])
        XCTAssertEqual(Set(rows(sections).map(\.id)).count, rows(sections).count)
        XCTAssertEqual(sections.map(\.id), sections.map(\.kind))
        XCTAssertEqual(rows(query.results(in: index, favoriteExerciseIDs: [], history: [])), [favorite, recent, other])
        XCTAssertEqual(history.first?.exercises.first?.exercise, favorite)
    }

    func testRecentsRequireCompletedSetsInFinishedHistoryAndAvailableCatalogIdentity() {
        let completed = Exercise(name: "Completed")
        let incomplete = Exercise(name: "Incomplete")
        let empty = Exercise(name: "Empty")
        let active = Exercise(name: "Active completed set")
        let unavailable = Exercise(name: "Unavailable recorded snapshot")
        let availableIDs = Set([completed, incomplete, empty, active].map(\.id))
        let history = [
            session([performed(active)], at: Date(timeIntervalSince1970: 300), finished: false),
            session([WorkoutExercise(exercise: incomplete), WorkoutExercise(exercise: empty, sets: []),
                     performed(unavailable), performed(completed), performed(completed)])
        ]
        XCTAssertEqual(ExerciseDiscoveryQuery.recentExerciseIDs(in: history, availableIDs: availableIDs), [completed.id])
        XCTAssertEqual(ExerciseDiscoveryQuery.recentExerciseIDs(in: [], availableIDs: availableIDs), [])
        XCTAssertEqual(ExerciseDiscoveryQuery.recentExerciseIDs(in: history, availableIDs: availableIDs, limit: 0), [])
    }

    func testRecentsUseLatestSessionDateStableSessionTiesAndExerciseOrderWithLimit() throws {
        let exercises = (0..<11).map { Exercise(name: "Exercise \($0)") }
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let history = [
            session(exercises.map(performed), at: Date(timeIntervalSince1970: 100)),
            session([performed(exercises[2]), performed(exercises[0])], at: Date(timeIntervalSince1970: 200), id: secondID),
            session([performed(exercises[1]), performed(exercises[2])], at: Date(timeIntervalSince1970: 200), id: firstID)
        ]
        let ids = ExerciseDiscoveryQuery.recentExerciseIDs(in: history, availableIDs: Set(exercises.map(\.id)))
        XCTAssertEqual(ids, [1, 2, 0, 3, 4, 5, 6, 7].map { exercises[$0].id })
        XCTAssertEqual(ExerciseDiscoveryQuery.recentExerciseIDs(in: history.reversed(), availableIDs: Set(exercises.map(\.id))), ids)
    }

    func testRecentsRecomputeAfterHistoryDeletionAndRoundTripUsingCurrentCatalogSnapshots() throws {
        let oldSnapshot = Exercise(name: "Recorded name")
        let current = Exercise(id: oldSnapshot.id, name: "Current name")
        let older = Exercise(name: "Older")
        let history = [session([performed(oldSnapshot)], at: Date(timeIntervalSince1970: 200)), session([performed(older)])]
        let index = ExerciseDiscoveryIndex(exercises: [current, older], details: [:])
        let decoded = try JSONDecoder().decode([WorkoutSession].self, from: JSONEncoder().encode(history))
        let query = ExerciseDiscoveryQuery()
        XCTAssertEqual(query.results(in: index, history: decoded).first?.exercises, [current, older])
        XCTAssertEqual(query.results(in: index, history: Array(decoded.dropFirst())).first?.exercises, [older])
        XCTAssertEqual(query.results(in: index, history: []).first?.kind, .allExercises)
        XCTAssertEqual(decoded.first?.exercises.first?.exercise.name, "Recorded name")
    }

    func testSearchFindsExercisesOutsideRecentLimitInAllExercises() {
        let exercises = (0..<10).map { Exercise(name: "Movement \($0)") }
        let index = ExerciseDiscoveryIndex(exercises: exercises, details: [:])
        let history = [session(exercises.map(performed))]
        let sections = ExerciseDiscoveryQuery(searchText: "Movement 9").results(in: index, history: history)
        XCTAssertEqual(sections.map(\.kind), [.allExercises])
        XCTAssertEqual(rows(sections), [exercises[9]])
    }

    func testClearingMetadataFiltersPreservesSearch() {
        var query = ExerciseDiscoveryQuery(searchText: "press", equipment: .unknown, muscle: .value("Chest"), type: .value("Strength"))
        XCTAssertTrue(query.hasMetadataFilters)
        query.clearMetadataFilters()
        XCTAssertFalse(query.hasMetadataFilters)
        XCTAssertTrue(query.hasFilters)
        XCTAssertEqual(query.searchText, "press")
    }

    func testClearFiltersRestoresAllBundledExercisesWithoutMutatingCatalog() {
        let original = ExerciseCatalog.all
        var query = ExerciseDiscoveryQuery(searchText: "bench", equipment: .value("Barbell"), muscle: .value("Chest"), type: .value("Strength"))
        XCTAssertTrue(query.hasFilters)
        XCTAssertTrue(rows(query.results(in: .catalog)).contains { $0.id == original.first?.id })
        query.clearFilters()
        XCTAssertFalse(query.hasFilters)
        XCTAssertEqual(rows(query.results(in: .catalog)), original)
        XCTAssertEqual(ExerciseCatalog.all, original)
    }
}
