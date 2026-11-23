import XCTest

@MainActor
final class SetHeartRateUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testActiveWorkoutSetMarkingTimingAndHistoryPersistence() {
        let app = launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Upper Body"].firstMatch.waitForExistence(timeout: 5))
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "startTemplate-")).firstMatch
        reveal(start, in: app)
        start.tap()

        let firstMenu = app.buttons["setHeartRateMenu-1"].firstMatch
        let timing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Timing set")).firstMatch
        let cancel = app.buttons["cancelSetTimer-1"].firstMatch
        choose("Start Timed Set", from: firstMenu, in: app)
        reveal(cancel, in: app)
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(timing.exists)
        XCTAssertEqual(firstMenu.value as? String, "Marked for heart rate")

        choose("Start Timed Set", from: firstMenu, in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let completeFirst = app.buttons["completeSet-1"].firstMatch
        reveal(completeFirst, in: app)
        completeFirst.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        let secondMenu = app.buttons["setHeartRateMenu-2"].firstMatch
        choose("Mark for Heart Rate", from: secondMenu, in: app)
        XCTAssertEqual(secondMenu.value as? String, "Marked for heart rate")
        let completeSecond = app.buttons["completeSet-2"].firstMatch
        reveal(completeSecond, in: app)
        completeSecond.tap()

        app.buttons["finishWorkoutButton"].tap()
        app.buttons["confirmFinishWorkoutButton"].firstMatch.tap()
        let summary = app.buttons["closeWorkoutSummaryButton"]
        if summary.waitForExistence(timeout: 5) { summary.tap() }

        openHistory("Upper Body", in: app)
        assertSavedSetIndicators(in: app)
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-ui-testing" }
        app.launch()
        openHistory("Upper Body", in: app)
        assertSavedSetIndicators(in: app)
    }

    func testWorkoutDetailHeartRateCorrelationRequiresExplicitLoadAndFiltersSets() {
        let app = launch(withHeartRateFixture: true)
        defer { app.terminate() }
        openHistory("Fixture Upper Body", in: app)

        let load = app.buttons["loadWorkoutHeartRateButton"]
        let chart = element("workoutHeartRateChart", in: app)
        reveal(load, in: app)
        XCTAssertFalse(chart.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        load.tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        reveal(chart, in: app)

        let filter = app.buttons["workoutHeartRateFilterPicker"]
        let next = app.buttons["workoutHeartRateNextSetButton"]
        let previous = app.buttons["workoutHeartRatePreviousSetButton"]
        let estimated = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Est. window")).firstMatch

        reveal(next, in: app)
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(estimated.exists)
        next.tap()
        XCTAssertTrue(previous.isEnabled)
        XCTAssertFalse(next.isEnabled, "The fixture has two marked timed sets.")
        previous.tap()
        XCTAssertFalse(previous.isEnabled)

        for (title, reading) in [("Avg HR", "127 bpm"), ("Peak HR", "148 bpm"), ("60s Recovery", "-22 bpm")] {
            let metric = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, reading)
            ).firstMatch
            reveal(metric, in: app)
        }

        choose("All sets", from: filter, in: app, upward: false)
        reveal(next, in: app)
        next.tap()
        reveal(estimated, in: app)
        XCTAssertTrue(next.isEnabled, "All sets includes the completion-only sets.")
        choose("Marked sets", from: filter, in: app, upward: false)
        reveal(next, in: app)
        XCTAssertFalse(previous.isEnabled)
        XCTAssertFalse(estimated.exists)
    }

    func testHealthDashboardSetHeartRateTrendsRequireExplicitLoadAndResetOnRangeChange() {
        let app = launch(withHeartRateFixture: true)
        defer { app.terminate() }

        let health = app.tabBars.buttons["Health"]
        XCTAssertTrue(health.waitForExistence(timeout: 5))
        health.tap()
        let activity = app.segmentedControls["healthSectionPicker"].buttons["Activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()

        let load = app.buttons["loadSetHeartRateTrendsButton"]
        let chart = element("healthSetHeartRateTrendChart", in: app)
        reveal(load, in: app)
        XCTAssertTrue(load.label.contains("Load Set Heart Rate"))
        XCTAssertFalse(chart.exists)
        load.tap()
        let exercise = app.buttons["healthSetHeartRateExercisePicker"]
        reveal(exercise, in: app)
        reveal(chart, in: app)

        let filter = app.segmentedControls["healthSetHeartRateFilterPicker"]
        let marked = filter.buttons["Marked sets"]
        let all = filter.buttons["All sets"]
        reveal(all, in: app, upward: false)
        XCTAssertTrue(marked.isSelected)
        all.tap()
        XCTAssertTrue(all.isSelected)
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        marked.tap()
        XCTAssertTrue(marked.isSelected)
        XCTAssertTrue(chart.waitForExistence(timeout: 5))

        choose("Month", from: app.buttons["healthDateRangePicker"], in: app, upward: false)
        XCTAssertTrue(chart.waitForNonExistence(timeout: 5))
        XCTAssertFalse(exercise.exists)
        reveal(load, in: app)
        XCTAssertTrue(load.label.contains("Load Set Heart Rate"))
    }

    private func launch(withHeartRateFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if withHeartRateFixture {
            app.launchArguments += ["--health-dashboard-ui-fixture", "--set-heart-rate-ui-fixture"]
        }
        app.launch()
        return app
    }

    private func openHistory(_ workout: String, in app: XCUIApplication) {
        let history = app.tabBars.buttons["History"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let row = app.buttons["historyWorkout-\(workout)"].firstMatch
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars[workout].waitForExistence(timeout: 5))
    }

    private func assertSavedSetIndicators(in app: XCUIApplication) {
        let timed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Timed ")).firstMatch
        reveal(timed, in: app)
        let marked = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Marked for heart rate")
        )
        XCTAssertTrue(marked.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertFalse(element("workoutHeartRateChart", in: app).exists)
    }

    private func choose(_ option: String, from menu: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        reveal(menu, in: app, upward: upward)
        menu.tap()
        let choice = app.buttons[option].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func reveal(_ control: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<10 {
            if control.exists && control.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: upward ? 0.74 : 0.34))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: upward ? 0.34 : 0.74))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(control.exists && control.isHittable, "Could not reveal \(control)")
    }
}
