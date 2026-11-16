import XCTest

final class WorkoutResumeScrollUITests: XCTestCase {
    @MainActor
    func testNextSetOnMinimizeForegroundAndRelaunch() {
        continueAfterFailure = false
        let app = launchFresh()
        defer { app.terminate() }
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'startTemplate-'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let first = app.buttons["completeSet-1"].firstMatch
        reveal(first, in: app)
        first.tap()
        if app.alerts.buttons["Allow"].waitForExistence(timeout: 2) { app.alerts.buttons["Allow"].tap() }
        let next = app.buttons["completeSet-2"].firstMatch
        scrollAway(in: app)
        app.buttons["minimizeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 5))
        app.buttons["resumeWorkoutButton"].tap()
        assertVisible(next, in: app)
        XCTAssertEqual(app.staticTexts["nextSetExerciseName"].label, "Bench Press")
        XCTAssertTrue(app.staticTexts["nextSetExerciseName"].isHittable)
        capture("Next set after minimizing", app: app)
        scrollAway(in: app)
        XCUIDevice.shared.press(.home)
        app.activate()
        assertVisible(next, in: app)
        capture("Next set after foregrounding", app: app)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        assertVisible(app.buttons["completeSet-2"].firstMatch, in: app)
    }

    @MainActor
    func testDisabledPreferencePersistsAndDoesNotScrollOnForeground() {
        continueAfterFailure = false
        let app = launchFresh()
        defer { app.terminate() }
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["autoScrollActiveWorkoutToggle"]
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "1")
        if toggle.switches.firstMatch.exists { toggle.switches.firstMatch.tap() } else { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        capture("Auto-scroll setting off", app: app)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        reveal(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        app.tabBars.buttons["Workout"].tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'startTemplate-'")).firstMatch.tap()
        scrollAway(in: app)
        let discard = app.buttons["discardWorkoutButton"]
        XCTAssertTrue(discard.isHittable)
        XCUIDevice.shared.press(.home)
        app.activate()
        assertVisible(discard, in: app)
    }

    @MainActor
    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        return app
    }

    @MainActor
    private func scrollAway(in app: XCUIApplication) {
        let discard = app.buttons["discardWorkoutButton"]
        for _ in 0..<15 where !discard.exists || !discard.isHittable { app.swipeUp() }
        XCTAssertTrue(discard.isHittable)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let visible = NSPredicate { _, _ in
            element.exists && element.isHittable && app.frame.contains(element.frame)
        }
        expectation(for: visible, evaluatedWith: nil)
        waitForExpectations(timeout: 8)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
