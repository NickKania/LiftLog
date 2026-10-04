import XCTest

final class LiftLogUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateTemplateCompleteSetAndResumeAfterRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        app.buttons["createTemplateButton"].tap()
        let name = app.textFields["templateNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Smoke Routine")
        app.buttons["addExerciseButton"].tap()
        app.buttons["exercise-Bench Press"].tap()
        let weight = app.textFields["setWeight-1"].firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.tap()
        weight.typeText(XCUIKeyboardKey.delete.rawValue + "135")
        app.buttons["saveTemplateButton"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Smoke Routine"].waitForExistence(timeout: 5))
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).allElementsBoundByIndex.last!
        start.tap()
        let complete = app.buttons["completeSet-1"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertEqual(complete.label, "Mark set 1 incomplete")
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["completeSet-1"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["completeSet-1"].firstMatch.label, "Mark set 1 incomplete")
        XCTAssertEqual(app.textFields["setWeight-1"].firstMatch.value as? String, "135")
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Smoke Routine"].waitForExistence(timeout: 5))
        app.staticTexts["Smoke Routine"].tap()
        XCTAssertTrue(app.staticTexts["Bench Press"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Completed workout history"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
