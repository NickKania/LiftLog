import XCTest

final class AssistantUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAssistantExplainsConnectionWithoutBlockingWorkoutLogging() {
        let app = launchApp()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["assistantPrivacyDisclosure"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Assistant before sign-in"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.tabBars.buttons["Workout"].tap()
        app.buttons["startEmptyWorkoutButton"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatGPTConnectionIsAvailableInSettings() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["chatGPTSettingsLink"].tap()
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chatGPTManageUsageLink"].exists || app.links["chatGPTManageUsageLink"].exists)
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].waitForExistence(timeout: 10))
        return app
    }
}
