import XCTest

final class WorkoutHistoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFiltersCombineWithExerciseSearchAndClearNoMatches() {
        let app = launchHistory()
        defer { app.terminate() }
        assertCount("12 of 12 workouts", in: app)
        selectFilter("Date range", option: "Last 7 days", in: app)
        assertCount("3 of 12 workouts", in: app)
        selectFilter("Template", option: "Fixture Upper Body", in: app)
        assertCount("2 of 12 workouts", in: app)

        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("BENCH\n")
        assertCount("2 of 12 workouts", in: app)
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "Squat\n")
        XCTAssertTrue(app.staticTexts["No matching workouts"].waitForExistence(timeout: 5))
        app.buttons["clearHistoryFiltersButton"].tap()
        assertCount("12 of 12 workouts", in: app)
        XCTAssertFalse(app.staticTexts["No matching workouts"].exists)
    }

    @MainActor
    func testSortOrdersAndFilteredDetailNavigation() {
        let app = launchHistory()
        defer { app.terminate() }
        assertFirstWorkout("Fixture Upper Body", in: app)
        selectSort("Oldest first", in: app)
        assertFirstWorkout("Fixture Lower Body", in: app)
        selectSort("Name A–Z", in: app)
        assertFirstWorkout("Fixture Lower Body", in: app)
        selectSort("Name Z–A", in: app)
        assertFirstWorkout("Fixture Upper Body", in: app)
        selectSort("Newest first", in: app)
        selectFilter("Template", option: "Fixture Lower Body", in: app)
        assertCount("6 of 12 workouts", in: app)
        app.buttons["historyWorkout-Fixture Lower Body"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Squat"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        assertCount("6 of 12 workouts", in: app)
        XCTAssertTrue(app.buttons["importWorkoutsButton"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Filtered workout history"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDeletingFilteredWorkoutUpdatesResults() {
        let app = launchHistory()
        defer { app.terminate() }
        selectSort("Oldest first", in: app)
        selectFilter("Template", option: "Fixture Lower Body", in: app)
        assertCount("6 of 12 workouts", in: app)
        app.buttons["historyWorkout-Fixture Lower Body"].firstMatch.swipeLeft()
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "deleteHistoryWorkout-")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        app.buttons["confirmDeleteHistoryWorkoutButton"].firstMatch.tap()
        assertCount("5 of 11 workouts", in: app)
        app.buttons["historyFilterMenu"].tap()
        app.buttons["Clear filters"].tap()
        assertCount("11 of 11 workouts", in: app)
        XCTAssertTrue(app.buttons["historySortMenu"].label.contains("Oldest first"))
    }

    @MainActor
    func testEmptyHistoryStillOffersImport() {
        let app = launchHistory(populated: false)
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importWorkoutsButton"].exists)
        XCTAssertFalse(app.staticTexts["No matching workouts"].exists)
    }

    @MainActor
    private func launchHistory(populated: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--health-dashboard-ui-fixture") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))
        app.tabBars.buttons["History"].tap()
        return app
    }

    @MainActor
    private func selectFilter(_ picker: String, option: String, in app: XCUIApplication) {
        app.buttons["historyFilterMenu"].tap()
        app.buttons[picker].firstMatch.tap()
        let button = app.buttons[option].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    private func selectSort(_ option: String, in app: XCUIApplication) {
        app.buttons["historySortMenu"].tap()
        let button = app.buttons[option].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
    }

    @MainActor
    private func assertCount(_ text: String, in app: XCUIApplication) {
        let count = app.staticTexts["historyResultCount"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ==[c] %@", text), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor
    private func assertFirstWorkout(_ name: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyWorkout-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.identifier, "historyWorkout-\(name)")
    }
}
