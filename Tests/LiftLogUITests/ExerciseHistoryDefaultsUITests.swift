import XCTest

final class ExerciseHistoryDefaultsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAddedExerciseUsesSavedPerformanceAndSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["startEmptyWorkoutButton"].tap()
        addBench(in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "0")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "10")
        replace(app.textFields["setWeight-1"], with: "135", app: app)
        replace(app.textFields["setReps-1"], with: "7", app: app)
        app.buttons["completeSet-1"].tap()
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["closeWorkoutSummaryButton"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutSummaryButton"].tap()
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 5))
        app.buttons["startEmptyWorkoutButton"].tap()
        addBench(in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "135")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "7")
        XCTAssertEqual(app.buttons["completeSet-1"].label, "Complete set 1")
        XCTAssertFalse(app.staticTexts["setTargetReps-1"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.textFields["setWeight-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "135")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "7")
    }

    @MainActor private func addBench(in app: XCUIApplication) {
        app.buttons["addExerciseButton"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Bench Press")
        app.buttons["exercise-Bench Press"].tap()
        XCTAssertTrue(app.textFields["setWeight-1"].waitForExistence(timeout: 5))
    }

    @MainActor private func replace(_ field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        let value = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + text)
        app.buttons["Done"].tap()
    }
}
