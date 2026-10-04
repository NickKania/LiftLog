import XCTest

final class PersonalCatalogUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testImportedCustomExerciseIsSearchableAndReusableAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--import-ui-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))
        app.tabBars.buttons["History"].tap()
        app.buttons["importWorkoutsButton"].tap()
        let action = app.buttons["reviewOrImportButton"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        XCTAssertTrue(app.navigationBars["Review Import"].waitForExistence(timeout: 5))
        action.tap()
        let confirm = app.alerts.buttons["confirmWorkoutImportButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["importSuccessCount"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        app.buttons["createTemplateButton"].tap()
        app.buttons["addExerciseButton"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("  fIXture   squat ")
        let importedExercise = app.buttons["exercise-Fixture Squat"]
        XCTAssertTrue(importedExercise.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "exercise-Fixture Squat").count, 1)
        XCTAssertFalse(app.buttons["addCustomExerciseButton"].exists)
        importedExercise.tap()
        XCTAssertTrue(app.buttons["Remove Fixture Squat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["setReps-1"].exists)
    }
}
