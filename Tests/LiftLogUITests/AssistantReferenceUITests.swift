import XCTest

final class AssistantReferenceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSelectedWorkoutTagContainsWrappedLabel() throws {
        try assertSelectedWorkoutTagLayout(largeText: false)
    }

    @MainActor
    func testSelectedWorkoutTagContainsWrappedLabelWithLargeText() throws {
        try assertSelectedWorkoutTagLayout(largeText: true)
    }

    @MainActor
    private func assertSelectedWorkoutTagLayout(largeText: Bool) throws {
        let app = launchFixture(largeText: largeText)
        enterDraft("Based on my morning workout, what should be my new target rep counts/weights for my next workout?", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let key = selectRow(named: "Recorded Fixture Workout 1", kind: "workout", in: app)
        finishPicker(in: app)

        let tags = app.scrollViews["assistantSelectedReferences"]
        let label = element("assistantSelectedReference.\(key)", in: app)
        let remove = app.buttons["assistantRemoveReference.\(key)"]
        XCTAssertTrue(label.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: largeText ? "Wrapped workout tag with large text" : "Wrapped workout tag")
        XCTAssertGreaterThanOrEqual(label.frame.minY - tags.frame.minY, 6, "The tag must leave space above its wrapped label")
        XCTAssertGreaterThanOrEqual(tags.frame.maxY - label.frame.maxY, 6, "The tag must contain the complete date subtitle with bottom padding")
        XCTAssertTrue(app.frame.contains(label.frame), "The complete tag label must remain onscreen")
        XCTAssertGreaterThanOrEqual(label.frame.minY, app.navigationBars.firstMatch.frame.maxY, "The tag must stay below navigation")
        XCTAssertLessThanOrEqual(label.frame.maxY + 6, app.textFields["assistantComposer"].frame.minY, "The tag must leave the question field visible")
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertFalse(label.exists)
        XCTAssertTrue(app.textFields["assistantComposer"].isHittable)
    }

    @MainActor
    func testSearchAndSendIncludesTemplateAndExactCompletedWorkoutData() throws {
        let app = launchFixture()
        enterDraft("Compare these selected records", in: app)

        openPicker(in: app)
        search("Upper", in: app)
        let templateKey = selectRow(named: "Upper Body", kind: "template", in: app)
        XCTAssertEqual(referenceRows(in: app).count, 1, "Search should exclude unrelated templates and workouts")
        finishPicker(in: app)
        XCTAssertTrue(element("assistantSelectedReference.\(templateKey)", in: app).exists)

        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let workoutKey = selectRow(named: "Recorded Fixture Workout 1", kind: "workout", in: app)
        XCTAssertEqual(referenceRows(in: app).count, 2, "The session has distinct workout and Apple Health tags")
        finishPicker(in: app)
        XCTAssertTrue(element("assistantSelectedReference.\(workoutKey)", in: app).exists)
        XCTAssertEqual(app.textFields["assistantComposer"].value as? String, "Compare these selected records")
        sendDraft(in: app)

        assertResponse("Received 2 selected records.", in: app)
        let templateID = recordID(in: templateKey)
        assertResponse("Received template Upper Body; id: \(templateID); record id: \(templateID); status: template; unit: lb; exercises: 4.", in: app)
        assertResponse("Template set Bench Press: 0 lb × 8 target reps; 3 sets.", in: app)
        let workoutID = recordID(in: workoutKey)
        assertResponse("Received workout Recorded Fixture Workout 1; id: \(workoutID); record id: \(workoutID); status: completed; unit: lb; exercises: 1.", in: app)
        assertResponse("Workout source: assistant-ui-fixture-0.", in: app)
        assertResponse("Workout set Bench Press: 135 lb × 8 reps; completed true; 1 sets.", in: app)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Received workout Recorded Fixture Workout 2;")).firstMatch.exists)

        let transcriptTemplate = element("assistantMessageReference.\(templateKey)", in: app)
        reveal(transcriptTemplate, in: app)
        XCTAssertTrue(transcriptTemplate.label.contains("Upper Body"))
        let transcriptWorkout = element("assistantMessageReference.\(workoutKey)", in: app)
        reveal(transcriptWorkout, in: app)
        XCTAssertTrue(transcriptWorkout.label.contains("Recorded Fixture Workout 1"))
        XCTAssertTrue(transcriptWorkout.label.contains("Completed workout"))
        XCTAssertFalse(element("assistantSelectedReference.\(templateKey)", in: app).exists)
        XCTAssertFalse(element("assistantSelectedReference.\(workoutKey)", in: app).exists)
        keepScreenshot(of: app, named: "Submitted template and completed workout tags")
    }

    @MainActor
    func testCancelMentionSearchPreservesDraftAndRemovalExcludesReferenceFromRequest() throws {
        let app = launchFixture()
        enterDraft("Keep this question", in: app)
        openPicker(in: app)
        search("Upper", in: app)
        let templateKey = selectRow(named: "Upper Body", kind: "template", in: app)
        finishPicker(in: app)

        let composer = app.textFields["assistantComposer"]
        composer.tap()
        composer.typeText(" @")
        XCTAssertTrue(app.textFields["assistantReferenceSearch"].waitForExistence(timeout: 5), "Typing a standalone @ should open the picker")
        search("No such fixture record", in: app)
        XCTAssertTrue(element("assistantReferenceNoResults", in: app).waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        search("Recorded Fixture Workout 1", in: app)
        let cancelledWorkoutKey = selectRow(named: "Recorded Fixture Workout 1", kind: "workout", in: app)
        app.buttons["assistantReferencePickerCancelButton"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, "Keep this question @")
        XCTAssertTrue(element("assistantSelectedReference.\(templateKey)", in: app).exists)
        XCTAssertFalse(element("assistantSelectedReference.\(cancelledWorkoutKey)", in: app).exists)

        app.buttons["assistantRemoveReference.\(templateKey)"].tap()
        XCTAssertFalse(element("assistantSelectedReference.\(templateKey)", in: app).exists)
        XCTAssertEqual(composer.value as? String, "Keep this question @")
        sendDraft(in: app)
        assertResponse("Received 0 selected records.", in: app)
        XCTAssertFalse(element("assistantMessageReference.\(templateKey)", in: app).exists)
        XCTAssertFalse(element("assistantMessageReference.\(cancelledWorkoutKey)", in: app).exists)
    }

    @MainActor
    func testNewChatClearsDraftTagsAndSendsOnlyNewSelection() throws {
        let app = launchFixture()
        enterDraft("Start a conversation", in: app)
        sendDraft(in: app)
        assertResponse("Received 0 selected records.", in: app)

        enterDraft("Discard this draft", in: app)
        openPicker(in: app)
        search("Upper", in: app)
        let oldTemplateKey = selectRow(named: "Upper Body", kind: "template", in: app)
        finishPicker(in: app)
        XCTAssertTrue(element("assistantSelectedReference.\(oldTemplateKey)", in: app).exists)
        app.buttons["assistantNewChatButton"].tap()

        XCTAssertTrue(element("assistantEmptyState", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("assistantSelectedReference.\(oldTemplateKey)", in: app).exists)
        XCTAssertFalse(app.staticTexts["Received 0 selected records."].exists)
        XCTAssertFalse(app.buttons["assistantSendButton"].isEnabled)
        XCTAssertNotEqual(app.textFields["assistantComposer"].value as? String, "Discard this draft")

        enterDraft("Inspect the second workout", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 2", in: app)
        let newWorkoutKey = selectRow(named: "Recorded Fixture Workout 2", kind: "workout", in: app)
        finishPicker(in: app)
        sendDraft(in: app)
        assertResponse("Received 1 selected records.", in: app)
        let workoutID = recordID(in: newWorkoutKey)
        assertResponse("Received workout Recorded Fixture Workout 2; id: \(workoutID); record id: \(workoutID); status: completed; unit: lb; exercises: 1.", in: app)
        assertResponse("Workout source: assistant-ui-fixture-1.", in: app)
        assertResponse("Workout set Bench Press: 145 lb × 8 reps; completed true; 1 sets.", in: app)
        XCTAssertFalse(element("assistantMessageReference.\(oldTemplateKey)", in: app).exists)
        reveal(element("assistantMessageReference.\(newWorkoutKey)", in: app), in: app)
    }

    @MainActor
    func testHealthTagReadsOnlyOnSendAndExpiresAfterMessage() throws {
        let app = launchFixture()
        enterDraft("Review my session heart rate", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let healthKey = selectRow(named: "Apple Health · Recorded Fixture Workout 1", kind: "health", in: app)
        let workoutRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantReferenceRow.workout:"))
        XCTAssertEqual(workoutRows.count, 1)
        XCTAssertEqual(workoutRows.firstMatch.value as? String, "Not selected", "A Health tag must not select the workout tag")
        finishPicker(in: app)
        XCTAssertTrue(element("assistantSelectedReference.\(healthKey)", in: app).label.contains("Apple Health"))
        XCTAssertTrue(element("assistantComposerPrivacyDisclosure", in: app).label.contains("shares it with OpenAI for this message"))
        sendDraft(in: app)
        assertResponse("Health reads: 1.", in: app)
        assertResponse("Received 1 Health snapshots for this message.", in: app)
        assertResponse("Health Recorded Fixture Workout 1: heartRate readings 120, 140.", in: app)
        reveal(element("assistantMessageReference.\(healthKey)", in: app), in: app)
        XCTAssertFalse(element("assistantSelectedReference.\(healthKey)", in: app).exists)

        enterDraft("What about the next session?", in: app)
        sendDraft(in: app)
        assertResponse("Received 0 Health snapshots for this message.", in: app)
        XCTAssertFalse(app.staticTexts["Health reads: 2."].exists)
        keepScreenshot(of: app, named: "Explicit Health tag and untagged follow-up")
    }

    @MainActor
    func testCancelRemoveAndNewChatDiscardHealthConsentWithoutReading() throws {
        let app = launchFixture()
        enterDraft("Review the workout only", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let canceledKey = selectRow(named: "Apple Health · Recorded Fixture Workout 1", kind: "health", in: app)
        app.buttons["assistantReferencePickerCancelButton"].tap()
        XCTAssertFalse(element("assistantSelectedReference.\(canceledKey)", in: app).exists)

        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let removedKey = selectRow(named: "Apple Health · Recorded Fixture Workout 1", kind: "health", in: app)
        finishPicker(in: app)
        app.buttons["assistantRemoveReference.\(removedKey)"].tap()
        XCTAssertFalse(element("assistantSelectedReference.\(removedKey)", in: app).exists)

        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        let workoutKey = selectRow(named: "Recorded Fixture Workout 1", kind: "workout", in: app)
        finishPicker(in: app)
        sendDraft(in: app)
        assertResponse("Received 1 selected records.", in: app)
        assertResponse("Health reads: 0.", in: app)
        assertResponse("Received 0 Health snapshots for this message.", in: app)
        XCTAssertFalse(element("assistantMessageReference.\(removedKey)", in: app).exists)
        reveal(element("assistantMessageReference.\(workoutKey)", in: app), in: app)

        enterDraft("Discard this Health draft", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        _ = selectRow(named: "Apple Health · Recorded Fixture Workout 1", kind: "health", in: app)
        finishPicker(in: app)
        app.buttons["assistantNewChatButton"].tap()
        XCTAssertTrue(element("assistantEmptyState", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("assistantSelectedReference.\(removedKey)", in: app).exists)
        enterDraft("Plain new message", in: app)
        sendDraft(in: app)
        assertResponse("Health reads: 0.", in: app)
        assertResponse("Received 0 selected records.", in: app)
    }

    @MainActor
    func testHealthChartUsesSessionReadingsAndHealthPresentation() throws {
        let app = launchFixture(additionalArguments: ["--assistant-health-chart-ui-fixture"])
        enterDraft("Chart the selected session heart rate", in: app)
        openPicker(in: app)
        search("Recorded Fixture Workout 1", in: app)
        _ = selectRow(named: "Apple Health · Recorded Fixture Workout 1", kind: "health", in: app)
        finishPicker(in: app)
        sendDraft(in: app)
        reveal(element("assistantWorkoutChart", in: app), in: app)
        XCTAssertFalse(app.segmentedControls["assistantChartRangePicker"].exists)
        reveal(element("assistantChartSelectedValue", in: app), in: app)
        XCTAssertEqual(element("assistantChartSelectedValue", in: app).label, "140")
        XCTAssertTrue(app.staticTexts["bpm"].exists)
        let source = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Source: Apple Health in tagged workout sessions")).firstMatch
        reveal(source, in: app)
        XCTAssertTrue(source.label.contains("Average heart rate per interval"))
        reveal(app.buttons["assistantChartPreviousButton"], in: app)
        app.buttons["assistantChartPreviousButton"].tap()
        XCTAssertEqual(element("assistantChartSelectedValue", in: app).label, "120")
        keepScreenshot(of: app, named: "Apple Health session heart rate chart")
    }

    @MainActor
    private func launchFixture(largeText: Bool = false, additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--assistant-ui-fixture", "--assistant-reference-ui-fixture"] + additionalArguments
        if largeText {
            app.launchArguments += ["--assistant-dark-ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Assistant"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Assistant"].tap()
        let gotIt = app.buttons["assistantWelcomeGotItButton"]
        if gotIt.waitForExistence(timeout: 2) { gotIt.tap() }
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func enterDraft(_ text: String, in app: XCUIApplication) {
        let composer = app.textFields["assistantComposer"]
        composer.tap()
        composer.typeText(text)
    }

    @MainActor
    private func sendDraft(in app: XCUIApplication) {
        let send = app.buttons["assistantSendButton"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        send.tap()
    }

    @MainActor
    private func openPicker(in app: XCUIApplication) {
        app.buttons["assistantAddReferenceButton"].tap()
        XCTAssertTrue(app.textFields["assistantReferenceSearch"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication) {
        let search = app.textFields["assistantReferenceSearch"]
        search.tap()
        search.typeText(text)
    }

    @MainActor
    private func referenceRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "assistantReferenceRow."))
    }

    @MainActor
    private func selectRow(named name: String, kind: String, in app: XCUIApplication) -> String {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", "assistantReferenceRow.\(kind):", name + ",")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let key = String(row.identifier.dropFirst("assistantReferenceRow.".count))
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertEqual(row.value as? String, "Selected")
        return key
    }

    @MainActor
    private func finishPicker(in app: XCUIApplication) {
        app.buttons["assistantReferencePickerDoneButton"].tap()
        XCTAssertTrue(app.textFields["assistantComposer"].waitForExistence(timeout: 5))
    }

    private func recordID(in key: String) -> String {
        String(key.split(separator: ":", maxSplits: 1).last!)
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func assertResponse(_ text: String, in app: XCUIApplication) {
        let response = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        reveal(response, in: app)
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        _ = element.waitForExistence(timeout: 5)
        let transcript = app.scrollViews.firstMatch
        for _ in 0..<8 where !element.isHittable { transcript.swipeDown() }
        for _ in 0..<10 where !element.isHittable { transcript.swipeUp() }
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
