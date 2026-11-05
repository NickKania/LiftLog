import XCTest

final class WorkoutShareUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testHistoryShareFormatsAndSystemSheet() {
        let app = launchHistory()
        defer { app.terminate() }
        app.buttons["shareWorkoutButton"].tap()
        let preview = app.images["workoutSharePreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("4 completed sets, 28 reps"))
        XCTAssertTrue(preview.label.contains("4,540 lb × reps"))
        XCTAssertTrue(preview.label.contains("Exercises: Bench Press · Barbell Row"))
        let storyHeight = preview.frame.height
        app.buttons["Square · 1:1"].tap()
        let square = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(preview.frame.height - preview.frame.width) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [square], timeout: 5), .completed)
        XCTAssertLessThan(preview.frame.height, storyHeight)
        XCTAssertFalse(preview.label.contains("Exercises:"))
        app.buttons["shareWorkoutImageButton"].tap()
        XCTAssertTrue(app.navigationBars["Workout statistics"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSummaryShareDoneReturnsToHistory() {
        let app = launchHistory()
        defer { app.terminate() }
        let summary = app.buttons["workoutSummaryHistoryButton"]
        for _ in 0..<5 {
            if summary.exists && summary.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        summary.tap()
        XCTAssertTrue(app.buttons["shareWorkoutSummaryButton"].waitForExistence(timeout: 5))
        app.buttons["shareWorkoutSummaryButton"].tap()
        XCTAssertTrue(app.images["workoutSharePreview"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutShareButton"].tap()
        XCTAssertTrue(app.buttons["closeWorkoutSummaryButton"].waitForExistence(timeout: 5))
        app.buttons["closeWorkoutSummaryButton"].tap()
        XCTAssertTrue(app.buttons["shareWorkoutButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVoiceOverVolumeMatchesCardPrecision() {
        let app = launchHistory(workoutName: "Fixture Lower Body")
        defer { app.terminate() }
        app.buttons["shareWorkoutButton"].tap()
        let preview = app.images["workoutSharePreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Volume 2,503.8 kg × reps"), preview.label)
    }

    @MainActor
    func testLongNameAndOverflowPreviewFormats() {
        let name = "Full Body Strength Training with Heavy Compound Lifts and Accessory Exercises for Upper Body Lower Body and Core Conditioning"
        let app = launchHistory(workoutName: name, extraArguments: [
            "--workout-share-long-name-ui-fixture", "--workout-share-overflow-ui-fixture"
        ])
        defer { app.terminate() }
        app.buttons["shareWorkoutButton"].tap()
        let preview = app.images["workoutSharePreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("20 completed sets, 160 reps"))
        XCTAssertTrue(preview.label.contains("Alternate Hammer Curl"))
        for format in ["Story · 9:16", "Square · 1:1"] {
            app.buttons[format].tap()
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Long name and exercise overflow – \(format)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func launchHistory(workoutName: String = "Fixture Upper Body", extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "--health-dashboard-ui-fixture",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launchArguments += extraArguments
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["History"].waitForExistence(timeout: 10))
        app.tabBars.buttons["History"].tap()
        app.buttons.matching(NSPredicate(format: "identifier == %@", "historyWorkout-\(workoutName)")).firstMatch.tap()
        XCTAssertTrue(app.buttons["shareWorkoutButton"].waitForExistence(timeout: 5))
        return app
    }
}
