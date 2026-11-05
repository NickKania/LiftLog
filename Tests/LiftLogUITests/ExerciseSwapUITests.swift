import XCTest

/// Replacements affect one explicit entry; saved plans and completed results stay independent.
final class ExerciseSwapUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTemplateReplacementCancellationVersionSavingAndOriginalVersionSurviveRelaunch() {
        let app = launchApp()
        defer { app.terminate() }
        createTemplate(named: "Swap Versions", in: app)
        openNewestPlan(in: app)
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled)

        openSwap(for: "Bench Press", in: app)
        cancelSwap(in: app)
        assertExercise("Bench Press", active: false, in: app)
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled)

        openSwap(for: "Bench Press", in: app)
        reviewReplacement("Overhead Press", in: app)
        XCTAssertEqual(app.staticTexts["exerciseSwapOriginalName"].label, "Bench Press")
        XCTAssertEqual(app.staticTexts["exerciseSwapReplacementName"].label, "Overhead Press")
        keepScreenshot(of: app, named: "Template replacement review before explicit confirmation")
        tap("exerciseSwapConfirmButton", in: app)
        assertExercise("Overhead Press", active: false, in: app)
        reveal(app.textFields["setWeight-1"], in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "0")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "8")
        XCTAssertTrue(app.buttons["saveTemplateButton"].isEnabled)
        app.navigationBars["Plan Next Workout"].buttons["Cancel"].tap()

        openNewestPlan(in: app)
        assertExercise("Bench Press", active: false, in: app)
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled, "Canceling the parent discards the replacement draft")
        openSwap(for: "Bench Press", in: app)
        reviewReplacement("Overhead Press", in: app)
        tap("exerciseSwapConfirmButton", in: app)
        XCTAssertEqual(app.buttons["saveTemplateButton"].label, "Save Version")
        app.buttons["saveTemplateButton"].tap()

        relaunch(app)
        XCTAssertEqual(newestControl(prefix: "currentTemplateVersion-", type: .staticText, in: app).label, "Version 2 · Default")
        openNewestPlan(in: app)
        assertExercise("Overhead Press", active: false, in: app)
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled)
        app.navigationBars["Plan Next Workout"].buttons["Cancel"].tap()
        let versions = newestControl(prefix: "templateVersions-", in: app)
        reveal(versions, in: app)
        versions.tap()
        tap("templateVersion-1", in: app)
        tap("startTemplateVersion-1", in: app)
        assertExercise("Bench Press", active: true, in: app)
        reveal(app.textFields["setWeight-1"], in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "80")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "8")
        XCTAssertTrue(app.staticTexts["setTargetWeight-1"].label.contains("80"), "Version 1 keeps its original prescription")
    }

    @MainActor
    func testActiveReplacementRequiresConfirmationClearsTargetsAndLeavesSourcePlanUnchanged() {
        let app = launchApp()
        defer { app.terminate() }
        createTemplate(named: "Swap Session", in: app)
        startNewestTemplate(in: app)
        reveal(app.textFields["setWeight-1"], in: app)
        XCTAssertTrue(app.staticTexts["setTargetWeight-1"].exists)
        openSwap(for: "Bench Press", active: true, in: app)
        reviewReplacement("Overhead Press", in: app)
        cancelSwap(in: app)
        assertExercise("Bench Press", active: true, in: app)
        reveal(app.textFields["setWeight-1"], in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "80")
        XCTAssertTrue(app.staticTexts["setTargetWeight-1"].exists)

        openSwap(for: "Bench Press", active: true, in: app)
        reviewReplacement("Overhead Press", in: app)
        tap("exerciseSwapConfirmButton", in: app)
        assertExercise("Overhead Press", active: true, in: app)
        assertUnplannedReplacement(in: app)
        keepScreenshot(of: app, named: "Active replacement starts at zero load without original targets")
        relaunch(app)
        tap("resumeWorkoutButton", in: app)
        assertExercise("Overhead Press", active: true, in: app)
        assertUnplannedReplacement(in: app)
        tap("minimizeWorkoutButton", in: app)
        openNewestPlan(in: app)
        assertExercise("Bench Press", active: false, in: app)
        reveal(app.textFields["setWeight-1"], in: app)
        XCTAssertEqual(app.textFields["setWeight-1"].value as? String, "80")
        XCTAssertFalse(app.buttons["saveTemplateButton"].isEnabled, "An active replacement must not edit its source plan")
    }

    @MainActor
    func testExerciseWithCompletedSetCannotBeReplaced() {
        let app = launchApp()
        defer { app.terminate() }
        createTemplate(named: "Protected Completed Set", in: app)
        startNewestTemplate(in: app)
        tap("completeSet-1", in: app)
        let menu = exerciseMenu("Bench Press", active: true, in: app)
        reveal(menu, in: app)
        menu.tap()
        let replace = app.buttons["replaceExerciseButton"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        XCTAssertFalse(replace.isEnabled, "Recorded sets must remain attached to the exercise actually performed")
        keepScreenshot(of: app, named: "Replacement disabled for an exercise with a completed set")
    }

    /// Run in light and dark appearance; screenshots preserve the real accessible UI.
    @MainActor
    func testReplacementSearchAndReviewAtAccessibilityTextSize() {
        let app = launchApp(largeText: true)
        defer { app.terminate() }
        beginTemplate(named: "Accessible Replacement", in: app)
        addBenchPress(in: app)
        openSwap(for: "Bench Press", in: app)
        keepScreenshot(of: app, named: "Similar movements replacement picker accessibility XXXL")
        search("OHP", in: app)
        let candidate = replacementCandidate("Overhead Press", in: app)
        reveal(candidate, in: app)
        XCTAssertTrue(candidate.isHittable)
        keepScreenshot(of: app, named: "Replacement alias search accessibility XXXL")
        candidate.tap()
        let replacement = app.staticTexts["exerciseSwapReplacementName"]
        reveal(replacement, in: app)
        XCTAssertEqual(replacement.label, "Overhead Press")
        keepScreenshot(of: app, named: "Replacement review accessibility XXXL")
        let confirm = app.buttons["exerciseSwapConfirmButton"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isHittable)
        keepScreenshot(of: app, named: "Replacement consequences and confirmation accessibility XXXL")
        cancelSwap(in: app)
        assertExercise("Bench Press", active: false, in: app)
    }

    @MainActor
    private func launchApp(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
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
    private func beginTemplate(named name: String, in app: XCUIApplication) {
        app.buttons["createTemplateButton"].tap()
        let field = app.textFields["templateNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Done"].tap()
    }

    @MainActor
    private func createTemplate(named name: String, in app: XCUIApplication) {
        beginTemplate(named: name, in: app)
        addBenchPress(in: app)
        replaceText(in: app.textFields["setWeight-1"], with: "80", app: app)
        replaceText(in: app.textFields["setReps-1"], with: "8", app: app)
        app.buttons["Done"].tap()
        app.buttons["saveTemplateButton"].tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func addBenchPress(in app: XCUIApplication) {
        tap("addExerciseButton", in: app)
        search("Bench Press", in: app)
        tap("exercise-Bench Press", in: app)
        assertExercise("Bench Press", active: false, in: app)
    }

    @MainActor
    private func openNewestPlan(in app: XCUIApplication) {
        let plan = newestControl(prefix: "planTemplate-", in: app)
        reveal(plan, in: app)
        plan.tap()
        XCTAssertTrue(app.navigationBars["Plan Next Workout"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func startNewestTemplate(in app: XCUIApplication) {
        let start = newestControl(prefix: "startTemplate-", in: app)
        reveal(start, in: app)
        start.tap()
        XCTAssertTrue(app.buttons["finishWorkoutButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func newestControl(prefix: String, type: XCUIElement.ElementType = .button, in app: XCUIApplication) -> XCUIElement {
        let controls = app.descendants(matching: type).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        XCTAssertGreaterThan(controls.count, 0)
        return controls.element(boundBy: max(0, controls.count - 1))
    }

    @MainActor
    private func exerciseMenu(_ name: String, active: Bool, in app: XCUIApplication) -> XCUIElement {
        let label = active ? "Options for \(name)" : "Exercise options for \(name)"
        return app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", label, active ? "workoutExerciseMenu-" : "templateExerciseMenu-")).firstMatch
    }

    @MainActor
    private func assertExercise(_ name: String, active: Bool, in app: XCUIApplication) {
        let menu = exerciseMenu(name, active: active, in: app)
        reveal(menu, in: app)
        XCTAssertTrue(menu.isHittable)
    }

    @MainActor
    private func openSwap(for name: String, active: Bool = false, in app: XCUIApplication) {
        let menu = exerciseMenu(name, active: active, in: app)
        reveal(menu, in: app)
        menu.tap()
        let replace = app.buttons["replaceExerciseButton"]
        XCTAssertTrue(replace.waitForExistence(timeout: 5))
        XCTAssertTrue(replace.isEnabled)
        replace.tap()
        XCTAssertTrue(app.buttons["exerciseSwapCancelButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func cancelSwap(in app: XCUIApplication) {
        let review = app.navigationBars["Review Replacement"]
        let navigation = review.exists ? review : app.navigationBars["Replace Exercise"]
        navigation.buttons["exerciseSwapCancelButton"].firstMatch.tap()
    }

    @MainActor
    private func replacementCandidate(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", "Review replacement with \(name)", "exerciseSwapCandidate-")).firstMatch
    }

    @MainActor
    private func reviewReplacement(_ name: String, in app: XCUIApplication) {
        search(name, in: app)
        let candidate = replacementCandidate(name, in: app)
        reveal(candidate, in: app)
        candidate.tap()
        XCTAssertTrue(app.staticTexts["exerciseSwapReplacementName"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func assertUnplannedReplacement(in app: XCUIApplication) {
        let weight = app.textFields["setWeight-1"]
        reveal(weight, in: app)
        XCTAssertEqual(weight.value as? String, "0")
        XCTAssertEqual(app.textFields["setReps-1"].value as? String, "8")
        XCTAssertFalse(app.staticTexts["setTargetWeight-1"].exists)
        XCTAssertFalse(app.staticTexts["setTargetReps-1"].exists)
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        reveal(field, in: app)
        let current = field.value as? String ?? ""
        // These short numeric fixture fields do not always expose Select All.
        // Tap their trailing inside edge to place the caret after the last digit,
        // then erase the complete actual value rather than its placeholder.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty && current != field.placeholderValue {
            let clear = field.buttons["Clear text"]
            XCTAssertTrue(clear.waitForExistence(timeout: 5))
            clear.tap()
        }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
        field.typeText("\n")
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        reveal(element, in: app)
        element.tap()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.isHittable { return }
        let surface = scrollSurface(in: app)
        // Search lower content first unless an existing element's frame shows
        // it is above the visible list. Dragging down at the top of a sheet can
        // dismiss it, so do not start with an unconditional downward swipe.
        let targetFrame = element.exists ? element.frame : .zero
        let scrollDownFirst = targetFrame != .zero && targetFrame.maxY < surface.frame.minY + 80
        for _ in 0..<15 {
            if scrollDownFirst { surface.swipeDown() } else { surface.swipeUp() }
            if element.isHittable { return }
        }
        for _ in 0..<15 {
            if scrollDownFirst { surface.swipeUp() } else { surface.swipeDown() }
            if element.isHittable { return }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func scrollSurface(in app: XCUIApplication) -> XCUIElement {
        let identifier: String?
        if app.navigationBars["Review Replacement"].exists {
            identifier = "exerciseSwapReviewList"
        } else if app.navigationBars["Replace Exercise"].exists {
            identifier = "exerciseSwapList"
        } else if app.navigationBars["New Template"].exists || app.navigationBars["Plan Next Workout"].exists {
            identifier = "templateEditor"
        } else if app.buttons["finishWorkoutButton"].exists {
            identifier = "activeWorkoutEditor"
        } else {
            identifier = nil
        }
        if let identifier {
            let list = app.collectionViews[identifier]
            // XCTest often reports SwiftUI List itself as not hittable while
            // its children are visible. Its identifier still scopes scrolling.
            if list.exists { return list }
        }
        return app
    }

    @MainActor
    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
