import Foundation
import XCTest
@testable import LiftLogCore

final class WorkoutHistoryQueryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func workout(_ name: String, at date: Date, templateID: UUID? = nil,
                         exercise: String = "Bench Press") -> WorkoutSession {
        WorkoutSession(templateID: templateID, name: name, startedAt: date,
                       finishedAt: date.addingTimeInterval(600), exercises: [
                        WorkoutExercise(exercise: Exercise(name: exercise))
                       ])
    }

    func testSearchMatchesWorkoutAndExerciseNamesIgnoringCaseAccentsAndWhitespace() {
        let upper = workout("Café Upper Body", at: date(3, 9))
        let lower = workout("Lower Body", at: date(3, 8), exercise: "Squat")
        let history = [upper, lower]
        XCTAssertEqual(WorkoutHistoryQuery(searchText: "  CAFE   bench \n").results(in: history), [upper])
        XCTAssertEqual(WorkoutHistoryQuery(searchText: "SQUAT").results(in: history), [lower])
        XCTAssertEqual(WorkoutHistoryQuery(searchText: "  \n ").results(in: history), history)
        XCTAssertTrue(WorkoutHistoryQuery(searchText: "deadlift").results(in: history).isEmpty)
        XCTAssertFalse(WorkoutHistoryQuery(searchText: " \n ").hasFilters)
    }

    func testDateRangesIncludeWholeBoundaryDayAcrossDaylightSaving() {
        let now = date(3, 9)
        let boundary = workout("Boundary", at: date(3, 3, 0))
        let before = workout("Before", at: date(3, 2, 23))
        let today = workout("Today", at: date(3, 9, 9))
        let future = workout("Future", at: date(3, 10))
        let history = [before, boundary, today, future]
        XCTAssertEqual(WorkoutHistoryQuery(dateRange: .week).results(in: history, now: now, calendar: calendar), [today, boundary])
        XCTAssertEqual(WorkoutHistoryDateRange.month.startDate(relativeTo: now, calendar: calendar), date(2, 8, 0))
        XCTAssertEqual(WorkoutHistoryDateRange.threeMonths.startDate(relativeTo: now, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2025, month: 12, day: 10)))
        XCTAssertEqual(WorkoutHistoryQuery().results(in: history).count, 4)
    }

    func testSearchDateAndTemplateFiltersCombineByIdentity() {
        let id = UUID()
        let sameNameID = UUID()
        let recent = workout("Upper", at: date(3, 8), templateID: id)
        let renamed = workout("Old name", at: date(3, 7), templateID: id)
        let unrelated = workout("Upper", at: date(3, 8), templateID: sameNameID)
        let old = workout("Upper", at: date(1, 1), templateID: id)
        let other = workout("Imported", at: date(3, 8))
        let history = [recent, renamed, unrelated, old, other]
        let query = WorkoutHistoryQuery(searchText: "bench", dateRange: .week, template: .template(id))
        XCTAssertEqual(query.results(in: history, now: date(3, 9), calendar: calendar), [recent, renamed])
        XCTAssertEqual(WorkoutHistoryQuery(template: .other).results(in: history), [other])
        let options = WorkoutHistoryTemplateOption.options(in: history)
        XCTAssertEqual(Set(options.map(\.id)), Set([id, sameNameID]))
        XCTAssertEqual(options.first { $0.id == id }?.name, "Upper")
    }

    func testAllSortOrdersUseStableTiesWithoutChangingHistory() {
        var first = workout("Alpha", at: date(3, 8))
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var tied = first
        tied.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let older = workout("Alpha", at: date(3, 7))
        let beta = workout("Beta", at: date(3, 9))
        let history = [tied, older, beta, first]
        XCTAssertEqual(WorkoutHistoryQuery().results(in: history), [beta, first, tied, older])
        XCTAssertEqual(WorkoutHistoryQuery(sort: .oldest).results(in: history), [older, first, tied, beta])
        XCTAssertEqual(WorkoutHistoryQuery(sort: .nameAscending).results(in: history), [first, tied, older, beta])
        XCTAssertEqual(WorkoutHistoryQuery(sort: .nameDescending).results(in: history), [beta, first, tied, older])
        XCTAssertEqual(history, [tied, older, beta, first])
        XCTAssertTrue(WorkoutHistoryQuery().results(in: []).isEmpty)
    }

    func testClearingFiltersPreservesSelectedSort() {
        var query = WorkoutHistoryQuery(searchText: "Bench", dateRange: .month, template: .other, sort: .oldest)
        XCTAssertTrue(query.hasFilters)
        query.clearFilters()
        XCTAssertFalse(query.hasFilters)
        XCTAssertEqual(query.sort, .oldest)
    }
}
