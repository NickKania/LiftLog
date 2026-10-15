import XCTest

/// All exercise guidance uses isolated offline catalog and personal-step data.
final class ExerciseInstructionsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testDefaultStepsAreReadableWithoutReviewOrAddingTheExercise() {
        let app = launchApp()
        defer { app.terminate() }
        openDetail("Bench Press", in: app)

        let firstStep = instructionStep(1, in: app)
        scrollTo(firstStep, in: app)
        XCTAssertTrue(firstStep.label.contains("Lie back on a flat bench"))
        XCTAssertEqual(app.staticTexts["exerciseInstructionsSource"].label, "Default steps")
        XCTAssertFalse(app.staticTexts["exerciseInstructionsUnavailable"].exists)
        XCTAssertFalse(app.staticTexts["Instructions await review"].exists)
        XCTAssertTrue(app.buttons["editExerciseInstructionsButton"].exists)
        keepScreenshot(of: app, named: "Default exercise steps visible offline")

        app.navigationBars["Exercise Details"].buttons.firstMatch.tap()
        app.buttons["exercisePickerCancelButton"].tap()
        XCTAssertTrue(app.navigationBars["New Template"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove Bench Press"].exists)
    }

    @MainActor
    func testPersonalEditCancellationPersistenceAndResetDraftSemantics() {
        let app = launchApp()
        defer { app.terminate() }
        openDetail("Bench Press", in: app)
        openEditor(in: app)
        replaceText(in: instructionField(1, in: app), with: "My saved bench setup.", app: app)
        app.buttons["saveExerciseInstructionsButton"].tap()
        assertFirstStep("My saved bench setup.", source: "Your personal steps", in: app)

        relaunch(app)
        openDetail("Bench Press", in: app)
        assertFirstStep("My saved bench setup.", source: "Your personal steps", in: app)
        openEditor(in: app)
        replaceText(in: instructionField(1, in: app), with: "Unsaved change.", app: app)
        app.buttons["cancelExerciseInstructionsButton"].tap()
        assertFirstStep("My saved bench setup.", source: "Your personal steps", in: app)

        openEditor(in: app)
        resetDraft(in: app)
        XCTAssertTrue((instructionField(1, in: app).value as? String ?? "").contains("Lie back on a flat bench"))
        app.buttons["cancelExerciseInstructionsButton"].tap()
        assertFirstStep("My saved bench setup.", source: "Your personal steps", in: app)

        openEditor(in: app)
        resetDraft(in: app)
        app.buttons["saveExerciseInstructionsButton"].tap()
        let restored = instructionStep(1, in: app)
        scrollTo(restored, in: app)
        XCTAssertTrue(restored.label.contains("Lie back on a flat bench"))
        XCTAssertEqual(app.staticTexts["exerciseInstructionsSource"].label, "Default steps")
        relaunch(app)
        openDetail("Bench Press", in: app)
        scrollTo(restored, in: app)
        XCTAssertTrue(restored.label.contains("Lie back on a flat bench"))
        XCTAssertEqual(app.staticTexts["exerciseInstructionsSource"].label, "Default steps")
    }

    @MainActor
    func testMissingDefaultsSupportValidationAddingRemovingAndReorderingPersonalSteps() {
        let app = launchApp()
        defer { app.terminate() }
        openDetail("Iron Cross", in: app)
        let unavailable = app.staticTexts["exerciseInstructionsUnavailable"]
        scrollTo(unavailable, in: app)
        XCTAssertEqual(unavailable.label, "No default steps available")
        let add = app.buttons["addExerciseInstructionsButton"]
        scrollTo(add, in: app)
        add.tap()
        XCTAssertTrue(app.buttons["saveExerciseInstructionsButton"].waitForExistence(timeout: 5))

        app.buttons["saveExerciseInstructionsButton"].tap()
        let error = app.alerts["Unable to save"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "A blank step must be rejected without dismissing the draft")
        keepScreenshot(of: app, named: "Empty personal instruction validation")
        error.buttons["OK"].tap()
        let first = instructionField(1, in: app)
        first.tap()
        first.typeText("Set up carefully.")
        tap("addExerciseInstructionButton", in: app)
        let second = instructionField(2, in: app)
        scrollTo(second, in: app)
        second.tap()
        second.typeText("Check the position.")
        app.toolbars.buttons["Done"].tap()
        tap("moveExerciseInstructionUp-2", in: app)
        // Resolve each field by its current position after reordering.
        XCTAssertEqual(instructionField(1, in: app).value as? String, "Check the position.")
        XCTAssertEqual(instructionField(2, in: app).value as? String, "Set up carefully.")
        tap("addExerciseInstructionButton", in: app)
        tap("deleteExerciseInstruction-3", in: app)
        XCTAssertFalse(instructionField(3, in: app).exists)
        app.buttons["saveExerciseInstructionsButton"].tap()
        assertFirstStep("Check the position.", source: "Your personal steps", in: app)
        XCTAssertEqual(instructionStep(2, in: app).label, "Step 2. Set up carefully.")
        XCTAssertFalse(app.staticTexts["exerciseInstructionsUnavailable"].exists)
        keepScreenshot(of: app, named: "Personal instructions for exercise without defaults")

        relaunch(app)
        openDetail("Iron Cross", in: app)
        assertFirstStep("Check the position.", source: "Your personal steps", in: app)
        XCTAssertEqual(instructionStep(2, in: app).label, "Step 2. Set up carefully.")
    }

    /// Repeat in both appearances; attachments capture actual accessible detail/editor layouts.
    @MainActor
    func testInstructionsAndEditorAtAccessibilityTextSize() {
        let app = launchApp(largeText: true)
        defer { app.terminate() }
        openDetail("Bench Press", in: app)
        scrollTo(instructionStep(1, in: app), in: app)
        keepScreenshot(of: app, named: "Default exercise steps accessibility XXXL")
        openEditor(in: app)
        let first = instructionField(1, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Exercise instruction editor accessibility XXXL")
        scrollTo(app.buttons["addExerciseInstructionButton"], in: app)
        keepScreenshot(of: app, named: "Exercise instruction editor controls accessibility XXXL")
        app.buttons["cancelExerciseInstructionsButton"].tap()
        XCTAssertTrue(app.navigationBars["Exercise Details"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchApp(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // A prior test runner may have left a process alive with different fixtures.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func openDetail(_ name: String, in app: XCUIApplication) {
        app.buttons["createTemplateButton"].tap()
        tap("addExerciseButton", in: app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(name + "\n")
        tap("exerciseInfo-\(name)", in: app)
        XCTAssertTrue(app.staticTexts["exerciseDetailName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["exerciseDetailName"].label, name)
    }

    @MainActor
    private func openEditor(in app: XCUIApplication) {
        let edit = app.buttons["editExerciseInstructionsButton"]
        scrollTo(edit, in: app, upward: false)
        edit.tap()
        XCTAssertTrue(app.buttons["saveExerciseInstructionsButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func resetDraft(in app: XCUIApplication) {
        tap("resetExerciseInstructionsButton", in: app)
        let reset = app.buttons["resetExerciseInstructionsConfirmButton"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        let first = instructionField(1, in: app)
        scrollTo(first, in: app, upward: false)
    }

    @MainActor
    private func assertFirstStep(_ text: String, source: String, in app: XCUIApplication) {
        let first = instructionStep(1, in: app)
        XCTAssertTrue(app.navigationBars["Exercise Details"].waitForExistence(timeout: 5))
        scrollTo(first, in: app)
        XCTAssertEqual(first.label, "Step 1. " + text)
        XCTAssertEqual(app.staticTexts["exerciseInstructionsSource"].label, source)
    }

    @MainActor
    private func instructionStep(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        // The numbered row is one VoiceOver element, including its full step label.
        app.descendants(matching: .any).matching(identifier: "exerciseInstructionStep-\(number)").firstMatch
    }

    @MainActor
    private func instructionField(_ number: Int, in app: XCUIApplication) -> XCUIElement {
        // SwiftUI multiline TextField may expose a text field or text view by OS.
        app.descendants(matching: .any).matching(identifier: "exerciseInstructionField-\(number)").firstMatch
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        scrollTo(field, in: app)
        field.tap()
        field.press(forDuration: 1.1)
        // The native edit menu exposes this as a cell/static text on newer iOS
        // and as a menu item on earlier systems. Match its semantic action label.
        let selectAll = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), "Use native selection to replace the entire value regardless of cursor position")
        selectAll.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        scrollTo(button, in: app)
        button.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<18 {
            if element.isHittable { return }
            if app.buttons["saveExerciseInstructionsButton"].exists {
                // A center swipe can scroll inside a multiline instruction field.
                // Drag the editor's trailing margin to scroll its containing list.
                let list = app.collectionViews["exerciseInstructionsEditor"]
                let surface = list.exists ? list : app
                let startY = upward ? 0.75 : 0.25
                let endY = upward ? 0.25 : 0.75
                let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: startY))
                let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: endY))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else if upward {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
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
