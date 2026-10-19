import XCTest

final class WorkoutSummaryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testFinishingWorkoutShowsSavedFactsWithoutAutomaticNetworkRequest() {
        let app = launchFixture(reset: true)
        app.tabBars.buttons["Workout"].tap()
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()

        let facts = app.otherElements["workoutSummarySavedStats"]
        XCTAssertTrue(facts.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "completed sets")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Workout insights"].exists)
        setToggle("workoutSummaryIncludeHealthToggle", enabled: true, in: app)
        reveal(app.buttons["workoutSummaryGenerateButton"], in: app)
        app.buttons["workoutSummaryGenerateButton"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Workout insights")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

    @MainActor
    func testAutomaticSummaryIsWorkoutOnlyUntilHealthIsExplicitlySelected() {
        let app = launchFixture(reset: true)
        enableAutomaticSummaries(in: app)
        app.tabBars.buttons["Workout"].tap()
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()

        XCTAssertTrue(app.otherElements["workoutSummarySavedStats"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Workout insights")).firstMatch.waitForExistence(timeout: 5))

        // Automatic generation is workout-only. Health requires a new explicit
        // selection and a second Generate action.
        setToggle("workoutSummaryIncludeHealthToggle", enabled: true, in: app)
        reveal(app.buttons["workoutSummaryGenerateButton"], in: app)
        app.buttons["workoutSummaryGenerateButton"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Heart rate and active energy")).firstMatch.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Workout summary with explicit Health opt in")
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

    @MainActor
    func testSummaryPromptSaveCancelResetAndAutomaticPreferenceSurviveRelaunch() {
        let app = launchFixture(reset: true)
        openSettings(in: app)
        let editor = app.textViews["workoutSummaryPromptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        replaceText(in: editor, with: "Focus on clean reps and give me one next-session suggestion.", app: app)
        app.buttons["workoutSummarySettingsCancel"].tap()

        openSettings(in: app)
        XCTAssertFalse((editor.value as? String ?? "").contains("clean reps"))
        replaceText(in: editor, with: "Focus on clean reps and give me one next-session suggestion.", app: app)
        app.buttons["workoutSummarySettingsSave"].tap()

        openSettings(in: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("clean reps"))
        app.buttons["workoutSummaryResetPromptButton"].tap()
        app.buttons["workoutSummarySettingsCancel"].tap()
        openSettings(in: app)
        XCTAssertTrue((editor.value as? String ?? "").contains("clean reps"), "Reset draft must not save until Save is tapped")
        app.buttons["workoutSummaryResetPromptButton"].tap()
        app.buttons["workoutSummarySettingsSave"].tap()

        openSettings(in: app)
        XCTAssertFalse((editor.value as? String ?? "").contains("clean reps"))
        setToggle("workoutSummaryAutomaticToggle", enabled: true, in: app)
        app.buttons["workoutSummarySettingsSave"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture", "--workout-summary-ui-fixture"]
        app.launch()
        openSettings(in: app)
        XCTAssertEqual(toggleControl("workoutSummaryAutomaticToggle", in: app).value as? String, "1")
    }

    @MainActor
    func testPromptActionsRemainReachableAtAccessibilityTextSize() {
        let app = launchFixture(reset: true, largeText: true)
        app.tabBars.buttons["Settings"].tap()
        let settings = app.buttons["workoutSummarySettingsLink"]
        reveal(settings, in: app)
        // A partially exposed row can report hittable while the tab bar covers
        // its tap point at accessibility sizes. Bring the whole row into view.
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<4 where settings.frame.maxY >= tabBar.frame.minY {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertLessThan(settings.frame.maxY, tabBar.frame.minY)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Summaries"].waitForExistence(timeout: 5))
        let cancel = app.buttons["workoutSummarySettingsCancel"]
        let save = app.buttons["workoutSummarySettingsSave"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(save.isHittable)
        keepScreenshot(of: app, named: "Prompt settings accessibility XXXL")
        let editor = app.textViews["workoutSummaryPromptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(save.isHittable)
        keepScreenshot(of: app, named: "Prompt keyboard accessibility XXXL")
        cancel.tap()
        XCTAssertTrue(app.buttons["workoutSummarySettingsLink"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSummaryRequestErrorOffersRetry() {
        let app = launchFixture(reset: true, error: true)
        enableAutomaticSummaries(in: app)
        app.tabBars.buttons["Workout"].tap()
        app.buttons["resumeWorkoutButton"].tap()
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Couldn’t generate insights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workoutSummaryRetryButton"].exists)
        XCTAssertTrue(app.buttons["closeWorkoutSummaryButton"].exists)
        reveal(app.buttons["workoutSummaryRetryButton"], in: app)
        keepScreenshot(of: app, named: "Workout summary request error with retry")
    }

    @MainActor
    func testStopDismissAndHistoryReopenClearTransientResponse() {
        let app = launchFixture(reset: true, delayed: true)
        app.buttons["resumeWorkoutButton"].tap()
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        let generate = app.buttons["workoutSummaryGenerateButton"]
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        reveal(generate, in: app)
        generate.tap()
        let stop = app.buttons["workoutSummaryStopButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Workout summary generation in progress")
        stop.tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Workout insights"].exists)
        app.buttons["closeWorkoutSummaryButton"].tap()
        app.tabBars.buttons["History"].tap()
        app.buttons["historyWorkout-Summary Fixture Workout"].tap()
        let reopen = app.buttons["workoutSummaryHistoryButton"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        reveal(generate, in: app)
        generate.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        app.buttons["closeWorkoutSummaryButton"].tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 5))
        reopen.tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertFalse(stop.exists)
        XCTAssertFalse(app.staticTexts["Workout insights"].exists)
    }

    @MainActor
    private func launchFixture(reset: Bool, error: Bool = false, delayed: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["--ui-testing", "--assistant-ui-fixture", "--workout-summary-ui-fixture"]
        if reset { arguments.append("--reset-ui-testing") }
        if error { arguments.append("--workout-summary-error-ui-fixture") }
        if delayed { arguments.append("--workout-summary-delayed-ui-fixture") }
        if largeText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        app.buttons["workoutSummarySettingsLink"].tap()
        XCTAssertTrue(app.navigationBars["Workout Summaries"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func enableAutomaticSummaries(in app: XCUIApplication) {
        openSettings(in: app)
        setToggle("workoutSummaryAutomaticToggle", enabled: true, in: app)
        app.buttons["workoutSummarySettingsSave"].tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func toggleControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let labelledSwitch = app.switches[identifier]
        XCTAssertTrue(labelledSwitch.waitForExistence(timeout: 5))
        // iOS exposes the labelled row and its native UISwitch separately.
        let control = labelledSwitch.switches.firstMatch
        return control.exists ? control : labelledSwitch
    }

    @MainActor
    private func setToggle(_ identifier: String, enabled: Bool, in app: XCUIApplication) {
        reveal(app.switches[identifier], in: app)
        let control = toggleControl(identifier, in: app)
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected { control.tap() }
        XCTAssertEqual(control.value as? String, expected)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        field.press(forDuration: 1.0)
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
