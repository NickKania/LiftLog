import XCTest

final class AssistantInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

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
    private func launchFixture(delayed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--assistant-ui-fixture"]
        if delayed { app.launchArguments.append("--assistant-delayed-ui-fixture") }
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
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
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
