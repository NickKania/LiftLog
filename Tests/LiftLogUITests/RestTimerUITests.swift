import XCTest

final class RestTimerUITests: XCTestCase {
    @MainActor
    func testConfiguredRestStartsRestartsSurvivesMinimizeAndSkips() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        addUIInterruptionMonitor(withDescription: "Rest notification permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        app.buttons["createTemplateButton"].tap()
        app.textFields["templateNameField"].tap()
        app.textFields["templateNameField"].typeText("Timed routine")
        app.buttons["Done"].tap()
        let rest = app.steppers["templateRestStepper"]
        XCTAssertTrue(rest.waitForExistence(timeout: 5))
        XCTAssertTrue(rest.label.contains("2:00"))
        for _ in 0..<6 { app.buttons["templateRestStepper-Decrement"].tap() }
        XCTAssertTrue(rest.label.contains("0:30"))
        app.buttons["addExerciseButton"].tap()
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        app.buttons["exercise-Bench Press"].tap()
        app.buttons["Add Set"].tap()
        app.buttons["Add Set"].tap()
        app.buttons["Add Set"].tap()
        app.buttons["saveTemplateButton"].tap()
        app.swipeUp()
        let name = app.staticTexts["Timed routine"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'startTemplate-'")).allElementsBoundByIndex.last!
        if !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.buttons["completeSet-1"].waitForExistence(timeout: 5))
        app.buttons["completeSet-1"].tap()
        app.tap() // Allow the interruption monitor to dismiss the system prompt if needed.
        let countdown = app.descendants(matching: .any)["restCountdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        XCTAssertTrue(countdown.label.hasPrefix("0:"))
        assertCountdown(countdown, in: app, isBelowSet: 1, aboveSet: 2)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Inline rest timer below completed set"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["minimizeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 5))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rest complete"), object: countdown)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 35), .completed)
        assertCountdown(countdown, in: app, isBelowSet: 1, aboveSet: 2)
        app.buttons["completeSet-3"].tap()
        XCTAssertTrue(countdown.label == "0:30" || countdown.label == "0:29")
        assertCountdown(countdown, in: app, isBelowSet: 3, aboveSet: 4)
        app.buttons["completeSet-2"].tap()
        XCTAssertTrue(countdown.label == "0:30" || countdown.label == "0:29")
        assertCountdown(countdown, in: app, isBelowSet: 2, aboveSet: 3)
        app.buttons["skipRestButton"].tap()
        XCTAssertFalse(countdown.exists)
        app.buttons["completeSet-4"].tap()
        XCTAssertFalse(countdown.exists, "There is no next set after the final completion")
    }

    @MainActor
    private func assertCountdown(_ countdown: XCUIElement, in app: XCUIApplication, isBelowSet completedNumber: Int, aboveSet nextNumber: Int, file: StaticString = #filePath, line: UInt = #line) {
        let completed = app.buttons["completeSet-\(completedNumber)"]
        let next = app.buttons["completeSet-\(nextNumber)"]
        let positioned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            countdown.exists && completed.exists && next.exists &&
                countdown.frame.minY >= completed.frame.maxY &&
                countdown.frame.maxY <= next.frame.minY
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [positioned], timeout: 5), .completed,
                       "Rest countdown should be between set \(completedNumber) and set \(nextNumber)", file: file, line: line)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "restCountdown").count, 1, file: file, line: line)
    }
}
