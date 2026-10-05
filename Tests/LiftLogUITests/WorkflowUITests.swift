import XCTest

/// User-facing validation, exercise discovery, destructive actions, and preferences.
final class WorkflowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTemplateRequiresValidNameExerciseAndRepsAndCancelDoesNotSave() {
        let app = launchFreshApp()
        defer { app.terminate() }
        app.buttons["createTemplateButton"].tap()
        let save = app.buttons["saveTemplateButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)

        let name = app.textFields["templateNameField"]
        replaceText(in: name, with: "   ", app: app)
        addBenchPress(in: app)
        XCTAssertFalse(save.isEnabled, "Whitespace is not a template name")
        replaceText(in: name, with: "Cancelled Routine", app: app)
        XCTAssertTrue(save.isEnabled)

        let reps = app.textFields["setReps-1"]
        replaceText(in: reps, with: "0", app: app)
        XCTAssertTrue(app.staticTexts["Enter a weight of 0 or more and at least 1 rep."].exists)
        XCTAssertFalse(save.isEnabled, "Invalid reps must prevent saving")
        replaceText(in: reps, with: "8", app: app)
        XCTAssertTrue(save.isEnabled)
        app.navigationBars["New Template"].buttons["Cancel"].tap()

        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Cancelled Routine"].exists)
    }

    @MainActor
    func testSearchFiltersCatalogAndCustomExerciseSurvivesRelaunch() {
        let app = launchFreshApp()
        defer { app.terminate() }
        app.buttons["startEmptyWorkoutButton"].tap()
        app.buttons["addExerciseButton"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("bEnCh")
        XCTAssertTrue(app.buttons["exercise-Bench Press"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exercise-Squat"].exists)
        app.buttons["exercise-Bench Press"].tap()
        XCTAssertTrue(app.textFields["setWeight-1"].waitForExistence(timeout: 5))

        app.buttons["addExerciseButton"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Workflow Sled Push")
        XCTAssertTrue(app.buttons["addCustomExerciseButton"].waitForExistence(timeout: 5))
        app.buttons["addCustomExerciseButton"].tap()
        XCTAssertTrue(app.buttons["addSet-Workflow Sled Push"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["addSet-Workflow Sled Push"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addSet-Bench Press"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "setWeight-1").count, 2, "Both selected exercises must retain their logged sets")
    }

    @MainActor
    func testDiscardRequiresConfirmationAndDoesNotCreateHistory() {
        let app = launchFreshApp()
        defer { app.terminate() }
        app.buttons["startEmptyWorkoutButton"].tap()
        let finish = app.buttons["finishWorkoutButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertFalse(finish.isEnabled)
        addBenchPress(in: app)
        let complete = app.buttons["completeSet-1"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        XCTAssertFalse(finish.isEnabled)
        complete.tap()
        XCTAssertTrue(finish.isEnabled)

        app.buttons["discardWorkoutButton"].tap()
        let confirmDiscard = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Discard Workout", "discardWorkoutButton")).firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // Newer iOS versions expose a dedicated outside-tap dismissal region.
            app.otherElements["PopoverDismissRegion"].tap()
        }
        XCTAssertTrue(confirmDiscard.waitForNonExistence(timeout: 5))
        XCTAssertEqual(complete.label, "Mark set 1 incomplete", "Cancel must preserve logged sets")
        app.buttons["discardWorkoutButton"].tap()
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.tap()
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeWorkoutButton"].exists)

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["startEmptyWorkoutButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["resumeWorkoutButton"].exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Build your history"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnitPreferencePersistsWhileActiveWorkoutKeepsRecordedUnit() {
        let app = launchFreshApp()
        defer { app.terminate() }
        app.buttons["startEmptyWorkoutButton"].tap()
        addBenchPress(in: app)
        let weight = app.textFields["setWeight-1"]
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertEqual(weight.label, "Weight for set 1, lb")
        app.buttons["minimizeWorkoutButton"].tap()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["weightUnitPicker"].tap()
        app.buttons["Kilograms (kg)"].tap()
        app.tabBars.buttons["Workout"].tap()

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["weightUnitPicker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["weightUnitPicker"].label.contains("Kilograms"))
        app.tabBars.buttons["Workout"].tap()
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertEqual(weight.label, "Weight for set 1, lb")
        app.buttons["minimizeWorkoutButton"].tap()
        app.buttons["createTemplateButton"].tap()
        addBenchPress(in: app)
        XCTAssertTrue(weight.waitForExistence(timeout: 5))
        XCTAssertEqual(weight.label, "Weight for set 1, kg", "New template inputs must use the saved preference")
    }

    @MainActor
    func testTemplateVersionsPreserveOldPlanAndWorkoutTargets() {
        let app = launchFreshApp()
        defer { app.terminate() }
        let plan = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "planTemplate-")).firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(app.navigationBars["Plan Next Workout"].waitForExistence(timeout: 5))
        let save = app.buttons["saveTemplateButton"]
        XCTAssertFalse(save.isEnabled, "A version must contain a change")
        replaceText(in: app.textFields["setReps-1"].firstMatch, with: "9", app: app)
        app.navigationBars["Plan Next Workout"].buttons["Cancel"].tap()
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        let currentVersion = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "currentTemplateVersion-")).firstMatch
        XCTAssertEqual(currentVersion.label, "Version 1 · Default", "Cancelling must not save a version")

        plan.tap()
        replaceText(in: app.textFields["setWeight-1"].firstMatch, with: "140", app: app)
        replaceText(in: app.textFields["setReps-1"].firstMatch, with: "9", app: app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        XCTAssertEqual(currentVersion.label, "Version 2 · Default")
        let versions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "templateVersions-")).firstMatch
        versions.tap()
        XCTAssertTrue(app.buttons["templateVersion-2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["templateVersion-1"].exists)
        app.buttons["templateVersion-1"].tap()
        app.buttons["startTemplateVersion-1"].tap()
        XCTAssertTrue(app.staticTexts["activeWorkoutTemplateVersion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["activeWorkoutTemplateVersion"].label, "Template version 1")
        XCTAssertEqual(app.staticTexts["setTargetWeight-1"].firstMatch.label, "Target: 0 lb")
        XCTAssertEqual(app.staticTexts["setTargetReps-1"].firstMatch.label, "Target: 8")
        replaceText(in: app.textFields["setWeight-1"].firstMatch, with: "135", app: app)
        replaceText(in: app.textFields["setReps-1"].firstMatch, with: "7", app: app)
        XCTAssertEqual(app.staticTexts["setTargetWeight-1"].firstMatch.label, "Target: 0 lb")
        XCTAssertEqual(app.staticTexts["setTargetReps-1"].firstMatch.label, "Target: 8")
        app.buttons["completeSet-1"].firstMatch.tap()
        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        app.tabBars.buttons["History"].tap()
        app.buttons["historyWorkout-Upper Body"].tap()
        XCTAssertTrue(app.staticTexts["historySetPlan-1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["historySetPlan-1"].label, "Planned: 0 lb × 8")
        XCTAssertTrue(app.staticTexts["135 lb × 7"].exists)
    }

    @MainActor
    private func launchFreshApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func addBenchPress(in app: XCUIApplication) {
        app.buttons["addExerciseButton"].tap()
        let bench = app.buttons["exercise-Bench Press"]
        XCTAssertTrue(bench.waitForExistence(timeout: 5))
        bench.tap()
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) {
        field.tap()
        let current = field.value as? String ?? ""
        // Empty text fields expose their placeholder as value; only delete actual input.
        let count = current == field.placeholderValue ? 0 : current.count
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
        app.buttons["Done"].tap()
    }
}
