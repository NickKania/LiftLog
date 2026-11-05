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
    func testDuplicateTargetsAndSupersetsStayIdentifiableAfterMoving() {
        continueAfterFailure = false
        let app = fixtureApp()
        defer { app.terminate() }
        let first = entry("Bench Press", number: 1, in: app)
        let third = entry("Bench Press", number: 3, in: app)
        let fourth = entry("Bench Press", number: 4, in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertTrue((first.value as? String ?? "").contains("100 lb × 5 reps"))
        XCTAssertTrue((first.value as? String ?? "").contains("Superset A"))
        XCTAssertTrue((third.value as? String ?? "").contains("50 lb × 12 reps"))
        XCTAssertTrue((third.value as? String ?? "").contains("No superset"))
        reveal(fourth, in: app)
        XCTAssertTrue((fourth.value as? String ?? "").contains("100 lb × 5 reps"))
        reveal(first, in: app)
        let handle = app.cells.containing(.any, identifier: third.identifier).buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder Bench Press")).firstMatch
        handle.press(forDuration: 0.5, thenDragTo: first)
        XCTAssertLessThan(third.frame.minY, first.frame.minY)
        XCTAssertTrue((first.value as? String ?? "").contains("Superset A"), "Group identity stays with its original member")
        XCTAssertTrue((entry("Barbell Row", number: 2, in: app).value as? String ?? "").contains("Superset A"))
        XCTAssertTrue((third.value as? String ?? "").contains("50 lb × 12 reps"))
        app.buttons["saveExerciseOrderButton"].tap()
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["resumeWorkoutButton"].tap()
        app.buttons["reorderExercisesButton"].tap()
        let reloadedFirst = entry("Bench Press", number: 1, in: app)
        XCTAssertTrue(reloadedFirst.waitForExistence(timeout: 5))
        XCTAssertTrue((reloadedFirst.value as? String ?? "").contains("50 lb × 12 reps"))
        XCTAssertTrue((entry("Bench Press", number: 2, in: app).value as? String ?? "").contains("Superset A"))
    }

    @MainActor
    func testUnlinkedEntriesShowWorkoutOnlyAndDoNotPromiseTemplateUpdate() {
        continueAfterFailure = false
        let app = fixtureApp(unlinked: true)
        defer { app.terminate() }
        XCTAssertTrue((entry("Bench Press", number: 1, in: app).value as? String ?? "").contains("Workout only"))
        let message = app.staticTexts["exerciseOrderTemplateMessage"]
        for _ in 0..<5 where !message.exists || !message.isHittable { app.swipeUp() }
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("this workout only"))
        XCTAssertTrue(message.label.contains("its order will stay the same"))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor
    private func fixtureApp(unlinked: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--exercise-order-ui-fixture"]
        if unlinked { app.launchArguments.append("--exercise-order-unlinked-ui-fixture") }
        app.launch()
        XCTAssertTrue(app.buttons["resumeWorkoutButton"].waitForExistence(timeout: 10))
        app.buttons["resumeWorkoutButton"].tap()
        XCTAssertTrue(app.buttons["reorderExercisesButton"].waitForExistence(timeout: 5))
        app.buttons["reorderExercisesButton"].tap()
        return app
    }

    @MainActor
    private func entry(_ name: String, number: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND identifier BEGINSWITH %@", "\(name), entry \(number)", "reorderExercise-")).firstMatch
    }

    @MainActor
    private func moveCurlToTop(in app: XCUIApplication) {
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder Dumbbell Curl")).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let target = row("Bench Press", in: app)
        handle.press(forDuration: 0.5, thenDragTo: target)
        assertOrder(["Dumbbell Curl", "Bench Press", "Barbell Row", "Overhead Press"], in: app)
    }

    @MainActor
    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier BEGINSWITH %@", name + ", entry ", "reorderExercise-")).firstMatch
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
