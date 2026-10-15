import XCTest

final class ExerciseOrderUITests: XCTestCase {
    @MainActor
    func testCancelSaveRelaunchAndFutureTemplateWorkoutOrder() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing"]
        app.launch()
        defer { app.terminate() }
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(app.buttons["reorderExercisesButton"].waitForExistence(timeout: 5))
        app.buttons["reorderExercisesButton"].tap()
        XCTAssertFalse(app.buttons["saveExerciseOrderButton"].isEnabled)
        assertOrder(["Bench Press", "Barbell Row", "Overhead Press", "Dumbbell Curl"], in: app)
        moveCurlToTop(in: app)
        XCTAssertTrue(app.buttons["saveExerciseOrderButton"].isEnabled)
        app.buttons["cancelExerciseOrderButton"].tap()
        app.buttons["reorderExercisesButton"].tap()
        assertOrder(["Bench Press", "Barbell Row", "Overhead Press", "Dumbbell Curl"], in: app)
        XCTAssertFalse(app.buttons["saveExerciseOrderButton"].isEnabled)
        moveCurlToTop(in: app)
        app.buttons["saveExerciseOrderButton"].tap()
        let firstExercise = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workoutExerciseMenu-")).firstMatch
        XCTAssertTrue(firstExercise.waitForExistence(timeout: 5))
        XCTAssertEqual(firstExercise.label, "Options for Dumbbell Curl")
        XCTAssertTrue(app.staticTexts["activeWorkoutTemplateVersion"].label.contains("1"))

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["reorderExercisesButton"].waitForExistence(timeout: 5))
        app.buttons["reorderExercisesButton"].tap()
        assertOrder(["Dumbbell Curl", "Bench Press", "Barbell Row", "Overhead Press"], in: app)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Saved workout exercise order"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["cancelExerciseOrderButton"].tap()
        app.swipeUp()
        app.swipeUp()
        let discard = app.buttons["discardWorkoutButton"]
        for _ in 0..<6 where !discard.isHittable { app.swipeUp() }
        discard.tap()
        app.buttons["Discard Workout"].firstMatch.tap()
        XCTAssertTrue(app.buttons["createTemplateButton"].waitForExistence(timeout: 5))
        let version = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "currentTemplateVersion-")).firstMatch
        XCTAssertEqual(version.label, "Version 2 · Default")
        start.tap()
        XCTAssertTrue(app.staticTexts["activeWorkoutTemplateVersion"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["activeWorkoutTemplateVersion"].label, "Template version 2")
        app.buttons["reorderExercisesButton"].tap()
        assertOrder(["Dumbbell Curl", "Bench Press", "Barbell Row", "Overhead Press"], in: app)
    }

    @MainActor
    private func moveCurlToTop(in app: XCUIApplication) {
        let handle = app.buttons["Reorder Dumbbell Curl"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let target = row("Bench Press", in: app)
        handle.press(forDuration: 0.5, thenDragTo: target)
        assertOrder(["Dumbbell Curl", "Bench Press", "Barbell Row", "Overhead Press"], in: app)
    }

    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", name, "reorderExercise-")).firstMatch
    }

    @MainActor
    private func assertOrder(_ names: [String], in app: XCUIApplication) {
        let ordered = names.map { row($0, in: app) }
        for row in ordered { XCTAssertTrue(row.waitForExistence(timeout: 5)) }
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(pair.0.frame.minY, pair.1.frame.minY)
        }
    }
}
