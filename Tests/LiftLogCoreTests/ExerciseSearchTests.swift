import XCTest
@testable import LiftLogCore

final class ExerciseSearchTests: XCTestCase {
    private func matches(_ text: String, _ exercises: [Exercise]) -> [ExerciseSearchMatch] {
        ExerciseDiscoveryQuery(searchText: text).searchMatches(in: ExerciseDiscoveryIndex(exercises: exercises, details: [:]))
    }

    private func detail(equipment: String = "Barbell", sourceRecordID: String = "Synthetic") throws -> ExerciseDetail {
        var detail = try XCTUnwrap(ExerciseCatalog.details.values.first)
        detail.equipment = equipment
        detail.source.sourceRecordID = sourceRecordID
        return detail
    }

    func testExactNameRanksAheadOfSubstringThenCategoryAndAliasWithStableTies() {
        let alias = Exercise(name: "Romanian Deadlift")
        let category = Exercise(name: "Custom movement", category: "RDL")
        let substring = Exercise(name: "RDL with pause")
        let exact = Exercise(name: "RDL")
        let secondSubstring = Exercise(name: "Single-Leg RDL")
        let exercises = [alias, category, substring, exact, secondSubstring]
        let result = matches("rdl", exercises)
        XCTAssertEqual(result.map(\.exercise), [exact, substring, secondSubstring, alias, category])
        XCTAssertEqual(result.map(\.kind), [.direct, .direct, .direct, .alias, .direct])
        XCTAssertEqual(matches("rdl", exercises), result)
        XCTAssertEqual(matches("", exercises).map(\.exercise), exercises)
    }

    func testCuratedAcronymsPreserveEquipmentAndExecutionVariantsAndCustomNames() {
        let overhead = Exercise(name: "Overhead Press")
        let dumbbell = Exercise(name: "Dumbbell Romanian Deadlift")
        let barbell = Exercise(name: "Barbell Romanian Deadlift")
        let singleLeg = Exercise(name: "Single-Leg Dumbbell Romanian Deadlift")
        let incline = Exercise(name: "Incline Dumbbell Press")
        let custom = Exercise(name: "My Dumbbell Press")
        let exercises = [overhead, dumbbell, barbell, singleLeg, incline, custom]
        XCTAssertEqual(matches("ohp", exercises).map(\.exercise), [overhead])
        XCTAssertEqual(matches("db rdl", exercises).map(\.exercise), [dumbbell, singleLeg])
        XCTAssertEqual(matches("bb rdl", exercises).map(\.exercise), [barbell])
        XCTAssertEqual(matches("incline db press", exercises).map(\.exercise), [incline])
        XCTAssertEqual(matches("my db press", exercises).map(\.exercise), [custom])
        XCTAssertEqual(Set(matches("rdl", exercises).map(\.id)), Set([dumbbell.id, barbell.id, singleLeg.id]))
        // Existing name-substring matches remain direct, even for a short acronym.
        XCTAssertEqual(matches("db", [Exercise(name: "Oddball")]).first?.kind, .direct)
        XCTAssertTrue(matches("db", [Exercise(name: "Dumbfounded Curl")]).isEmpty)
        let alias = matches("ohp", exercises).first
        XCTAssertEqual(alias?.kind, .alias)
        XCTAssertEqual(alias?.matchedAlias, "OHP")
        XCTAssertEqual(alias?.displayReason, "Also known as “OHP”")
        XCTAssertEqual(exercises.map(\.name), ["Overhead Press", "Dumbbell Romanian Deadlift", "Barbell Romanian Deadlift",
                                               "Single-Leg Dumbbell Romanian Deadlift", "Incline Dumbbell Press", "My Dumbbell Press"])
    }

    func testSourceAliasesFindLegacyStarterLabelsWithoutChangingIdentity() throws {
        let starter = Exercise(name: "Overhead Press")
        let index = ExerciseDiscoveryIndex(exercises: [starter], details: [
            starter.id: try detail(sourceRecordID: "Standing_Military_Press")
        ])
        let result = ExerciseDiscoveryQuery(searchText: "military press").searchMatches(in: index)
        XCTAssertEqual(result.map(\.exercise), [starter])
        XCTAssertEqual(result.first?.kind, .alias)
        XCTAssertEqual(result.first?.matchedAlias, "Standing Military Press")
        XCTAssertEqual(result.first?.exercise.name, "Overhead Press")
    }

    func testPunctuationDiacriticsWhitespaceAndReorderedNameTokensRemainDirect() {
        let pullup = Exercise(name: "Pull-Up (Wide Grip)")
        let cafe = Exercise(name: "Café   Incline\nPress", category: "Upper Body")
        let exercises = [pullup, cafe]
        XCTAssertEqual(matches("pull up", exercises).map(\.exercise), [pullup])
        XCTAssertEqual(matches("wide grip pull", exercises).map(\.exercise), [pullup])
        XCTAssertEqual(matches(" CAFE\tINCLINE ", exercises).map(\.exercise), [cafe])
        XCTAssertEqual(matches("quat", [Exercise(name: "Squat")]).first?.kind, .direct)
        XCTAssertTrue(matches("incline incline", exercises).isEmpty)
        XCTAssertEqual(matches("pull up", exercises).first?.displayReason, nil)
    }

