import XCTest

final class WorkoutHistoryEditingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCorrectionDraftReviewPersistenceAndUndo() {
        let app = launch(populated: true)
        defer { app.terminate() }
        openFirstWorkout(in: app)
        app.buttons["editHistoryWorkoutButton"].tap()
        let name = app.textFields["historyEditorNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replaceName(name, with: "Discard this draft", in: app)
        app.buttons["cancelHistoryEditorButton"].tap()
        XCTAssertTrue(app.navigationBars["Fixture Upper Body"].waitForExistence(timeout: 5))
        app.buttons["editHistoryWorkoutButton"].tap()
        replaceName(name, with: "Corrected Upper", in: app)
        replace(app.descendants(matching: .any)["historyEditorNotesField"], with: "Synthetic session note")
        app.buttons["Done"].firstMatch.tap()
        let weight = app.textFields["setWeight-1"].firstMatch
        scrollTo(weight, in: app)
        replace(weight, with: "77")
        let reps = app.textFields["setReps-1"].firstMatch
        replace(reps, with: "9")
        let secondWeight = app.textFields["setWeight-2"].firstMatch
        XCTAssertNotEqual(secondWeight.value as? String, "77", "Only the edited row changes")
        app.buttons["Done"].firstMatch.tap()
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "historyEditorExerciseNotes-")).firstMatch
        scrollTo(note, in: app)
        replace(note, with: "Synthetic exercise note")
        app.buttons["Done"].firstMatch.tap()
        attach("History correction editor", app: app)
        app.buttons["reviewHistoryWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["saveHistoryWorkoutButton"].waitForExistence(timeout: 5))
        attach("Correction review", app: app)
        app.buttons["saveHistoryWorkoutButton"].tap()
        XCTAssertTrue(app.navigationBars["Corrected Upper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic session note"].exists)
        attach("Corrected workout detail", app: app)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--health-dashboard-ui-fixture"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        app.buttons["historyWorkout-Corrected Upper"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synthetic session note"].waitForExistence(timeout: 5))
        let result = app.staticTexts["77 lb × 9"]
        scrollTo(result, in: app)
        XCTAssertTrue(result.exists)
        app.buttons["undoHistoryCorrectionButton"].tap()
        let undo = app.buttons["Restore Previous Record"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        attach("Undo correction confirmation", app: app)
        undo.tap()
        XCTAssertTrue(app.navigationBars["Fixture Upper Body"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["undoHistoryCorrectionButton"].exists)
        app.terminate()
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(app.buttons["historyWorkout-Corrected Upper"].exists)
        XCTAssertTrue(app.buttons["historyWorkout-Fixture Upper Body"].firstMatch.exists)
    }

    @MainActor
    func testManualCompletedHistoryEntry() {
        let app = launch(populated: false)
        defer { app.terminate() }
        attach("Empty history with manual entry", app: app)
        app.buttons["addPastWorkoutButton"].tap()
        XCTAssertTrue(app.textFields["historyEditorNameField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["reviewHistoryWorkoutButton"].isEnabled)
        replace(app.textFields["historyEditorNameField"], with: "Manual Past Session")
        app.buttons["addHistoryExerciseButton"].tap()
        let search = app.searchFields["Find or create an exercise"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Bench Press")
        let add = app.buttons.matching(identifier: "exercise-Bench Press").firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let weight = app.textFields["setWeight-1"].firstMatch
        scrollTo(weight, in: app)
        replace(weight, with: "95")
        replace(app.textFields["setReps-1"].firstMatch, with: "0")
        XCTAssertFalse(app.buttons["reviewHistoryWorkoutButton"].isEnabled)
        attach("Invalid completed set", app: app)
        replace(app.textFields["setReps-1"].firstMatch, with: "5")
        app.buttons["Done"].firstMatch.tap()
        app.buttons["reviewHistoryWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["saveHistoryWorkoutButton"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.textFields["setWeight-1"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["reviewHistoryWorkoutButton"].tap()
        app.buttons["saveHistoryWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["historyWorkout-Manual Past Session"].waitForExistence(timeout: 5))
        app.buttons["historyWorkout-Manual Past Session"].tap()
        XCTAssertTrue(app.staticTexts["95 lb × 5"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["undoHistoryCorrectionButton"].exists)
        attach("Manual past workout", app: app)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["historyWorkout-Manual Past Session"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRenameWorkoutOverSevenDaysPreservesDurationAndUndoAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--history-long-workout-ui-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        app.tabBars.buttons["History"].tap()
        let original = app.buttons["historyWorkout-Eight-day Workout"]
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.swipeLeft()
        app.buttons["Rename"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replace(field, with: "Renamed Long Workout")
        app.alerts.buttons["saveHistoryWorkoutNameButton"].firstMatch.tap()
        let renamed = app.buttons["historyWorkout-Renamed Long Workout"]
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.tap()
        XCTAssertTrue(app.staticTexts["Duration, 11520 min 0 sec"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic workout left open for eight days."].exists)
        attach("Renamed eight-day workout", app: app)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-ui-testing" }
        app.launch()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        renamed.tap()
        XCTAssertTrue(app.staticTexts["Duration, 11520 min 0 sec"].waitForExistence(timeout: 5))
        app.buttons["undoHistoryCorrectionButton"].tap()
        let undo = app.buttons["Restore Previous Record"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.navigationBars["Eight-day Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Duration, 11520 min 0 sec"].exists)
        XCTAssertFalse(app.buttons["undoHistoryCorrectionButton"].exists)
        attach("Restored eight-day workout", app: app)
    }

    @MainActor
    private func launch(populated: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--health-dashboard-ui-fixture") }
        app.launch()
        app.tabBars.buttons["History"].tap()
        return app
    }

    @MainActor
    private func openFirstWorkout(in app: XCUIApplication) {
        let row = app.buttons["historyWorkout-Fixture Upper Body"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    @MainActor
    private func replaceName(_ field: XCUIElement, with text: String, in app: XCUIApplication) {
        field.tap()
        field.press(forDuration: 1.1)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select All")).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }

    @MainActor
    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String)?.count ?? 0) + text)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let editor = app.collectionViews["historyWorkoutEditor"]
            let list = editor.exists ? editor : app.collectionViews.allElementsBoundByIndex.last ?? app.collectionViews.firstMatch
            let above = element.exists && element.frame.maxY < list.frame.minY + 80
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.3 : 0.7))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
