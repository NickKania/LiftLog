import XCTest

final class WorkoutImportUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDeleteHistoryConfirmationPersistenceAndEmptyState() {
        let app = launchFixture(reset: true)
        openImport(in: app)
        app.buttons["reviewOrImportButton"].tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        app.buttons["reviewOrImportButton"].tap()
        app.alerts.buttons["confirmWorkoutImportButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importSuccessCount"].waitForExistence(timeout: 5))
        app.buttons["viewImportedHistoryButton"].tap()

        let upper = app.buttons["historyWorkout-Sample Upper"]
        let lower = app.buttons["historyWorkout-Sample Lower"]
        XCTAssertTrue(upper.waitForExistence(timeout: 5))
        upper.swipeLeft()
        app.buttons["Delete"].tap()
        let confirm = app.alerts.buttons["confirmDeleteHistoryWorkoutButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(upper.exists)
        XCTAssertTrue(lower.exists)

        upper.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(upper.waitForNonExistence(timeout: 5))
        XCTAssertTrue(lower.exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--import-ui-fixture"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(lower.waitForExistence(timeout: 5))
        XCTAssertFalse(upper.exists)

        lower.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCancelReviewDoesNotCreateHistory() {
        let app = launchFixture(reset: true)
        openImport(in: app)
        XCTAssertTrue(app.staticTexts["selectedImportFile"].waitForExistence(timeout: 5))
        app.buttons["reviewOrImportButton"].tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutImportButton"].tap()
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--import-ui-fixture"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testImportMultipleWorkoutsPersistsAndPreventsDuplicates() {
        let app = launchFixture(reset: true)
        openImport(in: app)
        app.buttons["reviewOrImportButton"].tap()
        let importButton = app.buttons["reviewOrImportButton"]
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Workout import review"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(importButton.label, "Import 2 Workouts")
        importButton.tap()
        let confirm = app.alerts.buttons["confirmWorkoutImportButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["importSuccessCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["importSuccessCount"].label, "2 workouts imported")
        app.buttons["viewImportedHistoryButton"].tap()
        XCTAssertTrue(app.buttons["historyWorkout-Sample Upper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["historyWorkout-Sample Lower"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing", "--import-ui-fixture"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["historyWorkout-Sample Upper"].waitForExistence(timeout: 5))
        openImport(in: app)
        app.buttons["reviewOrImportButton"].tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        XCTAssertEqual(importButton.label, "Import 0 Workouts")
        XCTAssertFalse(importButton.isEnabled)
    }

    @MainActor
    func testSelectOneWorkoutAndReviewExerciseMapping() {
        let app = launchFixture(reset: true)
        openImport(in: app)
        app.buttons["importWeightUnitPicker"].tap()
        app.buttons["Kilograms (kg)"].tap()
        app.buttons["importTimeZonePicker"].tap()
        XCTAssertTrue(app.navigationBars["Export Time Zone"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["importWeightUnitPicker"].label.contains("Kilograms"), "Returning from time zone selection must preserve the export unit")
        app.buttons["reviewOrImportButton"].tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        let match = app.buttons["importMapping-Bench Press"]
        scrollTo(match, in: app)
        match.tap()
        XCTAssertTrue(app.buttons["keepOriginalImportExerciseButton"].waitForExistence(timeout: 5))
        app.buttons["keepOriginalImportExerciseButton"].tap()
        let clear = app.buttons["clearImportWorkoutsButton"]
        scrollTo(clear, in: app)
        clear.tap()
        XCTAssertEqual(app.buttons["reviewOrImportButton"].label, "Import 0 Workouts")
        XCTAssertFalse(app.buttons["reviewOrImportButton"].isEnabled)
        let upper = app.buttons["importSelection-strong:19:2024-01-01 10:00:00:12:Sample Upper"].firstMatch
        scrollTo(upper, in: app)
        upper.tap()
        XCTAssertEqual(app.buttons["reviewOrImportButton"].label, "Import 1 Workout")
        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "Workout import selection"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)
        app.staticTexts["Sample Upper"].tap()
        XCTAssertTrue(app.staticTexts["50 kg × 10"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        app.buttons["reviewOrImportButton"].tap()
        app.alerts.buttons["confirmWorkoutImportButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["importSuccessCount"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["importSuccessCount"].label, "1 workout imported")
        app.buttons["viewImportedHistoryButton"].tap()
        XCTAssertTrue(app.buttons["historyWorkout-Sample Upper"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["historyWorkout-Sample Lower"].exists)
        app.buttons["historyWorkout-Sample Upper"].tap()
        XCTAssertTrue(app.staticTexts["50 kg × 10"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchFixture(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--import-ui-fixture"] + (reset ? ["--reset-ui-testing"] : [])
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))
        app.tabBars.buttons["History"].tap()
        return app
    }

    @MainActor
    private func openImport(in app: XCUIApplication) {
        app.buttons["importWorkoutsButton"].tap()
        XCTAssertTrue(app.buttons["reviewOrImportButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            let footer = app.buttons["reviewOrImportButton"]
            // UIKit can report a partially occluded List row as hittable under the inset.
            if element.exists && element.isHittable && element.frame.maxY < footer.frame.minY - 12 { return }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertLessThan(element.frame.maxY, app.buttons["reviewOrImportButton"].frame.minY - 12)
    }
}