    func testTypoFallbackSupportsInsertionDeletionSubstitutionAndTransposition() {
        let bench = Exercise(name: "Bench Press")
        let romanian = Exercise(name: "Romanian Deadlift")
        for query in ["Bnech Press", "Bennch Press", "Bech Press", "Banch Press"] {
            let result = matches(query, [bench, romanian])
            XCTAssertEqual(result.map(\.exercise), [bench], query)
            XCTAssertEqual(result.first?.kind, .approximate, query)
            XCTAssertEqual(result.first?.displayReason, "Similar spelling")
        }
        XCTAssertEqual(matches("romainan deadlft", [romanian]).map(\.exercise), [romanian])
        XCTAssertTrue(matches("bnc press", [bench]).isEmpty) // Short tokens never get fuzzy expansion.
        XCTAssertEqual(matches("bench pres", [bench]).first?.kind, .direct)
    }

    func testFallbackDoesNotMixApproximateMatchesWhenAnyDirectOrAliasResultExists() {
        let exact = Exercise(name: "Bnech Press")
        let bench = Exercise(name: "Bench Press")
        XCTAssertEqual(matches("Bnech Press", [bench, exact]).map(\.exercise), [exact])
        let alias = Exercise(name: "Dumbbell Curl")
        let near = Exercise(name: "DB Curls")
        XCTAssertEqual(matches("DB Curl", [alias, near]).map(\.exercise), [near, alias])
        XCTAssertTrue(matches("DB Curl", [alias, near]).allSatisfy { $0.kind != .approximate })
    }

    func testFiltersApplyToAliasesAndFallbackAndHiddenDirectMatchesSuppressFallback() throws {
        let dumbbell = Exercise(name: "Dumbbell Bench Press")
        let barbell = Exercise(name: "Barbell Bench Press")
        let exact = Exercise(name: "Bnech Press")
        let index = ExerciseDiscoveryIndex(exercises: [dumbbell, barbell, exact], details: [
            dumbbell.id: try detail(equipment: "Dumbbell"),
            barbell.id: try detail(), exact.id: try detail()
        ])
        XCTAssertEqual(ExerciseDiscoveryQuery(searchText: "db bench", equipment: .value("Dumbbell"))
            .searchMatches(in: index).map(\.exercise), [dumbbell])
        XCTAssertTrue(ExerciseDiscoveryQuery(searchText: "db bench", equipment: .value("Barbell"))
            .searchMatches(in: index).isEmpty)
        XCTAssertTrue(ExerciseDiscoveryQuery(searchText: "bnech press", equipment: .value("Dumbbell"))
            .searchMatches(in: index).isEmpty)
        let fallback = ExerciseDiscoveryIndex(exercises: [dumbbell, barbell], details: [
            dumbbell.id: try detail(equipment: "Dumbbell"), barbell.id: try detail()
        ])
        XCTAssertEqual(ExerciseDiscoveryQuery(searchText: "bnech press", equipment: .value("Dumbbell"))
            .searchMatches(in: fallback).map(\.exercise), [dumbbell])
        XCTAssertTrue(ExerciseDiscoveryQuery(searchText: "bnech press", equipment: .unknown)
            .searchMatches(in: fallback).isEmpty)
    }

    func testFallbackRejectsUnrelatedShortAndExcessiveQueriesButPreservesExactCustomSearch() {
        let bench = Exercise(name: "Bench Press")
        let squat = Exercise(name: "Squat")
        for query in ["xyz", "oh", "bnc", "benc prs", "pasta dinner", String(repeating: "x", count: 10_000),
                      Array(repeating: "benxh", count: 9).joined(separator: " ")] {
            XCTAssertTrue(matches(query, [bench, squat]).isEmpty, query.prefix(80).description)
        }
        let longName = Exercise(name: String(repeating: "x", count: 100))
        XCTAssertEqual(matches(longName.name, [longName]).map(\.exercise), [longName])
        let custom = Exercise(name: "My Garage Movement")
        XCTAssertEqual(matches("my garag movement", [custom]).map(\.exercise), [custom])
    }

    func testSearchResultsCanBeReusedForFeaturedSectionsWithoutDuplicates() {
        let first = Exercise(name: "Dumbbell Curl")
        let second = Exercise(name: "Incline Dumbbell Curl")
        let index = ExerciseDiscoveryIndex(exercises: [first, second, first], details: [:])
        let query = ExerciseDiscoveryQuery(searchText: "db curl")
        let matches = query.searchMatches(in: index)
        let sections = query.results(searchMatches: matches, in: index, favoriteExerciseIDs: [second.id])
        XCTAssertEqual(sections.map(\.kind), [.favorites, .allExercises])
        XCTAssertEqual(sections.map(\.exercises), [[second], [first]])
        XCTAssertEqual(query.results(in: index, favoriteExerciseIDs: [second.id]), sections)
        XCTAssertEqual(Set(matches.map(\.id)).count, 2)
    }

    func testBundledCatalogSupportsAcronymsAndLegacySourceNamesOffline() {
        let ohp = ExerciseDiscoveryQuery(searchText: "ohp").searchMatches(in: .catalog)
        XCTAssertEqual(ohp.first?.exercise.name, "Overhead Press")
        XCTAssertEqual(ohp.first?.kind, .alias)
        let military = ExerciseDiscoveryQuery(searchText: "standing military press").searchMatches(in: .catalog)
        XCTAssertTrue(military.contains { $0.exercise.name == "Overhead Press" && $0.kind == .alias })
        XCTAssertFalse(ExerciseDiscoveryQuery(searchText: "db curl").searchMatches(in: .catalog).isEmpty)
    }
}
