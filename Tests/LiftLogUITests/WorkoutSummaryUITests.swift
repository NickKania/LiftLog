import XCTest
import UIKit

final class WorkoutSummaryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSummaryExplainsBlockedProviderSwitchForUnreadableArchive() {
        let app = launchFixture(reset: true, onDevice: true,
                                additionalArguments: ["--foundation-models-corrupt-archive-ui-fixture"])
        finishFixtureWorkout(in: app)
        let matches = app.buttons.matching(identifier: "assistantProviderPicker")
        let picker = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
        for _ in 0..<10 where !picker.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(picker.label.contains("ChatGPT"))
        picker.tap()
        app.buttons["Apple Intelligence"].tap()
        XCTAssertTrue(picker.label.contains("ChatGPT"), "Summary provider changes must preserve the unreadable chat archive")
        let error = app.descendants(matching: .any)["assistantProviderStorageError"].firstMatch
        reveal(error, in: app)
        XCTAssertTrue(error.label.contains("preserved"))
        XCTAssertTrue(error.label.contains("try choosing the provider again"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "assistantProviderStorageError").count, 1)
        XCTAssertTrue(app.otherElements["workoutSummarySavedStats"].exists)
        XCTAssertFalse(app.buttons["workoutSummaryGenerateButton"].exists)
        keepScreenshot(of: app, named: "Workout summary explains blocked provider switch")
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

    @MainActor
    func testOnDeviceSummaryAndHealthUseSelectedProviderWithoutChatGPT() {
        let app = launchFixture(reset: true, onDevice: true)
        finishFixtureWorkout(in: app)
        let disclosure = app.staticTexts["workoutSummaryDisclosure"]
        reveal(disclosure, in: app)
        XCTAssertTrue(disclosure.label.contains("on this iPhone"))
        XCTAssertTrue(disclosure.label.contains("without a ChatGPT account"))
        let generate = app.buttons["workoutSummaryGenerateButton"]
        reveal(generate, in: app)
        generate.tap()
        let insights = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Workout insights")).firstMatch
        XCTAssertTrue(insights.waitForExistence(timeout: 5))
        setToggle("workoutSummaryIncludeHealthToggle", enabled: true, in: app)
        reveal(generate, in: app)
        generate.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Heart rate and active energy")).firstMatch.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "On-device workout summary with explicit Health")

        chooseSummaryProvider("ChatGPT", in: app)
        reveal(disclosure, in: app)
        XCTAssertTrue(disclosure.label.contains("Connect an eligible ChatGPT account"))
        XCTAssertFalse(generate.exists, "Switching to ChatGPT must still require its account")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Heart rate and active energy")).firstMatch.exists)
        XCTAssertTrue(insights.exists, "Saved workout-only insights remain readable across providers")
        chooseSummaryProvider("Apple Intelligence", in: app)
        reveal(app.switches["workoutSummaryIncludeHealthToggle"], in: app)
        XCTAssertEqual(toggleControl("workoutSummaryIncludeHealthToggle", in: app).value as? String, "0")
        XCTAssertTrue(insights.exists, "Saved insights remain available without regenerating")
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

    @MainActor
    func testOnDeviceAutomaticSummaryRemainsWorkoutOnly() {
        let app = launchFixture(reset: true, onDevice: true)
        enableAutomaticSummaries(in: app)
        finishFixtureWorkout(in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Workout insights")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Heart rate and active energy")).firstMatch.exists)
        reveal(app.switches["workoutSummaryIncludeHealthToggle"], in: app)
        XCTAssertEqual(toggleControl("workoutSummaryIncludeHealthToggle", in: app).value as? String, "0")
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

