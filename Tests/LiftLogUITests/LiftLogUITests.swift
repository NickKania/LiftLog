import XCTest

final class LiftLogUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSetValuesPropagateAcrossRemainingExerciseSets() throws {
        addUIInterruptionMonitor(withDescription: "Rest notification permission") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()

        let weight = app.textFields["setWeight-1"].firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.tap()
        weight.typeText(XCUIKeyboardKey.delete.rawValue + "142.5")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.textFields["setWeight-2"].firstMatch.value as? String, "142.5")
        XCTAssertEqual(app.textFields["setWeight-3"].firstMatch.value as? String, "142.5")

        let reps = app.textFields["setReps-2"].firstMatch
        reps.tap()
        reps.typeText(XCUIKeyboardKey.delete.rawValue + "6")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.textFields["setReps-1"].firstMatch.value as? String, "6")
        XCTAssertEqual(app.textFields["setReps-3"].firstMatch.value as? String, "6")
        XCTAssertEqual(weight.value as? String, "142.5")

        app.buttons["completeSet-1"].firstMatch.tap()
        app.tap() // Dismiss the first rest-timer notification permission prompt if present.
        XCTAssertFalse(weight.isEnabled)
        XCTAssertFalse(app.textFields["setReps-1"].firstMatch.isEnabled)
        let remainingWeight = app.textFields["setWeight-2"].firstMatch
        remainingWeight.tap()
        remainingWeight.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "150")
        app.buttons["Done"].tap()
        reps.tap()
        reps.typeText(XCUIKeyboardKey.delete.rawValue + "5")
        app.buttons["Done"].tap()
        XCTAssertEqual(weight.value as? String, "142.5")
        XCTAssertEqual(app.textFields["setReps-1"].firstMatch.value as? String, "6")
        XCTAssertEqual(app.textFields["setWeight-3"].firstMatch.value as? String, "150")
        XCTAssertEqual(app.textFields["setReps-3"].firstMatch.value as? String, "5")

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.textFields["setWeight-3"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["setWeight-3"].firstMatch.value as? String, "150")
        XCTAssertEqual(app.textFields["setReps-3"].firstMatch.value as? String, "5")
        XCTAssertEqual(app.textFields["setWeight-1"].firstMatch.value as? String, "142.5")
        XCTAssertEqual(app.textFields["setReps-1"].firstMatch.value as? String, "6")
        app.buttons["completeSet-1"].firstMatch.tap()
        XCTAssertTrue(app.textFields["setWeight-1"].firstMatch.isEnabled)
        XCTAssertTrue(app.textFields["setReps-1"].firstMatch.isEnabled)
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
        app.buttons["Done"].tap()
        app.buttons["addExerciseButton"].tap()
        app.buttons["exercise-Bench Press"].tap()
        app.buttons["Add Set"].tap()
        XCTAssertTrue(app.textFields["setWeight-2"].waitForExistence(timeout: 5))
        let weight = app.textFields["setWeight-1"].firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        weight.tap()
        weight.typeText(XCUIKeyboardKey.delete.rawValue + "135")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.textFields["setWeight-2"].value as? String, "135")
        XCTAssertTrue(app.staticTexts["TARGET REPS"].exists)
        let reps = app.textFields["setReps-2"]
        reps.tap()
        reps.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "6")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "6")
        XCTAssertEqual(reps.value as? String, "6")
        app.buttons["saveTemplateButton"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Smoke Routine"].waitForExistence(timeout: 5))
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).allElementsBoundByIndex.last!
        start.tap()
        let complete = app.buttons["completeSet-1"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["setTargetReps-1"].firstMatch.label, "Target: 6")
        let actualReps = app.textFields["setReps-1"].firstMatch
        actualReps.tap()
        actualReps.typeText(XCUIKeyboardKey.delete.rawValue + "5")
        app.buttons["Done"].tap()
        XCTAssertEqual(app.staticTexts["setTargetReps-1"].firstMatch.label, "Target: 6")
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
        XCTAssertEqual(app.textFields["setReps-1"].firstMatch.value as? String, "5")
        XCTAssertEqual(app.staticTexts["setTargetReps-1"].firstMatch.label, "Target: 6")
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
