import XCTest

final class AssistantInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSettingsDefaultModelAppliesToNewChatsAndSurvivesRelaunch() throws {
        let app = launchFixture()
        let currentModel = app.buttons["assistantModelPicker"]
        XCTAssertTrue(currentModel.waitForExistence(timeout: 5))
        XCTAssertTrue(currentModel.label.contains("Fixture Model"))
        send("Hello", in: app)
        XCTAssertTrue(app.buttons["assistantNewChatButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        let defaultModel = app.buttons["assistantDefaultModelPicker"]
        XCTAssertTrue(defaultModel.waitForExistence(timeout: 5))
        defaultModel.tap()
        app.buttons["Alternate Model"].tap()
        XCTAssertTrue(defaultModel.label.contains("Alternate Model"))
        keepScreenshot(of: app, named: "Default assistant model in Settings")
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(currentModel.label.contains("Fixture Model"))
        app.buttons["assistantNewChatButton"].tap()
        XCTAssertTrue(currentModel.waitForExistence(timeout: 5))
        XCTAssertTrue(currentModel.label.contains("Alternate Model"))

        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(currentModel.waitForExistence(timeout: 5))
        XCTAssertTrue(currentModel.label.contains("Alternate Model"))
        app.tabBars.buttons["Settings"].tap()
        defaultModel.tap()
        app.buttons["Automatic"].tap()
        XCTAssertTrue(defaultModel.label.contains("Automatic"))
    }

    @MainActor
    func testReviewedTemplateIsSavedOnlyAfterApplyAndSurvivesRelaunch() throws {
        let app = launchFixture()
        send("Create a routine", in: app)
        let apply = app.buttons["assistantApplyProposalButton"]
        reveal(apply, in: app)
        XCTAssertTrue(app.staticTexts["BEFORE"].exists)
        XCTAssertTrue(app.staticTexts["AFTER"].exists)
        keepScreenshot(of: app, named: "Assistant proposal before Apply")

        app.tabBars.buttons["Workout"].tap()
        XCTAssertFalse(app.staticTexts["Assistant Fixture Routine"].exists)
        app.tabBars.buttons["Assistant"].tap()
        reveal(apply, in: app)
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Assistant Fixture Routine"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture"]
        app.launch()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Assistant Fixture Routine"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDiscardedProposalDoesNotSaveTemplate() throws {
        let app = launchFixture()
        send("Create a routine", in: app)
        let discard = app.buttons["assistantDiscardProposalButton"]
        reveal(discard, in: app)
        discard.tap()
        XCTAssertTrue(app.staticTexts["Discarded"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        app.swipeUp()
        XCTAssertFalse(app.staticTexts["Assistant Fixture Routine"].exists)
    }

    @MainActor
    func testRecordedHistoryChartOffersImageSharing() throws {
        let app = launchFixture()
        send("Chart my training volume", in: app)
        let share = app.buttons["assistantShareChartButton"]
        reveal(share, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["assistantWorkoutChart"].exists)
        XCTAssertTrue(app.staticTexts["Source: completed sets in 2 recorded workouts."].exists)
        keepScreenshot(of: app, named: "Assistant chart before sharing")
        share.tap()
        XCTAssertTrue(app.buttons["Copy"].waitForExistence(timeout: 5) || app.otherElements["ActivityListView"].exists)
    }

    @MainActor
    func testChartSelectionStyleAndWorkoutDetails() throws {
        let app = launchFixture()
        send("Chart my training volume", in: app)
        let previous = app.buttons["assistantChartPreviousButton"]
        reveal(previous, in: app)
        let selectedValue = app.staticTexts["assistantChartSelectedValue"]
        XCTAssertEqual(selectedValue.label, "1,160")
        previous.tap()
        XCTAssertEqual(selectedValue.label, "1,080")
        XCTAssertFalse(previous.isEnabled)
        app.buttons["assistantChartNextButton"].tap()
        XCTAssertEqual(selectedValue.label, "1,160")

        let chart = app.descendants(matching: .any)["assistantWorkoutChart"].firstMatch
        reveal(chart, in: app)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.4))
            .press(forDuration: 0.4, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.4)))
        XCTAssertEqual(selectedValue.label, "1,080", "Dragging the plot should select the nearest workout")

        app.buttons["assistantChartStyleButton"].tap()
        app.buttons["Bars"].tap()
        XCTAssertEqual(app.buttons["assistantChartStyleButton"].value as? String, "Bars")
        keepScreenshot(of: app, named: "Interactive chart with bar selection")

        let disclosure = app.descendants(matching: .any)["assistantChartWorkoutsDisclosure"].firstMatch
        reveal(disclosure, in: app)
        disclosure.tap()
        let firstWorkout = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recorded Fixture Workout 1,")).firstMatch
        reveal(firstWorkout, in: app)
        firstWorkout.tap()
        reveal(selectedValue, in: app)
        XCTAssertEqual(selectedValue.label, "1,080")
    }

    @MainActor
    func testChartRangesFilterRecordedSnapshot() throws {
        let app = launchFixture(dense: true)
        send("Chart my training volume", in: app)
        let range = app.segmentedControls["assistantChartRangePicker"]
        reveal(range, in: app)
        range.buttons["30 days"].tap()
        let source = app.staticTexts["Source: completed sets in 2 recorded workouts."]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        range.buttons["90 days"].tap()
        XCTAssertTrue(app.staticTexts["Source: completed sets in 5 recorded workouts."].exists)
        range.buttons["All"].tap()
        XCTAssertTrue(app.staticTexts["Source: completed sets in 10 recorded workouts."].exists)
        keepScreenshot(of: app, named: "Ten workout chart with readable date ticks")
    }

    @MainActor
    func testMarkdownRendersNativeBlocksAndCopyActions() throws {
        let app = launchFixture()
        send("Show formatting", in: app)
        let heading = app.staticTexts["Your training, in perspective"]
        reveal(heading, in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "**")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "## ")).firstMatch.exists)
        keepScreenshot(of: app, named: "Markdown heading, nested list and workout table")
        let copy = app.buttons["Copy response"]
        reveal(copy, in: app)
        copy.tap()
        let code = app.staticTexts["volume = weight × completed reps"]
        reveal(code, in: app)
        // Enriched Markdown exposes code copying through the native context
        // menu and a VoiceOver action rather than a separate accessible button.
        code.press(forDuration: 1)
        let copyCode = app.buttons["Copy"].firstMatch
        XCTAssertTrue(copyCode.waitForExistence(timeout: 5))
        copyCode.tap()
        XCTAssertTrue(app.links["Training reference"].exists || app.staticTexts["Training reference"].exists)
        keepScreenshot(of: app, named: "Markdown quote, code block and link")
    }

    @MainActor
    func testChartAndMarkdownWithLargeTextInDarkMode() throws {
        let app = launchFixture(largeText: true)
        send("Chart my training volume", in: app)
        let transcript = app.scrollViews.firstMatch
        XCTAssertGreaterThanOrEqual(transcript.frame.minX, app.frame.minX - 1, "Large assistant controls must not widen the transcript beyond the screen")
        XCTAssertLessThanOrEqual(transcript.frame.maxX, app.frame.maxX + 1, "The transcript gutter must remain onscreen for scrolling")
        let previous = app.buttons["assistantChartPreviousButton"]
        reveal(previous, in: app)
        previous.tap()
        XCTAssertEqual(app.staticTexts["assistantChartSelectedValue"].label, "1,080")
        keepScreenshot(of: app, named: "Chart details with large text in dark mode")
        let share = app.buttons["assistantShareChartButton"]
        reveal(share, in: app)
        keepScreenshot(of: app, named: "Formatted workout reply with large text in dark mode")
    }

    @MainActor
    func testProgressRemainsVisibleThroughToolRound() throws {
        let app = launchFixture(delayed: true)
        send("Chart my training volume", in: app)
        let progress = app.descendants(matching: .any)["assistantWorkingIndicator"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 2))
        XCTAssertTrue(app.frame.contains(progress.frame), "Progress must be visible above the composer")
        XCTAssertTrue(app.buttons["assistantCancelButton"].exists)
        XCTAssertFalse(app.buttons["assistantSendButton"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["assistantWorkoutChart"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(progress.exists, "Progress must remain visible while the model explains the tool result")
        XCTAssertTrue(app.frame.contains(progress.frame), "The chart must not push progress offscreen")
        XCTAssertTrue(app.staticTexts["Here is the result from your recorded workout data. Review any proposed changes before applying them."].waitForExistence(timeout: 8))
        XCTAssertFalse(progress.exists)
    }

    @MainActor
    func testResponseSurvivesRepeatedForegroundTabSwitches() throws {
        let app = launchFixture(concurrent: true)
        send("Show formatting", in: app)
        XCTAssertTrue(app.buttons["assistantCancelButton"].waitForExistence(timeout: 2))
        for tab in ["Workout", "History", "Settings"] {
            app.tabBars.buttons[tab].tap()
            app.tabBars.buttons["Assistant"].tap()
            XCTAssertTrue(app.buttons["assistantModelPicker"].exists)
            XCTAssertTrue(app.textFields["assistantComposer"].exists)
        }
        XCTAssertTrue(app.staticTexts["Your training, in perspective"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.buttons["assistantCancelButton"].exists)
        XCTAssertFalse(app.staticTexts["Assistant unavailable"].exists)
        keepScreenshot(of: app, named: "Completed response after foreground tab switches")
    }

    @MainActor
    func testResponseSurvivesTabSwitchAndBackgrounding() throws {
        let app = launchFixture(delayed: true)
        send("Chart my training volume", in: app)
        let progress = app.descendants(matching: .any)["assistantWorkingIndicator"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 2))
        app.tabBars.buttons["Workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.buttons["assistantModelPicker"].exists)

        XCUIDevice.shared.press(.home)
        app.activate()
        let answer = app.staticTexts["Here is the result from your recorded workout data. Review any proposed changes before applying them."]
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["assistantCancelButton"].exists)
        XCTAssertFalse(app.staticTexts["Assistant unavailable"].exists)
        XCTAssertTrue(app.buttons["assistantModelPicker"].exists)
        XCTAssertTrue(app.buttons["assistantSendButton"].exists)
        keepScreenshot(of: app, named: "Assistant response after tab switch and foregrounding")
    }

    @MainActor
    func testExpiredBackgroundTimeKeepsChatConnectedAndAllowsAnotherMessage() throws {
        let app = launchFixture(delayed: true, expiring: true)
        send("Chart my training volume", in: app)
        let notice = app.descendants(matching: .any)["assistantRequestErrorNotice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Response interrupted."].exists)
        XCTAssertTrue(app.buttons["assistantModelPicker"].exists)
        XCTAssertTrue(app.buttons["assistantSendButton"].exists)
        XCTAssertFalse(app.buttons["assistantCancelButton"].exists)
        XCTAssertFalse(app.buttons["assistantApplyProposalButton"].exists)
        keepScreenshot(of: app, named: "Assistant remains signed in after background allowance expires")
        send("Another question", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["assistantWorkingIndicator"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(notice.exists)
        app.buttons["assistantCancelButton"].tap()
    }

    @MainActor
    func testPendingResponseCanBeCancelled() throws {
        let app = launchFixture(delayed: true)
        send("Chart my training volume", in: app)
        let progress = app.descendants(matching: .any)["assistantWorkingIndicator"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 2))
        app.buttons["assistantCancelButton"].tap()
        XCTAssertTrue(app.buttons["assistantSendButton"].waitForExistence(timeout: 2))
        XCTAssertFalse(progress.exists)
    }

    @MainActor
    private func launchFixture(delayed: Bool = false, dense: Bool = false, largeText: Bool = false, expiring: Bool = false, concurrent: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--assistant-ui-fixture"]
        if delayed { app.launchArguments.append("--assistant-delayed-ui-fixture") }
        if concurrent { app.launchArguments.append("--assistant-concurrent-ui-fixture") }
        if expiring { app.launchArguments.append("--assistant-expiring-ui-fixture") }
        if dense { app.launchArguments.append("--assistant-dense-chart-ui-fixture") }
        if largeText {
            app.launchArguments += ["--assistant-dark-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        let gotIt = app.buttons["assistantWelcomeGotItButton"]
        if gotIt.waitForExistence(timeout: 2) { gotIt.tap() }
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func send(_ question: String, in app: XCUIApplication) {
        let composer = app.textFields["assistantComposer"]
        composer.tap()
        composer.typeText(question)
        let send = app.buttons["assistantSendButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        let transcript = app.scrollViews.firstMatch
        // Scroll using the target's position. Large-text replies can span several
        // pages in either direction, and a lazy card may not yet be realized.
        for _ in 0..<20 {
            if element.exists && element.isHittable { return }
            let viewport = transcript.frame
            let delta = element.exists ? viewport.midY - element.frame.midY : viewport.height
            let distance = min(max(abs(delta), 44), viewport.height * 0.35)
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            let end = start.withOffset(CGVector(dx: 0, dy: delta >= 0 ? distance : -distance))
            // Short drags in the transcript gutter avoid overshooting a control
            // or hitting chart gestures. Holding at the end suppresses inertia.
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