    @MainActor
    func testProviderSwitchCancelsOnDeviceSummaryAndClearsHealthSelection() {
        let app = launchFixture(reset: true, delayed: true, onDevice: true)
        finishFixtureWorkout(in: app)
        setToggle("workoutSummaryIncludeHealthToggle", enabled: true, in: app)
        let generate = app.buttons["workoutSummaryGenerateButton"]
        reveal(generate, in: app)
        generate.tap()
        XCTAssertTrue(app.buttons["workoutSummaryStopButton"].waitForExistence(timeout: 5))
        chooseSummaryProvider("ChatGPT", in: app)
        XCTAssertFalse(app.buttons["workoutSummaryStopButton"].exists)
        chooseSummaryProvider("Apple Intelligence", in: app)
        reveal(app.switches["workoutSummaryIncludeHealthToggle"], in: app)
        XCTAssertEqual(toggleControl("workoutSummaryIncludeHealthToggle", in: app).value as? String, "0")
        XCTAssertFalse(app.buttons["workoutSummaryStopButton"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Workout insights")).firstMatch.exists)
        app.buttons["closeWorkoutSummaryButton"].tap()
    }

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
        finishFixtureWorkout(in: app)
        XCTAssertTrue(app.staticTexts["Couldn’t generate insights"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workoutSummaryRetryButton"].exists)
        XCTAssertTrue(app.buttons["closeWorkoutSummaryButton"].exists)
        reveal(app.buttons["workoutSummaryRetryButton"], in: app)
        keepScreenshot(of: app, named: "Workout summary request error with retry")
    }

    @MainActor
    func testLoadingCardAlignsWithSavedStats() {
        checkLoadingCard(includeHealth: false, largeText: false)
    }

    @MainActor
    func testLoadingCardWithHealthAlignsWithSavedStats() {
        checkLoadingCard(includeHealth: true, largeText: false)
    }

    @MainActor
    func testLoadingCardWithHealthSupportsAccessibilityText() {
        checkLoadingCard(includeHealth: true, largeText: true)
    }

    @MainActor
    private func checkLoadingCard(includeHealth: Bool, largeText: Bool) {
        var arguments: [String] = []
        if !largeText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        }
        let app = launchFixture(reset: true, delayed: true, largeText: largeText,
                                additionalArguments: arguments)
        finishFixtureWorkout(in: app)
        if includeHealth { setToggle("workoutSummaryIncludeHealthToggle", enabled: true, in: app) }
        let generate = app.buttons["workoutSummaryGenerateButton"]
        reveal(generate, in: app)
        generate.tap()
        let card = app.otherElements["workoutSummaryWorkingCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let stats = app.otherElements["workoutSummarySavedStats"]
        XCTAssertEqual(card.frame.minX, stats.frame.minX, accuracy: 1)
        let leadingMargin = stats.frame.minX - app.frame.minX
        XCTAssertEqual(card.frame.maxX, app.frame.maxX - leadingMargin, accuracy: 1,
                       "The loading card must keep equal leading and trailing margins")
        let stop = app.buttons["workoutSummaryStopButton"]
        reveal(stop, in: app)
        XCTAssertGreaterThanOrEqual(stop.frame.minX, card.frame.minX + 15)
        XCTAssertLessThanOrEqual(stop.frame.maxX, card.frame.maxX - 15)
        if largeText {
            let progress = app.staticTexts["workoutSummaryProgress"]
            XCTAssertTrue(progress.exists)
            XCTAssertTrue(progress.isHittable)
            let status = progress.staticTexts["Generating insights…"]
            let spinner = progress.activityIndicators.firstMatch
            XCTAssertTrue(status.exists)
            XCTAssertTrue(status.isHittable, "The loading status must remain visible at accessibility XXXL")
            XCTAssertTrue(spinner.exists)
            let statusFrame = status.frame
            XCTAssertTrue(app.scrollViews.firstMatch.frame.contains(statusFrame),
                          "The entire loading status must fit in the visible scroll area")
            XCTAssertGreaterThanOrEqual(statusFrame.minY, app.navigationBars["Workout Summary"].frame.maxY)
            let singleLineHeight = UIFont.preferredFont(
                forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
            ).lineHeight
            XCTAssertGreaterThan(statusFrame.height, singleLineHeight * 1.5,
                                 "The loading status must wrap instead of truncating to one line")
            XCTAssertLessThanOrEqual(spinner.frame.maxY, statusFrame.minY,
                                     "The spinner must stack above the loading status at accessibility XXXL")
            XCTAssertEqual(spinner.frame.minX, statusFrame.minX, accuracy: 1,
                           "The stacked spinner and loading status must share leading alignment")
        }
        keepScreenshot(of: app, named: "Workout insights loading \(includeHealth ? "with Health" : "workout only") \(largeText ? "accessibility XXXL" : "default text")")
        stop.tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
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
    func testSavedSummaryReopensFromHistoryAfterRelaunchWithoutProviderAccess() {
        let app = launchFixture(reset: true)
        finishFixtureWorkout(in: app)
        let generate = app.buttons["workoutSummaryGenerateButton"]
        reveal(generate, in: app)
        generate.tap()
        let insights = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Workout insights")).firstMatch
        XCTAssertTrue(insights.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved insights"].exists)
        app.buttons["closeWorkoutSummaryButton"].tap()
        app.tabBars.buttons["History"].tap()
        app.buttons["historyWorkout-Summary Fixture Workout"].tap()
        app.buttons["workoutSummaryHistoryButton"].tap()
        XCTAssertTrue(insights.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Saved workout insights reopened from History")
        app.terminate()

        // The unavailable on-device provider needs no account or inference request to read saved text.
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture", "--workout-summary-ui-fixture",
                               "--foundation-models-ui-fixture", "--foundation-models-unavailable-ui-fixture"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        app.buttons["historyWorkout-Summary Fixture Workout"].tap()
        app.buttons["workoutSummaryHistoryButton"].tap()
        XCTAssertTrue(insights.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved insights"].exists)
        XCTAssertFalse(app.buttons["workoutSummaryStopButton"].exists)
        keepScreenshot(of: app, named: "Saved workout insights after relaunch without provider access")
    }

    @MainActor
    private func launchFixture(reset: Bool, error: Bool = false, delayed: Bool = false, largeText: Bool = false, onDevice: Bool = false, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["--ui-testing", "--assistant-ui-fixture", "--workout-summary-ui-fixture"]
        if onDevice {
            arguments.append("--foundation-models-ui-fixture")
        }
        if reset { arguments.append("--reset-ui-testing") }
        if error { arguments.append("--workout-summary-error-ui-fixture") }
        if delayed { arguments.append("--workout-summary-delayed-ui-fixture") }
        if largeText {
            arguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = arguments + additionalArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Workout"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func finishFixtureWorkout(in app: XCUIApplication) {
        app.tabBars.buttons["Workout"].tap()
        app.buttons["resumeWorkoutButton"].tap()
        let finish = app.buttons["finishWorkoutButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: finish)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        finish.tap()
        let confirmation = app.buttons["confirmFinishWorkoutButton"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(app.otherElements["workoutSummarySavedStats"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func chooseSummaryProvider(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["assistantProviderPicker"]
        for _ in 0..<10 where !picker.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        app.buttons[name].tap()
        XCTAssertTrue(picker.label.contains(name))
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
