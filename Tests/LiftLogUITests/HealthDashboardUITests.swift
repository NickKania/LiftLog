import XCTest

final class HealthDashboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyDashboardExplainsHowToCreateTrainingHistory() {
        let app = launchDashboard(populated: false)
        defer { app.terminate() }

        let empty = app.staticTexts["Your training story starts here"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertFalse(element("healthWeekdayChart", in: app).exists)
        selectSection("Weight", in: app)
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(element("healthWeightChart", in: app).exists)
        selectSection("Activity", in: app)
        XCTAssertTrue(empty.exists)
        XCTAssertFalse(app.buttons["loadDashboardHealthButton"].exists)
    }

    @MainActor
    func testConsistencyChartsAndDateRangeReflectCompletedWorkouts() {
        let app = launchDashboard()
        defer { app.terminate() }

        assertValue("healthWorkoutCount", equals: "10", in: app)
        XCTAssertTrue(element("healthWeekdayChart", in: app).exists)
        reveal(element("healthWorkoutHeatmap", in: app), in: app)
        reveal(element("healthDurationMetrics", in: app), in: app)

        selectRange("All time", in: app)
        assertValue("healthWorkoutCount", equals: "12", in: app)
        selectRange("Month", in: app)
        assertValue("healthWorkoutCount", equals: "7", in: app)
        XCTAssertTrue(app.buttons["healthDateRangePicker"].label.contains("Month"))
        keepScreenshot(of: app, named: "Health dashboard month consistency")
    }

    @MainActor
    func testExerciseSelectionAndProgressConvertMixedRecordedUnits() {
        let app = launchDashboard()
        defer { app.terminate() }
        selectRange("All time", in: app)
        selectSection("Weight", in: app)

        selectExercise("Bench Press", in: app)
        XCTAssertTrue(element("healthWeightChart", in: app).exists)
        assertValue("healthWeightSelectedValue", equals: "185 lb", in: app)
        reveal(element("healthExerciseRecords", in: app), in: app)

        selectExercise("Squat", in: app)
        assertValue("healthWeightSelectedValue", equals: "220 lb", in: app)
        selectExercise("Bench Press", in: app)

        app.tabBars.buttons["Settings"].tap()
        app.buttons["weightUnitPicker"].tap()
        app.buttons["Kilograms (kg)"].tap()
        app.tabBars.buttons["Health"].tap()
        assertValue("healthWeightSelectedValue", equals: "83.9 kg", in: app)
        keepScreenshot(of: app, named: "Health exercise progress in kilograms")
    }

    @MainActor
    func testHealthMetricsRequireExplicitLoadAndReloadAfterRangeChange() {
        let app = launchDashboard()
        defer { app.terminate() }
        selectRange("Year", in: app)
        selectSection("Activity", in: app)

        XCTAssertTrue(element("healthWorkoutTimeTotal", in: app).exists)
        let load = app.buttons["loadDashboardHealthButton"]
        reveal(load, in: app)
        XCTAssertTrue(load.label.contains("Load Apple Health"))
        assertLabel("healthCaloriesBurned", contains: "Not loaded", in: app)
        assertLabel("healthAverageHeartRate", contains: "Not loaded", in: app)
        reveal(load, in: app, upward: false)
        load.tap()

        assertLabel("healthCaloriesBurned", contains: "3,540", in: app)
        assertLabel("healthAverageHeartRate", contains: "129.5", in: app)
        XCTAssertTrue(element("healthCaloriesBurned", in: app).label.contains("kcal"))
        XCTAssertTrue(element("healthAverageHeartRate", in: app).label.contains("bpm"))
        XCTAssertFalse(app.alerts.firstMatch.exists, "The synthetic provider must not prompt for HealthKit access.")

        // Both Year and All time include the same twelve fixture sessions. The
        // selected range still changes consent context and must clear readings.
        selectRange("All time", in: app)
        reveal(load, in: app)
        XCTAssertTrue(load.label.contains("Load Apple Health"))
        assertLabel("healthCaloriesBurned", contains: "Not loaded", in: app)
        assertLabel("healthAverageHeartRate", contains: "Not loaded", in: app)
        XCTAssertFalse(element("healthDashboardReadStatus", in: app).exists)
        reveal(load, in: app, upward: false)
        load.tap()
        assertLabel("healthCaloriesBurned", contains: "3,540", in: app)
        assertLabel("healthAverageHeartRate", contains: "129.5", in: app)

        selectRange("Month", in: app)
        reveal(load, in: app)
        XCTAssertTrue(load.label.contains("Load Apple Health"))
        assertLabel("healthCaloriesBurned", contains: "Not loaded", in: app)
        reveal(load, in: app, upward: false)
        load.tap()
        assertLabel("healthCaloriesBurned", contains: "1,890", in: app)
        assertLabel("healthAverageHeartRate", contains: "127", in: app)
        keepScreenshot(of: app, named: "Loaded local Health dashboard readings")
    }

    @MainActor
    func testOverlappingWorkoutsDoNotDoubleCountCaloriesAndExplainCoverage() {
        let app = launchDashboard(overlapping: true)
        defer { app.terminate() }
        selectRange("All time", in: app)
        assertValue("healthWorkoutCount", equals: "13", in: app)
        selectSection("Activity", in: app)
        let load = app.buttons["loadDashboardHealthButton"]
        reveal(load, in: app)
        load.tap()

        assertLabel("healthCaloriesBurned", contains: "3,540", in: app)
        assertLabel("healthCaloriesBurned", contains: "12 of 13 workouts", in: app)
        assertLabel("healthCaloriesOverlapWarning", contains: "1 overlapping workout", in: app)
        keepScreenshot(of: app, named: "Overlapping calorie readings excluded")
    }

    @MainActor
    private func launchDashboard(populated: Bool = true, overlapping: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if populated { app.launchArguments.append("--health-dashboard-ui-fixture") }
        if overlapping { app.launchArguments.append("--health-dashboard-overlap-ui-fixture") }
        app.launch()
        let tab = app.tabBars.buttons["Health"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(element("healthDashboard", in: app).waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func selectSection(_ name: String, in app: XCUIApplication) {
        let picker = app.segmentedControls["healthSectionPicker"]
        reveal(picker, in: app, upward: false)
        picker.buttons[name].tap()
    }

    @MainActor
    private func selectRange(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["healthDateRangePicker"]
        reveal(picker, in: app, upward: false)
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    @MainActor
    private func selectExercise(_ name: String, in app: XCUIApplication) {
        let picker = app.buttons["healthWeightExercisePicker"]
        reveal(picker, in: app, upward: false)
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    @MainActor
    private func assertLabel(_ identifier: String, contains value: String, in app: XCUIApplication) {
        let metric = element(identifier, in: app)
        reveal(metric, in: app)
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", value), object: metric)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "Expected \(identifier) to contain \(value), got \(metric.label)")
    }

    @MainActor
    private func assertValue(_ identifier: String, equals value: String, in app: XCUIApplication) {
        let metric = element(identifier, in: app)
        reveal(metric, in: app)
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: metric)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed,
                       "Expected \(identifier) value \(value), got \(metric.value ?? "nil")")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<8 where !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
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
