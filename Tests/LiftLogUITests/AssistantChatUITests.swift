import XCTest

final class AssistantChatUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testGeneratedTitlesCanBeRenamedAndRichChatsReopenAfterRelaunch() throws {
        let app = launchFixture()
        send("Chart my training volume", in: app)
        let chart = app.descendants(matching: .any)["assistantWorkoutChart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        openChats(in: app)
        let chartRow = chatRow(titled: "Training volume history", in: app)
        XCTAssertTrue(chartRow.waitForExistence(timeout: 10), "Luna should name the conversation")
        let chartID = id(of: chartRow)
        rename(chatID: chartID, to: "My saved progress", in: app)
        app.buttons["assistantChatListNewButton"].tap()
        send("Show formatting", in: app)
        XCTAssertTrue(app.staticTexts["Your training, in perspective"].waitForExistence(timeout: 10))
        openChats(in: app)
        let markdownRow = chatRow(titled: "Training summary", in: app)
        XCTAssertTrue(markdownRow.waitForExistence(timeout: 10))
        let markdownID = id(of: markdownRow)
        app.buttons["assistantChat.\(chartID)"].tap()
        reveal(app.buttons["assistantShareChartButton"], in: app)
        XCTAssertTrue(chart.exists)
        XCTAssertTrue(app.staticTexts["Source: completed sets in 2 recorded workouts."].exists)
        XCTAssertTrue(app.buttons["assistantShareChartButton"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture", "--assistant-chat-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        reveal(app.buttons["assistantShareChartButton"], in: app)
        XCTAssertTrue(chart.exists)
        openChats(in: app)
        XCTAssertTrue(chatRow(titled: "My saved progress", in: app).exists)
        app.buttons["assistantChat.\(markdownID)"].tap()
        reveal(app.staticTexts["Your training, in perspective"], in: app)
        XCTAssertTrue(app.buttons["Copy response"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "## ")).firstMatch.exists)
        reveal(app.staticTexts["volume = weight × completed reps"], in: app)
        XCTAssertTrue(app.buttons["Copy code"].exists)
        keepScreenshot(of: app, named: "Saved markdown chat after relaunch")
    }

    @MainActor
    func testTwoChatsRunIndependentlyAndCancelOnlySelectedChat() throws {
        let app = launchFixture(concurrent: true)
        send("Chart my training volume", in: app)
        XCTAssertTrue(app.buttons["assistantCancelButton"].waitForExistence(timeout: 5))
        app.buttons["assistantNewChatButton"].tap()
        send("Show formatting", in: app)
        openChats(in: app)
        let chartRow = chatRow(titled: "Chart my training volume", in: app)
        let markdownRow = chatRow(titled: "Show formatting", in: app)
        XCTAssertTrue(chartRow.waitForExistence(timeout: 5))
        XCTAssertTrue(markdownRow.waitForExistence(timeout: 5))
        let chartID = id(of: chartRow)
        let markdownID = id(of: markdownRow)
        XCTAssertTrue(app.descendants(matching: .any)["assistantChatWorking.\(chartID)"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["assistantChatWorking.\(markdownID)"].firstMatch.exists)
        keepScreenshot(of: app, named: "Two assistant chats running at once")
        chartRow.tap()
        app.buttons["assistantCancelButton"].tap()
        XCTAssertTrue(app.buttons["assistantSendButton"].waitForExistence(timeout: 5))
        openChats(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["assistantChatWorking.\(chartID)"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["assistantChatWorking.\(markdownID)"].firstMatch.exists)
        app.buttons["assistantChat.\(markdownID)"].tap()
        XCTAssertTrue(app.staticTexts["Your training, in perspective"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["assistantSendButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testReviewedProposalStatusReopensAfterRelaunch() throws {
        let app = launchFixture()
        send("Create a routine", in: app)
        let apply = app.buttons["assistantApplyProposalButton"]
        reveal(apply, in: app)
        apply.tap()
        XCTAssertTrue(app.staticTexts["Applied"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture", "--assistant-chat-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        reveal(app.staticTexts["Applied"], in: app)
        XCTAssertFalse(app.buttons["assistantApplyProposalButton"].exists)
    }

    @MainActor
    func testSavedChatDeletionCanBeCancelledAndPersistsAfterRelaunch() throws {
        let app = launchFixture()
        send("Show formatting", in: app)
        XCTAssertTrue(app.staticTexts["Your training, in perspective"].waitForExistence(timeout: 10))
        openChats(in: app)
        let row = chatRow(titled: "Training summary", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let chatID = id(of: row)
        row.swipeLeft()
        app.buttons["assistantDeleteChat.\(chatID)"].tap()
        XCTAssertTrue(app.alerts["Delete chat?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        row.swipeLeft()
        app.buttons["assistantDeleteChat.\(chatID)"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 2))
        XCTAssertTrue(chatRow(titled: "New chat", in: app).exists)
        app.buttons["assistantChatListDoneButton"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].exists)
        XCTAssertFalse(app.staticTexts["Your training, in perspective"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--assistant-ui-fixture", "--assistant-chat-ui-fixture"]
        app.launch()
        app.tabBars.buttons["Assistant"].tap()
        openChats(in: app)
        XCTAssertFalse(app.buttons["assistantChat.\(chatID)"].exists)
        XCTAssertTrue(chatRow(titled: "New chat", in: app).exists)
    }

    @MainActor
    private func launchFixture(concurrent: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--assistant-ui-fixture", "--assistant-chat-ui-fixture"]
        if concurrent { app.launchArguments.append("--assistant-concurrent-ui-fixture") }
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
    private func openChats(in app: XCUIApplication) {
        app.buttons["assistantChatsButton"].tap()
        XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func chatRow(titled title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "assistantChat.", title)).firstMatch
    }

    @MainActor
    private func id(of row: XCUIElement) -> String {
        String(row.identifier.dropFirst("assistantChat.".count))
    }

    @MainActor
    private func rename(chatID: String, to title: String, in app: XCUIApplication) {
        app.buttons["assistantRenameChat.\(chatID)"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0) + title)
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(chatRow(titled: title, in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 10)
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<20 {
            if element.exists && element.isHittable { return }
            let viewport = transcript.frame
            let delta = element.exists ? viewport.midY - element.frame.midY : viewport.height
            let distance = min(max(abs(delta), 44), viewport.height * 0.35)
            let start = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
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
