import XCTest

/// Synthetic on-device inference only. These tests never require Apple Intelligence,
/// a ChatGPT account, live inference, or personal Health readings.
final class FoundationModelsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testProviderSettingsExplainsPreservedUnreadableArchive() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--foundation-models-ui-fixture",
                               "--foundation-models-corrupt-archive-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let picker = app.buttons["assistantProviderPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Apple Intelligence"].tap()
        let error = element("assistantProviderStorageError", in: app)
        reveal(error, in: app)
        XCTAssertTrue(error.label.contains("preserved"))
        XCTAssertTrue(picker.label.contains("ChatGPT"), "An unreadable archive must not be overwritten by a provider change")
        keepScreenshot(of: app, named: "Provider settings explains preserved unreadable archive")
    }

    @MainActor
    func testSignedOutAssistantExplainsBlockedProviderSwitchForUnreadableArchive() {
        assertBlockedAssistantProviderSwitch(additionalArguments: [], screenshotName: "Signed-out Assistant explains blocked provider switch")
    }

    @MainActor
    func testUnavailableProviderSelectionExplainsBlockedSwitchForUnreadableArchive() {
        assertBlockedAssistantProviderSwitch(additionalArguments: ["--foundation-models-unavailable-ui-fixture"],
                                             screenshotName: "Unavailable provider selection explains chat storage block")
    }

    @MainActor
    func testOnDeviceAnswerNeedsNoChatGPTAccountAndSwitchingClearsDraftAndTags() {
        let app = launchFixture()
        XCTAssertTrue(element("assistantOnDeviceBadge", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["continueWithChatGPTButton"].exists)
        XCTAssertFalse(app.buttons["assistantModelPicker"].exists)
        send("Hello", in: app)
        XCTAssertTrue(app.buttons["Copy response"].waitForExistence(timeout: 5))
        app.buttons["assistantChatsButton"].tap()
        XCTAssertTrue(app.buttons["assistantChatListNewButton"].waitForExistence(timeout: 5))
        app.buttons["assistantChatListNewButton"].tap()

        let composer = app.textFields["assistantComposer"]
        composer.tap()
        composer.typeText("Discard this local draft")
        selectHealthTag(in: app)
        XCTAssertTrue(element("assistantComposerPrivacyDisclosure", in: app).label.contains("processes it on this iPhone"))
        XCTAssertFalse(element("assistantComposerPrivacyDisclosure", in: app).label.contains("OpenAI"))
        chooseProvider("ChatGPT", in: app)
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(composer.exists)
        chooseProvider("Apple Intelligence", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertNotEqual(composer.value as? String, "Discard this local draft")
        XCTAssertFalse(app.buttons["assistantSendButton"].isEnabled)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantRemoveReference.")).firstMatch.exists)
        keepScreenshot(of: app, named: "On-device assistant after explicit provider switch")
    }

    @MainActor
    func testOnDeviceChartsAndReviewedEditsUseRecordedWorkouts() {
        let app = launchFixture()
        send("Chart my training volume", in: app)
        let chart = element("assistantWorkoutChart", in: app)
        reveal(chart, in: app)
        reveal(app.buttons["assistantShareChartButton"], in: app)
        XCTAssertTrue(app.staticTexts["Source: completed sets in 2 recorded workouts."].exists)
        keepScreenshot(of: app, named: "On-device chart from recorded workouts")

        app.buttons["assistantNewChatButton"].tap()
        send("Create a routine", in: app)
        let apply = app.buttons["assistantApplyProposalButton"]
        reveal(apply, in: app)
        XCTAssertTrue(app.staticTexts["BEFORE"].exists)
        XCTAssertTrue(app.staticTexts["AFTER"].exists)
        app.tabBars.buttons["Workout"].tap()
        XCTAssertFalse(app.staticTexts["Assistant Fixture Routine"].exists)
        app.tabBars.buttons["Assistant"].tap()
        reveal(apply, in: app)
        keepScreenshot(of: app, named: "On-device proposal awaiting explicit Apply")
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        let routine = app.staticTexts["Assistant Fixture Routine"]
        for _ in 0..<5 where !routine.isHittable { app.swipeUp() }
        XCTAssertTrue(routine.exists)
    }

    @MainActor
    func testOnDeviceControlsAndChartRemainReachableAtAccessibilityTextSize() {
        let app = launchFixture(additionalArguments: ["--assistant-dark-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        send("Chart my training volume", in: app)
        let transcript = app.scrollViews.firstMatch
        XCTAssertGreaterThanOrEqual(transcript.frame.minX, app.frame.minX - 1)
        XCTAssertLessThanOrEqual(transcript.frame.maxX, app.frame.maxX + 1)
        let previous = app.buttons["assistantChartPreviousButton"]
        reveal(previous, in: app)
        previous.tap()
        XCTAssertEqual(app.staticTexts["assistantChartSelectedValue"].label, "1,080")
        keepScreenshot(of: app, named: "On-device chart controls at accessibility XXXL")
        chooseProvider("ChatGPT", in: app)
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDiscardedOnDeviceProposalDoesNotSaveTemplate() {
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
    func testOnDeviceHealthDisclosureAndPerMessageConsent() {
        let app = launchFixture(additionalArguments: ["--assistant-reference-ui-fixture"])
        selectHealthTag(in: app)
        let disclosure = element("assistantComposerPrivacyDisclosure", in: app)
        XCTAssertTrue(disclosure.label.contains("on this iPhone for this message"))
        XCTAssertFalse(disclosure.label.contains("OpenAI"))
        send("Review my session heart rate", in: app)
        let health = app.staticTexts["Received 1 Health snapshots for this message."]
        reveal(health, in: app)
        reveal(app.staticTexts["Health Recorded Fixture Workout 1: heartRate readings 120, 140."], in: app)
        keepScreenshot(of: app, named: "On-device Health analysis with explicit per-message consent")
        send("What about the next session?", in: app)
        reveal(app.staticTexts["Received 0 Health snapshots for this message."], in: app)
        XCTAssertFalse(app.staticTexts["Health reads: 2."].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing", "--foundation-models-ui-fixture", "--assistant-reference-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        XCTAssertFalse(health.exists, "Health questions and replies must not survive relaunch")
    }

    @MainActor
    func testProviderSelectionIsSharedWithSettingsAndAccountSheet() {
        let app = launchFixture()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["assistantProviderPicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("assistantSystemModelLabel", in: app).exists)
        chooseProvider("ChatGPT", in: app)
        XCTAssertTrue(app.buttons["assistantDefaultModelPicker"].exists)
        app.tabBars.buttons["Assistant"].tap()
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        app.buttons["assistantAccountButton"].tap()
        XCTAssertTrue(app.navigationBars["Assistant Settings"].waitForExistence(timeout: 5))
        chooseProvider("Apple Intelligence", in: app)
        XCTAssertTrue(element("assistantProviderAvailability", in: app).exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnavailableOnDeviceProviderNeverFallsBackAndWorkoutLoggingWorks() {
        let app = launchFixture(additionalArguments: ["--foundation-models-unavailable-ui-fixture"], available: false)
        let notice = element("assistantLocalUnavailableNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("The on-device model is not ready"))
        XCTAssertFalse(app.textFields["assistantComposer"].exists)
        XCTAssertFalse(app.buttons["continueWithChatGPTButton"].exists, "An unavailable local model must not trigger ChatGPT sign-in")
        XCTAssertTrue(app.buttons["assistantRefreshAvailabilityButton"].exists)
        keepScreenshot(of: app, named: "On-device model not ready without cloud fallback")
        chooseProvider("ChatGPT", in: app)
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Workout"].tap()
        app.buttons["startEmptyWorkoutButton"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnavailableModelKeepsSavedChatReadableWithOneNotice() {
        let app = launchFixture()
        send("Show formatting", in: app)
        XCTAssertTrue(app.buttons["Copy response"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--foundation-models-ui-fixture", "--foundation-models-unavailable-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        let notice = element("assistantLocalUnavailableNotice", in: app)
        reveal(notice, in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "assistantLocalUnavailableNotice").count, 1)
        XCTAssertFalse(element("assistantRequestErrorNotice", in: app).exists, "Model availability should have one dedicated notice, not a duplicate chat error")
        XCTAssertFalse(app.textFields["assistantComposer"].exists)
        reveal(app.staticTexts["Your training, in perspective"], in: app)
        keepScreenshot(of: app, named: "Saved on-device chat with one unavailable notice")
    }

    @MainActor
    private func launchFixture(additionalArguments: [String] = [], available: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--foundation-models-ui-fixture"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Assistant"].tap()
        if available { XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5)) }
        return app
    }

    @MainActor
    private func assertBlockedAssistantProviderSwitch(additionalArguments: [String], screenshotName: String) {
        let app = launchFixture(additionalArguments: ["--foundation-models-corrupt-archive-ui-fixture"] + additionalArguments,
                                available: false)
        let picker = app.buttons["assistantProviderPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        reveal(picker, in: app)
        XCTAssertTrue(picker.label.contains("ChatGPT"))
        picker.tap()
        app.buttons["Apple Intelligence"].tap()
        XCTAssertTrue(picker.label.contains("ChatGPT"), "A failed chat save must preserve the selected provider")
        let error = element("assistantProviderStorageError", in: app)
        reveal(error, in: app)
        XCTAssertTrue(error.label.contains("preserved"))
        XCTAssertTrue(error.label.contains("try choosing the provider again"))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "assistantProviderStorageError").count, 1)
        XCTAssertFalse(element("assistantRequestErrorNotice", in: app).exists)
        XCTAssertFalse(app.textFields["assistantComposer"].exists)
        XCTAssertTrue(app.buttons["continueWithChatGPTButton"].exists)
        keepScreenshot(of: app, named: screenshotName)
    }

    @MainActor
    private func chooseProvider(_ name: String, in app: XCUIApplication) {
        // The presented settings sheet and its covered Assistant both expose the
        // shared control. Act on the visible control, as a user would.
        let matches = app.buttons.matching(identifier: "assistantProviderPicker")
        let picker = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        reveal(picker, in: app)
        picker.tap()
        app.buttons[name].tap()
        XCTAssertTrue(picker.label.contains(name))
    }

    @MainActor
    private func selectHealthTag(in app: XCUIApplication) {
        app.buttons["assistantAddReferenceButton"].tap()
        let search = app.textFields["assistantReferenceSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Recorded Fixture Workout 1")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantReferenceRow.health:")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertEqual(row.value as? String, "Selected")
        let disclosure = app.staticTexts["assistantHealthPickerDisclosure"]
        for _ in 0..<4 where !disclosure.isHittable { app.swipeUp() }
        XCTAssertTrue(disclosure.label.contains("processes available data on this iPhone"))
        XCTAssertFalse(disclosure.label.contains("OpenAI"))
        app.buttons["assistantReferencePickerDoneButton"].tap()
    }

    @MainActor
    private func send(_ question: String, in app: XCUIApplication) {
        let composer = app.textFields["assistantComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText(question)
        let send = app.buttons["assistantSendButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        send.tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        let scrollView = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        // Scroll within the visible gutter. Full-page swipes can land on a chart's
        // selection gesture or overshoot a control in a short large-text viewport.
        for _ in 0..<30 {
            if element.exists && element.isHittable { return }
            let viewport = scrollView.frame.intersection(app.frame)
            guard !viewport.isNull, viewport.height > 0 else { break }
            let delta = element.exists ? viewport.midY - element.frame.midY : viewport.height
            let distance = min(max(abs(delta), 44), viewport.height * 0.35)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.minX - app.frame.minX + 8, dy: viewport.midY - app.frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: delta >= 0 ? distance : -distance))
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
