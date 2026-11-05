import XCTest

final class CatalogCreditsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBundledCreditsAndFullLicenseAreAccessibleWithoutAnAccount() {
        let app = launchApp()
        defer { app.terminate() }

        app.tabBars.buttons["Settings"].tap()
        app.buttons["chatGPTSettingsLink"].tap()
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openCredits(in: app)
        XCTAssertTrue(app.staticTexts["catalogCreditsOfflineNotice"].exists)
        XCTAssertEqual(app.staticTexts["catalogCreditSource-free-exercise-db"].label, "free-exercise-db")
        XCTAssertTrue(app.staticTexts["catalogLicenseScope-free-exercise-db"].exists)
        keepScreenshot(of: app, named: "Bundled catalog credits without sign-in")

        let licenseLink = app.buttons["catalogFullLicenseLink-free-exercise-db"]
        scrollTo(licenseLink, in: app)
        licenseLink.tap()
        XCTAssertTrue(app.navigationBars["Unlicense"].waitForExistence(timeout: 5))
        let license = app.staticTexts["catalogFullLicenseText-free-exercise-db"]
        XCTAssertTrue(license.waitForExistence(timeout: 5))
        XCTAssertTrue(license.label.contains("This is free and unencumbered software released into the public domain."))
        XCTAssertTrue(license.label.contains("THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND"))
        XCTAssertTrue(license.label.contains("For more information, please refer to <https://unlicense.org>"))
        keepScreenshot(of: app, named: "Bundled Unlicense full text")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Credits & Licenses"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["catalogCreditsSettingsLink"].exists)
    }

    @MainActor
    func testCreditsExposePinnedRevisionAndReviewLimitsAtAccessibilityTextSize() {
        let app = launchApp(largeText: true)
        defer { app.terminate() }
        app.tabBars.buttons["Settings"].tap()
        openCredits(in: app)

        let revision = app.staticTexts["catalogSourceRevision-free-exercise-db"]
        scrollTo(revision, in: app)
        XCTAssertEqual(revision.label, "f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5")
        keepScreenshot(of: app, named: "Pinned catalog revision with accessibility text")

        let review = app.staticTexts["catalogReviewStatus-free-exercise-db"]
        scrollTo(review, in: app)
        XCTAssertEqual(review.label, "Awaiting content review")
        let reviewNote = app.staticTexts["catalogReviewNote-free-exercise-db"]
        scrollTo(reviewNote, in: app)
        XCTAssertFalse(reviewNote.label.isEmpty)
        keepScreenshot(of: app, named: "Catalog content review with accessibility text")

        let excludedPhotos = app.staticTexts["catalogExcludedContent-free-exercise-db"]
        scrollTo(excludedPhotos, in: app)
        XCTAssertTrue(excludedPhotos.label.contains("Photographs are not bundled or downloaded"))
        keepScreenshot(of: app, named: "Excluded catalog photographs with accessibility text")
    }

    @MainActor
    private func launchApp(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openCredits(in app: XCUIApplication) {
        let link = app.buttons["catalogCreditsSettingsLink"]
        scrollTo(link, in: app)
        link.tap()
        XCTAssertTrue(app.navigationBars["Credits & Licenses"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 where !element.isHittable { app.swipeUp() }
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
